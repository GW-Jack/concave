import { batch, effect, onCleanup, signal } from "./signals.js";

const _te = new TextEncoder();
const _td = new TextDecoder();

function _readI64(dv, off) {
  return dv.getInt32(off, false) * 4294967296 + dv.getUint32(off + 4, false);
}

function _writeI64(dv, off, val) {
  const hi = Math.floor(val / 4294967296);
  const lo = val >>> 0;
  dv.setInt32(off, hi, false);
  dv.setUint32(off + 4, lo, false);
}

function encodeBinaryFrame(msg) {
  if (msg.type === "authenticate") {
    if (msg.token === null || msg.token === undefined) {
      return new Uint8Array([0x01, 0]);
    }
    const tb = _te.encode(msg.token);
    const out = new Uint8Array(4 + tb.length);
    out[0] = 0x01;
    out[1] = 1;
    new DataView(out.buffer).setUint16(2, tb.length, false);
    out.set(tb, 4);
    return out;
  }
  if (msg.type === "unsubscribe") {
    const sb = _te.encode(msg.sub_id);
    const out = new Uint8Array(3 + sb.length);
    out[0] = 0x03;
    new DataView(out.buffer).setUint16(1, sb.length, false);
    out.set(sb, 3);
    return out;
  }
  if (msg.type === "ping") {
    const out = new Uint8Array(9);
    out[0] = 0x06;
    _writeI64(new DataView(out.buffer), 1, msg.ts ?? 0);
    return out;
  }
  const tag =
    msg.type === "subscribe" ? 0x02 :
    msg.type === "mutation" ? 0x04 :
    msg.type === "action" ? 0x05 :
    msg.type === "query" ? 0x07 : 0;
  const idStr = msg.type === "subscribe" ? msg.sub_id : msg.req_id;
  const idB = _te.encode(idStr);
  const nameB = _te.encode(msg.name);
  const argsB = _te.encode(JSON.stringify(msg.args ?? {}));
  const out = new Uint8Array(1 + 2 + idB.length + 2 + nameB.length + 4 + argsB.length);
  const dv = new DataView(out.buffer);
  let p = 0;
  out[p++] = tag;
  dv.setUint16(p, idB.length, false); p += 2;
  out.set(idB, p); p += idB.length;
  dv.setUint16(p, nameB.length, false); p += 2;
  out.set(nameB, p); p += nameB.length;
  dv.setUint32(p, argsB.length, false); p += 4;
  out.set(argsB, p);
  return out;
}

function decodeBinaryFrame(buf) {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let p = 0;
  const tag = bytes[p++];
  if (tag === 0x81) {
    const ok = bytes[p++] !== 0;
    const len = dv.getUint32(p, false); p += 4;
    const txt = len > 0 ? _td.decode(bytes.subarray(p, p + len)) : "";
    return ok
      ? { type: "auth_result", ok: true, identity: txt ? JSON.parse(txt) : null }
      : { type: "auth_result", ok: false, error: txt };
  }
  if (tag === 0x83) {
    const toTs = _readI64(dv, p); p += 8;
    const count = dv.getUint16(p, false); p += 2;
    const updates = [];
    for (let i = 0; i < count; i++) {
      const sLen = dv.getUint16(p, false); p += 2;
      const subId = _td.decode(bytes.subarray(p, p + sLen)); p += sLen;
      const ok = bytes[p++] !== 0;
      const pLen = dv.getUint32(p, false); p += 4;
      const payload = _td.decode(bytes.subarray(p, p + pLen)); p += pLen;
      updates.push(
        ok
          ? { sub_id: subId, ok: true, value: JSON.parse(payload) }
          : { sub_id: subId, ok: false, error: payload },
      );
    }
    return { type: "transition", to_ts: toTs, updates };
  }
  if (tag === 0x84 || tag === 0x85 || tag === 0x87) {
    const rLen = dv.getUint16(p, false); p += 2;
    const reqId = _td.decode(bytes.subarray(p, p + rLen)); p += rLen;
    const ok = bytes[p++] !== 0;
    const commitTs = tag === 0x84 ? _readI64(dv, p) : undefined;
    if (tag === 0x84) p += 8;
    const pLen = dv.getUint32(p, false); p += 4;
    const payload = _td.decode(bytes.subarray(p, p + pLen));
    const type = tag === 0x84 ? "mutation_result" : tag === 0x85 ? "action_result" : "query_result";
    return ok
      ? { type, req_id: reqId, ok: true, value: JSON.parse(payload), commit_ts: commitTs }
      : { type, req_id: reqId, ok: false, error: payload };
  }
  if (tag === 0x86) {
    return { type: "pong", ts: _readI64(dv, p) };
  }
  if (tag === 0x8f) {
    const mLen = dv.getUint32(p, false); p += 4;
    return { type: "error", message: _td.decode(bytes.subarray(p, p + mLen)) };
  }
  return { type: "error", message: `unknown binary tag ${tag}` };
}

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

const resolveRef = (r) => r?.ref ?? r;

export function optimisticAppend(ref, args, item) {
  const r = resolveRef(ref);
  return {
    optimisticUpdate(store) {
      const prev = store.getQuery(r, args) ?? [];
      store.setQuery(r, args, [...prev, typeof item === "function" ? item(prev) : item]);
    },
  };
}

function applyLiveReload(reason) {
  const links = reason === "css" && globalThis.document?.querySelectorAll?.('link[rel="stylesheet"]');
  if (links?.length) {
    const t = Date.now();
    for (const l of links) {
      const h = l.getAttribute("href")?.replace(/[?&]_cr=\d+/, "");
      if (h) l.setAttribute("href", `${h}${h.includes("?") ? "&" : "?"}_cr=${t}`);
    }
    return;
  }
  globalThis.location?.reload?.();
}

export class ConcaveClient {
  constructor(url, options = {}) {
    this.status = signal("connecting");
    this.commitTs = signal(0);
    this.identity = signal(null);

    this._binary = options.protocol ? options.protocol === "binary" : !options.webSocketImpl;
    this._wsUrl = normalizeWsUrl(url, this._binary);
    this._WsCtor = options.webSocketImpl ?? globalThis.WebSocket;
    this._ws = null;
    this._closed = false;
    this._reconnectAttempt = 0;
    this._reconnectTimer = null;
    this._nextId = 1;

    this._authToken = options.authToken ?? null;
    this._liveReload = options.liveReload ?? true;
    this._onReload = options.onReload ?? null;
    this._subsByKey = new Map();
    this._subsById = new Map();
    this._pending = new Map();
    this._inFlight = new Set();
    this._optimisticQueue = [];
    this._outboundQueue = [];

    this._connect();
  }

  _connect() {
    if (this._closed) return;
    this.status.set(this._reconnectAttempt > 0 ? "reconnecting" : "connecting");

    const ws = new this._WsCtor(this._wsUrl);
    if (this._binary) {
      ws.binaryType = "arraybuffer";
    }
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
        if (frame.req_id) this._inFlight.add(frame.req_id);
        ws.send(this._binary ? encodeBinaryFrame(frame) : JSON.stringify(frame));
      }
    });

    ws.addEventListener("message", (event) => {
      if (this._ws !== ws) return;
      try {
        if (event.data instanceof ArrayBuffer || ArrayBuffer.isView(event.data)) {
          this._handleServerFrame(decodeBinaryFrame(event.data));
        } else if (typeof Blob !== "undefined" && event.data instanceof Blob) {
          event.data.arrayBuffer().then((ab) => {
            if (this._ws === ws) this._handleServerFrame(decodeBinaryFrame(ab));
          });
        } else {
          const raw = typeof event.data === "string" ? event.data : String(event.data);
          this._handleServerFrame(JSON.parse(raw));
        }
      } catch (err) {
        console.error("[concave-client] malformed server frame:", err);
      }
    });

    const onDrop = () => {
      if (this._ws !== ws) return;
      this._ws = null;
      try { ws.close(); } catch {}
      this._failInFlightOnDisconnect();
      if (!this._closed) this._scheduleReconnect();
    };

    ws.addEventListener("close", onDrop);
    ws.addEventListener("error", () => {
      if (ws.readyState !== this._WsCtor.OPEN) onDrop();
    });
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
    if (this._inFlight.size === 0) return;
    const err = new Error("WebSocket disconnected");
    let removedAnyOpt = false;
    for (const reqId of this._inFlight) {
      const pending = this._pending.get(reqId);
      this._pending.delete(reqId);
      const idx = this._optimisticQueue.findIndex((o) => o.reqId === reqId);
      if (idx !== -1) {
        this._optimisticQueue.splice(idx, 1);
        removedAnyOpt = true;
      }
      pending?.reject(err);
    }
    this._inFlight.clear();
    if (removedAnyOpt) this._recomputeOptimisticSignals();
  }

  _sendRaw(payload) {
    if (this._ws && this._ws.readyState === this._WsCtor.OPEN) {
      if (payload.req_id) this._inFlight.add(payload.req_id);
      this._ws.send(this._binary ? encodeBinaryFrame(payload) : JSON.stringify(payload));
    } else if (payload.req_id) {
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
      case "mutation_result":
      case "action_result":
      case "query_result": {
        this._inFlight.delete(frame.req_id);
        const pending = this._pending.get(frame.req_id);
        this._pending.delete(frame.req_id);
        if (frame.ok) {
          if (frame.type === "mutation_result") {
            const opt = this._optimisticQueue.find((o) => o.reqId === frame.req_id);
            if (opt) {
              opt.resolvedCommitTs = frame.commit_ts ?? this.commitTs.peek();
              this._pruneOptimistic(this.commitTs.peek());
              this._recomputeOptimisticSignals();
            }
          }
          pending?.resolve(frame.value);
        } else {
          if (frame.type === "mutation_result") this._removeOptimistic(frame.req_id);
          pending?.reject(new Error(frame.error ?? `${frame.type.split("_")[0]} failed`));
        }
        break;
      }
      case "pong":
        break;
      case "reload": {
        if (this._onReload) {
          this._onReload(frame);
        } else if (this._liveReload) {
          applyLiveReload(frame.reason);
        }
        break;
      }
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
      getQuery: (ref, args) => overlay.get(subKey(resolveRef(ref).name, args)),
      setQuery: (ref, args, value) => {
        overlay.set(subKey(resolveRef(ref).name, args), value);
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
    const name = resolveRef(ref).name;
    const out = signal({
      status: "loading",
      data: undefined,
      error: undefined,
    });

    const isFn = typeof argsOrAccessor === "function";
    const dispose = effect(() => {
      const resolved = isFn ? argsOrAccessor() : argsOrAccessor;

      if (resolved === null || resolved === undefined) {
        out.set({ status: "paused", data: undefined, error: undefined });
        return;
      }

      const { entry, release } = this._acquireSub(name, resolved);
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

  _rpc(type, prefix, ref, args, opt) {
    const req_id = `${prefix}_${this._nextId++}`;
    if (opt) {
      this._optimisticQueue.push({ reqId: req_id, apply: opt });
      this._recomputeOptimisticSignals();
    }
    return new Promise((resolve, reject) => {
      this._pending.set(req_id, { resolve, reject });
      this._sendRaw({ type, req_id, name: resolveRef(ref).name, args });
    });
  }

  mutate(ref, args, options) {
    return this._rpc("mutation", "mut", ref, args, options?.optimisticUpdate);
  }

  optimisticAppend(ref, args, item) {
    return optimisticAppend(ref, args, item);
  }

  action(ref, args) {
    return this._rpc("action", "act", ref, args);
  }

  queryOnce(ref, args) {
    return this._rpc("query", "qry", ref, args);
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

function normalizeWsUrl(url, binary) {
  let base;
  if (url.startsWith("ws://") || url.startsWith("wss://")) {
    base = url.endsWith("/ws") ? url : `${url.replace(/\/$/, "")}/ws`;
  } else {
    const converted = url
      .replace(/^http:\/\//, "ws://")
      .replace(/^https:\/\//, "wss://");
    base = converted.endsWith("/ws")
      ? converted
      : `${converted.replace(/\/$/, "")}/ws`;
  }
  return binary && !base.includes("proto=") ? `${base}${base.includes("?") ? "&" : "?"}proto=bin` : base;
}
