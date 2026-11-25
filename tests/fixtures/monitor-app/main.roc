app [concave_app] {
    pf: platform "../../../platform/main.roc",
    sdk: "../../../packages/concave-sdk/main.roc",
    monitor: "../../../packages/monitor/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Schema
import sdk.Table
import monitor.Attrs
import monitor.Monitor

## Two independently mounted Monitor instances proving strict host-enforced namespace isolation.
app_monitor : Monitor.Mount
app_monitor =
    Monitor.mount("monitor")
    |> Monitor.with_insecure_webhooks(True)

ops_monitor : Monitor.Mount
ops_monitor = Monitor.mount_with("ops_monitor", {
    require_auth_for_admin: True,
    max_batch_size: 2,
    default_retention_ms: 86400000,
})

JobDoc : {
    id : Str,
    created_at : I64,
    name : Str,
    amount : I64,
}

jobs_schema : Schema
jobs_schema = Schema.record([
    Schema.field("name", Schema.str),
    Schema.field("amount", Schema.int),
])

jobs_table : Table(JobDoc)
jobs_table = Table.define("jobs", jobs_schema)

ProcessJobArgs : {
    name : Str,
    amount : I64,
    trace_id : Str,
}

process_job_args_schema : Schema
process_job_args_schema = Schema.record([
    Schema.field("name", Schema.str),
    Schema.field("amount", Schema.int),
    Schema.field("trace_id", Schema.str),
])

list_jobs! : Ctx.QueryCtx, {} => Try(List(JobDoc), Str)
list_jobs! = |ctx, _|
    Db.query(jobs_table)
    |> Db.asc()
    |> Db.collect!(ctx.db)

## Demonstrates transactional `Monitor.record_span!` + `Monitor.record_metric!` inside a parent
## app mutation. If `amount <= 0`, returns `Err` AFTER logging to prove ACID rollback leaves
## zero ghost logs or metrics.
process_job! : Ctx.MutationCtx, ProcessJobArgs => Try(Str, Str)
process_job! = |ctx, args| {
    _ = Monitor.record_span!(
        app_monitor,
        ctx,
        "billing",
        "jobs.process",
        args.trace_id,
        42,
        "ok",
        [Attrs.attr("job_name", args.name)],
    )?

    _ = Monitor.record_metric!(
        app_monitor,
        ctx,
        "jobs.amount",
        "gauge",
        args.amount.to_f64(),
        "billing",
        [Attrs.attr("job_name", args.name)],
    )?

    if args.amount <= 0 {
        return Err("Job amount must be positive")
    }

    Db.insert!(ctx.db, jobs_table, {
        name: args.name,
        amount: args.amount,
    })
}

concave_app : () -> App
concave_app = ||
    App.new("concave-monitor-test")
    |> App.table(jobs_table)
    |> Monitor.attach(app_monitor)
    |> Monitor.attach(ops_monitor)
    |> App.query("jobs.list", Schema.record([]), Schema.list(Table.doc_schema(jobs_table)), list_jobs!)
    |> App.mutation("jobs.process", process_job_args_schema, Schema.id("jobs"), process_job!)
