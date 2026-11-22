app [concave_app] {
    pf: platform "../../../platform/main.roc",
    sdk: "../../../packages/concave-sdk/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Schema
import sdk.Table

NoteDoc : {
    id : Str,
    created_at : I64,
    title : Str,
    body : Str,
    seq : I64,
}

notes_schema : Schema
notes_schema = Schema.record([
    Schema.field("title", Schema.str),
    Schema.field("body", Schema.str),
    Schema.field("seq", Schema.int),
])

notes_table : Table(NoteDoc)
notes_table =
    Table.define("notes", notes_schema)
    |> Table.with_index("by_seq", ["seq"])

notes_by_seq : Table.Index(NoteDoc)
notes_by_seq = Table.index_ref(notes_table, "by_seq")

EventDoc : {
    id : Str,
    created_at : I64,
    kind : Str,
    detail : Str,
}

events_schema : Schema
events_schema = Schema.record([
    Schema.field("kind", Schema.str),
    Schema.field("detail", Schema.str),
])

events_table : Table(EventDoc)
events_table = Table.define("events", events_schema)

EmptyArgs : {}

CreateNoteArgs : {
    title : Str,
    body : Str,
    seq : I64,
}

RecordEventArgs : {
    kind : Str,
    detail : Str,
}

ScheduleArgs : {
    delay_ms : I64,
    detail : Str,
}

CancelArgs : {
    job_id : Str,
}

StorageIdArgs : {
    storage_id : Str,
}

PaginateArgs : {
    cursor : Str,
    page_size : U64,
}

SearchArgs : {
    q : Str,
    limit : U64,
}

notes_create! : Ctx.MutationCtx, CreateNoteArgs => Try(Str, Str)
notes_create! = |ctx, args|
    Db.insert!(ctx.db, notes_table, {
        title: args.title,
        body: args.body,
        seq: args.seq,
    })

notes_paginate! : Ctx.QueryCtx, PaginateArgs => Try(Db.Page(NoteDoc), Str)
notes_paginate! = |ctx, args|
    Db.from_index(notes_by_seq)
    |> Db.asc
    |> Db.paginate!(ctx.db, args.cursor, args.page_size)

notes_search! : Ctx.QueryCtx, SearchArgs => Try(List(NoteDoc), Str)
notes_search! = |ctx, args|
    Db.search!(ctx.db, notes_table, "body", args.q, args.limit)

events_record! : Ctx.MutationCtx, RecordEventArgs => Try(Str, Str)
events_record! = |ctx, args|
    Db.insert!(ctx.db, events_table, {
        kind: args.kind,
        detail: args.detail,
    })

events_list! : Ctx.QueryCtx, EmptyArgs => Try(List(EventDoc), Str)
events_list! = |ctx, _|
    Db.query(events_table) |> Db.asc |> Db.collect!(ctx.db)

jobs_schedule_commit! : Ctx.MutationCtx, ScheduleArgs => Try(Str, Str)
jobs_schedule_commit! = |ctx, args| {
    run_after! = ctx.scheduler.run_after!
    payload = "{\"kind\":\"scheduled\",\"detail\":${Json.to_str(args.detail)}}"
    run_after!(args.delay_ms, "events.record", payload)
}

jobs_schedule_abort! : Ctx.MutationCtx, ScheduleArgs => Try(Str, Str)
jobs_schedule_abort! = |ctx, args| {
    run_after! = ctx.scheduler.run_after!
    payload = "{\"kind\":\"rolled_back\",\"detail\":${Json.to_str(args.detail)}}"
    _ = run_after!(args.delay_ms, "events.record", payload)?
    Err("deliberate mutation rollback")
}

jobs_cancel! : Ctx.MutationCtx, CancelArgs => Try(Bool, Str)
jobs_cancel! = |ctx, args| {
    cancel! = ctx.scheduler.cancel!
    cancel!(args.job_id)?
    Ok(Bool.True)
}

files_upload_url! : Ctx.MutationCtx, EmptyArgs => Try(Str, Str)
files_upload_url! = |ctx, _| {
    gen! = ctx.storage.generate_upload_url!
    gen!()
}

files_download_url! : Ctx.QueryCtx, StorageIdArgs => Try(Str, Str)
files_download_url! = |ctx, args| {
    get_url! = ctx.storage.get_url!
    get_url!(args.storage_id)
}

files_delete! : Ctx.MutationCtx, StorageIdArgs => Try(Bool, Str)
files_delete! = |ctx, args| {
    del! = ctx.storage.delete!
    del!(args.storage_id)?
    Ok(Bool.True)
}

webhook_note! : Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponse, Str)
webhook_note! = |ctx, req| {
    run_mut! = ctx.run_mutation!
    note_id = run_mut!("notes.create", req.body)?
    Ok({
        status: 201,
        content_type: "application/json",
        body: "{\"received\":true,\"note_id\":${note_id},\"query\":${Json.to_str(req.query)}}",
    })
}

webhook_echo! : Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponse, Str)
webhook_echo! = |_, req|
    Ok({
        status: 200,
        content_type: "application/json",
        body: "{\"method\":${Json.to_str(req.method)},\"path\":${Json.to_str(req.path)},\"query\":${Json.to_str(req.query)}}",
    })

concave_app : () -> App
concave_app = ||
    App.new("platform-features-test")
    |> App.table(notes_table)
    |> App.table(events_table)
    |> App.mutation("notes.create", Schema.any, Schema.str, notes_create!)
    |> App.query("notes.paginate", Schema.any, Schema.any, notes_paginate!)
    |> App.query("notes.search", Schema.any, Schema.any, notes_search!)
    |> App.mutation("events.record", Schema.any, Schema.str, events_record!)
    |> App.query("events.list", Schema.any, Schema.any, events_list!)
    |> App.mutation("jobs.schedule_commit", Schema.any, Schema.str, jobs_schedule_commit!)
    |> App.mutation("jobs.schedule_abort", Schema.any, Schema.str, jobs_schedule_abort!)
    |> App.mutation("jobs.cancel", Schema.any, Schema.bool, jobs_cancel!)
    |> App.mutation("files.upload_url", Schema.any, Schema.str, files_upload_url!)
    |> App.query("files.download_url", Schema.any, Schema.str, files_download_url!)
    |> App.mutation("files.delete", Schema.any, Schema.bool, files_delete!)
    |> App.cron("heartbeat", 150, "events.record", "{\"kind\":\"cron\",\"detail\":\"tick\"}")
    |> App.http_route("POST", "/webhooks/note", webhook_note!)
    |> App.http_route("GET", "/webhooks/echo/*", webhook_echo!)
