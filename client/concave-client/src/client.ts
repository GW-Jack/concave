import {
  type Accessor,
  type Dispose,
  type Signal,
  batch,
  effect,
  onCleanup,
  signal,
} from "./signals.ts";

export type FunctionKind = "query" | "mutation" | "action";

export interface FunctionReference<Kind extends FunctionKind, Args, Result> {
  readonly kind: Kind;
  readonly name: string;
  readonly __args?: Args;
  readonly __result?: Result;
}

export type ConnectionStatus =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "closed";

export interface AuthIdentity {
  subject: string;
  issuer: string;
  name?: string | null;
  claims?: unknown;
}

export interface QueryState<T> {
  readonly status: "loading" | "ready" | "error";
  readonly data: T | undefined;
  readonly error: string | undefined;
}

export interface OptimisticLocalStore {
  getQuery<Args, Result>(
    ref: FunctionReference<"query", Args, Result>,
    args: Args,
  ): Result | undefined;
  setQuery<Args, Result>(
    ref: FunctionReference<"query", Args, Result>,
    args: Args,
    value: Result,
  ): void;
}

export interface MutateOptions {
  optimisticUpdate?: (store: OptimisticLocalStore) => void;
}

interface QueryUpdateFrame {
  sub_id: string;
  ok: boolean;
  value?: unknown;
  error?: string;
}

type ServerFrame =
  | {
      type: "auth_result";
      ok: boolean;
      identity?: AuthIdentity;
      error?: string;
    }
  | {
      type: "transition";
      to_ts: number;
      updates: QueryUpdateFrame[];
    }
  | {
      type: "mutation_result";
      req_id: string;
      ok: boolean;
      value?: unknown;
      error?: string;
      commit_ts?: number;
    }
  | {
      type: "action_result";
      req_id: string;
      ok: boolean;
      value?: unknown;
      error?: string;
    }
  | { type: "pong"; ts: number }
  | { type: "error"; message: string };

interface SubscriptionEntry {
  subId: string;
  key: string;
  name: string;
  args: unknown;
  refCount: number;
  serverState: QueryState<unknown>;
  signal: Signal<QueryState<unknown>>;
}

interface PendingOptimistic {
  reqId: string;
  resolvedCommitTs?: number;
  apply: (store: OptimisticLocalStore) => void;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
}

function stableStringify(val: unknown): string {
  if (val === null || typeof val !== "object") {
    return JSON.stringify(val);
  }
  if (Array.isArray(val)) {
    return `[${val.map(stableStringify).join(",")}]`;
  }
  const obj = val as Record<string, unknown>;
  const keys = Object.keys(obj).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify(obj[k])}`).join(",")}}`;
}

function subKey(name: string, args: unknown): string {
  return `${name}:${stableStringify(args)}`;
}

export interface ConcaveClientOptions {
  webSocketImpl?: typeof WebSocket;
  authToken?: string | null;
}

export class ConcaveClient {
  readonly status: Signal<ConnectionStatus> = signal<ConnectionStatus>("connecting");
  readonly commitTs: Signal<number> = signal<number>(0);
  readonly identity: Signal<AuthIdentity | null> = signal<AuthIdentity | null>(null);

  private readonly wsUrl: string;
  private readonly WsCtor: typeof WebSocket;
  private ws: WebSocket | null = null;
  private closed = false;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private nextId = 1;

  private authToken: string | null = null;
  private readonly subsByKey = new Map<string, SubscriptionEntry>();
  private readonly subsById = new Map<string, SubscriptionEntry>();
  private readonly pendingMutations = new Map<string, PendingRequest>();
  private readonly pendingActions = new Map<string, PendingRequest>();
  private readonly optimisticQueue: PendingOptimistic[] = [];
  private readonly outboundQueue: string[] = [];

  constructor(url: string, options: ConcaveClientOptions = {}) {
    this.wsUrl = normalizeWsUrl(url);
    this.WsCtor = options.webSocketImpl ?? globalThis.WebSocket;
    this.authToken = options.authToken ?? null;
    this.connect();
  }

  private connect(): void {
    if (this.closed) return;
    this.status.set(this.reconnectAttempt > 0 ? "reconnecting" : "connecting");

    const ws = new this.WsCtor(this.wsUrl);
    this.ws = ws;

    ws.addEventListener("open", () => {
      if (this.ws !== ws) return;
      this.reconnectAttempt = 0;
      this.status.set("connected");

      if (this.authToken !== null) {
        this.sendRaw({ type: "authenticate", token: this.authToken });
      }

      for (const entry of this.subsByKey.values()) {
        this.sendRaw({
          type: "subscribe",
          sub_id: entry.subId,
          name: entry.name,
          args: entry.args,
        });
      }

      while (this.outboundQueue.length > 0) {
        ws.send(this.outboundQueue.shift()!);
      }
    });

    ws.addEventListener("message", (event) => {
      if (this.ws !== ws) return;
      try {
        const raw = typeof event.data === "string" ? event.data : String(event.data);
        this.handleServerFrame(JSON.parse(raw) as ServerFrame);
      } catch (err) {
        console.error("[concave-client] malformed server frame:", err);
      }
    });

    ws.addEventListener("close", () => {
      if (this.ws !== ws) return;
      this.ws = null;
      if (!this.closed) {
        this.scheduleReconnect();
      }
    });

    ws.addEventListener("error", () => {});
  }

  private scheduleReconnect(): void {
    this.status.set("reconnecting");
    const delayMs = Math.min(5000, 200 * 2 ** Math.min(this.reconnectAttempt, 5));
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delayMs);
  }

  private sendRaw(payload: unknown): void {
    const encoded = JSON.stringify(payload);
    if (this.ws && this.ws.readyState === this.WsCtor.OPEN) {
      this.ws.send(encoded);
    } else {
      this.outboundQueue.push(encoded);
    }
  }

  private handleServerFrame(frame: ServerFrame): void {
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
            const entry = this.subsById.get(upd.sub_id);
            if (!entry) continue;
            entry.serverState = upd.ok
              ? { status: "ready", data: upd.value, error: undefined }
              : { status: "error", data: undefined, error: upd.error ?? "query failed" };
          }
          this.pruneOptimistic(frame.to_ts);
          this.recomputeOptimisticSignals();
        });
        break;
      }
      case "mutation_result": {
        const pending = this.pendingMutations.get(frame.req_id);
        this.pendingMutations.delete(frame.req_id);
        if (frame.ok) {
          const opt = this.optimisticQueue.find((o) => o.reqId === frame.req_id);
          if (opt) {
            opt.resolvedCommitTs = frame.commit_ts ?? this.commitTs.peek();
            this.pruneOptimistic(this.commitTs.peek());
            this.recomputeOptimisticSignals();
          }
          pending?.resolve(frame.value);
        } else {
          this.removeOptimistic(frame.req_id);
          pending?.reject(new Error(frame.error ?? "mutation failed"));
        }
        break;
      }
      case "action_result": {
        const pending = this.pendingActions.get(frame.req_id);
        this.pendingActions.delete(frame.req_id);
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

  private pruneOptimistic(currentCommitTs: number): void {
    for (let i = this.optimisticQueue.length - 1; i >= 0; i -= 1) {
      const opt = this.optimisticQueue[i];
      if (opt.resolvedCommitTs !== undefined && currentCommitTs >= opt.resolvedCommitTs) {
        this.optimisticQueue.splice(i, 1);
      }
    }
  }

  private removeOptimistic(reqId: string): void {
    const idx = this.optimisticQueue.findIndex((o) => o.reqId === reqId);
    if (idx !== -1) {
      this.optimisticQueue.splice(idx, 1);
      this.recomputeOptimisticSignals();
    }
  }

  private recomputeOptimisticSignals(): void {
    const overlay = new Map<string, unknown>();
    for (const [k, entry] of this.subsByKey) {
      if (entry.serverState.status === "ready") {
        overlay.set(k, entry.serverState.data);
      }
    }

    const store: OptimisticLocalStore = {
      getQuery: (ref, args) => overlay.get(subKey(ref.name, args)) as never,
      setQuery: (ref, args, value) => {
        overlay.set(subKey(ref.name, args), value);
      },
    };

    for (const opt of this.optimisticQueue) {
      try {
        opt.apply(store);
      } catch (err) {
        console.error("[concave-client] optimistic update error:", err);
      }
    }

    batch(() => {
      for (const [k, entry] of this.subsByKey) {
        if (entry.serverState.status === "ready" && overlay.has(k)) {
          entry.signal.set({ status: "ready", data: overlay.get(k), error: undefined });
        } else {
          entry.signal.set(entry.serverState);
        }
      }
    });
  }

  setAuth(token: string | null): void {
    this.authToken = token;
    if (token === null) {
      this.identity.set(null);
    }
    this.sendRaw({ type: "authenticate", token });
  }

  private acquireSub(name: string, args: unknown): {
    entry: SubscriptionEntry;
    release: Dispose;
  } {
    const key = subKey(name, args);
    let entry = this.subsByKey.get(key);
    if (!entry) {
      const subId = `sub_${this.nextId++}`;
      const initial: QueryState<unknown> = {
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
        signal: signal<QueryState<unknown>>(initial),
      };
      this.subsByKey.set(key, entry);
      this.subsById.set(subId, entry);
      this.sendRaw({ type: "subscribe", sub_id: subId, name, args });
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
          this.subsByKey.delete(captured.key);
          this.subsById.delete(captured.subId);
          this.sendRaw({ type: "unsubscribe", sub_id: captured.subId });
        }
      },
    };
  }

  query<Args, Result>(
    ref: FunctionReference<"query", Args, Result>,
    argsOrAccessor: Args | Accessor<Args | null | undefined>,
  ): Accessor<QueryState<Result>> & { dispose: Dispose } {
    const out = signal<QueryState<Result>>({
      status: "loading",
      data: undefined,
      error: undefined,
    });

    const isFn = typeof argsOrAccessor === "function";
    const dispose = effect(() => {
      const resolved = isFn
        ? (argsOrAccessor as Accessor<Args | null | undefined>)()
        : argsOrAccessor;

      if (resolved === null || resolved === undefined) {
        out.set({ status: "loading", data: undefined, error: undefined });
        return;
      }

      const { entry, release } = this.acquireSub(ref.name, resolved);
      const stopMirror = effect(() => {
        out.set(entry.signal() as QueryState<Result>);
      });

      onCleanup(() => {
        stopMirror();
        release();
      });
    });

    const accessor = (() => out()) as Accessor<QueryState<Result>> & {
      dispose: Dispose;
    };
    accessor.dispose = dispose;
    return accessor;
  }

  mutate<Args, Result>(
    ref: FunctionReference<"mutation", Args, Result>,
    args: Args,
    options?: MutateOptions,
  ): Promise<Result> {
    const reqId = `mut_${this.nextId++}`;
    if (options?.optimisticUpdate) {
      this.optimisticQueue.push({
        reqId,
        apply: options.optimisticUpdate,
      });
      this.recomputeOptimisticSignals();
    }

    return new Promise<Result>((resolve, reject) => {
      this.pendingMutations.set(reqId, {
        resolve: (v) => resolve(v as Result),
        reject,
      });
      this.sendRaw({
        type: "mutation",
        req_id: reqId,
        name: ref.name,
        args,
      });
    });
  }

  action<Args, Result>(
    ref: FunctionReference<"action", Args, Result>,
    args: Args,
  ): Promise<Result> {
    const reqId = `act_${this.nextId++}`;
    return new Promise<Result>((resolve, reject) => {
      this.pendingActions.set(reqId, {
        resolve: (v) => resolve(v as Result),
        reject,
      });
      this.sendRaw({
        type: "action",
        req_id: reqId,
        name: ref.name,
        args,
      });
    });
  }

  close(): void {
    this.closed = true;
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
    this.ws = null;
    this.status.set("closed");
  }
}

function normalizeWsUrl(url: string): string {
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
