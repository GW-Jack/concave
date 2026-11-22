import assert from "node:assert/strict";
import test from "node:test";
import {
  ConcaveClient,
  batch,
  computed,
  createRoot,
  effect,
  signal,
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
