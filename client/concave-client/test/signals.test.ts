import assert from "node:assert/strict";
import test from "node:test";
import {
  ConcaveClient,
  type FunctionReference,
  batch,
  computed,
  createRoot,
  effect,
  signal,
} from "../src/index.ts";

test("signals, computed, batch, and createRoot cleanup", () => {
  const a = signal(2);
  const b = signal(3);
  const sum = computed(() => a() + b());

  const seen: number[] = [];
  let rootDispose!: () => void;
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
  type Listener = (ev: { data?: string }) => void;

  class MockWebSocket {
    static readonly CONNECTING = 0;
    static readonly OPEN = 1;
    static readonly CLOSING = 2;
    static readonly CLOSED = 3;

    readyState = MockWebSocket.CONNECTING;
    sent: unknown[] = [];
    url: string;
    private listeners = new Map<string, Set<Listener>>();

    constructor(url: string) {
      this.url = url;
      lastSocket = this;
    }

    addEventListener(type: string, fn: Listener) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type)!.add(fn);
    }

    send(data: string) {
      this.sent.push(JSON.parse(data));
    }

    close() {
      this.readyState = MockWebSocket.CLOSED;
      this.emit("close", {});
    }

    open() {
      this.readyState = MockWebSocket.OPEN;
      this.emit("open", {});
    }

    receive(frame: unknown) {
      this.emit("message", { data: JSON.stringify(frame) });
    }

    private emit(type: string, ev: { data?: string }) {
      for (const fn of this.listeners.get(type) ?? []) fn(ev);
    }
  }

  let lastSocket!: MockWebSocket;

  const listRef: FunctionReference<"query", { room: string }, string[]> = {
    kind: "query",
    name: "messages.list",
  };
  const sendRef: FunctionReference<"mutation", { room: string; body: string }, string> = {
    kind: "mutation",
    name: "messages.send",
  };

  const client = new ConcaveClient("http://127.0.0.1:3210", {
    webSocketImpl: MockWebSocket as unknown as typeof WebSocket,
  });

  const room = signal("general");
  const messages = client.query(listRef, () => ({ room: room() }));

  lastSocket.open();
  const subFrame = lastSocket.sent.find(
    (m) => (m as { type: string }).type === "subscribe",
  ) as { sub_id: string };
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

  const mutFrame = lastSocket.sent.find(
    (m) => (m as { type: string }).type === "mutation",
  ) as { req_id: string };

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
