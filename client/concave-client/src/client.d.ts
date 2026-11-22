import type { Accessor, Dispose, Signal } from "./signals.js";

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

export interface ConcaveClientOptions {
  webSocketImpl?: typeof WebSocket;
  authToken?: string | null;
}

export declare class ConcaveClient {
  readonly status: Signal<ConnectionStatus>;
  readonly commitTs: Signal<number>;
  readonly identity: Signal<AuthIdentity | null>;

  constructor(url: string, options?: ConcaveClientOptions);

  setAuth(token: string | null): void;

  query<Args, Result>(
    ref: FunctionReference<"query", Args, Result>,
    argsOrAccessor: Args | Accessor<Args | null | undefined>,
  ): Accessor<QueryState<Result>> & { dispose: Dispose };

  mutate<Args, Result>(
    ref: FunctionReference<"mutation", Args, Result>,
    args: Args,
    options?: MutateOptions,
  ): Promise<Result>;

  action<Args, Result>(
    ref: FunctionReference<"action", Args, Result>,
    args: Args,
  ): Promise<Result>;

  close(): void;
}
