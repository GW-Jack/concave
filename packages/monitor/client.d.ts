import type { ConcaveClient, QueryState } from "../../client/concave-client/src/client.js";
import type { Accessor, Dispose } from "../../client/concave-client/src/signals.js";

export interface Attr {
  key: string;
  value: string;
}

export type LogLevel = "debug" | "info" | "warn" | "error" | "fatal";
export type IssueStatus = "open" | "resolved" | "ignored";
export type MetricKind = "counter" | "gauge" | "timing";
export type AlertKind = "error_count" | "log_count" | "metric";
export type AlertAgg = "count" | "sum" | "avg" | "min" | "max" | "p50" | "p95" | "p99";
export type AlertOp = "gt" | "gte" | "lt" | "lte" | "eq";

export interface IssueDoc {
  id: string;
  created_at: number;
  fingerprint: string;
  title: string;
  source: string;
  error_type: string;
  level: string;
  status: IssueStatus;
  count: number;
  first_seen_ms: number;
  last_seen_ms: number;
  last_message: string;
  last_stack: string;
  last_trace_id: string;
  last_user_id: string;
  attrs: Attr[];
  resolved_at_ms: number;
}

export interface LogDoc {
  id: string;
  created_at: number;
  timestamp_ms: number;
  level: LogLevel;
  level_num: number;
  service: string;
  fn_name: string;
  trace_id: string;
  span_id: string;
  duration_ms: number;
  status: string;
  message: string;
  attrs: Attr[];
}

export interface MetricBucket {
  bucket_start_ms: number;
  count: number;
  sum: number;
  min: number;
  max: number;
  avg: number;
  p50: number;
  p95: number;
  p99: number;
}

export interface MetricSeriesResult {
  name: string;
  count: number;
  sum: number;
  min: number;
  max: number;
  avg: number;
  p50: number;
  p95: number;
  p99: number;
  buckets: MetricBucket[];
}

export interface AlertRuleDoc {
  id: string;
  created_at: number;
  key: string;
  name: string;
  active: boolean;
  kind: AlertKind;
  target: string;
  aggregation: AlertAgg;
  op: AlertOp;
  threshold: number;
  window_ms: number;
  cooldown_ms: number;
  webhook_url: string;
  status: "ok" | "firing" | "acked";
  last_value: number;
  last_eval_ms: number;
  last_triggered_ms: number;
  updated_at_ms: number;
}

export interface IncidentDoc {
  id: string;
  created_at: number;
  rule_key: string;
  rule_name: string;
  status: "firing" | "acked" | "resolved";
  triggered_at_ms: number;
  resolved_at_ms: number;
  trigger_value: number;
  threshold: number;
  message: string;
  webhook_delivered: boolean;
}

export interface OverviewResult {
  open_issues: number;
  total_issues: number;
  error_events_in_window: number;
  error_logs_in_window: number;
  firing_alerts: number;
  active_rules: number;
  top_issues: Array<{
    id: string;
    fingerprint: string;
    title: string;
    source: string;
    level: string;
    status: string;
    count: number;
    last_seen_ms: number;
  }>;
  services: string[];
}

export interface CaptureErrorResult {
  issue_id: string;
  fingerprint: string;
  is_new: boolean;
  reopened: boolean;
  count: number;
}

export interface EvaluateAndNotifyResult {
  evaluated: number;
  firing: number;
  resolved: number;
  webhooks_sent: number;
  webhooks_failed: number;
}

export interface PruneResult {
  deleted_logs: number;
  deleted_metrics: number;
  deleted_incidents: number;
}

export type AttrsInput = Record<string, unknown> | Attr[] | null | undefined;

export function toAttrs(input: AttrsInput): Attr[];
export function fromAttrs(attrs: Attr[] | null | undefined): Record<string, string>;

export interface CreateMonitorOptions {
  service?: string;
  release?: string;
  environment?: string;
  captureGlobalErrors?: boolean;
  maxBreadcrumbs?: number;
}

export interface MonitorClient {
  addBreadcrumb(category: string, message: string): void;
  captureException(
    err: unknown,
    ctx?: {
      source?: string;
      errorType?: string;
      level?: LogLevel;
      traceId?: string;
      userId?: string;
      fingerprint?: string;
      attrs?: AttrsInput;
      timestampMs?: number;
    },
  ): Promise<CaptureErrorResult>;
  updateIssueStatus(issueId: string, status: IssueStatus): Promise<boolean>;
  log(
    level: LogLevel,
    message: string,
    opts?: {
      service?: string;
      fnName?: string;
      traceId?: string;
      spanId?: string;
      durationMs?: number;
      status?: string;
      attrs?: AttrsInput;
      timestampMs?: number;
    },
  ): Promise<string>;
  metric(
    name: string,
    value: number,
    opts?: {
      kind?: MetricKind;
      service?: string;
      attrs?: AttrsInput;
      timestampMs?: number;
    },
  ): Promise<string>;
  time<T>(
    name: string,
    fn: (traceId: string) => Promise<T>,
    opts?: { service?: string; traceId?: string; attrs?: Record<string, unknown> },
  ): Promise<T>;
  upsertAlertRule(rule: {
    key: string;
    name?: string;
    active?: boolean;
    kind: AlertKind;
    target?: string;
    aggregation?: AlertAgg;
    op?: AlertOp;
    threshold: number;
    window_ms?: number;
    cooldown_ms?: number;
    webhook_url?: string;
  }): Promise<string>;
  deleteAlertRule(key: string): Promise<boolean>;
  acknowledgeIncident(incidentId: string): Promise<boolean>;
  evaluateAlerts(): Promise<{
    evaluated: number;
    firing: number;
    resolved: number;
    notifications: Array<{
      incident_id: string;
      rule_key: string;
      rule_name: string;
      event: string;
      webhook_url: string;
      value: number;
      threshold: number;
      message: string;
      timestamp_ms: number;
    }>;
  }>;
  evaluateAndNotify(): Promise<EvaluateAndNotifyResult>;
  prune(opts?: { retention_ms?: number; max_delete?: number }): Promise<PruneResult>;
  subscribeOverview(
    opts?:
      | { window_ms?: number; top_n?: number }
      | Accessor<{ window_ms?: number; top_n?: number } | null>,
  ): Accessor<QueryState<OverviewResult>> & { dispose: Dispose };
  subscribeIssues(
    opts?:
      | { status?: string; source?: string; limit?: number }
      | Accessor<{ status?: string; source?: string; limit?: number } | null>,
  ): Accessor<QueryState<IssueDoc[]>> & { dispose: Dispose };
  subscribeLogs(
    opts?:
      | { service?: string; level?: string; fn_name?: string; limit?: number }
      | Accessor<{ service?: string; level?: string; fn_name?: string; limit?: number } | null>,
  ): Accessor<QueryState<LogDoc[]>> & { dispose: Dispose };
  subscribeSearchLogs(
    queryText: string | Accessor<string | null>,
    limit?: number,
  ): Accessor<QueryState<LogDoc[]>> & { dispose: Dispose };
  subscribeTrace(
    traceId: string | Accessor<string | null>,
    limit?: number,
  ): Accessor<QueryState<LogDoc[]>> & { dispose: Dispose };
  subscribeMetric(
    name: string,
    opts?: { service?: string; from_ms?: number; to_ms?: number; bucket_ms?: number },
  ): Accessor<QueryState<MetricSeriesResult>> & { dispose: Dispose };
  subscribeAlerts(): Accessor<QueryState<AlertRuleDoc[]>> & { dispose: Dispose };
  subscribeIncidents(
    opts?: { status?: string; rule_key?: string; limit?: number },
  ): Accessor<QueryState<IncidentDoc[]>> & { dispose: Dispose };
  dispose(): void;
  toAttrs: typeof toAttrs;
  fromAttrs: typeof fromAttrs;
}

export function createMonitor(
  client: ConcaveClient,
  monitorApi: Record<string, any>,
  options?: CreateMonitorOptions,
): MonitorClient;
