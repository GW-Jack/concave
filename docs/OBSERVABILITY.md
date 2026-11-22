# Observability & Monitoring in Concave

Concave intentionally separates observability into **two clean layers** with a strict boundary between what the **platform operator** owns and what **application maintainers** own and can act on:

1. **Layer 1 — Platform Reliability Telemetry (Built into the Zig Host)**: Zero-allocation, lock-free runtime metrics and structured JSON logs owned by the Concave platform operator. Completely storage-independent so visibility stays alive even when WAL/Postgres is degraded.
2. **Layer 2 — Application Monitoring Component (`packages/monitor`)**: A reusable, zero-dependency pure-Roc component + embedded browser/Node ESM client (`/_concave/monitor.js`) giving app maintainers grouped error tracking, searchable live logs, custom metrics with percentiles, and webhook alerts—without exposing noisy infra metrics they don't control.

---

## Layer 1: Platform Operator Telemetry (Zig Host Runtime)

Built directly into `ConcaveEngine` (`zig/runtime/metrics.zig`) using lock-free atomics and fixed-bucket latency histograms—zero heap allocations on the request hot path and zero database writes.

### Operator Endpoints

Protected by `CONCAVE_OPERATOR_TOKEN` (falls back to `CONCAVE_ADMIN_KEY`, or allowed locally when `CONCAVE_ALLOW_DEV_TOKENS=true` and neither key is set). Pass the token via `Authorization: Bearer <token>` or `?token=<token>`.

| Endpoint | Format | Purpose |
| --- | --- | --- |
| `GET /_internal/metrics` | Prometheus / OpenMetrics (`text/plain; version=0.0.4`) | Scrape directly from Cloud Monitoring, Prometheus, or Grafana |
| `GET /_internal/status` | JSON (`application/json`) | Instant human/CLI reliability snapshot |

#### Exported Metrics
- **Health & Replication**: `concave_up{storage="wal|postgres"}`, `concave_uptime_seconds`, `concave_commit_ts`, `concave_commit_lag`
- **WebSockets & Reactivity**: `concave_active_clients`, `concave_active_subscriptions`, `concave_ws_connections_total`, `concave_ws_invalidations_total`, `concave_ws_transitions_sent_total`
- **RPC Throughput & Errors**: `concave_rpcs_total{kind="query|mutation|action|http_route",status="ok|error"}`
- **OCC & Storage**: `concave_occ_retries_total`, `concave_occ_exhausted_total`, `concave_storage_commits_total`, `concave_storage_errors_total`
- **Scheduler & HTTP**: `concave_scheduler_jobs_total{status="ok|error"}`, `concave_http_requests_total`, `concave_http_errors_total{class="4xx|5xx"}`
- **Latency Histograms** (buckets `1ms` .. `5s`, `_sum`, `_count`):
  - `concave_query_duration_seconds`
  - `concave_mutation_duration_seconds`
  - `concave_action_duration_seconds`
  - `concave_storage_commit_duration_seconds`
  - `concave_ws_fanout_duration_seconds`

### Structured JSON Logs (Cloud Run / Cloud Logging)

Set `CONCAVE_LOG_FORMAT=json` to emit single-line JSON RPC logs to `stderr` with Cloud Logging-compatible `severity` (`INFO` / `ERROR`), `fn`, `kind`, `duration_ms`, `occ_retries`, `ok`, and `error`:

```sh
CONCAVE_OPERATOR_TOKEN=super-secret \
CONCAVE_LOG_FORMAT=json \
./my-concave-app --serve --port 8080
```

---

## Layer 2: Application Monitoring Component (`packages/monitor`)

`packages/monitor` gives app developers actionable visibility into **their own code and users**:
- **Sentry-Style Error Grouping**: Deterministic fingerprinting normalizes volatile numbers, UUIDs, and hex IDs so recurring failures group into a single issue. Resolving an issue that recurs automatically reopens it as a regression.
- **Structured Logs & Spans**: Correlated by `trace_id`, tailed reactively over WebSockets, and full-text searchable via Concave's built-in `Db.search!`.
- **Custom App Metrics & Percentiles**: Record counters, gauges, or timings and subscribe to time-bucketed `count`, `sum`, `min`, `max`, `avg`, `p50`, `p95`, and `p99` rollups.
- **Threshold Alerts & Webhooks**: Define rules over error counts, log counts, or metric aggregates; evaluate via `App.cron` and dispatch JSON webhooks (Slack/Discord/PagerDuty/custom) with cooldown deduplication and reactive `ok | firing | acked` state transitions.

All 5 tables (`issues`, `logs`, `metrics`, `alert_rules`, `incidents`) live inside the mounted component's host-enforced namespace while participating in your app's exact same ACID transactions.

### Mounting & Attaching in Roc

```roc
app [concave_app] {
    pf: platform "./platform/main.roc",
    sdk: "./packages/concave-sdk/main.roc",
    monitor: "./packages/monitor/main.roc",
}

import sdk.App
import sdk.Ctx
import monitor.Attrs
import monitor.Monitor

monitor : Monitor.Mount
monitor = Monitor.mount("monitor")

# Optional custom configuration:
# monitor = Monitor.mount_with("monitor", {
#     require_auth_for_admin: True,
#     max_batch_size: 100,
#     default_retention_ms: 604800000, # 7 days
# })

concave_app : () -> App
concave_app = ||
    App.new("my-app")
    # Attach component endpoints, or use `attach_with_cron` to also schedule
    # periodic alert evaluation (every 30s) and retention pruning (every 1h):
    |> Monitor.attach_with_cron(monitor, 30000, 3600000)
```

### Transactional Server-Side Helpers

Call `Monitor.log_info!`, `Monitor.log_error!`, `Monitor.record_span!`, `Monitor.capture_error!`, or `Monitor.record_metric!` inside your own mutations:

```roc
process_order! : Ctx.MutationCtx, ProcessOrderArgs => Try(Str, Str)
process_order! = |ctx, args| {
    # Committed atomically with the order — rolls back automatically if this mutation returns `Err`!
    _ = Monitor.record_span!(
        monitor,
        ctx,
        "billing",
        "orders.process",
        args.trace_id,
        18,
        "ok",
        [Attrs.attr("order_id", args.order_id)],
    )?
    _ = Monitor.record_metric!(
        monitor,
        ctx,
        "orders.amount_cents",
        "gauge",
        args.amount.to_f64(),
        "billing",
        [],
    )?
    Db.insert!(ctx.db, orders_table, { order_id: args.order_id, amount: args.amount })
}
```

### Attached Endpoints (`<ns>.*`)

#### Mutations
- `<ns>.captureError` — Capture an error, group by deterministic fingerprint, auto-reopen regressions, and record a correlated error log.
- `<ns>.updateIssueStatus` — Transition an issue to `open`, `resolved`, or `ignored`.
- `<ns>.log` / `<ns>.logBatch` — Write structured logs or traced spans.
- `<ns>.recordMetric` / `<ns>.recordMetricBatch` — Record custom counters, gauges, or timings.
- `<ns>.upsertAlertRule` / `<ns>.deleteAlertRule` — Manage threshold alert rules (`error_count`, `log_count`, `metric`).
- `<ns>.acknowledgeIncident` — Silence a firing incident & alert rule until it clears.
- `<ns>.evaluateAlerts` — Evaluate all active rules against their sliding window, update states, and open/resolve incidents.
- `<ns>.prune` — Delete logs, metrics, and resolved incidents older than `retention_ms`.

#### Action
- `<ns>.evaluateAndNotify` — Runs `<ns>.evaluateAlerts` and delivers JSON POST webhooks via `ctx.http_fetch!` for every newly firing or resolved alert.

#### Reactive Queries (Live WebSocket Subscriptions)
- `<ns>.overview` — Live application health KPIs (`open_issues`, `error_events_in_window`, `firing_alerts`, `top_issues`, `services`).
- `<ns>.listIssues` / `<ns>.getIssue` — Reactive grouped error inbox and issue detail.
- `<ns>.recentLogs` — Live log tail (scoped by `service`, `level`, or `fn_name` for surgical ReadSet reactivity).
- `<ns>.searchLogs` — Reactive full-text search across log messages via `Db.search!`.
- `<ns>.traceLogs` — Chronological timeline of all logs & spans for a `trace_id`.
- `<ns>.metricSeries` — Time-bucketed metric series with `count`, `sum`, `min`, `max`, `avg`, `p50`, `p95`, `p99`.
- `<ns>.listAlertRules` / `<ns>.listIncidents` — Live alert rule statuses and incident history.

### Zero-Dependency Browser & Node Client (`/_concave/monitor.js`)

The Zig host embeds `packages/monitor/client.js` directly at `/_concave/monitor.js` alongside `/_concave/index.js`:

```js
import { ConcaveClient } from "/_concave/index.js";
import { createMonitor } from "/_concave/monitor.js";
import { api } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin);
const monitor = createMonitor(client, api.monitor, {
  service: "web",
  release: "v1.4.2",
  captureGlobalErrors: true, // hooks window.onerror + unhandledrejection
});

monitor.addBreadcrumb("ui", "Clicked checkout button");
await monitor.time("checkout.submit", async (traceId) => {
  await client.mutate(api.orders.place, { trace_id: traceId, amount: 4900 });
});

// Live reactive subscriptions (update over WebSockets):
const overview = monitor.subscribeOverview();
const openIssues = monitor.subscribeIssues({ status: "open" });
const errorLogs = monitor.subscribeLogs({ level: "error" });
const latency = monitor.subscribeMetric("checkout.submit.duration_ms");
```
