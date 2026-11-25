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

const MAX_U16 = 0xffff;
const MAX_U32 = 0xffffffff;
const MAX_OUTBOUND_QUEUE = 256;

function _assertLen(len, max, label) {
  if (len > max) {
    throw new RangeError(`${label} length ${len} exceeds maximum ${max}`);
  }
}

function encodeBinaryFrame(msg) {
  if (msg.type === "authenticate") {
    if (msg.token === null || msg.token === undefined) {
      return new Uint8Array([0x01, 0]);
    }
    const tb = _te.encode(msg.token);
    _assertLen(tb.length, MAX_U16, "auth token");
    const out = new Uint8Array(4 + tb.length);
    out[0] = 0x01;
    out[1] = 1;
    new DataView(out.buffer).setUint16(2, tb.length, false);
    out.set(tb, 4);
    return out;
  }
  if (msg.type === "unsubscribe") {
    const sb = _te.encode(msg.sub_id);
    _assertLen(sb.length, MAX_U16, "sub_id");
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
  _assertLen(idB.length, MAX_U16, "frame id");
  _assertLen(nameB.length, MAX_U16, "function name");
  _assertLen(argsB.length, MAX_U32, "args payload");
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
  if (bytes.byteLength < 1) {
    return { type: "error", message: "truncated binary frame" };
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let p = 0;
  const has = (n) => n >= 0 && p + n <= bytes.byteLength;
  const tag = bytes[p++];
  if (tag === 0x81) {
    if (!has(5)) return { type: "error", message: "truncated binary frame" };
    const ok = bytes[p++] !== 0;
    const len = dv.getUint32(p, false); p += 4;
    if (!has(len)) return { type: "error", message: "truncated binary frame" };
    const txt = len > 0 ? _td.decode(bytes.subarray(p, p + len)) : "";
    return ok
      ? { type: "auth_result", ok: true, identity: txt ? JSON.parse(txt) : null }
      : { type: "auth_result", ok: false, error: txt };
  }
  if (tag === 0x83) {
    if (!has(10)) return { type: "error", message: "truncated binary frame" };
    const toTs = _readI64(dv, p); p += 8;
    const count = dv.getUint16(p, false); p += 2;
    const updates = [];
    for (let i = 0; i < count; i++) {
      if (!has(2)) return { type: "error", message: "truncated binary frame" };
      const sLen = dv.getUint16(p, false); p += 2;
      if (!has(sLen + 5)) return { type: "error", message: "truncated binary frame" };
      const subId = _td.decode(bytes.subarray(p, p + sLen)); p += sLen;
      const ok = bytes[p++] !== 0;
      const pLen = dv.getUint32(p, false); p += 4;
      if (!has(pLen)) return { type: "error", message: "truncated binary frame" };
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
    if (!has(2)) return { type: "error", message: "truncated binary frame" };
    const rLen = dv.getUint16(p, false); p += 2;
    const headerExtra = tag === 0x84 ? 13 : 5;
    if (!has(rLen + headerExtra)) return { type: "error", message: "truncated binary frame" };
    const reqId = _td.decode(bytes.subarray(p, p + rLen)); p += rLen;
    const ok = bytes[p++] !== 0;
    const commitTs = tag === 0x84 ? _readI64(dv, p) : undefined;
    if (tag === 0x84) p += 8;
    const pLen = dv.getUint32(p, false); p += 4;
    if (!has(pLen)) return { type: "error", message: "truncated binary frame" };
    const payload = _td.decode(bytes.subarray(p, p + pLen));
    const type = tag === 0x84 ? "mutation_result" : tag === 0x85 ? "action_result" : "query_result";
    return ok
      ? { type, req_id: reqId, ok: true, value: JSON.parse(payload), commit_ts: commitTs }
      : { type, req_id: reqId, ok: false, error: payload };
  }
  if (tag === 0x86) {
    if (!has(8)) return { type: "error", message: "truncated binary frame" };
    return { type: "pong", ts: _readI64(dv, p) };
  }
  if (tag === 0x8f) {
    if (!has(4)) return { type: "error", message: "truncated binary frame" };
    const mLen = dv.getUint32(p, false); p += 4;
    if (!has(mLen)) return { type: "error", message: "truncated binary frame" };
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

function _parseJwtPayload(token) {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    let jsonStr;
    if (typeof atob === "function") {
      const bin = atob(padded);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
      jsonStr = _td.decode(bytes);
    } else if (typeof Buffer !== "undefined") {
      jsonStr = Buffer.from(padded, "base64").toString("utf8");
    } else {
      return null;
    }
    const payload = JSON.parse(jsonStr);
    return payload && typeof payload === "object" ? payload : null;
  } catch {
    return null;
  }
}

function _parseJwtExpMs(token) {
  const payload = _parseJwtPayload(token);
  return payload && typeof payload.exp === "number" && Number.isFinite(payload.exp)
    ? payload.exp * 1000
    : null;
}

function _isSameJwtUser(prevToken, nextToken) {
  if (!prevToken || !nextToken) return false;
  const p1 = _parseJwtPayload(prevToken);
  const p2 = _parseJwtPayload(nextToken);
  if (!p1 || !p2) return false;
  if (typeof p1.sub !== "string" || !p1.sub || p1.sub !== p2.sub) return false;
  return (p1.iss ?? null) === (p2.iss ?? null);
}

export class ConcaveClient {
  constructor(url, options = {}) {
    this.status = signal("connecting");
    this.commitTs = signal(0);
    this.identity = signal(null);
    this.isAuthenticated = signal(false);

    this._binary = options.protocol ? options.protocol === "binary" : !options.webSocketImpl;
    this._wsUrl = normalizeWsUrl(url, this._binary);
    this._WsCtor = options.webSocketImpl ?? globalThis.WebSocket;
    this._ws = null;
    this._closed = false;
    this._reconnectAttempt = 0;
    this._reconnectTimer = null;
    this._nextId = 1;

    this._authToken = options.authToken ?? null;
    this._fetchToken = typeof options.fetchToken === "function" ? options.fetchToken : null;
    this._refreshMarginMs = options.refreshMarginMs ?? 30_000;
    this._refreshTimer = null;
    this._refreshPromise = null;
    this._refreshPromiseForced = false;
    this._authRejectionRetried = false;
    this._authGen = 0;
    this._hasOpenedOnce = false;
    this._warnIfInsecureAuth(this._authToken);
    if (this._authToken && this._fetchToken) {
      this._scheduleTokenRefresh();
    }
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
      this._authRejectionRetried = false;
      this.status.set("connected");

      const flushOnOpen = () => {
        if (this._ws !== ws || ws.readyState !== this._WsCtor.OPEN) return;

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
      };

      const isBootstrap = !this._hasOpenedOnce;
      this._hasOpenedOnce = true;
      if (this._fetchToken) {
        this._refreshAuthToken(false, { send: false, bootstrap: isBootstrap }).finally(flushOnOpen);
      } else {
        flushOnOpen();
      }
    });

    ws.addEventListener("message", (event) => {
      if (this._ws !== ws) return;
      try {
        if (event.data instanceof ArrayBuffer || ArrayBuffer.isView(event.data)) {
          this._handleServerFrame(decodeBinaryFrame(event.data));
        } else if (typeof Blob !== "undefined" && event.data instanceof Blob) {
          event.data
            .arrayBuffer()
            .then((ab) => {
              if (this._ws === ws) this._handleServerFrame(decodeBinaryFrame(ab));
            })
            .catch((err) => {
              console.error("[concave-client] malformed binary blob frame:", err);
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

  _warnIfInsecureAuth(token) {
    if (!token || !this._wsUrl.startsWith("ws://")) return;
    try {
      const host = new URL(this._wsUrl).hostname;
      if (host !== "localhost" && host !== "127.0.0.1" && host !== "::1" && host !== "[::1]") {
        console.warn("[concave-client] sending auth token over unencrypted ws:// connection");
      }
    } catch {}
  }

  _scheduleReconnect() {
    this.status.set("reconnecting");
    const baseMs = Math.min(5000, 200 * 2 ** Math.min(this._reconnectAttempt, 5));
    const delayMs = Math.round(baseMs * (0.75 + Math.random() * 0.5));
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
      if (this._outboundQueue.length >= MAX_OUTBOUND_QUEUE) {
        const pending = this._pending.get(payload.req_id);
        this._pending.delete(payload.req_id);
        this._removeOptimistic(payload.req_id);
        pending?.reject(new Error("Outbound RPC queue full"));
        return;
      }
      // Only queue RPCs; `authenticate` and active `subscribe` frames are re-emitted cleanly on `open`
      // without duplicating subscriptions or sending stale auth frames.
      this._outboundQueue.push(payload);
    }
  }

  _handleServerFrame(frame) {
    switch (frame.type) {
      case "auth_result": {
        if (frame.ok) {
          this._authRejectionRetried = false;
          this._setIdentity(frame.identity ?? null);
        } else if (this._fetchToken && !this._authRejectionRetried) {
          this._authRejectionRetried = true;
          this._refreshAuthToken(true, { send: true }).then((nextToken) => {
            if (this._closed) return;
            if (!nextToken) {
              this._clearAuthOnFailure(frame.error);
            }
          });
        } else {
          this._clearAuthOnFailure(frame.error);
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

  _parseJwtExpMs(token) {
    return _parseJwtExpMs(token);
  }

  _setIdentity(identity) {
    batch(() => {
      this.identity.set(identity);
      this.isAuthenticated.set(identity !== null);
    });
  }

  _clearRefreshTimer() {
    if (this._refreshTimer !== null) {
      clearTimeout(this._refreshTimer);
      this._refreshTimer = null;
    }
  }

  _scheduleTokenRefresh() {
    this._clearRefreshTimer();
    if (this._closed || !this._fetchToken || !this._authToken) return;
    const expMs = this._parseJwtExpMs(this._authToken);
    if (expMs === null) return;
    const delayMs = Math.max(1000, expMs - Date.now() - this._refreshMarginMs);
    this._refreshTimer = setTimeout(() => {
      this._refreshTimer = null;
      if (this._closed || !this._fetchToken) return;
      void this._refreshAuthToken(true, { send: true });
    }, delayMs);
  }

  async _refreshAuthToken(forceRefresh = false, { send = true, bootstrap = false } = {}) {
    if (!this._fetchToken || this._closed) return null;
    if (this._refreshPromise && (!forceRefresh || this._refreshPromiseForced)) {
      return this._refreshPromise;
    }
    const fetcher = this._fetchToken;
    const gen = this._authGen;
    const run = (async () => {
      try {
        const token = await fetcher({ forceRefresh });
        if (this._closed || this._fetchToken !== fetcher || this._authGen !== gen) return null;
        const next = token ?? null;
        this._applyAuthToken(next, { send, bootstrap, resetRetry: false, bumpGen: false });
        return next;
      } catch (err) {
        console.warn("[concave-client] fetchToken failed:", err);
        return null;
      } finally {
        if (this._refreshPromise === run) {
          this._refreshPromise = null;
          this._refreshPromiseForced = false;
        }
      }
    })();
    this._refreshPromise = run;
    this._refreshPromiseForced = forceRefresh;
    return run;
  }

  _resetAuthContextState() {
    this._optimisticQueue.length = 0;
    if (this._outboundQueue.length > 0) {
      const dropped = this._outboundQueue.splice(0);
      const err = new Error("Auth context changed");
      for (const frame of dropped) {
        if (frame.req_id) {
          const pending = this._pending.get(frame.req_id);
          this._pending.delete(frame.req_id);
          pending?.reject(err);
        }
      }
    }
    if (this._subsByKey.size > 0) {
      batch(() => {
        for (const entry of this._subsByKey.values()) {
          const loading = { status: "loading", data: undefined, error: undefined };
          entry.serverState = loading;
          entry.signal.set(loading);
        }
      });
    }
  }

  _clearAuthOnFailure(error) {
    this._authGen += 1;
    this._clearRefreshTimer();
    this._authToken = null;
    this._setIdentity(null);
    this._resetAuthContextState();
    console.warn("[concave-client] auth rejected:", error);
  }

  _applyAuthToken(token, { send = true, bootstrap = false, resetRetry = true, bumpGen = true } = {}) {
    const nextToken = token ?? null;
    if (bumpGen) this._authGen += 1;
    if (resetRetry) this._authRejectionRetried = false;
    this._warnIfInsecureAuth(nextToken);
    const prevToken = this._authToken;
    const changed = prevToken !== nextToken;
    this._authToken = nextToken;

    if (nextToken === null) {
      this._clearRefreshTimer();
    } else {
      this._scheduleTokenRefresh();
    }

    if (changed) {
      const sameUserRotation = _isSameJwtUser(prevToken, nextToken);
      const initialBootstrap = bootstrap && prevToken === null && nextToken !== null;
      if (!sameUserRotation && !initialBootstrap) {
        this._setIdentity(null);
        this._resetAuthContextState();
      }
    }

    if (send) {
      this._sendRaw({ type: "authenticate", token: nextToken });
    }
  }

  getToken() {
    return this._authToken;
  }

  setTokenFetcher(fn) {
    this._fetchToken = typeof fn === "function" ? fn : null;
    this._authRejectionRetried = false;
    if (this._fetchToken) {
      if (this._authToken) {
        this._scheduleTokenRefresh();
      } else if (this._ws && this._ws.readyState === this._WsCtor.OPEN) {
        void this._refreshAuthToken(false, { send: true });
      }
    } else {
      this._clearRefreshTimer();
    }
  }

  setAuth(token) {
    this._applyAuthToken(token, { send: true, bootstrap: false, resetRetry: true, bumpGen: true });
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
    this._clearRefreshTimer();
    if (this._reconnectTimer !== null) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    this._ws?.close();
    this._ws = null;
    const err = new Error("Client closed");
    for (const pending of this._pending.values()) {
      pending.reject(err);
    }
    this._pending.clear();
    this._inFlight.clear();
    this._outboundQueue.length = 0;
    this._optimisticQueue.length = 0;
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
