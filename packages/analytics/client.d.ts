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

export interface FeatureFlagDoc {
  id: string;
  created_at: number;
  key: string;
  name: string;
  active: boolean;
  rollout_pct: number;
  filters: PropertyFilter[];
  variants: FlagVariant[];
  updated_at_ms: number;
}

export interface EventDoc {
  id: string;
  created_at: number;
  distinct_id: string;
  event: string;
  timestamp_ms: number;
  session_id: string;
  group_type: string;
  group_key: string;
  properties: Prop[];
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

export interface SummaryResult {
  total_events: number;
  unique_persons: number;
  active_sessions: number;
  top_events: Array<{
    event: string;
    count: number;
    unique_persons: number;
  }>;
}

export interface TrendResult {
  event: string;
  total_events: number;
  unique_persons: number;
  buckets: Array<{
    bucket_start_ms: number;
    count: number;
    unique_persons: number;
  }>;
  breakdown: Array<{
    value: string;
    count: number;
    unique_persons: number;
  }>;
}

export interface FunnelResult {
  total_entered: number;
  overall_conversion_rate: number;
  steps: Array<{
    step_index: number;
    event: string;
    count: number;
    conversion_rate_from_prev: number;
    conversion_rate_from_start: number;
    avg_time_from_prev_ms: number;
  }>;
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

export type PropsInput = Record<string, unknown> | Prop[];

export interface AnalyticsClient {
  readonly distinctId: string;
  readonly anonId: string;
  readonly sessionId: string;
  capture(
    event: string,
    properties?: PropsInput,
    meta?: CaptureMeta,
  ): Promise<string>;
  captureBatch(
    events: Array<{
      event: string;
      properties?: PropsInput;
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
    overrideProperties?: PropsInput | (() => PropsInput),
    targetDistinctId?: string | (() => string | null | undefined),
  ): Accessor<QueryState<FlagEvaluation[]>> & { dispose: Dispose };
  subscribeFlag(
    key: string,
    overrideProperties?: PropsInput | (() => PropsInput),
    targetDistinctId?: string | (() => string | null | undefined),
  ): Accessor<QueryState<FlagEvaluation>> & { dispose: Dispose };
  subscribeListFlags(): Accessor<QueryState<FeatureFlagDoc[]>> & { dispose: Dispose };
  subscribeSummary(
    opts?:
      | { from_ms?: number; to_ms?: number; top_n?: number }
      | (() => { from_ms?: number; to_ms?: number; top_n?: number } | null),
  ): Accessor<QueryState<SummaryResult>> & { dispose: Dispose };
  subscribeTrends(
    event: string,
    opts?: {
      from_ms?: number;
      to_ms?: number;
      bucket_ms?: number;
      breakdown_property?: string;
      filters?: PropertyFilter[];
    },
  ): Accessor<QueryState<TrendResult>> & { dispose: Dispose };
  subscribeFunnel(
    steps: string[],
    opts?:
      | {
          from_ms?: number;
          to_ms?: number;
          conversion_window_ms?: number;
          filters?: PropertyFilter[];
        }
      | (() => {
          from_ms?: number;
          to_ms?: number;
          conversion_window_ms?: number;
          filters?: PropertyFilter[];
        } | null),
  ): Accessor<QueryState<FunnelResult>> & { dispose: Dispose };
  subscribeRecentEvents(
    opts?:
      | { event?: string; limit?: number }
      | (() => { event?: string; limit?: number } | null),
  ): Accessor<QueryState<EventDoc[]>> & { dispose: Dispose };
  evaluateFlagAndTrack(
    key: string,
    overrideProperties?: PropsInput,
    targetDistinctId?: string,
  ): Promise<FlagEvaluation>;
  upsertFlag(flag: {
    key: string;
    name?: string;
    active: boolean;
    rollout_pct?: number;
    filters?: PropertyFilter[];
    variants?: FlagVariant[];
  }): Promise<string>;
  deleteFlag(key: string): Promise<boolean>;
  isEnabled(evals: FlagEvaluation[] | undefined, key: string, fallback?: boolean): boolean;
  getVariant(evals: FlagEvaluation[] | undefined, key: string, fallback?: string): string;
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
