platform ""
    requires {
        concave_app : () -> App
    }
    exposes [Host]
    packages {
        sdk: "../packages/concave-sdk/main.roc",
    }
    provides {
        "roc_introspect": introspect_for_host,
        "roc_dispatch_query": dispatch_query_for_host!,
        "roc_dispatch_mutation": dispatch_mutation_for_host!,
        "roc_dispatch_action": dispatch_action_for_host!,
        "roc_dispatch_http": dispatch_http_for_host!,
    }
    hosted {
        "roc_host_db_get": Host.db_get!,
        "roc_host_db_query": Host.db_query!,
        "roc_host_db_paginate": Host.db_paginate!,
        "roc_host_db_search": Host.db_search!,
        "roc_host_db_insert": Host.db_insert!,
        "roc_host_db_patch": Host.db_patch!,
        "roc_host_db_replace": Host.db_replace!,
        "roc_host_db_delete": Host.db_delete!,
        "roc_host_schedule_job": Host.schedule_job!,
        "roc_host_cancel_job": Host.cancel_job!,
        "roc_host_storage_upload_url": Host.storage_upload_url!,
        "roc_host_storage_get_url": Host.storage_get_url!,
        "roc_host_storage_delete": Host.storage_delete!,
        "roc_host_auth_identity": Host.auth_identity!,
        "roc_host_http_fetch": Host.http_fetch!,
        "roc_host_run_query": Host.run_query!,
        "roc_host_run_mutation": Host.run_mutation!,
        "roc_host_now_ms": Host.now_ms!,
    }
    targets: {
        inputs_dir: "targets/",
        arm64mac: { inputs: ["libhost.a", app] },
        x64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        x64linux: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        arm64linux: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
    }

import Host
import sdk.App
import sdk.Ctx

unwrap_wire : Str -> Try(Str, Str)
unwrap_wire = |raw|
    if Str.starts_with(raw, "OK:") {
        Ok(Str.drop_prefix(raw, "OK:"))
    } else if Str.starts_with(raw, "ERR:") {
        Err(Str.drop_prefix(raw, "ERR:"))
    } else {
        Err("malformed host wire response: ${raw}")
    }

unwrap_wire_unit : Str -> Try({}, Str)
unwrap_wire_unit = |raw|
    match unwrap_wire(raw) {
        Ok(_) => Ok({})
        Err(e) => Err(e)
    }

wrap_wire : Try(Str, Str) -> Str
wrap_wire = |res|
    match res {
        Ok(payload) => "OK:${payload}"
        Err(msg) => "ERR:${msg}"
    }

auth_from_host! : () => Try(Ctx.AuthIdentity, [Unauthenticated])
auth_from_host! = || {
    raw = Host.auth_identity!()
    match unwrap_wire(raw) {
        Ok(json_str) =>
            match Json.parse(json_str) {
                Ok(id) => Ok(id)
                Err(_) => Err(Unauthenticated)
            }
        Err(_) => Err(Unauthenticated)
    }
}

make_db_reader : Str -> Ctx.DbReader
make_db_reader = |namespace| {
    namespace,
    get_raw!: |ns, tbl, doc_id| unwrap_wire(Host.db_get!(ns, tbl, doc_id)),
    query_raw!: |req_json| unwrap_wire(Host.db_query!(req_json)),
    paginate_raw!: |req_json| unwrap_wire(Host.db_paginate!(req_json)),
    search_raw!: |req_json| unwrap_wire(Host.db_search!(req_json)),
}

make_db_writer : Str -> Ctx.DbWriter
make_db_writer = |namespace| {
    namespace,
    get_raw!: |ns, tbl, doc_id| unwrap_wire(Host.db_get!(ns, tbl, doc_id)),
    query_raw!: |req_json| unwrap_wire(Host.db_query!(req_json)),
    paginate_raw!: |req_json| unwrap_wire(Host.db_paginate!(req_json)),
    search_raw!: |req_json| unwrap_wire(Host.db_search!(req_json)),
    insert_raw!: |ns, tbl, body_json| unwrap_wire(Host.db_insert!(ns, tbl, body_json)),
    patch_raw!: |ns, tbl, doc_id, patch_json| unwrap_wire_unit(Host.db_patch!(ns, tbl, doc_id, patch_json)),
    replace_raw!: |ns, tbl, doc_id, body_json| unwrap_wire_unit(Host.db_replace!(ns, tbl, doc_id, body_json)),
    delete_raw!: |ns, tbl, doc_id| unwrap_wire_unit(Host.db_delete!(ns, tbl, doc_id)),
}

make_scheduler : () -> Ctx.Scheduler
make_scheduler = || {
    run_after!: |delay_ms, fn_name, args_json| {
        now = Host.now_ms!()
        unwrap_wire(Host.schedule_job!(now + delay_ms, fn_name, args_json))
    },
    run_at!: |run_at_ms, fn_name, args_json|
        unwrap_wire(Host.schedule_job!(run_at_ms, fn_name, args_json)),
    cancel!: |job_id| unwrap_wire_unit(Host.cancel_job!(job_id)),
}

make_storage_reader : () -> Ctx.StorageReader
make_storage_reader = || {
    get_url!: |storage_id| unwrap_wire(Host.storage_get_url!(storage_id)),
}

make_storage_writer : () -> Ctx.StorageWriter
make_storage_writer = || {
    generate_upload_url!: || unwrap_wire(Host.storage_upload_url!()),
    get_url!: |storage_id| unwrap_wire(Host.storage_get_url!(storage_id)),
    delete!: |storage_id| unwrap_wire_unit(Host.storage_delete!(storage_id)),
}

make_query_ctx : () -> Ctx.QueryCtx
make_query_ctx = || {
    db: make_db_reader(""),
    storage: make_storage_reader(),
    auth!: auth_from_host!,
    now_ms!: Host.now_ms!,
}

make_mutation_ctx : () -> Ctx.MutationCtx
make_mutation_ctx = || {
    db: make_db_writer(""),
    scheduler: make_scheduler(),
    storage: make_storage_writer(),
    auth!: auth_from_host!,
    now_ms!: Host.now_ms!,
}

make_action_ctx : () -> Ctx.ActionCtx
make_action_ctx = || {
    storage: make_storage_writer(),
    auth!: auth_from_host!,
    now_ms!: Host.now_ms!,
    http_fetch!: |req| {
        raw = unwrap_wire(Host.http_fetch!(req.method, req.url, req.body))?
        match Json.parse(raw) {
            Ok(resp) => Ok(resp)
            Err(InvalidJson(msg)) => Err("failed to decode http_fetch response: ${msg}")
        }
    },
    run_query!: |name, args_json| unwrap_wire(Host.run_query!(name, args_json)),
    run_mutation!: |name, args_json| unwrap_wire(Host.run_mutation!(name, args_json)),
}

introspect_for_host : () -> Str
introspect_for_host = || App.manifest_json(concave_app())

dispatch_query_for_host! : Str, Str => Str
dispatch_query_for_host! = |name, args_json|
    wrap_wire(App.dispatch_query!(concave_app(), make_query_ctx(), name, args_json))

dispatch_mutation_for_host! : Str, Str => Str
dispatch_mutation_for_host! = |name, args_json|
    wrap_wire(App.dispatch_mutation!(concave_app(), make_mutation_ctx(), name, args_json))

dispatch_action_for_host! : Str, Str => Str
dispatch_action_for_host! = |name, args_json|
    wrap_wire(App.dispatch_action!(concave_app(), make_action_ctx(), name, args_json))

dispatch_http_for_host! : Str, Str, Str => Str
dispatch_http_for_host! = |method, path, req_json|
    wrap_wire(App.dispatch_http!(concave_app(), make_action_ctx(), method, path, req_json))
