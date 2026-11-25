import test from "node:test";
import assert from "node:assert/strict";

import { signal, effect } from "../src/signals.js";
import { el } from "../src/dom.js";
import { ConcaveClient } from "../src/client.js";
import { fromProps, createAnalytics } from "../../../packages/analytics/client.js";
import { fromAttrs, createMonitor } from "../../../packages/monitor/client.js";

function makeMockDocument() {
  class MockNode {
    constructor(tag) {
      this.tagName = tag;
      this.attrs = new Map();
      this.listeners = new Map();
      this.children = [];
      this.style = {
        setProperty(k, v) {
          this[k] = v;
        },
      };
    }
    setAttribute(k, v) {
      this.attrs.set(k, v);
    }
    removeAttribute(k) {
      this.attrs.delete(k);
    }
    getAttribute(k) {
      return this.attrs.get(k);
    }
    addEventListener(ev, fn) {
      this.listeners.set(ev, fn);
    }
    removeEventListener(ev) {
      this.listeners.delete(ev);
    }
    appendChild(child) {
      this.children.push(child);
      return child;
    }
  }
  const origDocument = globalThis.document;
  const origNode = globalThis.Node;
  globalThis.Node = MockNode;
  globalThis.document = {
    createElement: (tag) => new MockNode(tag),
    createTextNode: (t) => ({ nodeType: 3, textContent: t }),
    createComment: (t) => ({ nodeType: 8, textContent: t }),
    createDocumentFragment: () => new MockNode("#frag"),
  };
  return () => {
    globalThis.document = origDocument;
    globalThis.Node = origNode;
  };
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
    this.sent.push(data);
  }
  close() {
    this.readyState = MockWebSocket.CLOSED;
  }
}

test("dom.el blocks string on* attributes, srcdoc, unsafe URL schemes, and style prototype keys", () => {
  const restore = makeMockDocument();
  try {
    let clicked = 0;
    const a = el("a", {
      href: "javascript:alert(1)",
      onClick: "alert(1)",
      ONERROR: "alert(2)",
      srcdoc: "<script>alert(3)</script>",
      onMouseDown: () => {
        clicked += 1;
      },
      style: { color: "red", cssText: "background:url(javascript:1)", ["__proto__"]: { polluted: 1 } },
    });

    assert.equal(a.getAttribute("href"), undefined);
    assert.equal(a.getAttribute("onClick"), undefined);
    assert.equal(a.getAttribute("ONERROR"), undefined);
    assert.equal(a.getAttribute("srcdoc"), undefined);
    assert.equal(a.style.color, "red");
    assert.equal(a.style.cssText, undefined);
    assert.equal(({}).polluted, undefined);
    assert.equal(typeof a.listeners.get("mousedown"), "function");
    a.listeners.get("mousedown")();
    assert.equal(clicked, 1);

    const safe = el("a", { href: "https://example.com/path?x=1" });
    assert.equal(safe.getAttribute("href"), "https://example.com/path?x=1");

    const rel = el("a", { href: "/dashboard" });
    assert.equal(rel.getAttribute("href"), "/dashboard");

    const dataImg = el("img", { src: "data:text/html,<script>x</script>" });
    assert.equal(dataImg.getAttribute("src"), undefined);

    const protoRel = el("a", { href: "//evil.example/phish" });
    assert.equal(protoRel.getAttribute("href"), undefined);
  } finally {
    restore();
  }
});

test("signals.flushEffects throws on infinite effect cycles", () => {
  const count = signal(0);
  let dispose;
  assert.throws(() => {
    dispose = effect(() => {
      const c = count();
      count.set(c + 1);
    });
  }, /Reactive effect cycle detected/);
  dispose?.();
});

test("ConcaveClient.setAuth(null) clears cached subscription data and drops stale queued RPCs", async () => {
  MockWebSocket.instances = [];
  const client = new ConcaveClient("ws://127.0.0.1:9999/ws", {
    webSocketImpl: MockWebSocket,
    protocol: "json",
    authToken: "dev:alice",
  });
  const ws = MockWebSocket.instances[0];
  ws.open();

  const q = client.query({ name: "messages.secret" }, {});
  const subMsg = JSON.parse(ws.sent.find((s) => s.includes('"subscribe"')));
  ws.emit("message", {
    data: JSON.stringify({
      type: "transition",
      to_ts: 1,
      updates: [{ sub_id: subMsg.sub_id, ok: true, value: { secret: "top-secret" } }],
    }),
  });
  assert.deepEqual(q().data, { secret: "top-secret" });

  // Disconnect briefly, enqueue an RPC under Alice's session, then sign out.
  ws.readyState = MockWebSocket.CLOSED;
  const staleRpc = client.mutate({ name: "messages.send" }, { body: "hi" });
  client.setAuth(null);

  assert.equal(q().status, "loading");
  assert.equal(q().data, undefined);
  await assert.rejects(staleRpc, /Auth context changed/);

  client.close();
});

test("ConcaveClient.close rejects pending RPCs and handles truncated binary frames safely", async () => {
  MockWebSocket.instances = [];
  const client = new ConcaveClient("ws://127.0.0.1:9999/ws", {
    webSocketImpl: MockWebSocket,
    protocol: "binary",
  });
  const ws = MockWebSocket.instances[0];
  ws.open();

  // Send truncated binary frames (transition header without body) — must not throw uncaught errors.
  ws.emit("message", { data: new Uint8Array([0x83, 0, 0]).buffer });
  ws.emit("message", { data: new Uint8Array([]).buffer });

  const p = client.queryOnce({ name: "items.list" }, {});
  client.close();
  await assert.rejects(p, /Client closed/);
});

test("analytics & monitor clients prevent prototype pollution and strip URL query/hash by default", async () => {
  const props = fromProps([
    { key: "__proto__", value: "polluted" },
    { key: "constructor", value: "bad" },
    { key: "plan", value: "pro" },
  ]);
  assert.equal(Object.getPrototypeOf(props), null);
  assert.equal(props.plan, "pro");
  assert.equal(props["__proto__"], undefined);
  assert.equal(({}).polluted, undefined);

  const attrs = fromAttrs([
    { key: "__proto__", value: "polluted" },
    { key: "env", value: "prod" },
  ]);
  assert.equal(Object.getPrototypeOf(attrs), null);
  assert.equal(attrs.env, "prod");

  const origWindow = globalThis.window;
  const origDocument = globalThis.document;
  globalThis.window = {
    location: {
      href: "https://app.example.com/reset?token=supersecret#frag",
      pathname: "/reset",
      host: "app.example.com",
    },
  };
  globalThis.document = {
    referrer: "https://auth.example.com/cb?code=oauthsecret",
  };
  try {
    const calls = [];
    const fakeClient = {
      mutate: async (ref, args) => {
        calls.push({ ref, args });
        return "ok";
      },
      identity: () => null,
    };

    const analytics = createAnalytics(fakeClient, { capture: { name: "analytics.capture" } }, { storage: null });
    await analytics.capturePageview();
    const pvProps = fromProps(calls[0].args.properties);
    assert.equal(pvProps.$current_url, "https://app.example.com/reset");
    assert.equal(pvProps.$referrer, "https://auth.example.com/cb");

    const monitor = createMonitor(fakeClient, { captureError: { name: "monitor.captureError" } });
    await monitor.captureException(new Error("boom"));
    const errAttrs = fromAttrs(calls[1].args.attrs);
    assert.equal(errAttrs.url, "https://app.example.com/reset");
  } finally {
    globalThis.window = origWindow;
    globalThis.document = origDocument;
  }
});
