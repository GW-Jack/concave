import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table
import Alerts
import Attrs
import Fingerprint
import Rollups

## Reusable pure-Roc Application Observability & Monitoring Component for Concave.
##
## Designed specifically for application maintainers (what they own and can act on):
## - Sentry-style Error Tracking & Grouping (`captureError`, `updateIssueStatus`, `listIssues`, `getIssue`)
##   with deterministic fingerprinting and automatic reopen on regression
## - Structured Logs & Spans (`log`, `logBatch`, `recentLogs`, `searchLogs`, `traceLogs`)
##   with live WebSocket tailing, `trace_id` correlation, and reactive full-text `Db.search!`
## - Custom Application Metrics & Percentiles (`recordMetric`, `recordMetricBatch`, `metricSeries`)
##   with time-bucketed count/sum/min/max/avg/p50/p95/p99 rollups
## - Threshold Alert Rules, Incidents & Webhook Notifications (`upsertAlertRule`, `deleteAlertRule`,
##   `evaluateAlerts`, `evaluateAndNotify`, `acknowledgeIncident`, `listAlertRules`, `listIncidents`)
## - Retention Pruning (`prune`) & optional Cron wiring (`attach_with_cron`)
## - Strict host-enforced namespace isolation across 5 tables (`issues`, `logs`, `metrics`, `alert_rules`, `incidents`)

Monitor := [Monitor].{
    # -------------------------------------------------------------------------
    # Document Types
    # -------------------------------------------------------------------------

    IssueDoc : {
        id : Str,
        created_at : I64,
        fingerprint : Str,
        title : Str,
        source : Str,
        error_type : Str,
        level : Str,
        status : Str,
        count : I64,
        first_seen_ms : I64,
        last_seen_ms : I64,
        last_message : Str,
        last_stack : Str,
        last_trace_id : Str,
        last_user_id : Str,
        attrs : List(Attrs.Attr),
        resolved_at_ms : I64,
    }

    LogDoc : {
        id : Str,
        created_at : I64,
        timestamp_ms : I64,
        level : Str,
        level_num : I64,
        service : Str,
        fn_name : Str,
        trace_id : Str,
        span_id : Str,
        duration_ms : I64,
        status : Str,
        message : Str,
        attrs : List(Attrs.Attr),
    }

    MetricDoc : {
        id : Str,
        created_at : I64,
        timestamp_ms : I64,
        name : Str,
        kind : Str,
        value : F64,
        service : Str,
        attrs : List(Attrs.Attr),
    }

    AlertRuleDoc : {
        id : Str,
        created_at : I64,
        key : Str,
        name : Str,
        active : Bool,
        kind : Str,
        target : Str,
        aggregation : Str,
        op : Str,
        threshold : F64,
        window_ms : I64,
        cooldown_ms : I64,
        webhook_url : Str,
        status : Str,
        last_value : F64,
        last_eval_ms : I64,
        last_triggered_ms : I64,
        updated_at_ms : I64,
    }

    IncidentDoc : {
        id : Str,
        created_at : I64,
        rule_key : Str,
        rule_name : Str,
        status : Str,
        triggered_at_ms : I64,
        resolved_at_ms : I64,
        trigger_value : F64,
        threshold : F64,
        message : Str,
        webhook_delivered : Bool,
    }

    # -------------------------------------------------------------------------
    # Wire Argument & Result Types
    # -------------------------------------------------------------------------

    CaptureErrorArgs : {
        source : Str,
        error_type : Str,
        message : Str,
        level : Str,
        stack : Str,
        trace_id : Str,
        user_id : Str,
        fingerprint : Str,
        attrs : List(Attrs.Attr),
        timestamp_ms : I64,
    }

    CaptureErrorResult : {
        issue_id : Str,
        fingerprint : Str,
        is_new : Bool,
        reopened : Bool,
        count : I64,
    }

    UpdateIssueStatusArgs : {
        issue_id : Str,
        status : Str,
    }

    ListIssuesArgs : {
        status : Str,
        source : Str,
        limit : I64,
    }

    GetIssueArgs : {
        issue_id : Str,
        fingerprint : Str,
    }

    GetIssueResult : {
        found : Bool,
        id : Str,
        fingerprint : Str,
        title : Str,
        source : Str,
        error_type : Str,
        level : Str,
        status : Str,
        count : I64,
        first_seen_ms : I64,
        last_seen_ms : I64,
        last_message : Str,
        last_stack : Str,
        last_trace_id : Str,
        last_user_id : Str,
        attrs : List(Attrs.Attr),
        resolved_at_ms : I64,
    }

    LogArgs : {
        level : Str,
        service : Str,
        fn_name : Str,
        trace_id : Str,
        span_id : Str,
        duration_ms : I64,
        status : Str,
        message : Str,
        attrs : List(Attrs.Attr),
        timestamp_ms : I64,
    }

    LogBatchArgs : {
        entries : List(LogArgs),
    }

    BatchResult : {
        accepted : I64,
        ids : List(Str),
    }

    RecentLogsArgs : {
        service : Str,
        level : Str,
        fn_name : Str,
        limit : I64,
    }

    SearchLogsArgs : {
        query : Str,
        limit : I64,
    }

    TraceLogsArgs : {
        trace_id : Str,
        limit : I64,
    }

    RecordMetricArgs : {
        name : Str,
        kind : Str,
        value : F64,
        service : Str,
        attrs : List(Attrs.Attr),
        timestamp_ms : I64,
    }

    RecordMetricBatchArgs : {
        metrics : List(RecordMetricArgs),
    }

    MetricSeriesArgs : {
        name : Str,
        service : Str,
        from_ms : I64,
        to_ms : I64,
        bucket_ms : I64,
    }

    OverviewArgs : {
        window_ms : I64,
        top_n : I64,
    }

    UpsertAlertRuleArgs : {
        key : Str,
        name : Str,
        active : Bool,
        kind : Str,
        target : Str,
        aggregation : Str,
        op : Str,
        threshold : F64,
        window_ms : I64,
        cooldown_ms : I64,
        webhook_url : Str,
    }

    DeleteAlertRuleArgs : {
        key : Str,
    }

    AcknowledgeIncidentArgs : {
        incident_id : Str,
    }

    ListIncidentsArgs : {
        status : Str,
        rule_key : Str,
        limit : I64,
    }

    WebhookNotification : {
        incident_id : Str,
        rule_key : Str,
        rule_name : Str,
        event : Str,
        webhook_url : Str,
        value : F64,
        threshold : F64,
        message : Str,
        timestamp_ms : I64,
    }

    EvaluateAlertsResult : {
        evaluated : I64,
        firing : I64,
        resolved : I64,
        notifications : List(WebhookNotification),
    }

    MarkDeliveredArgs : {
        incident_id : Str,
    }

    EvaluateAndNotifyResult : {
        evaluated : I64,
        firing : I64,
        resolved : I64,
        webhooks_sent : I64,
        webhooks_failed : I64,
    }

    PruneArgs : {
        retention_ms : I64,
        max_delete : I64,
    }

    PruneResult : {
        deleted_logs : I64,
        deleted_metrics : I64,
        deleted_incidents : I64,
    }

    Config : {
        require_auth_for_admin : Bool,
        max_batch_size : I64,
        default_retention_ms : I64,
    }

    Mount : {
        namespace : Str,
        require_auth_for_admin : Bool,
        admin_roles : List(Str),
        allow_insecure_webhooks : Bool,
        max_batch_size : I64,
        default_retention_ms : I64,
        spec : Component.ComponentSpec,
    }

    # -------------------------------------------------------------------------
    # Schemas & Tables
    # -------------------------------------------------------------------------

    attr_schema : Schema
    attr_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("value", Schema.str),
    ])

    issues_schema : Schema
    issues_schema = Schema.record([
        Schema.field("fingerprint", Schema.str),
        Schema.field("title", Schema.str),
        Schema.field("source", Schema.str),
        Schema.field("error_type", Schema.str),
        Schema.field("level", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("count", Schema.int),
        Schema.field("first_seen_ms", Schema.int),
        Schema.field("last_seen_ms", Schema.int),
        Schema.field("last_message", Schema.str),
        Schema.field("last_stack", Schema.str),
        Schema.field("last_trace_id", Schema.str),
        Schema.field("last_user_id", Schema.str),
        Schema.field("attrs", Schema.list(attr_schema)),
        Schema.field("resolved_at_ms", Schema.int),
    ])

    issues_table : Table(IssueDoc)
    issues_table =
        Table.define("issues", issues_schema)
        |> Table.with_index("by_fingerprint", ["fingerprint"])
        |> Table.with_index("by_status_last_seen", ["status", "last_seen_ms"])
        |> Table.with_index("by_source_last_seen", ["source", "last_seen_ms"])
        |> Table.with_index("by_last_seen", ["last_seen_ms"])

    issues_by_fingerprint : Table.Index(IssueDoc)
    issues_by_fingerprint = Table.index_ref(issues_table, "by_fingerprint")

    issues_by_status_last_seen : Table.Index(IssueDoc)
    issues_by_status_last_seen = Table.index_ref(issues_table, "by_status_last_seen")

    issues_by_source_last_seen : Table.Index(IssueDoc)
    issues_by_source_last_seen = Table.index_ref(issues_table, "by_source_last_seen")

    issues_by_last_seen : Table.Index(IssueDoc)
    issues_by_last_seen = Table.index_ref(issues_table, "by_last_seen")

    logs_schema : Schema
    logs_schema = Schema.record([
        Schema.field("timestamp_ms", Schema.int),
        Schema.field("level", Schema.str),
        Schema.field("level_num", Schema.int),
        Schema.field("service", Schema.str),
        Schema.field("fn_name", Schema.str),
        Schema.field("trace_id", Schema.str),
        Schema.field("span_id", Schema.str),
        Schema.field("duration_ms", Schema.int),
        Schema.field("status", Schema.str),
        Schema.field("message", Schema.str),
        Schema.field("attrs", Schema.list(attr_schema)),
    ])

    logs_table : Table(LogDoc)
    logs_table =
        Table.define("logs", logs_schema)
        |> Table.with_index("by_timestamp", ["timestamp_ms"])
        |> Table.with_index("by_service_time", ["service", "timestamp_ms"])
        |> Table.with_index("by_level_time", ["level", "timestamp_ms"])
        |> Table.with_index("by_trace_time", ["trace_id", "timestamp_ms"])
        |> Table.with_index("by_fn_time", ["fn_name", "timestamp_ms"])

    logs_by_timestamp : Table.Index(LogDoc)
    logs_by_timestamp = Table.index_ref(logs_table, "by_timestamp")

    logs_by_service_time : Table.Index(LogDoc)
    logs_by_service_time = Table.index_ref(logs_table, "by_service_time")

    logs_by_level_time : Table.Index(LogDoc)
    logs_by_level_time = Table.index_ref(logs_table, "by_level_time")

    logs_by_trace_time : Table.Index(LogDoc)
    logs_by_trace_time = Table.index_ref(logs_table, "by_trace_time")

    logs_by_fn_time : Table.Index(LogDoc)
    logs_by_fn_time = Table.index_ref(logs_table, "by_fn_time")

    metrics_schema : Schema
    metrics_schema = Schema.record([
        Schema.field("timestamp_ms", Schema.int),
        Schema.field("name", Schema.str),
        Schema.field("kind", Schema.str),
        Schema.field("value", Schema.float),
        Schema.field("service", Schema.str),
        Schema.field("attrs", Schema.list(attr_schema)),
    ])

    metrics_table : Table(MetricDoc)
    metrics_table =
        Table.define("metrics", metrics_schema)
        |> Table.with_index("by_timestamp", ["timestamp_ms"])
        |> Table.with_index("by_name_time", ["name", "timestamp_ms"])
        |> Table.with_index("by_service_time", ["service", "timestamp_ms"])

    metrics_by_timestamp : Table.Index(MetricDoc)
    metrics_by_timestamp = Table.index_ref(metrics_table, "by_timestamp")

    metrics_by_name_time : Table.Index(MetricDoc)
    metrics_by_name_time = Table.index_ref(metrics_table, "by_name_time")

    alert_rules_schema : Schema
    alert_rules_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("active", Schema.bool),
        Schema.field("kind", Schema.str),
        Schema.field("target", Schema.str),
        Schema.field("aggregation", Schema.str),
        Schema.field("op", Schema.str),
        Schema.field("threshold", Schema.float),
        Schema.field("window_ms", Schema.int),
        Schema.field("cooldown_ms", Schema.int),
        Schema.field("webhook_url", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("last_value", Schema.float),
        Schema.field("last_eval_ms", Schema.int),
        Schema.field("last_triggered_ms", Schema.int),
        Schema.field("updated_at_ms", Schema.int),
    ])

    alert_rules_table : Table(AlertRuleDoc)
    alert_rules_table =
        Table.define("alert_rules", alert_rules_schema)
        |> Table.with_index("by_key", ["key"])
        |> Table.with_index("by_status", ["status"])

    alert_rules_by_key : Table.Index(AlertRuleDoc)
    alert_rules_by_key = Table.index_ref(alert_rules_table, "by_key")

    incidents_schema : Schema
    incidents_schema = Schema.record([
        Schema.field("rule_key", Schema.str),
        Schema.field("rule_name", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("triggered_at_ms", Schema.int),
        Schema.field("resolved_at_ms", Schema.int),
        Schema.field("trigger_value", Schema.float),
        Schema.field("threshold", Schema.float),
        Schema.field("message", Schema.str),
        Schema.field("webhook_delivered", Schema.bool),
    ])

    incidents_table : Table(IncidentDoc)
    incidents_table =
        Table.define("incidents", incidents_schema)
        |> Table.with_index("by_rule_time", ["rule_key", "triggered_at_ms"])
        |> Table.with_index("by_status_time", ["status", "triggered_at_ms"])
        |> Table.with_index("by_triggered", ["triggered_at_ms"])

    incidents_by_rule_time : Table.Index(IncidentDoc)
    incidents_by_rule_time = Table.index_ref(incidents_table, "by_rule_time")

    incidents_by_status_time : Table.Index(IncidentDoc)
    incidents_by_status_time = Table.index_ref(incidents_table, "by_status_time")

    incidents_by_triggered : Table.Index(IncidentDoc)
    incidents_by_triggered = Table.index_ref(incidents_table, "by_triggered")

    # -------------------------------------------------------------------------
    # Endpoint Wire Schemas
    # -------------------------------------------------------------------------

    capture_error_args_schema : Schema
    capture_error_args_schema = Schema.record([
        Schema.field("source", Schema.str),
        Schema.field("error_type", Schema.str),
        Schema.field("message", Schema.str),
        Schema.field("level", Schema.str),
        Schema.field("stack", Schema.str),
        Schema.field("trace_id", Schema.str),
        Schema.field("user_id", Schema.str),
        Schema.field("fingerprint", Schema.str),
        Schema.field("attrs", Schema.list(attr_schema)),
        Schema.field("timestamp_ms", Schema.int),
    ])

    capture_error_result_schema : Schema
    capture_error_result_schema = Schema.record([
        Schema.field("issue_id", Schema.str),
        Schema.field("fingerprint", Schema.str),
        Schema.field("is_new", Schema.bool),
        Schema.field("reopened", Schema.bool),
        Schema.field("count", Schema.int),
    ])

    update_issue_status_args_schema : Schema
    update_issue_status_args_schema = Schema.record([
        Schema.field("issue_id", Schema.str),
        Schema.field("status", Schema.str),
    ])

    list_issues_args_schema : Schema
    list_issues_args_schema = Schema.record([
        Schema.field("status", Schema.str),
        Schema.field("source", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    get_issue_args_schema : Schema
    get_issue_args_schema = Schema.record([
        Schema.field("issue_id", Schema.str),
        Schema.field("fingerprint", Schema.str),
    ])

    get_issue_result_schema : Schema
    get_issue_result_schema = Schema.record([
        Schema.field("found", Schema.bool),
        Schema.field("id", Schema.str),
        Schema.field("fingerprint", Schema.str),
        Schema.field("title", Schema.str),
        Schema.field("source", Schema.str),
        Schema.field("error_type", Schema.str),
        Schema.field("level", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("count", Schema.int),
        Schema.field("first_seen_ms", Schema.int),
        Schema.field("last_seen_ms", Schema.int),
        Schema.field("last_message", Schema.str),
        Schema.field("last_stack", Schema.str),
        Schema.field("last_trace_id", Schema.str),
        Schema.field("last_user_id", Schema.str),
        Schema.field("attrs", Schema.list(attr_schema)),
        Schema.field("resolved_at_ms", Schema.int),
    ])

    log_args_schema : Schema
    log_args_schema = Schema.record([
        Schema.field("level", Schema.str),
        Schema.field("service", Schema.str),
        Schema.field("fn_name", Schema.str),
        Schema.field("trace_id", Schema.str),
        Schema.field("span_id", Schema.str),
        Schema.field("duration_ms", Schema.int),
        Schema.field("status", Schema.str),
        Schema.field("message", Schema.str),
        Schema.field("attrs", Schema.list(attr_schema)),
        Schema.field("timestamp_ms", Schema.int),
    ])

    log_batch_args_schema : Schema
    log_batch_args_schema = Schema.record([
        Schema.field("entries", Schema.list(log_args_schema)),
    ])

    batch_result_schema : Schema
    batch_result_schema = Schema.record([
        Schema.field("accepted", Schema.int),
        Schema.field("ids", Schema.list(Schema.str)),
    ])

    recent_logs_args_schema : Schema
    recent_logs_args_schema = Schema.record([
        Schema.field("service", Schema.str),
        Schema.field("level", Schema.str),
        Schema.field("fn_name", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    search_logs_args_schema : Schema
    search_logs_args_schema = Schema.record([
        Schema.field("query", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    trace_logs_args_schema : Schema
    trace_logs_args_schema = Schema.record([
        Schema.field("trace_id", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    record_metric_args_schema : Schema
    record_metric_args_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("kind", Schema.str),
        Schema.field("value", Schema.float),
        Schema.field("service", Schema.str),
        Schema.field("attrs", Schema.list(attr_schema)),
        Schema.field("timestamp_ms", Schema.int),
    ])

    record_metric_batch_args_schema : Schema
    record_metric_batch_args_schema = Schema.record([
        Schema.field("metrics", Schema.list(record_metric_args_schema)),
    ])

    metric_series_args_schema : Schema
    metric_series_args_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("service", Schema.str),
        Schema.field("from_ms", Schema.int),
        Schema.field("to_ms", Schema.int),
        Schema.field("bucket_ms", Schema.int),
    ])

    metric_bucket_schema : Schema
    metric_bucket_schema = Schema.record([
        Schema.field("bucket_start_ms", Schema.int),
        Schema.field("count", Schema.int),
        Schema.field("sum", Schema.float),
        Schema.field("min", Schema.float),
        Schema.field("max", Schema.float),
        Schema.field("avg", Schema.float),
        Schema.field("p50", Schema.float),
        Schema.field("p95", Schema.float),
        Schema.field("p99", Schema.float),
    ])

    metric_series_result_schema : Schema
    metric_series_result_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("count", Schema.int),
        Schema.field("sum", Schema.float),
        Schema.field("min", Schema.float),
        Schema.field("max", Schema.float),
        Schema.field("avg", Schema.float),
        Schema.field("p50", Schema.float),
        Schema.field("p95", Schema.float),
        Schema.field("p99", Schema.float),
        Schema.field("buckets", Schema.list(metric_bucket_schema)),
    ])

    overview_args_schema : Schema
    overview_args_schema = Schema.record([
        Schema.field("window_ms", Schema.int),
        Schema.field("top_n", Schema.int),
    ])

    issue_summary_schema : Schema
    issue_summary_schema = Schema.record([
        Schema.field("id", Schema.str),
        Schema.field("fingerprint", Schema.str),
        Schema.field("title", Schema.str),
        Schema.field("source", Schema.str),
        Schema.field("level", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("count", Schema.int),
        Schema.field("last_seen_ms", Schema.int),
    ])

    overview_result_schema : Schema
    overview_result_schema = Schema.record([
        Schema.field("open_issues", Schema.int),
        Schema.field("total_issues", Schema.int),
        Schema.field("error_events_in_window", Schema.int),
        Schema.field("error_logs_in_window", Schema.int),
        Schema.field("firing_alerts", Schema.int),
        Schema.field("active_rules", Schema.int),
        Schema.field("top_issues", Schema.list(issue_summary_schema)),
        Schema.field("services", Schema.list(Schema.str)),
    ])

    upsert_alert_rule_args_schema : Schema
    upsert_alert_rule_args_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("active", Schema.bool),
        Schema.field("kind", Schema.str),
        Schema.field("target", Schema.str),
        Schema.field("aggregation", Schema.str),
        Schema.field("op", Schema.str),
        Schema.field("threshold", Schema.float),
        Schema.field("window_ms", Schema.int),
        Schema.field("cooldown_ms", Schema.int),
        Schema.field("webhook_url", Schema.str),
    ])

    delete_alert_rule_args_schema : Schema
    delete_alert_rule_args_schema = Schema.record([
        Schema.field("key", Schema.str),
    ])

    acknowledge_incident_args_schema : Schema
    acknowledge_incident_args_schema = Schema.record([
        Schema.field("incident_id", Schema.str),
    ])

    list_incidents_args_schema : Schema
    list_incidents_args_schema = Schema.record([
        Schema.field("status", Schema.str),
        Schema.field("rule_key", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    webhook_notification_schema : Schema
    webhook_notification_schema = Schema.record([
        Schema.field("incident_id", Schema.str),
        Schema.field("rule_key", Schema.str),
        Schema.field("rule_name", Schema.str),
        Schema.field("event", Schema.str),
        Schema.field("webhook_url", Schema.str),
        Schema.field("value", Schema.float),
        Schema.field("threshold", Schema.float),
        Schema.field("message", Schema.str),
        Schema.field("timestamp_ms", Schema.int),
    ])

    evaluate_alerts_result_schema : Schema
    evaluate_alerts_result_schema = Schema.record([
        Schema.field("evaluated", Schema.int),
        Schema.field("firing", Schema.int),
        Schema.field("resolved", Schema.int),
        Schema.field("notifications", Schema.list(webhook_notification_schema)),
    ])

    mark_delivered_args_schema : Schema
    mark_delivered_args_schema = Schema.record([
        Schema.field("incident_id", Schema.str),
    ])

    evaluate_and_notify_result_schema : Schema
    evaluate_and_notify_result_schema = Schema.record([
        Schema.field("evaluated", Schema.int),
        Schema.field("firing", Schema.int),
        Schema.field("resolved", Schema.int),
        Schema.field("webhooks_sent", Schema.int),
        Schema.field("webhooks_failed", Schema.int),
    ])

    prune_args_schema : Schema
    prune_args_schema = Schema.record([
        Schema.field("retention_ms", Schema.int),
        Schema.field("max_delete", Schema.int),
    ])

    prune_result_schema : Schema
    prune_result_schema = Schema.record([
        Schema.field("deleted_logs", Schema.int),
        Schema.field("deleted_metrics", Schema.int),
        Schema.field("deleted_incidents", Schema.int),
    ])

    # -------------------------------------------------------------------------
    # Ergonomic Constructors & Mounting
    # -------------------------------------------------------------------------

    attr : Str, Str -> Attrs.Attr
    attr = Attrs.attr

    default_config : Config
    default_config = {
        require_auth_for_admin: True,
        max_batch_size: 100,
        default_retention_ms: 604800000, # 7 days
    }

    ## Mount an isolated Monitor component under `namespace` with secure defaults.
    mount : Str -> Mount
    mount = |namespace| mount_with(namespace, default_config)

    ## Mount an isolated Monitor component with explicit `Config`.
    mount_with : Str, Config -> Mount
    mount_with = |namespace, cfg| {
        namespace,
        require_auth_for_admin: cfg.require_auth_for_admin,
        admin_roles: ["admin"],
        allow_insecure_webhooks: False,
        max_batch_size: if cfg.max_batch_size <= 0 { 100 } else if cfg.max_batch_size > 500 { 500 } else { cfg.max_batch_size },
        default_retention_ms: if cfg.default_retention_ms <= 0 { 604800000 } else { cfg.default_retention_ms },
        spec: Component.define(
            namespace,
            "concave-monitor",
            [
                Table.spec(issues_table),
                Table.spec(logs_table),
                Table.spec(metrics_table),
                Table.spec(alert_rules_table),
                Table.spec(incidents_table),
            ],
        ),
    }

    ## Override the roles permitted to access Monitor admin/read endpoints (default: `["admin"]`; empty allows any authenticated user).
    with_admin_roles : Mount, List(Str) -> Mount
    with_admin_roles = |m, roles| {
        namespace: m.namespace,
        require_auth_for_admin: m.require_auth_for_admin,
        admin_roles: roles,
        allow_insecure_webhooks: m.allow_insecure_webhooks,
        max_batch_size: m.max_batch_size,
        default_retention_ms: m.default_retention_ms,
        spec: m.spec,
    }

    ## Opt in to plaintext `http://` alert webhook URLs (e.g. for local testing; production should keep `False` for HTTPS-only).
    with_insecure_webhooks : Mount, Bool -> Mount
    with_insecure_webhooks = |m, allow| {
        namespace: m.namespace,
        require_auth_for_admin: m.require_auth_for_admin,
        admin_roles: m.admin_roles,
        allow_insecure_webhooks: allow,
        max_batch_size: m.max_batch_size,
        default_retention_ms: m.default_retention_ms,
        spec: m.spec,
    }

    # -------------------------------------------------------------------------
    # Internal Helpers
    # -------------------------------------------------------------------------

    clamp_limit_u64 : I64, I64, I64 -> U64
    clamp_limit_u64 = |raw, default_val, max_val| {
        clamped =
            if raw <= 0 {
                default_val
            } else if raw > max_val {
                max_val
            } else {
                raw
            }
        var $out = 0.U64
        var $rem = clamped
        while $rem >= 100 {
            $out = $out + 100
            $rem = $rem - 100
        }
        while $rem >= 10 {
            $out = $out + 10
            $rem = $rem - 10
        }
        while $rem > 0 {
            $out = $out + 1
            $rem = $rem - 1
        }
        $out
    }

    is_admin_identity : Ctx.AuthIdentity, List(Str) -> Bool
    is_admin_identity = |id, admin_roles|
        if List.is_empty(admin_roles) {
            True
        } else {
            Ctx.has_any_role(id, admin_roles)
        }

    require_admin_if_needed! : Bool, List(Str), (() => Try(Ctx.AuthIdentity, [Unauthenticated])) => Try({}, Str)
    require_admin_if_needed! = |req_auth, admin_roles, auth!|
        if req_auth {
            id = Ctx.require_auth!(auth!)?
            if is_admin_identity(id, admin_roles) {
                Ok({})
            } else {
                Err("Forbidden: admin role required")
            }
        } else {
            Ok({})
        }

    clamp_attrs : List(Attrs.Attr) -> List(Attrs.Attr)
    clamp_attrs = |items| {
        var $out = []
        var $n = 0.I64
        for item in items {
            if $n < 64 {
                $out = List.append($out, item)
                $n = $n + 1
            }
        }
        $out
    }

    clamp_ingest_ts : I64, I64, Bool -> I64
    clamp_ingest_ts = |raw_ts, now, allow_historical| {
        if raw_ts <= 0 {
            return now
        }
        max_future = now + 300000 # 5 minutes
        if raw_ts > max_future {
            return now
        }
        if allow_historical {
            return raw_ts
        }
        max_past = now - 2592000000 # 30 days
        if raw_ts < max_past {
            now
        } else {
            raw_ts
        }
    }

    validate_webhook_url : Bool, Str -> Try(Str, Str)
    validate_webhook_url = |allow_http, raw| {
        trimmed = Str.trim(raw)
        if Str.is_empty(trimmed) {
            Ok("")
        } else if Str.starts_with(trimmed, "https://") {
            Ok(trimmed)
        } else if allow_http and Str.starts_with(trimmed, "http://") {
            Ok(trimmed)
        } else {
            Err("webhook_url must use https://")
        }
    }

    is_valid_issue_status : Str -> Bool
    is_valid_issue_status = |s| s == "open" or s == "resolved" or s == "ignored"

    normalize_metric_kind : Str -> Str
    normalize_metric_kind = |raw| {
        t = Str.trim(raw)
        if t == "counter" or t == "gauge" or t == "timing" {
            t
        } else {
            "gauge"
        }
    }

    normalize_rule_kind : Str -> Str
    normalize_rule_kind = |raw| {
        t = Str.trim(raw)
        if t == "error_count" or t == "log_count" or t == "metric" {
            t
        } else {
            "error_count"
        }
    }

    # -------------------------------------------------------------------------
    # Core Mutations (Scoped to Component Namespace)
    # -------------------------------------------------------------------------

    ## Capture an application or client error, auto-grouping into an Issue by deterministic
    ## fingerprint, auto-reopening regressions, and recording a correlated error log entry.
    ## When `trusted_caller` is False (public endpoint), untrusted client fingerprint overrides
    ## are ignored unless the caller holds an admin role, and authenticated `user_id` is bound to `id.subject`.
    capture_error_inner! : Bool, List(Str), Ctx.MutationCtx, CaptureErrorArgs => Try(CaptureErrorResult, Str)
    capture_error_inner! = |trusted_caller, admin_roles, ctx, args| {
        message = Str.trim(args.message)
        if Str.is_empty(message) {
            return Err("Error message cannot be empty")
        }
        source = if Str.is_empty(Str.trim(args.source)) { "app" } else { Str.trim(args.source) }
        error_type = if Str.is_empty(Str.trim(args.error_type)) { "Error" } else { Str.trim(args.error_type) }
        level =
            if Str.is_empty(Str.trim(args.level)) {
                "error"
            } else {
                Attrs.normalize_level(args.level)
            }

        auth! = ctx.auth!
        caller_auth = auth!()
        is_privileged =
            trusted_caller or match caller_auth {
                Ok(id) => is_admin_identity(id, admin_roles)
                Err(Unauthenticated) => False
            }

        fp_override = if is_privileged { args.fingerprint } else { "" }
        fp = Fingerprint.compute(fp_override, source, error_type, message)

        now_ms! = ctx.now_ms!
        now = now_ms!()
        ts = clamp_ingest_ts(args.timestamp_ms, now, is_privileged)

        user_id =
            match caller_auth {
                Ok(id) =>
                    if is_privileged and !Str.is_empty(Str.trim(args.user_id)) {
                        Str.trim(args.user_id)
                    } else {
                        id.subject
                    }
                Err(Unauthenticated) => Str.trim(args.user_id)
            }

        safe_attrs = clamp_attrs(args.attrs)

        reader = Ctx.as_reader(ctx.db)
        existing =
            Db.from_index(issues_by_fingerprint)
            |> Db.eq([Key.str(fp)])
            |> Db.first!(reader)?

        title = "${error_type}: ${message}"
        trace_id = Str.trim(args.trace_id)

        # Record a correlated structured log entry so sliding-window alerts, trace timelines,
        # and full-text log search see every occurrence automatically.
        log_attrs = Attrs.merge(safe_attrs, [
            Attrs.attr("fingerprint", fp),
            Attrs.attr("error_type", error_type),
        ])
        _ = Db.insert!(ctx.db, logs_table, {
            timestamp_ms: ts,
            level,
            level_num: Attrs.level_rank(level),
            service: source,
            fn_name: source,
            trace_id,
            span_id: "",
            duration_ms: 0,
            status: "issue",
            message: title,
            attrs: log_attrs,
        })?

        match existing {
            NotFound => {
                issue_id = Db.insert!(ctx.db, issues_table, {
                    fingerprint: fp,
                    title,
                    source,
                    error_type,
                    level,
                    status: "open",
                    count: 1,
                    first_seen_ms: ts,
                    last_seen_ms: ts,
                    last_message: message,
                    last_stack: args.stack,
                    last_trace_id: trace_id,
                    last_user_id: user_id,
                    attrs: safe_attrs,
                    resolved_at_ms: 0,
                })?
                Ok({
                    issue_id,
                    fingerprint: fp,
                    is_new: True,
                    reopened: False,
                    count: 1,
                })
            }
            Found(doc) => {
                next_count = doc.count + 1
                reopened = doc.status == "resolved"
                next_status = if reopened { "open" } else { doc.status }
                next_resolved_at = if reopened { 0 } else { doc.resolved_at_ms }
                next_last_seen = if ts > doc.last_seen_ms { ts } else { doc.last_seen_ms }
                next_first_seen = if doc.first_seen_ms == 0 or ts < doc.first_seen_ms { ts } else { doc.first_seen_ms }
                merged_attrs = Attrs.merge(doc.attrs, safe_attrs) |> clamp_attrs

                Db.patch!(ctx.db, issues_table, doc.id, {
                    status: next_status,
                    count: next_count,
                    first_seen_ms: next_first_seen,
                    last_seen_ms: next_last_seen,
                    last_message: message,
                    last_stack: if Str.is_empty(args.stack) { doc.last_stack } else { args.stack },
                    last_trace_id: if Str.is_empty(trace_id) { doc.last_trace_id } else { trace_id },
                    last_user_id: if Str.is_empty(user_id) { doc.last_user_id } else { user_id },
                    attrs: merged_attrs,
                    resolved_at_ms: next_resolved_at,
                })?

                Ok({
                    issue_id: doc.id,
                    fingerprint: fp,
                    is_new: False,
                    reopened,
                    count: next_count,
                })
            }
        }
    }

    ## Update an Issue's lifecycle status (`open`, `resolved`, or `ignored`).
    update_issue_status_inner! : Bool, List(Str), Ctx.MutationCtx, UpdateIssueStatusArgs => Try(Bool, Str)
    update_issue_status_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        next_status = Str.trim(args.status)
        if !is_valid_issue_status(next_status) {
            return Err("Issue status must be `open`, `resolved`, or `ignored`")
        }
        lookup = Db.get!(Ctx.as_reader(ctx.db), issues_table, args.issue_id)?
        match lookup {
            NotFound => Ok(False)
            Found(_) => {
                now_ms! = ctx.now_ms!
                resolved_at = if next_status == "resolved" { now_ms!() } else { 0 }
                Db.patch!(ctx.db, issues_table, args.issue_id, {
                    status: next_status,
                    resolved_at_ms: resolved_at,
                })?
                Ok(True)
            }
        }
    }

    ## Write a structured log entry or operation span.
    log_inner! : List(Str), Ctx.MutationCtx, LogArgs => Try(Str, Str)
    log_inner! = |admin_roles, ctx, args| {
        msg = Str.trim(args.message)
        if Str.is_empty(msg) {
            return Err("Log message cannot be empty")
        }
        level = Attrs.normalize_level(args.level)
        auth! = ctx.auth!
        is_admin = match auth!() {
            Ok(id) => is_admin_identity(id, admin_roles)
            Err(Unauthenticated) => False
        }
        now_ms! = ctx.now_ms!
        ts = clamp_ingest_ts(args.timestamp_ms, now_ms!(), is_admin)

        Db.insert!(ctx.db, logs_table, {
            timestamp_ms: ts,
            level,
            level_num: Attrs.level_rank(level),
            service: if Str.is_empty(Str.trim(args.service)) { "app" } else { Str.trim(args.service) },
            fn_name: Str.trim(args.fn_name),
            trace_id: Str.trim(args.trace_id),
            span_id: Str.trim(args.span_id),
            duration_ms: if args.duration_ms < 0 { 0 } else { args.duration_ms },
            status: if Str.is_empty(Str.trim(args.status)) { "ok" } else { Str.trim(args.status) },
            message: msg,
            attrs: clamp_attrs(args.attrs),
        })
    }

    ## Atomically write a batch of structured logs/spans (bounded by `max_batch_size`).
    log_batch_inner! : List(Str), I64, Ctx.MutationCtx, LogBatchArgs => Try(BatchResult, Str)
    log_batch_inner! = |admin_roles, max_batch, ctx, args| {
        count = Rollups.list_len_i64(args.entries)
        if count > max_batch {
            return Err("Log batch size ${count.to_str()} exceeds max_batch_size (${max_batch.to_str()})")
        }
        var $ids = []
        for entry in args.entries {
            id = log_inner!(admin_roles, ctx, entry)?
            $ids = List.append($ids, id)
        }
        Ok({ accepted: count, ids: $ids })
    }

    ## Record a single custom application metric (`counter`, `gauge`, or `timing`).
    record_metric_inner! : List(Str), Ctx.MutationCtx, RecordMetricArgs => Try(Str, Str)
    record_metric_inner! = |admin_roles, ctx, args| {
        name = Str.trim(args.name)
        if Str.is_empty(name) {
            return Err("Metric name cannot be empty")
        }
        auth! = ctx.auth!
        is_admin = match auth!() {
            Ok(id) => is_admin_identity(id, admin_roles)
            Err(Unauthenticated) => False
        }
        now_ms! = ctx.now_ms!
        ts = clamp_ingest_ts(args.timestamp_ms, now_ms!(), is_admin)

        Db.insert!(ctx.db, metrics_table, {
            timestamp_ms: ts,
            name,
            kind: normalize_metric_kind(args.kind),
            value: args.value,
            service: if Str.is_empty(Str.trim(args.service)) { "app" } else { Str.trim(args.service) },
            attrs: clamp_attrs(args.attrs),
        })
    }

    ## Atomically record a batch of application metrics (bounded by `max_batch_size`).
    record_metric_batch_inner! : List(Str), I64, Ctx.MutationCtx, RecordMetricBatchArgs => Try(BatchResult, Str)
    record_metric_batch_inner! = |admin_roles, max_batch, ctx, args| {
        count = Rollups.list_len_i64(args.metrics)
        if count > max_batch {
            return Err("Metric batch size ${count.to_str()} exceeds max_batch_size (${max_batch.to_str()})")
        }
        var $ids = []
        for m in args.metrics {
            id = record_metric_inner!(admin_roles, ctx, m)?
            $ids = List.append($ids, id)
        }
        Ok({ accepted: count, ids: $ids })
    }

    ## Create or update an alert rule by `key`.
    upsert_alert_rule_inner! : Bool, List(Str), Bool, Ctx.MutationCtx, UpsertAlertRuleArgs => Try(Str, Str)
    upsert_alert_rule_inner! = |req_auth, admin_roles, allow_http, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        key = Str.trim(args.key)
        if Str.is_empty(key) {
            return Err("Alert rule key cannot be empty")
        }
        webhook_url = validate_webhook_url(allow_http, args.webhook_url)?
        now_ms! = ctx.now_ms!
        now = now_ms!()

        kind = normalize_rule_kind(args.kind)
        name = if Str.is_empty(Str.trim(args.name)) { key } else { Str.trim(args.name) }
        window_ms = if args.window_ms <= 0 { 300000 } else if args.window_ms > 2592000000 { 2592000000 } else { args.window_ms }
        cooldown_ms = if args.cooldown_ms < 0 { 0 } else { args.cooldown_ms }
        agg = if Str.is_empty(Str.trim(args.aggregation)) { "count" } else { Str.trim(args.aggregation) }
        op = if Str.is_empty(Str.trim(args.op)) { "gte" } else { Str.trim(args.op) }

        reader = Ctx.as_reader(ctx.db)
        existing =
            Db.from_index(alert_rules_by_key)
            |> Db.eq([Key.str(key)])
            |> Db.first!(reader)?

        match existing {
            Found(doc) => {
                Db.patch!(ctx.db, alert_rules_table, doc.id, {
                    name,
                    active: args.active,
                    kind,
                    target: Str.trim(args.target),
                    aggregation: agg,
                    op,
                    threshold: args.threshold,
                    window_ms,
                    cooldown_ms,
                    webhook_url,
                    updated_at_ms: now,
                })?
                Ok(doc.id)
            }
            NotFound =>
                Db.insert!(ctx.db, alert_rules_table, {
                    key,
                    name,
                    active: args.active,
                    kind,
                    target: Str.trim(args.target),
                    aggregation: agg,
                    op,
                    threshold: args.threshold,
                    window_ms,
                    cooldown_ms,
                    webhook_url,
                    status: "ok",
                    last_value: 0.0,
                    last_eval_ms: 0,
                    last_triggered_ms: 0,
                    updated_at_ms: now,
                })
        }
    }

    ## Delete an alert rule by `key`.
    delete_alert_rule_inner! : Bool, List(Str), Ctx.MutationCtx, DeleteAlertRuleArgs => Try(Bool, Str)
    delete_alert_rule_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        existing =
            Db.from_index(alert_rules_by_key)
            |> Db.eq([Key.str(Str.trim(args.key))])
            |> Db.first!(Ctx.as_reader(ctx.db))?
        match existing {
            NotFound => Ok(False)
            Found(doc) => {
                Db.delete!(ctx.db, alert_rules_table, doc.id)?
                Ok(True)
            }
        }
    }

    ## Acknowledge a firing incident (and silence its alert rule until resolved).
    acknowledge_incident_inner! : Bool, List(Str), Ctx.MutationCtx, AcknowledgeIncidentArgs => Try(Bool, Str)
    acknowledge_incident_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        reader = Ctx.as_reader(ctx.db)
        lookup = Db.get!(reader, incidents_table, args.incident_id)?
        match lookup {
            NotFound => Ok(False)
            Found(inc) => {
                if inc.status == "resolved" {
                    return Ok(False)
                }
                Db.patch!(ctx.db, incidents_table, inc.id, { status: "acked" })?
                rule_lookup =
                    Db.from_index(alert_rules_by_key)
                    |> Db.eq([Key.str(inc.rule_key)])
                    |> Db.first!(reader)?
                match rule_lookup {
                    Found(rule) => {
                        if rule.status == "firing" {
                            Db.patch!(ctx.db, alert_rules_table, rule.id, { status: "acked" })?
                        }
                    }
                    NotFound => {}
                }
                Ok(True)
            }
        }
    }

    ## Compute the scalar value for a single alert rule over its sliding window `[now - window_ms, now]`.
    measure_rule_value! : Ctx.DbReader, AlertRuleDoc, I64 => Try(F64, Str)
    measure_rule_value! = |db, rule, now_ms| {
        from_ms = now_ms - rule.window_ms
        if rule.kind == "metric" {
            docs =
                Db.from_index(metrics_by_name_time)
                |> Db.gte([Key.str(rule.target), Key.int(from_ms)])
                |> Db.lte([Key.str(rule.target), Key.int(now_ms)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(db)?
            vals = docs |> List.map(|d| d.value)
            st = Rollups.compute_stats(vals)
            Ok(Rollups.select_aggregation(st, rule.aggregation))
        } else if rule.kind == "log_count" {
            # Count logs matching target level (or service if target is not a known level).
            target = Str.trim(rule.target)
            docs =
                if Str.is_empty(target) {
                    Db.from_index(logs_by_timestamp)
                    |> Db.gte([Key.int(from_ms)])
                    |> Db.lte([Key.int(now_ms)])
                    |> Db.take(2000)
                    |> Db.collect!(db)?
                } else if target == "debug" or target == "info" or target == "warn" or target == "error" or target == "fatal" {
                    Db.from_index(logs_by_level_time)
                    |> Db.gte([Key.str(target), Key.int(from_ms)])
                    |> Db.lte([Key.str(target), Key.int(now_ms)])
                    |> Db.take(2000)
                    |> Db.collect!(db)?
                } else {
                    Db.from_index(logs_by_service_time)
                    |> Db.gte([Key.str(target), Key.int(from_ms)])
                    |> Db.lte([Key.str(target), Key.int(now_ms)])
                    |> Db.take(2000)
                    |> Db.collect!(db)?
                }
            Ok(Rollups.list_len_i64(docs).to_f64())
        } else {
            # Default: `error_count` — count error/fatal logs (including captured issues) in window,
            # optionally filtered by `rule.target` service/source.
            docs =
                Db.from_index(logs_by_timestamp)
                |> Db.gte([Key.int(from_ms)])
                |> Db.lte([Key.int(now_ms)])
                |> Db.take(2000)
                |> Db.collect!(db)?
            target = Str.trim(rule.target)
            var $errs = 0.I64
            for d in docs {
                if d.level_num >= 40 {
                    if Str.is_empty(target) or d.service == target or d.fn_name == target {
                        $errs = $errs + 1
                    }
                }
            }
            Ok($errs.to_f64())
        }
    }

    ## Evaluate all active alert rules, update rule states, open/resolve incidents,
    ## and return webhook notifications to deliver.
    evaluate_alerts_inner! : Ctx.MutationCtx, {} => Try(EvaluateAlertsResult, Str)
    evaluate_alerts_inner! = |ctx, _| {
        now_ms! = ctx.now_ms!
        now = now_ms!()
        reader = Ctx.as_reader(ctx.db)

        rules = Db.query(alert_rules_table) |> Db.asc() |> Db.collect!(reader)?
        var $evaluated = 0.I64
        var $firing = 0.I64
        var $resolved = 0.I64
        var $notifications = []

        for rule in rules {
            if rule.active {
                $evaluated = $evaluated + 1
                actual = measure_rule_value!(reader, rule, now)?
                tr = Alerts.evaluate_transition(
                    {
                        key: rule.key,
                        name: rule.name,
                        status: rule.status,
                        op: rule.op,
                        threshold: rule.threshold,
                        cooldown_ms: rule.cooldown_ms,
                        last_triggered_ms: rule.last_triggered_ms,
                        webhook_url: rule.webhook_url,
                    },
                    actual,
                    now,
                )

                next_triggered = if tr.should_open_incident { now } else { rule.last_triggered_ms }
                Db.patch!(ctx.db, alert_rules_table, rule.id, {
                    status: tr.next_status,
                    last_value: actual,
                    last_eval_ms: now,
                    last_triggered_ms: next_triggered,
                })?

                if tr.should_open_incident {
                    $firing = $firing + 1
                    msg = "[FIRING] ${rule.name} (${rule.key}): actual=${actual.to_str()} ${rule.op} threshold=${rule.threshold.to_str()}"
                    inc_id = Db.insert!(ctx.db, incidents_table, {
                        rule_key: rule.key,
                        rule_name: rule.name,
                        status: "firing",
                        triggered_at_ms: now,
                        resolved_at_ms: 0,
                        trigger_value: actual,
                        threshold: rule.threshold,
                        message: msg,
                        webhook_delivered: Bool.False,
                    })?
                    if tr.should_notify {
                        $notifications = List.append($notifications, {
                            incident_id: inc_id,
                            rule_key: rule.key,
                            rule_name: rule.name,
                            event: tr.notify_event,
                            webhook_url: rule.webhook_url,
                            value: actual,
                            threshold: rule.threshold,
                            message: msg,
                            timestamp_ms: now,
                        })
                    }
                } else if tr.should_resolve_incidents {
                    $resolved = $resolved + 1
                    # Resolve any open/acked incidents for this rule.
                    existing_incs =
                        Db.from_index(incidents_by_rule_time)
                        |> Db.eq([Key.str(rule.key)])
                        |> Db.desc()
                        |> Db.take(20)
                        |> Db.collect!(reader)?
                    var $resolved_inc_id = ""
                    for inc in existing_incs {
                        if inc.status == "firing" or inc.status == "acked" {
                            Db.patch!(ctx.db, incidents_table, inc.id, {
                                status: "resolved",
                                resolved_at_ms: now,
                            })?
                            if Str.is_empty($resolved_inc_id) {
                                $resolved_inc_id = inc.id
                            }
                        }
                    }
                    if tr.should_notify {
                        msg = "[RESOLVED] ${rule.name} (${rule.key}): actual=${actual.to_str()} cleared threshold=${rule.threshold.to_str()}"
                        $notifications = List.append($notifications, {
                            incident_id: $resolved_inc_id,
                            rule_key: rule.key,
                            rule_name: rule.name,
                            event: tr.notify_event,
                            webhook_url: rule.webhook_url,
                            value: actual,
                            threshold: rule.threshold,
                            message: msg,
                            timestamp_ms: now,
                        })
                    }
                }
            }
        }

        Ok({
            evaluated: $evaluated,
            firing: $firing,
            resolved: $resolved,
            notifications: $notifications,
        })
    }

    ## Mark an incident's webhook notification as delivered (used by `evaluateAndNotify`).
    mark_delivered_inner! : Ctx.MutationCtx, MarkDeliveredArgs => Try(Bool, Str)
    mark_delivered_inner! = |ctx, args| {
        if Str.is_empty(Str.trim(args.incident_id)) {
            return Ok(False)
        }
        lookup = Db.get!(Ctx.as_reader(ctx.db), incidents_table, args.incident_id)?
        match lookup {
            NotFound => Ok(False)
            Found(_) => {
                Db.patch!(ctx.db, incidents_table, args.incident_id, { webhook_delivered: Bool.True })?
                Ok(True)
            }
        }
    }

    ## Delete logs, metrics, and resolved incidents older than `retention_ms`.
    prune_inner! : Bool, List(Str), I64, Ctx.MutationCtx, PruneArgs => Try(PruneResult, Str)
    prune_inner! = |req_auth, admin_roles, default_retention_ms, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        now_ms! = ctx.now_ms!
        ret_ms = if args.retention_ms > 0 { args.retention_ms } else { default_retention_ms }
        cutoff = now_ms!() - ret_ms
        cap = clamp_limit_u64(args.max_delete, 200, 1000)
        reader = Ctx.as_reader(ctx.db)

        old_logs =
            Db.from_index(logs_by_timestamp)
            |> Db.lt([Key.int(cutoff)])
            |> Db.asc()
            |> Db.take(cap)
            |> Db.collect!(reader)?
        var $del_logs = 0.I64
        for d in old_logs {
            Db.delete!(ctx.db, logs_table, d.id)?
            $del_logs = $del_logs + 1
        }

        old_metrics =
            Db.from_index(metrics_by_timestamp)
            |> Db.lt([Key.int(cutoff)])
            |> Db.asc()
            |> Db.take(cap)
            |> Db.collect!(reader)?
        var $del_metrics = 0.I64
        for d in old_metrics {
            Db.delete!(ctx.db, metrics_table, d.id)?
            $del_metrics = $del_metrics + 1
        }

        old_incidents =
            Db.from_index(incidents_by_triggered)
            |> Db.lt([Key.int(cutoff)])
            |> Db.asc()
            |> Db.take(cap)
            |> Db.collect!(reader)?
        var $del_incidents = 0.I64
        for d in old_incidents {
            if d.status == "resolved" {
                Db.delete!(ctx.db, incidents_table, d.id)?
                $del_incidents = $del_incidents + 1
            }
        }

        Ok({
            deleted_logs: $del_logs,
            deleted_metrics: $del_metrics,
            deleted_incidents: $del_incidents,
        })
    }

    # -------------------------------------------------------------------------
    # Action: Evaluate Alert Rules & Deliver Webhooks
    # -------------------------------------------------------------------------

    evaluate_and_notify_action! : Bool, List(Str), Str, Ctx.ActionCtx, {} => Try(EvaluateAndNotifyResult, Str)
    evaluate_and_notify_action! = |req_auth, admin_roles, ns, ctx, _| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        run_mutation! = ctx.run_mutation!
        eval_json = run_mutation!("${ns}.evaluateAlerts", "{}")?
        eval_res : EvaluateAlertsResult
        eval_res = match Json.parse(eval_json) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode evaluateAlerts result: ${msg}")
        }

        http_fetch! = ctx.http_fetch!
        var $sent = 0.I64
        var $failed = 0.I64

        for n in eval_res.notifications {
            if !Str.is_empty(Str.trim(n.webhook_url)) {
                payload = match Json.to_str_try({
                    event: n.event,
                    rule_key: n.rule_key,
                    rule_name: n.rule_name,
                    incident_id: n.incident_id,
                    value: n.value,
                    threshold: n.threshold,
                    message: n.message,
                    text: n.message,
                    timestamp_ms: n.timestamp_ms,
                }) {
                    Ok(s) => s
                    Err(_) => "{\"event\":${Json.to_str(n.event)},\"rule_key\":${Json.to_str(n.rule_key)},\"message\":${Json.to_str(n.message)}}"
                }
                res = http_fetch!({
                    method: "POST",
                    url: n.webhook_url,
                    body: payload,
                })
                match res {
                    Ok(resp) => {
                        if resp.status >= 200 and resp.status < 300 {
                            $sent = $sent + 1
                            if !Str.is_empty(n.incident_id) {
                                _ = run_mutation!(
                                    "${ns}.markWebhookDelivered",
                                    Json.to_str({ incident_id: n.incident_id }),
                                )
                            }
                        } else {
                            $failed = $failed + 1
                        }
                    }
                    Err(_) => {
                        $failed = $failed + 1
                    }
                }
            }
        }

        Ok({
            evaluated: eval_res.evaluated,
            firing: eval_res.firing,
            resolved: eval_res.resolved,
            webhooks_sent: $sent,
            webhooks_failed: $failed,
        })
    }

    # -------------------------------------------------------------------------
    # Reactive Queries (Live WebSocket Subscriptions)
    # -------------------------------------------------------------------------

    ## Reactive issue inbox (admin-gated when `req_auth` is True).
    list_issues_inner! : Bool, List(Str), Ctx.QueryCtx, ListIssuesArgs => Try(List(IssueDoc), Str)
    list_issues_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        lim = clamp_limit_u64(args.limit, 50, 200)
        status = Str.trim(args.status)
        source = Str.trim(args.source)

        if !Str.is_empty(status) {
            docs =
                Db.from_index(issues_by_status_last_seen)
                |> Db.eq([Key.str(status)])
                |> Db.desc()
                |> Db.take(lim)
                |> Db.collect!(ctx.db)?
            if Str.is_empty(source) {
                Ok(docs)
            } else {
                Ok(docs |> List.keep_if(|d| d.source == source))
            }
        } else if !Str.is_empty(source) {
            Db.from_index(issues_by_source_last_seen)
            |> Db.eq([Key.str(source)])
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        } else {
            Db.from_index(issues_by_last_seen)
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        }
    }

    ## Fetch a single issue by `issue_id` or `fingerprint` (admin-gated when `req_auth` is True).
    get_issue_inner! : Bool, List(Str), Ctx.QueryCtx, GetIssueArgs => Try(GetIssueResult, Str)
    get_issue_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        id = Str.trim(args.issue_id)
        fp = Str.trim(args.fingerprint)
        lookup =
            if !Str.is_empty(id) {
                Db.get!(ctx.db, issues_table, id)?
            } else if !Str.is_empty(fp) {
                Db.from_index(issues_by_fingerprint)
                |> Db.eq([Key.str(fp)])
                |> Db.first!(ctx.db)?
            } else {
                NotFound
            }

        match lookup {
            NotFound =>
                Ok({
                    found: False,
                    id: "",
                    fingerprint: fp,
                    title: "",
                    source: "",
                    error_type: "",
                    level: "",
                    status: "",
                    count: 0,
                    first_seen_ms: 0,
                    last_seen_ms: 0,
                    last_message: "",
                    last_stack: "",
                    last_trace_id: "",
                    last_user_id: "",
                    attrs: [],
                    resolved_at_ms: 0,
                })
            Found(d) =>
                Ok({
                    found: True,
                    id: d.id,
                    fingerprint: d.fingerprint,
                    title: d.title,
                    source: d.source,
                    error_type: d.error_type,
                    level: d.level,
                    status: d.status,
                    count: d.count,
                    first_seen_ms: d.first_seen_ms,
                    last_seen_ms: d.last_seen_ms,
                    last_message: d.last_message,
                    last_stack: d.last_stack,
                    last_trace_id: d.last_trace_id,
                    last_user_id: d.last_user_id,
                    attrs: d.attrs,
                    resolved_at_ms: d.resolved_at_ms,
                })
        }
    }

    ## Reactive live log tail (admin-gated when `req_auth` is True).
    recent_logs_inner! : Bool, List(Str), Ctx.QueryCtx, RecentLogsArgs => Try(List(LogDoc), Str)
    recent_logs_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        lim = clamp_limit_u64(args.limit, 50, 200)
        service = Str.trim(args.service)
        level = Str.trim(args.level)
        fn_name = Str.trim(args.fn_name)

        if !Str.is_empty(fn_name) {
            docs =
                Db.from_index(logs_by_fn_time)
                |> Db.eq([Key.str(fn_name)])
                |> Db.desc()
                |> Db.take(lim)
                |> Db.collect!(ctx.db)?
            Ok(docs)
        } else if !Str.is_empty(service) {
            docs =
                Db.from_index(logs_by_service_time)
                |> Db.eq([Key.str(service)])
                |> Db.desc()
                |> Db.take(lim)
                |> Db.collect!(ctx.db)?
            if Str.is_empty(level) {
                Ok(docs)
            } else {
                min_rank = Attrs.level_rank(level)
                Ok(docs |> List.keep_if(|d| d.level_num >= min_rank))
            }
        } else if !Str.is_empty(level) {
            norm = Attrs.normalize_level(level)
            Db.from_index(logs_by_level_time)
            |> Db.eq([Key.str(norm)])
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        } else {
            Db.from_index(logs_by_timestamp)
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        }
    }

    ## Reactive case-insensitive full-text search across log messages (admin-gated when `req_auth` is True).
    search_logs_inner! : Bool, List(Str), Ctx.QueryCtx, SearchLogsArgs => Try(List(LogDoc), Str)
    search_logs_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        q = Str.trim(args.query)
        if Str.is_empty(q) {
            return Ok([])
        }
        lim = clamp_limit_u64(args.limit, 50, 200)
        Db.search!(ctx.db, logs_table, "message", q, lim)
    }

    ## Chronological log & span timeline for a single `trace_id` (admin-gated when `req_auth` is True).
    trace_logs_inner! : Bool, List(Str), Ctx.QueryCtx, TraceLogsArgs => Try(List(LogDoc), Str)
    trace_logs_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        tid = Str.trim(args.trace_id)
        if Str.is_empty(tid) {
            return Ok([])
        }
        lim = clamp_limit_u64(args.limit, 100, 500)
        Db.from_index(logs_by_trace_time)
        |> Db.eq([Key.str(tid)])
        |> Db.asc()
        |> Db.take(lim)
        |> Db.collect!(ctx.db)
    }

    ## Time-bucketed metric rollup (admin-gated when `req_auth` is True, bounded scan).
    metric_series_inner! : Bool, List(Str), Ctx.QueryCtx, MetricSeriesArgs => Try(Rollups.MetricSeriesResult, Str)
    metric_series_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        name = Str.trim(args.name)
        if Str.is_empty(name) {
            return Err("Metric name is required")
        }
        now_ms! = ctx.now_ms!
        to_ms = if args.to_ms > 0 { args.to_ms } else { now_ms!() }
        from_ms = if args.from_ms > 0 { args.from_ms } else { to_ms - 3600000 }

        docs =
            Db.from_index(metrics_by_name_time)
            |> Db.gte([Key.str(name), Key.int(from_ms)])
            |> Db.lte([Key.str(name), Key.int(to_ms)])
            |> Db.asc()
            |> Db.take(2000)
            |> Db.collect!(ctx.db)?

        service = Str.trim(args.service)
        filtered =
            if Str.is_empty(service) {
                docs
            } else {
                docs |> List.keep_if(|d| d.service == service)
            }

        samples = filtered |> List.map(|d| { timestamp_ms: d.timestamp_ms, value: d.value })
        Ok(Rollups.compute_series(name, samples, args.bucket_ms))
    }

    ## Live application health overview KPIs (admin-gated when `req_auth` is True, bounded scan).
    overview_inner! : Bool, List(Str), Ctx.QueryCtx, OverviewArgs => Try(Rollups.OverviewResult, Str)
    overview_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        now_ms! = ctx.now_ms!
        now = now_ms!()
        win_ms = if args.window_ms <= 0 { 3600000 } else if args.window_ms > 2592000000 { 2592000000 } else { args.window_ms }
        top_n = if args.top_n <= 0 { 5 } else if args.top_n > 100 { 100 } else { args.top_n }
        from_ms = now - win_ms

        all_issues =
            Db.from_index(issues_by_last_seen)
            |> Db.desc()
            |> Db.take(200)
            |> Db.collect!(ctx.db)?

        var $open_count = 0.I64
        var $total_issues = 0.I64
        var $services = []
        var $top_issues = []
        var $top_added = 0.I64

        for iss in all_issues {
            $total_issues = $total_issues + 1
            $services = Rollups.add_unique_str($services, iss.source)
            if iss.status == "open" {
                $open_count = $open_count + 1
                if $top_added < top_n {
                    $top_issues = List.append($top_issues, {
                        id: iss.id,
                        fingerprint: iss.fingerprint,
                        title: iss.title,
                        source: iss.source,
                        level: iss.level,
                        status: iss.status,
                        count: iss.count,
                        last_seen_ms: iss.last_seen_ms,
                    })
                    $top_added = $top_added + 1
                }
            }
        }

        recent_logs =
            Db.from_index(logs_by_timestamp)
            |> Db.gte([Key.int(from_ms)])
            |> Db.lte([Key.int(now)])
            |> Db.take(2000)
            |> Db.collect!(ctx.db)?

        var $err_events = 0.I64
        var $err_logs = 0.I64
        for lg in recent_logs {
            $services = Rollups.add_unique_str($services, lg.service)
            if lg.level_num >= 40 {
                $err_logs = $err_logs + 1
                if lg.status == "issue" {
                    $err_events = $err_events + 1
                }
            }
        }

        rules = Db.query(alert_rules_table) |> Db.asc() |> Db.take(500) |> Db.collect!(ctx.db)?
        var $active_rules = 0.I64
        var $firing_alerts = 0.I64
        for r in rules {
            if r.active {
                $active_rules = $active_rules + 1
            }
            if r.status == "firing" {
                $firing_alerts = $firing_alerts + 1
            }
        }

        Ok({
            open_issues: $open_count,
            total_issues: $total_issues,
            error_events_in_window: $err_events,
            error_logs_in_window: $err_logs,
            firing_alerts: $firing_alerts,
            active_rules: $active_rules,
            top_issues: $top_issues,
            services: $services,
        })
    }

    redact_alert_rule : AlertRuleDoc -> AlertRuleDoc
    redact_alert_rule = |r| {
        id: r.id,
        created_at: r.created_at,
        key: r.key,
        name: r.name,
        active: r.active,
        kind: r.kind,
        target: r.target,
        aggregation: r.aggregation,
        op: r.op,
        threshold: r.threshold,
        window_ms: r.window_ms,
        cooldown_ms: r.cooldown_ms,
        webhook_url: if Str.is_empty(Str.trim(r.webhook_url)) { "" } else { "[redacted]" },
        status: r.status,
        last_value: r.last_value,
        last_eval_ms: r.last_eval_ms,
        last_triggered_ms: r.last_triggered_ms,
        updated_at_ms: r.updated_at_ms,
    }

    ## List all configured alert rules (admin-gated when `req_auth` is True, webhook URLs redacted on public API).
    list_alert_rules_inner! : Bool, List(Str), Bool, Ctx.QueryCtx, {} => Try(List(AlertRuleDoc), Str)
    list_alert_rules_inner! = |req_auth, admin_roles, redact_webhooks, ctx, _| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        rules = Db.query(alert_rules_table) |> Db.asc() |> Db.take(500) |> Db.collect!(ctx.db)?
        if redact_webhooks {
            Ok(rules |> List.map(redact_alert_rule))
        } else {
            Ok(rules)
        }
    }

    ## List alert incidents (admin-gated when `req_auth` is True).
    list_incidents_inner! : Bool, List(Str), Ctx.QueryCtx, ListIncidentsArgs => Try(List(IncidentDoc), Str)
    list_incidents_inner! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        lim = clamp_limit_u64(args.limit, 50, 200)
        status = Str.trim(args.status)
        rule_key = Str.trim(args.rule_key)

        if !Str.is_empty(rule_key) {
            docs =
                Db.from_index(incidents_by_rule_time)
                |> Db.eq([Key.str(rule_key)])
                |> Db.desc()
                |> Db.take(lim)
                |> Db.collect!(ctx.db)?
            if Str.is_empty(status) {
                Ok(docs)
            } else {
                Ok(docs |> List.keep_if(|d| d.status == status))
            }
        } else if !Str.is_empty(status) {
            Db.from_index(incidents_by_status_time)
            |> Db.eq([Key.str(status)])
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        } else {
            Db.from_index(incidents_by_triggered)
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        }
    }

    # -------------------------------------------------------------------------
    # Transactional Server-Side Helpers (Same ACID Transaction as Parent App!)
    # -------------------------------------------------------------------------

    ## Capture an error inside a parent app mutation's exact same ACID transaction.
    capture_error! : Mount, Ctx.MutationCtx, CaptureErrorArgs => Try(CaptureErrorResult, Str)
    capture_error! = |m, parent_ctx, args| {
        scoped = Ctx.scope_mutation(parent_ctx, m.namespace)
        capture_error_inner!(True, [], scoped, args)
    }

    ## Write a structured log inside a parent app mutation's exact same ACID transaction.
    ## If the parent mutation returns `Err`, the log rolls back automatically!
    log! : Mount, Ctx.MutationCtx, LogArgs => Try(Str, Str)
    log! = |m, parent_ctx, args| {
        scoped = Ctx.scope_mutation(parent_ctx, m.namespace)
        log_inner!(m.admin_roles, scoped, args)
    }

    ## Ergonomic one-liner to log an info message inside a parent app mutation.
    log_info! : Mount, Ctx.MutationCtx, Str, Str, List(Attrs.Attr) => Try(Str, Str)
    log_info! = |m, parent_ctx, service, message, attrs|
        log!(m, parent_ctx, {
            level: "info",
            service,
            fn_name: "",
            trace_id: "",
            span_id: "",
            duration_ms: 0,
            status: "ok",
            message,
            attrs,
            timestamp_ms: 0,
        })

    ## Ergonomic one-liner to log an error message inside a parent app mutation.
    log_error! : Mount, Ctx.MutationCtx, Str, Str, List(Attrs.Attr) => Try(Str, Str)
    log_error! = |m, parent_ctx, service, message, attrs|
        log!(m, parent_ctx, {
            level: "error",
            service,
            fn_name: "",
            trace_id: "",
            span_id: "",
            duration_ms: 0,
            status: "error",
            message,
            attrs,
            timestamp_ms: 0,
        })

    ## Record a traced operation span inside a parent app mutation.
    record_span! : Mount, Ctx.MutationCtx, Str, Str, Str, I64, Str, List(Attrs.Attr) => Try(Str, Str)
    record_span! = |m, parent_ctx, service, fn_name, trace_id, duration_ms, status, attrs|
        log!(m, parent_ctx, {
            level: if status == "error" { "error" } else { "info" },
            service,
            fn_name,
            trace_id,
            span_id: "",
            duration_ms,
            status,
            message: "${service}.${fn_name} (${duration_ms.to_str()}ms)",
            attrs,
            timestamp_ms: 0,
        })

    ## Record a custom application metric inside a parent app mutation's ACID transaction.
    record_metric! : Mount, Ctx.MutationCtx, Str, Str, F64, Str, List(Attrs.Attr) => Try(Str, Str)
    record_metric! = |m, parent_ctx, name, kind, value, service, attrs| {
        scoped = Ctx.scope_mutation(parent_ctx, m.namespace)
        record_metric_inner!(m.admin_roles, scoped, {
            name,
            kind,
            value,
            service,
            attrs,
            timestamp_ms: 0,
        })
    }

    ## Create or update an alert rule inside a parent app mutation (e.g., seeding default rules).
    upsert_alert_rule_in_tx! : Mount, Ctx.MutationCtx, UpsertAlertRuleArgs => Try(Str, Str)
    upsert_alert_rule_in_tx! = |m, parent_ctx, args| {
        scoped = Ctx.scope_mutation(parent_ctx, m.namespace)
        upsert_alert_rule_inner!(False, [], m.allow_insecure_webhooks, scoped, args)
    }

    ## List all alert rules from inside a parent app query or mutation (trusted server-side caller).
    list_alert_rules_in_query! : Mount, Ctx.QueryCtx => Try(List(AlertRuleDoc), Str)
    list_alert_rules_in_query! = |m, parent_ctx| {
        scoped = Ctx.scope_query(parent_ctx, m.namespace)
        list_alert_rules_inner!(False, [], False, scoped, {})
    }

    # -------------------------------------------------------------------------
    # App Attachment
    # -------------------------------------------------------------------------

    ## Attach the mounted Monitor component's isolated tables, mutations, reactive queries,
    ## internal scheduler helpers, and webhook alert notification action to `App`.
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        req_auth = m.require_auth_for_admin
        admin_roles = m.admin_roles
        allow_http = m.allow_insecure_webhooks
        max_batch = m.max_batch_size
        default_ret = m.default_retention_ms

        issue_doc_schema = Table.doc_schema_scoped(issues_table, ns)
        log_doc_schema = Table.doc_schema_scoped(logs_table, ns)
        alert_rule_doc_schema = Table.doc_schema_scoped(alert_rules_table, ns)
        incident_doc_schema = Table.doc_schema_scoped(incidents_table, ns)

        spec
        |> App.component(m.spec)
        # Mutations
        |> App.component_mutation(
            ns,
            "${ns}.captureError",
            capture_error_args_schema,
            capture_error_result_schema,
            |ctx, args| capture_error_inner!(False, admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.updateIssueStatus",
            update_issue_status_args_schema,
            Schema.bool,
            |ctx, args| update_issue_status_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.log",
            log_args_schema,
            Schema.scoped_id(ns, "logs"),
            |ctx, args| log_inner!(admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.logBatch",
            log_batch_args_schema,
            batch_result_schema,
            |ctx, args| log_batch_inner!(admin_roles, max_batch, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.recordMetric",
            record_metric_args_schema,
            Schema.scoped_id(ns, "metrics"),
            |ctx, args| record_metric_inner!(admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.recordMetricBatch",
            record_metric_batch_args_schema,
            batch_result_schema,
            |ctx, args| record_metric_batch_inner!(admin_roles, max_batch, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.upsertAlertRule",
            upsert_alert_rule_args_schema,
            Schema.scoped_id(ns, "alert_rules"),
            |ctx, args| upsert_alert_rule_inner!(req_auth, admin_roles, allow_http, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.deleteAlertRule",
            delete_alert_rule_args_schema,
            Schema.bool,
            |ctx, args| delete_alert_rule_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.acknowledgeIncident",
            acknowledge_incident_args_schema,
            Schema.bool,
            |ctx, args| acknowledge_incident_inner!(req_auth, admin_roles, ctx, args),
        )
        # Internal-only helper mutations (callable by evaluateAndNotify & crons; rejected on public HTTP/WS)
        |> App.component_internal_mutation(
            ns,
            "${ns}.evaluateAlerts",
            Schema.record([]),
            evaluate_alerts_result_schema,
            evaluate_alerts_inner!,
        )
        |> App.component_internal_mutation(
            ns,
            "${ns}.markWebhookDelivered",
            mark_delivered_args_schema,
            Schema.bool,
            mark_delivered_inner!,
        )
        |> App.component_internal_mutation(
            ns,
            "${ns}._cronPrune",
            prune_args_schema,
            prune_result_schema,
            |ctx, args| prune_inner!(False, [], default_ret, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.prune",
            prune_args_schema,
            prune_result_schema,
            |ctx, args| prune_inner!(req_auth, admin_roles, default_ret, ctx, args),
        )
        # Actions (evaluates rules + sends HTTP webhooks)
        |> App.action(
            "${ns}.evaluateAndNotify",
            Schema.record([]),
            evaluate_and_notify_result_schema,
            |ctx, args| evaluate_and_notify_action!(req_auth, admin_roles, ns, ctx, args),
        )
        |> App.component_internal_action(
            ns,
            "${ns}._cronEvaluateAndNotify",
            Schema.record([]),
            evaluate_and_notify_result_schema,
            |ctx, args| evaluate_and_notify_action!(False, [], ns, ctx, args),
        )
        # Reactive Queries (admin-gated when `req_auth` is True)
        |> App.component_query(
            ns,
            "${ns}.overview",
            overview_args_schema,
            overview_result_schema,
            |ctx, args| overview_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.listIssues",
            list_issues_args_schema,
            Schema.list(issue_doc_schema),
            |ctx, args| list_issues_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.getIssue",
            get_issue_args_schema,
            get_issue_result_schema,
            |ctx, args| get_issue_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.recentLogs",
            recent_logs_args_schema,
            Schema.list(log_doc_schema),
            |ctx, args| recent_logs_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.searchLogs",
            search_logs_args_schema,
            Schema.list(log_doc_schema),
            |ctx, args| search_logs_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.traceLogs",
            trace_logs_args_schema,
            Schema.list(log_doc_schema),
            |ctx, args| trace_logs_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.metricSeries",
            metric_series_args_schema,
            metric_series_result_schema,
            |ctx, args| metric_series_inner!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.listAlertRules",
            Schema.record([]),
            Schema.list(alert_rule_doc_schema),
            |ctx, args| list_alert_rules_inner!(req_auth, admin_roles, True, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.listIncidents",
            list_incidents_args_schema,
            Schema.list(incident_doc_schema),
            |ctx, args| list_incidents_inner!(req_auth, admin_roles, ctx, args),
        )
    }

    ## Attach the Monitor component AND wire recurring `App.cron` schedules for
    ## alert evaluation + webhook delivery (`eval_interval_ms > 0`) and retention pruning (`prune_interval_ms > 0`).
    ## Crons invoke internal endpoints (`_cronEvaluateAndNotify`, `_cronPrune`) so they continue working
    ## seamlessly with `require_auth_for_admin: True`.
    attach_with_cron : App, Mount, I64, I64 -> App
    attach_with_cron = |spec, m, eval_interval_ms, prune_interval_ms| {
        ns = m.namespace
        with_comp = attach(spec, m)
        with_eval =
            if eval_interval_ms > 0 {
                with_comp |> App.cron("${ns}_eval_alerts", eval_interval_ms, "${ns}._cronEvaluateAndNotify", "{}")
            } else {
                with_comp
            }
        if prune_interval_ms > 0 {
            prune_args = "{\"retention_ms\":${m.default_retention_ms.to_str()},\"max_delete\":250}"
            with_eval |> App.cron("${ns}_prune", prune_interval_ms, "${ns}._cronPrune", prune_args)
        } else {
            with_eval
        }
    }
}

expect {
    m = Monitor.mount("monitor")
    m.namespace == "monitor"
    and m.require_auth_for_admin
    and m.spec.pkg_name == "concave-monitor"
    and List.len(m.spec.tables) == 5
}

expect {
    m = Monitor.mount_with("ops_monitor", {
        require_auth_for_admin: True,
        max_batch_size: 50,
        default_retention_ms: 86400000,
    })
    spec = App.new("test") |> Monitor.attach_with_cron(m, 30000, 3600000)
    m.namespace == "ops_monitor"
    and m.require_auth_for_admin
    and m.max_batch_size == 50
    and List.len(spec.components) == 1
    and List.len(spec.mutations) == 13
    and List.len(spec.actions) == 2
    and List.len(spec.queries) == 9
    and List.len(spec.crons) == 2
}
