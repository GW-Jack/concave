import assert from "node:assert/strict";
import test from "node:test";
import {
  ConcaveClient,
  batch,
  computed,
  createRoot,
  each,
  effect,
  el,
  mount,
  onCleanup,
  show,
  signal,
} from "../src/index.js";

// Deterministic PRNG (Mulberry32) so every property test failure is 100% reproducible.
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ============================================================================
// 1. Signal Graph: Diamond Dependency, Dynamic Branch Switching & Cleanup Laws
// ============================================================================

test("signals: diamond dependency under batch emits consistent values and dynamic branches unsubscribe cleanly", () => {
  const src = signal(1);
  const left = computed(() => src() * 2);
  const right = computed(() => src() * 3);
  const sum = computed(() => left() + right());

  const observed = [];
  let dispose;
  createRoot((d) => {
    dispose = d;
    effect(() => {
      observed.push({ l: left(), r: right(), s: sum() });
    });
  });

  // Initial state must be consistent: 2 + 3 = 5.
  assert.deepEqual(observed, [{ l: 2, r: 3, s: 5 }]);

  for (let v = 2; v <= 20; v += 1) {
    src.set(v);
    // Glitch-freedom invariant: EXACTLY ONE effect execution per update, never an inconsistent intermediate state!
    assert.equal(observed.length, v, `diamond glitch detected at v=${v}: fired ${observed.length} times`);
    const last = observed[observed.length - 1];
    assert.equal(last.l, v * 2);
    assert.equal(last.r, v * 3);
    assert.equal(last.s, v * 5);
  }
  dispose();

  // Memoization cutoff: when a `computed` produces an equal value, downstream effects must NOT re-run!
  const n = signal(2);
  const isEven = computed(() => n() % 2 === 0);
  let parityRuns = 0;
  let stopParity;
  createRoot((d) => {
    stopParity = d;
    effect(() => {
      isEven();
      parityRuns += 1;
    });
  });
  assert.equal(parityRuns, 1);
  n.set(4); // still even -> must NOT re-run effect
  assert.equal(parityRuns, 1, "memoized computed must cut off redundant effect executions");
  n.set(5); // odd -> must re-run
  assert.equal(parityRuns, 2);
  stopParity();

  // Dynamic dependency switching: when `flag` switches to false, updates to `a` must NOT re-run effect!
  const flag = signal(true);
  const a = signal(10);
  const b = signal(100);
  let runs = 0;
  let cleanups = 0;
  let lastVal = 0;

  let stopSwitch;
  createRoot((d) => {
    stopSwitch = d;
    effect(() => {
      runs += 1;
      onCleanup(() => {
        cleanups += 1;
      });
      lastVal = flag() ? a() : b();
    });
  });

  assert.equal(runs, 1);
  assert.equal(lastVal, 10);

  a.set(11);
  assert.equal(runs, 2);
  assert.equal(cleanups, 1);
  assert.equal(lastVal, 11);

  flag.set(false);
  assert.equal(runs, 3);
  assert.equal(lastVal, 100);

  // `a` is no longer tracked — changing `a` must produce ZERO effect executions!
  a.set(999);
  assert.equal(runs, 3, "inactive branch signal must be unsubscribed");

  b.set(200);
  assert.equal(runs, 4);
  assert.equal(lastVal, 200);

  stopSwitch();
  assert.equal(cleanups, 4, "disposing root must invoke final onCleanup");
  b.set(300);
  assert.equal(runs, 4);
});

test("signals: randomized DAG updates match brute-force oracle across 500 mutations", () => {
  const rng = mulberry32(0x5164_0001);
  const roots = Array.from({ length: 6 }, (_, i) => signal(i + 1));
  const c0 = computed(() => roots[0]() + roots[1]());
  const c1 = computed(() => roots[2]() * 2 - roots[3]());
  const c2 = computed(() => (roots[4]() % 2 === 0 ? c0() + roots[5]() : c1() - roots[5]()));
  const c3 = computed(() => c0() + c1() + c2());

  let observed = 0;
  const dispose = createRoot((d) => {
    effect(() => {
      observed = c3();
    });
    return d;
  });

  const oracle = () => {
    const r = roots.map((s) => s.peek());
    const v0 = r[0] + r[1];
    const v1 = r[2] * 2 - r[3];
    const v2 = r[4] % 2 === 0 ? v0 + r[5] : v1 - r[5];
    return v0 + v1 + v2;
  };

  assert.equal(observed, oracle());

  for (let step = 0; step < 500; step += 1) {
    const batchCount = 1 + Math.floor(rng() * 3);
    batch(() => {
      for (let k = 0; k < batchCount; k += 1) {
        const idx = Math.floor(rng() * roots.length);
        roots[idx].set(Math.floor(rng() * 50) - 25);
      }
    });
    assert.equal(observed, oracle(), `DAG diverged from oracle at step ${step}`);
  }
  dispose();
});

// ============================================================================
// 2. ConcaveClient Model-Based Property Test (Optimistic Queue, Out-of-Order
//    Frames, Rollbacks, Shared RefCounts & Abrupt Reconnects)
// ============================================================================

test("ConcaveClient: model-based property test over 150 steps of optimistic mutations, out-of-order frames, rollbacks, and reconnects", async () => {
  const rng = mulberry32(0xC11E_4701);

  const sockets = [];
  let activeSocket = null;

  class SimWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;

    constructor(url) {
      this.url = url;
      this.readyState = SimWebSocket.CONNECTING;
      this.listeners = new Map();
      this.outbound = [];
      sockets.push(this);
      activeSocket = this;
    }

    addEventListener(type, fn) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type).add(fn);
    }

    send(data) {
      this.outbound.push(JSON.parse(data));
    }

    close() {
      this.readyState = SimWebSocket.CLOSED;
      this._emit("close", {});
    }

    open() {
      this.readyState = SimWebSocket.OPEN;
      this._emit("open", {});
    }

    drop() {
      this.readyState = SimWebSocket.CLOSED;
      this._emit("close", {});
    }

    receive(frame) {
      this._emit("message", { data: JSON.stringify(frame) });
    }

    _emit(type, ev) {
      for (const fn of this.listeners.get(type) ?? []) fn(ev);
    }
  }

  // Simulated authoritative server state: 3 integer counters `k0`, `k1`, `k2`.
  const serverState = { k0: 0, k1: 0, k2: 0 };
  let serverTs = 0;
  const serverSubs = new Map(); // sub_id -> { key }
  const inFlightServerFrames = []; // buffered server frames to deliver in shuffled order!

  const getRef = { kind: "query", name: "counter.get" };
  const incRef = { kind: "mutation", name: "counter.inc" };

  function processClientOutbound(sock) {
    while (sock.outbound.length > 0) {
      const msg = sock.outbound.shift();
      if (msg.type === "subscribe") {
        serverSubs.set(msg.sub_id, msg.args.key);
        inFlightServerFrames.push({
          type: "transition",
          to_ts: serverTs,
          updates: [{ sub_id: msg.sub_id, ok: true, value: serverState[msg.args.key] }],
        });
      } else if (msg.type === "unsubscribe") {
        serverSubs.delete(msg.sub_id);
      } else if (msg.type === "mutation") {
        const shouldFail = rng() < 0.3;
        if (shouldFail) {
          inFlightServerFrames.push({
            type: "mutation_result",
            req_id: msg.req_id,
            ok: false,
            error: "simulated rejection",
          });
        } else {
          serverState[msg.args.key] += msg.args.delta;
          serverTs += 1;
          const updates = [];
          for (const [sid, k] of serverSubs) {
            if (k === msg.args.key) {
              updates.push({ sub_id: sid, ok: true, value: serverState[k] });
            }
          }
          const mutRes = {
            type: "mutation_result",
            req_id: msg.req_id,
            ok: true,
            value: serverState[msg.args.key],
            commit_ts: serverTs,
          };
          const trans = { type: "transition", to_ts: serverTs, updates };
          // Randomly deliver `transition` BEFORE `mutation_result` or vice versa!
          if (rng() < 0.5) {
            inFlightServerFrames.push(trans, mutRes);
          } else {
            inFlightServerFrames.push(mutRes, trans);
          }
        }
      }
    }
  }

  const client = new ConcaveClient("http://127.0.0.1:3210", {
    webSocketImpl: SimWebSocket,
  });
  activeSocket.open();

  const keys = ["k0", "k1", "k2"];
  const watchers = keys.map((k) => client.query(getRef, { key: k }));
  const dynamicKey = signal("k0");
  const dynamicWatcher = client.query(getRef, () => ({ key: dynamicKey() }));

  processClientOutbound(activeSocket);
  while (inFlightServerFrames.length > 0) {
    activeSocket.receive(inFlightServerFrames.shift());
  }

  const pendingPromises = [];

  for (let step = 0; step < 150; step += 1) {
    const action = rng();
    if (action < 0.55) {
      // Fire an optimistic mutation on a random counter.
      const k = keys[Math.floor(rng() * keys.length)];
      const delta = 1 + Math.floor(rng() * 5);
      const p = client
        .mutate(
          incRef,
          { key: k, delta },
          {
            optimisticUpdate: (store) => {
              const cur = store.getQuery(getRef, { key: k });
              if (typeof cur === "number") {
                store.setQuery(getRef, { key: k }, cur + delta);
              }
            },
          },
        )
        .catch(() => {});
      pendingPromises.push(p);
    } else if (action < 0.72) {
      // Switch the dynamic reactive query to another counter (tests refcount inc/dec!).
      dynamicKey.set(keys[Math.floor(rng() * keys.length)]);
    } else if (action < 0.90) {
      // Deliver 1..3 buffered server frames.
      processClientOutbound(activeSocket);
      const count = 1 + Math.floor(rng() * 3);
      for (let i = 0; i < count && inFlightServerFrames.length > 0; i += 1) {
        activeSocket.receive(inFlightServerFrames.shift());
      }
    } else {
      // Abrupt socket drop + reconnect! Server forgets old connection's sub table and
      // client MUST re-subscribe all active refcounted queries on reopen.
      processClientOutbound(activeSocket);
      while (inFlightServerFrames.length > 0) {
        activeSocket.receive(inFlightServerFrames.shift());
      }
      serverSubs.clear();
      activeSocket.drop();
      // Force immediate reconnect without waiting real timers.
      clearTimeout(client._reconnectTimer);
      client._reconnectTimer = null;
      client._connect();
      activeSocket.open();
    }
  }

  // Drain all remaining client outbound & server frames until quiescent.
  processClientOutbound(activeSocket);
  while (inFlightServerFrames.length > 0) {
    activeSocket.receive(inFlightServerFrames.shift());
  }
  await Promise.all(pendingPromises);

  // Final convergence invariant: EVERY watcher MUST match authoritative serverState identically!
  for (let i = 0; i < keys.length; i += 1) {
    assert.equal(watchers[i]().status, "ready");
    assert.equal(
      watchers[i]().data,
      serverState[keys[i]],
      `counter ${keys[i]} diverged after optimistic updates & reconnects`,
    );
  }
  assert.equal(dynamicWatcher().data, serverState[dynamicKey()]);
  assert.equal(client._optimisticQueue.length, 0, "optimistic queue must drain completely");

  // Unsubscribing all watchers must leave ZERO active server subscriptions (no refcount leaks!).
  for (const w of watchers) w.dispose();
  dynamicWatcher.dispose();
  processClientOutbound(activeSocket);
  assert.equal(serverSubs.size, 0, "all subscriptions must be unsubscribed cleanly");

  client.close();
});

test("ConcaveClient: no duplicate subscribe on initial connect and in-flight optimistic mutations roll back cleanly on disconnect", async () => {
  let activeSocket = null;
  class MinimalWS {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;
    constructor() {
      this.readyState = MinimalWS.CONNECTING;
      this.listeners = new Map();
      this.sent = [];
      activeSocket = this;
    }
    addEventListener(type, fn) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type).add(fn);
    }
    send(d) {
      this.sent.push(JSON.parse(d));
    }
    close() {
      this.readyState = MinimalWS.CLOSED;
      for (const fn of this.listeners.get("close") ?? []) fn({});
    }
    open() {
      this.readyState = MinimalWS.OPEN;
      for (const fn of this.listeners.get("open") ?? []) fn({});
    }
    receive(frame) {
      for (const fn of this.listeners.get("message") ?? []) fn({ data: JSON.stringify(frame) });
    }
  }

  const getRef = { kind: "query", name: "counter.get" };
  const incRef = { kind: "mutation", name: "counter.inc" };

  // Subscribe BEFORE socket opens -> must send EXACTLY ONE subscribe frame on open (no duplicate!).
  const client = new ConcaveClient("http://127.0.0.1:3210", {
    webSocketImpl: MinimalWS,
    authToken: "dev:alice:Alice",
  });
  const q = client.query(getRef, { key: "x" });
  activeSocket.open();

  const subFrames = activeSocket.sent.filter((m) => m.type === "subscribe");
  const authFrames = activeSocket.sent.filter((m) => m.type === "authenticate");
  assert.equal(subFrames.length, 1, "must not send duplicate subscribe frames on initial open");
  assert.equal(authFrames.length, 1, "must not send duplicate authenticate frames on initial open");

  activeSocket.receive({
    type: "transition",
    to_ts: 1,
    updates: [{ sub_id: subFrames[0].sub_id, ok: true, value: 10 }],
  });
  assert.equal(q().data, 10);

  // Send optimistic mutation on open socket, then abruptly drop socket before server replies!
  const mutPromise = client.mutate(
    incRef,
    { key: "x", delta: 5 },
    {
      optimisticUpdate: (store) => {
        store.setQuery(getRef, { key: "x" }, (store.getQuery(getRef, { key: "x" }) ?? 0) + 5);
      },
    },
  );
  assert.equal(q().data, 15, "optimistic update must apply immediately");

  // Drop socket!
  activeSocket.close();
  await assert.rejects(() => mutPromise, /WebSocket disconnected/);
  assert.equal(q().data, 10, "optimistic update must roll back cleanly on socket disconnect");
  assert.equal(client._optimisticQueue.length, 0);

  q.dispose();
  client.close();
});

// ============================================================================
// 3. Surgical Keyed DOM Reconciliation (`dom.js` `each`, `show`, `mount`)
// ============================================================================

test("dom: keyed each preserves DOM node identity across shuffles and disposes removed row roots", () => {
  // Minimal deterministic DOM shim for Node.js verification.
  class FakeNode {
    constructor(nodeType, text = "") {
      this.nodeType = nodeType;
      this.textContent = text;
      this.parentNode = null;
      this.childNodes = [];
    }
    get nextSibling() {
      if (!this.parentNode) return null;
      const idx = this.parentNode.childNodes.indexOf(this);
      return idx >= 0 && idx + 1 < this.parentNode.childNodes.length
        ? this.parentNode.childNodes[idx + 1]
        : null;
    }
    appendChild(child) {
      if (child.nodeType === 11) {
        for (const c of [...child.childNodes]) this.appendChild(c);
        return child;
      }
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = this;
      this.childNodes.push(child);
      return child;
    }
    insertBefore(child, ref) {
      if (child.nodeType === 11) {
        for (const c of [...child.childNodes]) this.insertBefore(c, ref);
        return child;
      }
      if (child.parentNode) child.parentNode.removeChild(child);
      const idx = ref ? this.childNodes.indexOf(ref) : this.childNodes.length;
      child.parentNode = this;
      this.childNodes.splice(idx, 0, child);
      return child;
    }
    removeChild(child) {
      const idx = this.childNodes.indexOf(child);
      if (idx >= 0) {
        this.childNodes.splice(idx, 1);
        child.parentNode = null;
      }
      return child;
    }
  }

  class FakeElement extends FakeNode {
    constructor(tag) {
      super(1);
      this.tagName = tag.toUpperCase();
      this.attrs = new Map();
      this.className = "";
      this.style = {};
    }
    setAttribute(k, v) {
      this.attrs.set(k, v);
    }
    removeAttribute(k) {
      this.attrs.delete(k);
    }
    set innerHTML(v) {
      if (v === "") this.childNodes = [];
    }
  }

  const prevDoc = globalThis.document;
  const prevNode = globalThis.Node;
  globalThis.Node = FakeNode;
  globalThis.Node.TEXT_NODE = 3;
  globalThis.document = {
    createElement: (tag) => new FakeElement(tag),
    createTextNode: (t) => new FakeNode(3, t),
    createComment: (t) => new FakeNode(8, t),
    createDocumentFragment: () => new FakeNode(11),
  };

  try {
    const items = signal([
      { id: "a", label: "Alpha" },
      { id: "b", label: "Beta" },
      { id: "c", label: "Gamma" },
    ]);
    const visible = signal(true);
    const createdNodes = new Map();
    const disposedIds = [];

    const container = new FakeElement("div");
    const unmount = mount(container, () =>
      el(
        "section",
        null,
        show(visible, () => el("span", { id: "banner" }, "on")),
        each(
          items,
          (x) => x.id,
          (item) => {
            const id = item().id;
            const node = el("p", { "data-id": id }, () => item().label);
            createdNodes.set(id, node);
            onCleanup(() => disposedIds.push(id));
            return node;
          },
        ),
      ),
    );

    const section = container.childNodes[0];
    const getRowNodes = () => section.childNodes.filter((n) => n.tagName === "P");

    const origA = createdNodes.get("a");
    const origB = createdNodes.get("b");
    const origC = createdNodes.get("c");
    assert.deepEqual(getRowNodes(), [origA, origB, origC]);

    // Reorder + update label of "a" + delete "b" + insert "d"
    items.set([
      { id: "c", label: "Gamma" },
      { id: "d", label: "Delta" },
      { id: "a", label: "Alpha-Updated" },
    ]);

    const after = getRowNodes();
    assert.equal(after.length, 3);
    assert.equal(after[0], origC, "existing node 'c' must be moved, not recreated");
    assert.equal(after[2], origA, "existing node 'a' must be moved & updated in place");
    assert.deepEqual(disposedIds, ["b"], "removed row 'b' must have its reactive root disposed");

    // Verify surgical text update inside origA!
    const textNodeA = origA.childNodes.find((n) => n.nodeType === 3);
    assert.equal(textNodeA.textContent, "Alpha-Updated");

    visible.set(false);
    unmount();
    assert.ok(disposedIds.includes("a") && disposedIds.includes("c") && disposedIds.includes("d"));
  } finally {
    globalThis.document = prevDoc;
    globalThis.Node = prevNode;
  }
});
