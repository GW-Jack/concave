import type { Accessor, Dispose, Signal } from "./signals.js";

export type FunctionKind = "query" | "mutation" | "action";

export interface FunctionReference<Kind extends FunctionKind, Args, Result> {
  readonly kind: Kind;
  readonly name: string;
  readonly __args?: Args;
  readonly __result?: Result;
}

export type FunctionReferenceLike<Kind extends FunctionKind, Args, Result> =
  | FunctionReference<Kind, Args, Result>
  | { readonly ref: FunctionReference<Kind, Args, Result> };

export type ConnectionStatus =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "closed";

export interface ReloadEvent {
  readonly type: "reload";
  readonly reason: string;
}

export interface AuthIdentity {
  subject: string;
  issuer: string;
  name?: string | null;
  claims?: unknown;
}

export interface QueryState<T> {
  readonly status: "paused" | "loading" | "ready" | "error";
  readonly data: T | undefined;
  readonly error: string | undefined;
}

export interface OptimisticLocalStore {
  getQuery<Args, Result>(
    ref: FunctionReferenceLike<"query", Args, Result>,
    args: Args,
  ): Result | undefined;
  setQuery<Args, Result>(
    ref: FunctionReferenceLike<"query", Args, Result>,
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
  protocol?: "binary" | "json";
  liveReload?: boolean;
  onReload?: (event: ReloadEvent) => void;
}

export function optimisticAppend<Args, Item>(
  ref: FunctionReferenceLike<"query", Args, Item[]>,
  args: Args,
  item: Item | ((prev: Item[]) => Item),
): MutateOptions;

export declare class ConcaveClient {
  readonly status: Signal<ConnectionStatus>;
  readonly commitTs: Signal<number>;
  readonly identity: Signal<AuthIdentity | null>;

  constructor(url: string, options?: ConcaveClientOptions);

  setAuth(token: string | null): void;

  query<Args, Result>(
    ref: FunctionReferenceLike<"query", Args, Result>,
    argsOrAccessor: Args | Accessor<Args | null | undefined>,
  ): Accessor<QueryState<Result>> & { dispose: Dispose };

  mutate<Args, Result>(
    ref: FunctionReferenceLike<"mutation", Args, Result>,
    args: Args,
    options?: MutateOptions,
  ): Promise<Result>;

  optimisticAppend<Args, Item>(
    ref: FunctionReferenceLike<"query", Args, Item[]>,
    args: Args,
    item: Item | ((prev: Item[]) => Item),
  ): MutateOptions;

  action<Args, Result>(
    ref: FunctionReferenceLike<"action", Args, Result>,
    args: Args,
  ): Promise<Result>;

  queryOnce<Args, Result>(
    ref: FunctionReferenceLike<"query", Args, Result>,
    args: Args,
  ): Promise<Result>;

  close(): void;
}
