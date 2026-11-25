import assert from "node:assert/strict";
import test from "node:test";

import {
  ConcaveClient,
  createRouter,
  effect,
  matchRoute,
} from "../src/index.js";

function makeJwt(payload) {
  const b64url = (obj) =>
    Buffer.from(JSON.stringify(obj))
      .toString("base64")
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
  return `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(payload)}.sig`;
}

class MockWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;
  static instances = [];

  constructor(url) {
    this.url = url;
    this.readyState = MockWebSocket.CONNECTING;
    this.sent = [];
    this._listeners = new Map();
    MockWebSocket.instances.push(this);
  }
  addEventListener(type, fn) {
    if (!this._listeners.has(type)) this._listeners.set(type, []);
    this._listeners.get(type).push(fn);
  }
  emit(type, ev = {}) {
    for (const fn of this._listeners.get(type) ?? []) fn(ev);
  }
  open() {
    this.readyState = MockWebSocket.OPEN;
    this.emit("open");
  }
  send(data) {
    this.sent.push(JSON.parse(data));
  }
  receive(frame) {
    this.emit("message", { data: JSON.stringify(frame) });
  }
  close() {
    this.readyState = MockWebSocket.CLOSED;
  }
  drop() {
    this.readyState = MockWebSocket.CLOSED;
    this.emit("close");
  }
}

const tick = (ms = 20) => new Promise((r) => setTimeout(r, ms));

test("ConcaveClient calls fetchToken on initial connect and reconnect, updating isAuthenticated", async () => {
  MockWebSocket.instances = [];
  const calls = [];
  const nowSec = Math.floor(Date.now() / 1000);
  const jwt1 = makeJwt({ sub: "alice", iss: "concave", exp: nowSec + 3600 });
  const jwt2 = makeJwt({ sub: "alice", iss: "concave", exp: nowSec + 7200 });

  const client = new ConcaveClient("ws://127.0.0.1:9999/ws", {
    webSocketImpl: MockWebSocket,
    protocol: "json",
    fetchToken: async ({ forceRefresh }) => {
      calls.push(forceRefresh);
      return calls.length === 1 ? jwt1 : jwt2;
    },
  });

  assert.equal(client.isAuthenticated(), false);
  assert.equal(client.getToken(), null);

  const q = client.query({ name: "items.list" }, {});
  const ws1 = MockWebSocket.instances[0];
  ws1.open();
  await tick();

  assert.deepEqual(calls, [false]);
  assert.equal(client.getToken(), jwt1);
  assert.equal(ws1.sent[0].type, "authenticate");
  assert.equal(ws1.sent[0].token, jwt1);
  assert.equal(ws1.sent[1].type, "subscribe");

  ws1.receive({
    type: "auth_result",
    ok: true,
    identity: { subject: "alice", issuer: "concave" },
  });
  assert.equal(client.isAuthenticated(), true);
  assert.deepEqual(client.identity(), { subject: "alice", issuer: "concave" });

  // Drop connection and wait for reconnect
  ws1.drop();
  await tick(350);
  assert.equal(MockWebSocket.instances.length, 2);
  const ws2 = MockWebSocket.instances[1];
  ws2.open();
  await tick();

  assert.deepEqual(calls, [false, false]);
  assert.equal(client.getToken(), jwt2);
  assert.equal(ws2.sent[0].type, "authenticate");
  assert.equal(ws2.sent[0].token, jwt2);

  q.dispose();
  client.close();
});

test("ConcaveClient proactively refreshes JWT before exp without wiping cache for same sub", async () => {
  MockWebSocket.instances = [];
  const calls = [];
  const nowSec = Math.floor(Date.now() / 1000);
  // Expires in 5s with 30s margin -> scheduled at Math.max(1000, ...) = 1000ms
  const jwt1 = makeJwt({ sub: "alice", iss: "concave", exp: nowSec + 5 });
  const jwt2 = makeJwt({ sub: "alice", iss: "concave", exp: nowSec + 3600 });

  const client = new ConcaveClient("ws://127.0.0.1:9999/ws", {
    webSocketImpl: MockWebSocket,
    protocol: "json",
    refreshMarginMs: 30_000,
    fetchToken: async ({ forceRefresh }) => {
      calls.push(forceRefresh);
      return forceRefresh ? jwt2 : jwt1;
    },
  });

  const ws = MockWebSocket.instances[0];
  const q = client.query({ name: "messages.list" }, { room: "general" });
  ws.open();
  await tick();

  ws.receive({
    type: "auth_result",
    ok: true,
    identity: { subject: "alice", issuer: "concave" },
  });
  const subFrame = ws.sent.find((f) => f.type === "subscribe");
  ws.receive({
    type: "transition",
    to_ts: 1,
    updates: [{ sub_id: subFrame.sub_id, ok: true, value: ["hello"] }],
  });
  assert.equal(q().status, "ready");
  assert.deepEqual(q().data, ["hello"]);

  // Wait for proactive refresh timer (~1000ms)
  await tick(1150);

  assert.deepEqual(calls, [false, true]);
  assert.equal(client.getToken(), jwt2);
  const authFrames = ws.sent.filter((f) => f.type === "authenticate");
  assert.equal(authFrames.length, 2);
  assert.equal(authFrames[1].token, jwt2);

  // Crucial: same-sub rotation must NOT wipe subscription cache or flicker auth state
  assert.equal(q().status, "ready");
  assert.deepEqual(q().data, ["hello"]);
  assert.equal(client.isAuthenticated(), true);

  q.dispose();
  client.close();
});

test("ConcaveClient retries once on auth_result rejection and clears state if retry also fails", async () => {
  MockWebSocket.instances = [];
  const calls = [];
  const nowSec = Math.floor(Date.now() / 1000);
  const jwtStale = makeJwt({ sub: "alice", exp: nowSec + 3600 });
  const jwtFresh = makeJwt({ sub: "alice", exp: nowSec + 7200 });
  const jwtStillBad = makeJwt({ sub: "alice", exp: nowSec + 7200 });

  let phase = "recover";
  const client = new ConcaveClient("ws://127.0.0.1:9999/ws", {
    webSocketImpl: MockWebSocket,
    protocol: "json",
    authToken: jwtStale,
  });

  client.setTokenFetcher(async ({ forceRefresh }) => {
    calls.push(forceRefresh);
    if (phase === "recover") return jwtFresh;
    return jwtStillBad;
  });

  const ws = MockWebSocket.instances[0];
  const q = client.query({ name: "secret.data" }, {});
  ws.open();
  await tick();

  // Populate cache
  const subFrame = ws.sent.find((f) => f.type === "subscribe");
  ws.receive({
    type: "transition",
    to_ts: 1,
    updates: [{ sub_id: subFrame.sub_id, ok: true, value: { secret: 42 } }],
  });
  assert.deepEqual(q().data, { secret: 42 });

  // Server rejects initial token -> client retries once with forceRefresh: true
  ws.receive({ type: "auth_result", ok: false, error: "token expired" });
  await tick();

  assert.deepEqual(calls, [false, true]);
  assert.equal(client.getToken(), jwtFresh);
  // Server accepts refreshed token
  ws.receive({
    type: "auth_result",
    ok: true,
    identity: { subject: "alice", issuer: "concave" },
  });
  assert.equal(client.isAuthenticated(), true);
  assert.deepEqual(q().data, { secret: 42 });

  // Now simulate server rejecting both initial AND retried token -> must only retry once then clear!
  phase = "fail";
  const callsBefore = calls.length;
  ws.receive({ type: "auth_result", ok: false, error: "revoked" });
  await tick();
  assert.equal(calls.length, callsBefore + 1);
  assert.equal(calls.at(-1), true);

  // Server rejects the retry too -> must NOT call fetchToken again, must clear auth + cache
  ws.receive({ type: "auth_result", ok: false, error: "still revoked" });
  await tick();
  assert.equal(calls.length, callsBefore + 1);
  assert.equal(client.getToken(), null);
  assert.equal(client.identity(), null);
  assert.equal(client.isAuthenticated(), false);
  assert.equal(q().status, "loading");
  assert.equal(q().data, undefined);

  q.dispose();
  client.close();
});

test("ConcaveClient wipes cache when switching JWT sub or signing out with setAuth(null)", async () => {
  MockWebSocket.instances = [];
  const nowSec = Math.floor(Date.now() / 1000);
  const jwtAlice = makeJwt({ sub: "alice", iss: "concave", exp: nowSec + 3600 });
  const jwtBob = makeJwt({ sub: "bob", iss: "concave", exp: nowSec + 3600 });

  const client = new ConcaveClient("ws://127.0.0.1:9999/ws", {
    webSocketImpl: MockWebSocket,
    protocol: "json",
    authToken: jwtAlice,
  });
  const ws = MockWebSocket.instances[0];
  ws.open();

  ws.receive({
    type: "auth_result",
    ok: true,
    identity: { subject: "alice", issuer: "concave" },
  });
  const q = client.query({ name: "private.notes" }, {});
  const subFrame = ws.sent.find((f) => f.type === "subscribe");
  ws.receive({
    type: "transition",
    to_ts: 1,
    updates: [{ sub_id: subFrame.sub_id, ok: true, value: ["alice-secret"] }],
  });
  assert.deepEqual(q().data, ["alice-secret"]);
  assert.equal(client.isAuthenticated(), true);

  // Switch to Bob -> different sub MUST wipe cache & identity
  client.setAuth(jwtBob);
  assert.equal(client.getToken(), jwtBob);
  assert.equal(client.isAuthenticated(), false);
  assert.equal(q().status, "loading");
  assert.equal(q().data, undefined);

  // Receive Bob's data, then sign out
  ws.receive({
    type: "auth_result",
    ok: true,
    identity: { subject: "bob", issuer: "concave" },
  });
  ws.receive({
    type: "transition",
    to_ts: 2,
    updates: [{ sub_id: subFrame.sub_id, ok: true, value: ["bob-secret"] }],
  });
  assert.equal(client.isAuthenticated(), true);
  assert.deepEqual(q().data, ["bob-secret"]);

  client.setAuth(null);
  assert.equal(client.getToken(), null);
  assert.equal(client.isAuthenticated(), false);
  assert.equal(q().status, "loading");
  assert.equal(q().data, undefined);

  // Verify _parseJwtExpMs helper on valid & malformed tokens
  assert.equal(client._parseJwtExpMs(jwtAlice), (nowSec + 3600) * 1000);
  assert.equal(client._parseJwtExpMs("dev:alice"), null);
  assert.equal(client._parseJwtExpMs("a.!!!.c"), null);
  assert.equal(client._parseJwtExpMs(null), null);

  q.dispose();
  client.close();
});

test("matchRoute handles static, :param, wildcard *, URL decoding, and null-prototype safety", () => {
  const mRoot = matchRoute("/", "/");
  assert.equal(Object.getPrototypeOf(mRoot), null);
  assert.deepEqual({ ...mRoot }, {});

  assert.equal(matchRoute("/", "/rooms"), null);
  assert.deepEqual({ ...matchRoute("/rooms", "/rooms/") }, {});

  const mParam = matchRoute("/rooms/:id/msg/:mid", "/rooms/general%20chat/msg/a%2Fb");
  assert.equal(Object.getPrototypeOf(mParam), null);
  assert.equal(mParam.id, "general chat");
  assert.equal(mParam.mid, "a/b");

  assert.equal(matchRoute("/rooms/:id", "/rooms"), null);
  assert.equal(matchRoute("/rooms/:id", "/rooms/1/extra"), null);

  const mWild = matchRoute("/files/*", "/files/docs/my%20file/readme.md");
  assert.equal(Object.getPrototypeOf(mWild), null);
  assert.equal(mWild["*"], "docs/my file/readme.md");

  const mWildEmpty = matchRoute("/files/*", "/files");
  assert.equal(mWildEmpty["*"], "");

  const mProto = matchRoute("/:__proto__", "/polluted");
  assert.equal(Object.getPrototypeOf(mProto), null);
  assert.equal(mProto["__proto__"], undefined);
  assert.equal(({}).polluted, undefined);
});

test("createRouter tracks path/query/current reactively, validates navigate URLs, intercepts link clicks, and disposes popstate", () => {
  const routes = [
    { path: "/", name: "home" },
    { path: "/rooms/:id", name: "room" },
    { path: "/files/*", name: "files" },
  ];

  const historyCalls = [];
  const listeners = new Map();
  const origWindow = globalThis.window;
  const origDoc = globalThis.document;
  const origNode = globalThis.Node;

  class MockEl {
    constructor(tag) {
      this.tagName = tag;
      this.attrs = new Map();
      this.listeners = new Map();
      this.children = [];
    }
    setAttribute(k, v) { this.attrs.set(k, v); }
    getAttribute(k) { return this.attrs.get(k); }
    removeAttribute(k) { this.attrs.delete(k); }
    addEventListener(ev, fn) { this.listeners.set(ev, fn); }
    removeEventListener(ev) { this.listeners.delete(ev); }
    appendChild(c) { this.children.push(c); return c; }
  }

  globalThis.Node = MockEl;
  globalThis.document = {
    createElement: (t) => new MockEl(t),
    createTextNode: (t) => ({ nodeType: 3, textContent: t }),
    createComment: (t) => ({ nodeType: 8, textContent: t }),
    createDocumentFragment: () => new MockEl("#frag"),
  };
  globalThis.window = {
    location: { pathname: "/rooms/42", search: "?tab=chat&__proto__=bad" },
    history: {
      pushState: (...args) => historyCalls.push(["push", ...args]),
      replaceState: (...args) => historyCalls.push(["replace", ...args]),
    },
    addEventListener(ev, fn) {
      if (!listeners.has(ev)) listeners.set(ev, new Set());
      listeners.get(ev).add(fn);
    },
    removeEventListener(ev, fn) {
      listeners.get(ev)?.delete(fn);
    },
  };

  try {
    const router = createRouter(routes, { initialPath: "/rooms/42?tab=chat&filter=all&__proto__=x" });
    const seen = [];
    const stopEff = effect(() => {
      const c = router.current();
      seen.push(`${c.route?.name}:${c.params.id ?? c.params["*"] ?? ""}:${c.query.tab ?? ""}`);
    });

    assert.equal(router.path(), "/rooms/42");
    assert.equal(Object.getPrototypeOf(router.query()), null);
    assert.equal(router.query().tab, "chat");
    assert.equal(router.query().filter, "all");
    assert.equal(router.query()["__proto__"], undefined);
    assert.deepEqual(seen, ["room:42:chat"]);

    // navigate with pushState and replaceState
    router.navigate("/files/a/b?tab=raw");
    assert.equal(router.path(), "/files/a/b");
    assert.equal(router.current().route.name, "files");
    assert.equal(router.current().params["*"], "a/b");
    assert.equal(router.query().tab, "raw");
    assert.equal(historyCalls.length, 1);
    assert.equal(historyCalls[0][0], "push");
    assert.equal(historyCalls[0][3], "/files/a/b?tab=raw");
    assert.deepEqual(seen, ["room:42:chat", "files:a/b:raw"]);

    router.navigate("/", { replace: true });
    assert.equal(historyCalls[1][0], "replace");
    assert.equal(router.current().route.name, "home");

    // Reject unsafe / external / protocol-relative URLs
    assert.throws(() => router.navigate("//evil.com/phish"));
    assert.throws(() => router.navigate("/\\evil.com/phish"));
    assert.throws(() => router.navigate("https://evil.com"));
    assert.throws(() => router.navigate("javascript:alert(1)"));
    assert.throws(() => router.navigate("relative/path"));
    assert.equal(router.path(), "/");

    // link() creates <a> and intercepts plain left-clicks only
    const a = router.link("/rooms/99?tab=info", { class: "nav-link" }, "Room 99");
    assert.equal(a.getAttribute("href"), "/rooms/99?tab=info");
    assert.equal(a.className, "nav-link");

    // Modified click (ctrlKey) must NOT navigate
    let prevented = false;
    a.listeners.get("click")({
      button: 0,
      ctrlKey: true,
      defaultPrevented: false,
      preventDefault() { prevented = true; },
    });
    assert.equal(prevented, false);
    assert.equal(router.path(), "/");

    // Plain left click navigates
    a.listeners.get("click")({
      button: 0,
      defaultPrevented: false,
      preventDefault() { prevented = true; },
    });
    assert.equal(prevented, true);
    assert.equal(router.path(), "/rooms/99");
    assert.equal(router.query().tab, "info");

    // popstate updates router
    assert.equal(listeners.get("popstate").size, 1);
    globalThis.window.location = { pathname: "/files/pop", search: "?tab=back" };
    for (const fn of listeners.get("popstate")) fn();
    assert.equal(router.path(), "/files/pop");
    assert.equal(router.query().tab, "back");

    // dispose removes popstate listener
    stopEff();
    router.dispose();
    assert.equal(listeners.get("popstate").size, 0);
  } finally {
    globalThis.window = origWindow;
    globalThis.document = origDoc;
    globalThis.Node = origNode;
  }
});
