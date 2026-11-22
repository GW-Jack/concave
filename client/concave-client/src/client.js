import { batch, effect, onCleanup, signal } from "./signals.js";

function stableStringify(val) {
  if (val === null || typeof val !== "object") {
    return JSON.stringify(val);
  }
  if (Array.isArray(val)) {
    return `[${val.map(stableStringify).join(",")}]`;
  }
  const keys = Object.keys(val).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify(val[k])}`).join(",")}}`;
}

function subKey(name, args) {
  return `${name}:${stableStringify(args)}`;
}

export class ConcaveClient {
  constructor(url, options = {}) {
    this.status = signal("connecting");
    this.commitTs = signal(0);
    this.identity = signal(null);

    this._wsUrl = normalizeWsUrl(url);
    this._WsCtor = options.webSocketImpl ?? globalThis.WebSocket;
    this._ws = null;
    this._closed = false;
    this._reconnectAttempt = 0;
    this._reconnectTimer = null;
    this._nextId = 1;

    this._authToken = options.authToken ?? null;
    this._subsByKey = new Map();
    this._subsById = new Map();
    this._pendingMutations = new Map();
    this._pendingActions = new Map();
    this._inFlightMutations = new Set();
    this._inFlightActions = new Set();
    this._optimisticQueue = [];
    this._outboundQueue = [];

    this._connect();
  }

  _connect() {
    if (this._closed) return;
    this.status.set(this._reconnectAttempt > 0 ? "reconnecting" : "connecting");

    const ws = new this._WsCtor(this._wsUrl);
    this._ws = ws;

    ws.addEventListener("open", () => {
      if (this._ws !== ws) return;
      this._reconnectAttempt = 0;
      this.status.set("connected");

      if (this._authToken !== null) {
        this._sendRaw({ type: "authenticate", token: this._authToken });
      }

      for (const entry of this._subsByKey.values()) {
        this._sendRaw({
          type: "subscribe",
          sub_id: entry.subId,
          name: entry.name,
          args: entry.args,
        });
      }

      while (this._outboundQueue.length > 0) {
        const frame = this._outboundQueue.shift();
        if (frame.type === "mutation") {
          this._inFlightMutations.add(frame.req_id);
        } else if (frame.type === "action") {
          this._inFlightActions.add(frame.req_id);
        }
        ws.send(JSON.stringify(frame));
      }
    });

    ws.addEventListener("message", (event) => {
      if (this._ws !== ws) return;
      try {
        const raw = typeof event.data === "string" ? event.data : String(event.data);
        this._handleServerFrame(JSON.parse(raw));
      } catch (err) {
        console.error("[concave-client] malformed server frame:", err);
      }
    });

    ws.addEventListener("close", () => {
      if (this._ws !== ws) return;
      this._ws = null;
      this._failInFlightOnDisconnect();
      if (!this._closed) {
        this._scheduleReconnect();
      }
    });

    ws.addEventListener("error", () => {});
  }

  _scheduleReconnect() {
    this.status.set("reconnecting");
    const delayMs = Math.min(5000, 200 * 2 ** Math.min(this._reconnectAttempt, 5));
    this._reconnectAttempt += 1;
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      this._connect();
    }, delayMs);
  }

  _failInFlightOnDisconnect() {
    if (this._inFlightMutations.size === 0 && this._inFlightActions.size === 0) {
      return;
    }
    const err = new Error("WebSocket disconnected");
    let removedAnyOpt = false;
    for (const reqId of this._inFlightMutations) {
      const pending = this._pendingMutations.get(reqId);
      this._pendingMutations.delete(reqId);
      const idx = this._optimisticQueue.findIndex((o) => o.reqId === reqId);
      if (idx !== -1) {
        this._optimisticQueue.splice(idx, 1);
        removedAnyOpt = true;
      }
      pending?.reject(err);
    }
    this._inFlightMutations.clear();

    for (const reqId of this._inFlightActions) {
      const pending = this._pendingActions.get(reqId);
      this._pendingActions.delete(reqId);
      pending?.reject(err);
    }
    this._inFlightActions.clear();

    if (removedAnyOpt) {
      this._recomputeOptimisticSignals();
    }
  }

  _sendRaw(payload) {
    const encoded = JSON.stringify(payload);
    if (this._ws && this._ws.readyState === this._WsCtor.OPEN) {
      if (payload.type === "mutation") {
        this._inFlightMutations.add(payload.req_id);
      } else if (payload.type === "action") {
        this._inFlightActions.add(payload.req_id);
      }
      this._ws.send(encoded);
    } else if (payload.type === "mutation" || payload.type === "action") {
      // Only queue RPCs; `authenticate` and active `subscribe` frames are re-emitted cleanly on `open`
      // without duplicating subscriptions or sending stale auth frames.
      this._outboundQueue.push(payload);
    }
  }

  _handleServerFrame(frame) {
    switch (frame.type) {
      case "auth_result": {
        if (frame.ok) {
          this.identity.set(frame.identity ?? null);
        } else {
          this.identity.set(null);
          console.warn("[concave-client] auth rejected:", frame.error);
        }
        break;
      }
      case "transition": {
        batch(() => {
          this.commitTs.set(Math.max(this.commitTs.peek(), frame.to_ts));
          for (const upd of frame.updates) {
            const entry = this._subsById.get(upd.sub_id);
            if (!entry) continue;
            entry.serverState = upd.ok
              ? { status: "ready", data: upd.value, error: undefined }
              : { status: "error", data: undefined, error: upd.error ?? "query failed" };
          }
          this._pruneOptimistic(frame.to_ts);
          this._recomputeOptimisticSignals();
        });
        break;
      }
      case "mutation_result": {
        this._inFlightMutations.delete(frame.req_id);
        const pending = this._pendingMutations.get(frame.req_id);
        this._pendingMutations.delete(frame.req_id);
        if (frame.ok) {
          const opt = this._optimisticQueue.find((o) => o.reqId === frame.req_id);
          if (opt) {
            opt.resolvedCommitTs = frame.commit_ts ?? this.commitTs.peek();
            this._pruneOptimistic(this.commitTs.peek());
            this._recomputeOptimisticSignals();
          }
          pending?.resolve(frame.value);
        } else {
          this._removeOptimistic(frame.req_id);
          pending?.reject(new Error(frame.error ?? "mutation failed"));
        }
        break;
      }
      case "action_result": {
        this._inFlightActions.delete(frame.req_id);
        const pending = this._pendingActions.get(frame.req_id);
        this._pendingActions.delete(frame.req_id);
        if (frame.ok) {
          pending?.resolve(frame.value);
        } else {
          pending?.reject(new Error(frame.error ?? "action failed"));
        }
        break;
      }
      case "pong":
        break;
      case "error":
        console.error("[concave-client] server error:", frame.message);
        break;
    }
  }

  _pruneOptimistic(currentCommitTs) {
    for (let i = this._optimisticQueue.length - 1; i >= 0; i -= 1) {
      const opt = this._optimisticQueue[i];
      if (opt.resolvedCommitTs !== undefined && currentCommitTs >= opt.resolvedCommitTs) {
        this._optimisticQueue.splice(i, 1);
      }
    }
  }

  _removeOptimistic(reqId) {
    const idx = this._optimisticQueue.findIndex((o) => o.reqId === reqId);
    if (idx !== -1) {
      this._optimisticQueue.splice(idx, 1);
      this._recomputeOptimisticSignals();
    }
  }

  _recomputeOptimisticSignals() {
    const overlay = new Map();
    for (const [k, entry] of this._subsByKey) {
      if (entry.serverState.status === "ready") {
        overlay.set(k, entry.serverState.data);
      }
    }

    const store = {
      getQuery: (ref, args) => overlay.get(subKey(ref.name, args)),
      setQuery: (ref, args, value) => {
        overlay.set(subKey(ref.name, args), value);
      },
    };

    for (const opt of this._optimisticQueue) {
      try {
        opt.apply(store);
      } catch (err) {
        console.error("[concave-client] optimistic update error:", err);
      }
    }

    batch(() => {
      for (const [k, entry] of this._subsByKey) {
        if (entry.serverState.status === "ready" && overlay.has(k)) {
          entry.signal.set({ status: "ready", data: overlay.get(k), error: undefined });
        } else {
          entry.signal.set(entry.serverState);
        }
      }
    });
  }

  setAuth(token) {
    this._authToken = token;
    if (token === null) {
      this.identity.set(null);
    }
    this._sendRaw({ type: "authenticate", token });
  }

  _acquireSub(name, args) {
    const key = subKey(name, args);
    let entry = this._subsByKey.get(key);
    if (!entry) {
      const subId = `sub_${this._nextId++}`;
      const initial = {
        status: "loading",
        data: undefined,
        error: undefined,
      };
      entry = {
        subId,
        key,
        name,
        args,
        refCount: 0,
        serverState: initial,
        signal: signal(initial),
      };
      this._subsByKey.set(key, entry);
      this._subsById.set(subId, entry);
      this._sendRaw({ type: "subscribe", sub_id: subId, name, args });
    }
    entry.refCount += 1;

    let released = false;
    const captured = entry;
    return {
      entry: captured,
      release: () => {
        if (released) return;
        released = true;
        captured.refCount -= 1;
        if (captured.refCount <= 0) {
          this._subsByKey.delete(captured.key);
          this._subsById.delete(captured.subId);
          this._sendRaw({ type: "unsubscribe", sub_id: captured.subId });
        }
      },
    };
  }

  query(ref, argsOrAccessor) {
    const out = signal({
      status: "loading",
      data: undefined,
      error: undefined,
    });

    const isFn = typeof argsOrAccessor === "function";
    const dispose = effect(() => {
      const resolved = isFn ? argsOrAccessor() : argsOrAccessor;

      if (resolved === null || resolved === undefined) {
        out.set({ status: "loading", data: undefined, error: undefined });
        return;
      }

      const { entry, release } = this._acquireSub(ref.name, resolved);
      const stopMirror = effect(() => {
        out.set(entry.signal());
      });

      onCleanup(() => {
        stopMirror();
        release();
      });
    });

    const accessor = () => out();
    accessor.dispose = dispose;
    return accessor;
  }

  mutate(ref, args, options) {
    const reqId = `mut_${this._nextId++}`;
    if (options?.optimisticUpdate) {
      this._optimisticQueue.push({
        reqId,
        apply: options.optimisticUpdate,
      });
      this._recomputeOptimisticSignals();
    }

    return new Promise((resolve, reject) => {
      this._pendingMutations.set(reqId, { resolve, reject });
      this._sendRaw({
        type: "mutation",
        req_id: reqId,
        name: ref.name,
        args,
      });
    });
  }

  action(ref, args) {
    const reqId = `act_${this._nextId++}`;
    return new Promise((resolve, reject) => {
      this._pendingActions.set(reqId, { resolve, reject });
      this._sendRaw({
        type: "action",
        req_id: reqId,
        name: ref.name,
        args,
      });
    });
  }

  close() {
    this._closed = true;
    if (this._reconnectTimer !== null) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    this._ws?.close();
    this._ws = null;
    this.status.set("closed");
  }
}

function normalizeWsUrl(url) {
  if (url.startsWith("ws://") || url.startsWith("wss://")) {
    return url.endsWith("/ws") ? url : `${url.replace(/\/$/, "")}/ws`;
  }
  const converted = url
    .replace(/^http:\/\//, "ws://")
    .replace(/^https:\/\//, "wss://");
  return converted.endsWith("/ws")
    ? converted
    : `${converted.replace(/\/$/, "")}/ws`;
}
