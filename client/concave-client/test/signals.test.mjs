import assert from "node:assert/strict";
import test from "node:test";
import {
  ConcaveClient,
  batch,
  bindChecked,
  bindValue,
  computed,
  createRoot,
  effect,
  mount,
  optimisticAppend,
  signal,
  tags,
} from "../src/index.js";

test("signals, computed, batch, and createRoot cleanup", () => {
  const a = signal(2);
  const b = signal(3);
  const sum = computed(() => a() + b());

  const seen = [];
  let rootDispose;
  createRoot((dispose) => {
    rootDispose = dispose;
    effect(() => {
      seen.push(sum());
    });
  });

  assert.deepEqual(seen, [5]);

  batch(() => {
    a.set(10);
    b.set(20);
  });
  assert.deepEqual(seen, [5, 30]);

  rootDispose();
  a.set(100);
  assert.deepEqual(seen, [5, 30], "disposed root must stop tracking");
});

test("ConcaveClient reactive query transitions and optimistic updates", async () => {
  let lastSocket;

  class MockWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url) {
      this.readyState = MockWebSocket.CONNECTING;
      this.sent = [];
      this.url = url;
      this.listeners = new Map();
      lastSocket = this;
    }

    addEventListener(type, fn) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type).add(fn);
    }

    send(data) {
      this.sent.push(JSON.parse(data));
    }

    close() {
      this.readyState = MockWebSocket.CLOSED;
      this._emit("close", {});
    }

    open() {
      this.readyState = MockWebSocket.OPEN;
      this._emit("open", {});
    }

    receive(frame) {
      this._emit("message", { data: JSON.stringify(frame) });
    }

    _emit(type, ev) {
      for (const fn of this.listeners.get(type) ?? []) fn(ev);
    }
  }

  const listRef = { kind: "query", name: "messages.list" };
  const sendRef = { kind: "mutation", name: "messages.send" };

  const client = new ConcaveClient("http://127.0.0.1:3210", {
    webSocketImpl: MockWebSocket,
  });

  const room = signal("general");
  const messages = client.query(listRef, () => ({ room: room() }));

  lastSocket.open();
  const subFrame = lastSocket.sent.find((m) => m.type === "subscribe");
  assert.ok(subFrame, "should send subscribe frame on open");

  lastSocket.receive({
    type: "transition",
    to_ts: 1,
    updates: [{ sub_id: subFrame.sub_id, ok: true, value: ["hello"] }],
  });
  assert.deepEqual(messages().data, ["hello"]);

  const sendPromise = client.mutate(
    sendRef,
    { room: "general", body: "world" },
    {
      optimisticUpdate: (store) => {
        const cur = store.getQuery(listRef, { room: "general" }) ?? [];
        store.setQuery(listRef, { room: "general" }, [...cur, "world (optimistic)"]);
      },
    },
  );
  assert.deepEqual(messages().data, ["hello", "world (optimistic)"]);

  const mutFrame = lastSocket.sent.find((m) => m.type === "mutation");

  lastSocket.receive({
    type: "mutation_result",
    req_id: mutFrame.req_id,
    ok: true,
    value: "m2",
    commit_ts: 2,
  });
  lastSocket.receive({
    type: "transition",
    to_ts: 2,
    updates: [{ sub_id: subFrame.sub_id, ok: true, value: ["hello", "world"] }],
  });

  assert.equal(await sendPromise, "m2");
  assert.deepEqual(messages().data, ["hello", "world"]);

  messages.dispose();
  client.close();
});

test("createApi, optimisticAppend, and live reload frames", async () => {
  const { createApi } = await import(
    "../../../examples/chat-app/frontend/src/_generated/api.js"
  );

  let lastSocket;
  class MockWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url) {
      this.readyState = MockWebSocket.CONNECTING;
      this.sent = [];
      this.url = url;
      this.listeners = new Map();
      lastSocket = this;
    }

    addEventListener(type, fn) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type).add(fn);
    }

    send(raw) {
      this.sent.push(JSON.parse(raw));
    }

    close() {
      this.readyState = MockWebSocket.CLOSED;
      this._emit("close", {});
    }

    open() {
      this.readyState = MockWebSocket.OPEN;
      this._emit("open", {});
    }

    receive(frame) {
      this._emit("message", { data: JSON.stringify(frame) });
    }

    _emit(type, ev) {
      for (const fn of this.listeners.get(type) ?? []) fn(ev);
    }
  }

  const reloads = [];
  const client = new ConcaveClient("http://127.0.0.1:3210", {
    webSocketImpl: MockWebSocket,
    onReload: (ev) => reloads.push(ev),
  });
  const db = createApi(client);

  const rooms = db.rooms.list();
  const messages = db.messages.list({ room_id: "r1" });

  lastSocket.open();
  const subs = lastSocket.sent.filter((m) => m.type === "subscribe");
  assert.equal(subs.length, 2);
  const msgSub = subs.find((s) => s.name === "messages.list");
  assert.ok(msgSub);

  lastSocket.receive({
    type: "transition",
    to_ts: 1,
    updates: [{ sub_id: msgSub.sub_id, ok: true, value: [{ id: "m1", body: "hi" }] }],
  });
  assert.deepEqual(messages().data, [{ id: "m1", body: "hi" }]);

  // Use client.optimisticAppend with bound query function `db.messages.list`
  const mutPromise = db.messages.send(
    { room_id: "r1", body: "yo" },
    client.optimisticAppend(db.messages.list, { room_id: "r1" }, (prev) => ({
      id: `opt-${prev.length}`,
      body: "yo",
    })),
  );
  assert.deepEqual(messages().data, [
    { id: "m1", body: "hi" },
    { id: "opt-1", body: "yo" },
  ]);

  // Verify standalone optimisticAppend also works with raw ref
  const opt = optimisticAppend(db.messages.list.ref, { room_id: "r1" }, { id: "x", body: "z" });
  assert.equal(typeof opt.optimisticUpdate, "function");

  const mutFrame = lastSocket.sent.find((m) => m.type === "mutation");
  lastSocket.receive({
    type: "mutation_result",
    req_id: mutFrame.req_id,
    ok: true,
    value: "m2",
    commit_ts: 2,
  });
  lastSocket.receive({
    type: "transition",
    to_ts: 2,
    updates: [
      {
        sub_id: msgSub.sub_id,
        ok: true,
        value: [
          { id: "m1", body: "hi" },
          { id: "m2", body: "yo" },
        ],
      },
    ],
  });
  assert.equal(await mutPromise, "m2");
  assert.deepEqual(messages().data, [
    { id: "m1", body: "hi" },
    { id: "m2", body: "yo" },
  ]);

  // Verify paused reactive query reports status: "paused" (not stuck in "loading")
  const searchTerm = signal("");
  const pausedQuery = db.messages.list(() =>
    searchTerm() ? { room_id: searchTerm() } : null,
  );
  assert.equal(pausedQuery().status, "paused");
  assert.equal(pausedQuery().data, undefined);

  searchTerm.set("r2");
  assert.equal(pausedQuery().status, "loading");
  searchTerm.set("");
  assert.equal(pausedQuery().status, "paused");
  pausedQuery.dispose();

  // Verify reload frames trigger onReload
  lastSocket.receive({ type: "reload", reason: "css" });
  lastSocket.receive({ type: "reload", reason: "static" });
  assert.deepEqual(reloads, [
    { type: "reload", reason: "css" },
    { type: "reload", reason: "static" },
  ]);

  rooms.dispose();
  messages.dispose();
  client.close();
});

test("ConcaveClient reconnects even if WebSocket emits error without close during CONNECTING", async () => {
  const sockets = [];
  class ErrorOnlyConnectSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url) {
      this.url = url;
      this.readyState = ErrorOnlyConnectSocket.CONNECTING;
      this.listeners = new Map();
      this.closed = false;
      sockets.push(this);
    }
    addEventListener(type, fn) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type).add(fn);
    }
    send() {}
    close() {
      this.closed = true;
      this.readyState = ErrorOnlyConnectSocket.CLOSED;
    }
    emit(type, ev = {}) {
      for (const fn of this.listeners.get(type) ?? []) fn(ev);
    }
  }

  const client = new ConcaveClient("http://127.0.0.1:3210", {
    webSocketImpl: ErrorOnlyConnectSocket,
  });
  assert.equal(sockets.length, 1);

  // Simulate Node 22 undici WebSocket: emits error in CONNECTING and never emits close
  sockets[0].emit("error", { message: "ECONNREFUSED" });
  assert.equal(client.status(), "reconnecting");
  assert.equal(sockets[0].closed, true);

  // Wait for first 200ms backoff reconnect attempt
  await new Promise((r) => setTimeout(r, 280));
  assert.equal(sockets.length, 2, "client must attempt reconnect after error-without-close");

  // Second socket succeeds
  sockets[1].readyState = ErrorOnlyConnectSocket.OPEN;
  sockets[1].emit("open");
  assert.equal(client.status(), "connected");

  client.close();
});

test("dom helpers: tags proxy, bindValue, and bindChecked", () => {
  class MiniNode {
    constructor(nodeType) {
      this.nodeType = nodeType;
      this.parentNode = null;
      this.childNodes = [];
    }
    appendChild(child) {
      if (child.nodeType === 11) {
        const items = [...child.childNodes];
        for (const c of items) this.appendChild(c);
        return child;
      }
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = this;
      this.childNodes.push(child);
      return child;
    }
    insertBefore(child, ref) {
      if (child.nodeType === 11) {
        const items = [...child.childNodes];
        for (const c of items) this.insertBefore(c, ref);
        return child;
      }
      if (child.parentNode) child.parentNode.removeChild(child);
      const idx = ref ? this.childNodes.indexOf(ref) : -1;
      child.parentNode = this;
      if (idx === -1) this.childNodes.push(child);
      else this.childNodes.splice(idx, 0, child);
      return child;
    }
    removeChild(child) {
      const idx = this.childNodes.indexOf(child);
      if (idx !== -1) this.childNodes.splice(idx, 1);
      child.parentNode = null;
      return child;
    }
  }
  class MiniElement extends MiniNode {
    constructor(tag) {
      super(1);
      this.tagName = tag.toUpperCase();
      this.className = "";
      this.value = "";
      this.checked = false;
      this.attrs = new Map();
      this.listeners = new Map();
    }
    setAttribute(k, v) {
      this.attrs.set(k, String(v));
    }
    removeAttribute(k) {
      this.attrs.delete(k);
    }
    addEventListener(type, fn) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type).add(fn);
    }
    removeEventListener(type, fn) {
      this.listeners.get(type)?.delete(fn);
    }
    dispatch(type, ev) {
      for (const fn of this.listeners.get(type) ?? []) fn(ev);
    }
    set innerHTML(_v) {
      this.childNodes.length = 0;
    }
  }
  class MiniText extends MiniNode {
    constructor(t) {
      super(3);
      this.textContent = t;
    }
  }
  class MiniComment extends MiniNode {
    constructor(t) {
      super(8);
      this.textContent = t;
    }
  }
  class MiniFragment extends MiniNode {
    constructor() {
      super(11);
    }
  }

  const prevNode = globalThis.Node;
  const prevDoc = globalThis.document;
  globalThis.Node = MiniNode;
  MiniNode.TEXT_NODE = 3;
  globalThis.document = {
    createElement: (t) => new MiniElement(t),
    createTextNode: (s) => new MiniText(s),
    createComment: (s) => new MiniComment(s),
    createDocumentFragment: () => new MiniFragment(),
  };

  try {
    const { div, input, option, select, span } = tags;
    const text = signal("hello");
    const priority = signal("med");
    const enabled = signal(false);
    const seen = [];

    const container = new MiniElement("div");
    let textInput;
    let checkInput;
    let prioritySelect;
    let refSawChildren = 0;

    const dispose = mount(container, () =>
      div(
        span("plain"),
        div({ class: "box" }, () => text()),
        (textInput = input({ type: "text", ...bindValue(text, (v) => seen.push(v)) })),
        (checkInput = input({ type: "checkbox", ...bindChecked(enabled) })),
        (prioritySelect = select(
          {
            ...bindValue(priority),
            ref: (node) => {
              refSawChildren = node.childNodes.length;
            },
          },
          option({ value: "low" }, "Low"),
          option({ value: "med" }, "Med"),
          option({ value: "high" }, "High"),
        )),
      ),
    );

    const root = container.childNodes[0];
    assert.equal(root.tagName, "DIV");
    assert.equal(root.childNodes[0].tagName, "SPAN");
    assert.equal(root.childNodes[0].childNodes[0].textContent, "plain");
    assert.equal(root.childNodes[1].className, "box");
    assert.equal(textInput.value, "hello");
    assert.equal(checkInput.checked, false);
    assert.equal(prioritySelect.value, "med");
    assert.equal(refSawChildren, 3, "ref and value run after children are appended");

    // Simulate user typing
    textInput.dispatch("input", { target: { value: "world" } });
    assert.equal(text(), "world");
    assert.deepEqual(seen, ["world"]);
    assert.equal(textInput.value, "world");

    // Programmatic signal update reflects on input
    text.set("concave");
    assert.equal(textInput.value, "concave");

    // Simulate checkbox toggle
    checkInput.dispatch("change", { target: { checked: true } });
    assert.equal(enabled(), true);
    assert.equal(checkInput.checked, true);

    dispose();
  } finally {
    globalThis.Node = prevNode;
    globalThis.document = prevDoc;
  }
});
