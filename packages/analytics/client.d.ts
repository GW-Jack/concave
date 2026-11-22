import type { ConcaveClient, QueryState } from "../../client/concave-client/src/client.js";
import type { Accessor, Dispose } from "../../client/concave-client/src/signals.js";

export interface Prop {
  key: string;
  value: string;
}

export interface PropertyFilter {
  key: string;
  op: "eq" | "neq" | "contains" | "not_contains" | "is_set" | "is_not_set" | "in" | "not_in";
  value: string;
}

export interface FlagVariant {
  key: string;
  weight: number;
}

export interface FlagEvaluation {
  key: string;
  enabled: boolean;
  variant: string;
  reason: string;
}

export interface PersonProfile {
  found: boolean;
  distinct_id: string;
  properties: Prop[];
  aliases: string[];
  first_seen_ms: number;
  last_seen_ms: number;
  event_count: number;
}

export interface CreateAnalyticsOptions {
  distinctId?: string;
  sessionId?: string;
  storageKeyPrefix?: string;
  storage?: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null;
  defaultGroup?: { type: string; key: string } | null;
}

export interface CaptureMeta {
  distinctId?: string;
  sessionId?: string;
  groupType?: string;
  groupKey?: string;
  timestampMs?: number;
}

export interface AnalyticsClient {
  readonly distinctId: string;
  readonly anonId: string;
  readonly sessionId: string;
  capture(
    event: string,
    properties?: Record<string, unknown> | Prop[],
    meta?: CaptureMeta,
  ): Promise<string>;
  captureBatch(
    events: Array<{
      event: string;
      properties?: Record<string, unknown> | Prop[];
      distinctId?: string;
      sessionId?: string;
      groupType?: string;
      groupKey?: string;
      timestampMs?: number;
    }>,
  ): Promise<{ accepted: number; event_ids: string[] }>;
  capturePageview(extraProps?: Record<string, unknown>): Promise<string>;
  identify(
    newDistinctId: string,
    opts?: {
      set?: Record<string, unknown>;
      setOnce?: Record<string, unknown>;
      anonId?: string;
    },
  ): Promise<PersonProfile>;
  alias(aliasId: string, targetDistinctId?: string): Promise<boolean>;
  group(type: string, key: string): void;
  reset(): void;
  subscribeFlags(
    overrideProperties?: Record<string, unknown> | Prop[],
    targetDistinctId?: string,
  ): Accessor<QueryState<FlagEvaluation[]>> & { dispose: Dispose };
  subscribeFlag(
    key: string,
    overrideProperties?: Record<string, unknown> | Prop[],
    targetDistinctId?: string,
  ): Accessor<QueryState<FlagEvaluation>> & { dispose: Dispose };
  evaluateFlagAndTrack(
    key: string,
    overrideProperties?: Record<string, unknown> | Prop[],
    targetDistinctId?: string,
  ): Promise<FlagEvaluation>;
  toProps: typeof toProps;
  fromProps: typeof fromProps;
}

export declare function toProps(
  input: Record<string, unknown> | Prop[] | null | undefined,
): Prop[];

export declare function fromProps(
  props: Prop[] | null | undefined,
): Record<string, string>;

export declare function createAnalytics(
  client: ConcaveClient,
  analyticsApi: Record<string, any>,
  options?: CreateAnalyticsOptions,
): AnalyticsClient;
