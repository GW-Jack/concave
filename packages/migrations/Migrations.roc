import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table

## Reusable pure-Roc Resumable Batched Migrations Component for Concave.
##
## Features:
## - Isolated component namespace (default `"migrations"`) storing run metadata in `migration_runs`
## - Resumable, OCC-safe batched execution driven by Concave's transactional scheduler (`_runBatch`)
## - General custom batch step API (`Migrations.register`) plus ergonomic `Migrations.table_migration`
## - Admin role gating (`require_auth_for_admin: True`, `admin_roles: ["admin"]` by default)
## - Idempotency guard (refuses re-running `"running"` or `"completed"` unless `force: True`)
## - Clean cancellation (`cancel`) and side-effect-free `dry_run` mode
## - Live-subscribable progress queries (`status`, `get`)

Migrations := [Migrations].{
    # -------------------------------------------------------------------------
    # Document & Wire Types
    # -------------------------------------------------------------------------

    MigrationRunDoc : {
        id : Str,
        created_at : I64,
        name : Str,
        status : Str,
        cursor : Str,
        processed_count : I64,
        batch_size : I64,
        batches_run : I64,
        started_at_ms : I64,
        completed_at_ms : I64,
        last_error : Str,
    }

    BatchStepResult : {
        processed : I64,
        next_cursor : Str,
        is_done : Bool,
    }

    MigrationEntry : {
        name : Str,
        batch_fn! : Box((Ctx.MutationCtx, Str, U64 => Try(BatchStepResult, Str))),
    }

    Mount : {
        namespace : Str,
        require_auth_for_admin : Bool,
        admin_roles : List(Str),
        default_batch_size : I64,
        migrations : List(MigrationEntry),
        spec : Component.ComponentSpec,
    }

    EmptyArgs : {}

    GetArgs : {
        name : Str,
    }

    MigrationStatusResult : {
        found : Bool,
        registered : Bool,
        id : Str,
        name : Str,
        status : Str,
        cursor : Str,
        processed_count : I64,
        batch_size : I64,
        batches_run : I64,
        started_at_ms : I64,
        completed_at_ms : I64,
        last_error : Str,
    }

    StartArgs : {
        name : Str,
        batch_size : I64,
        dry_run : Bool,
        force : Bool,
    }

    StartResult : {
        run_id : Str,
        name : Str,
        status : Str,
        batch_size : I64,
        dry_run : Bool,
        job_id : Str,
    }

    CancelArgs : {
        name : Str,
    }

    RunBatchArgs : {
        name : Str,
        dry_run : Bool,
    }

    RunBatchResult : {
        status : Str,
        processed_count : I64,
        batches_run : I64,
        is_done : Bool,
    }

    # -------------------------------------------------------------------------
    # Isolated Component Table & Indexes
    # -------------------------------------------------------------------------

    migration_runs_schema : Schema
    migration_runs_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("cursor", Schema.str),
        Schema.field("processed_count", Schema.int),
        Schema.field("batch_size", Schema.int),
        Schema.field("batches_run", Schema.int),
        Schema.field("started_at_ms", Schema.int),
        Schema.field("completed_at_ms", Schema.int),
        Schema.field("last_error", Schema.str),
    ])

    migration_runs_table : Table(MigrationRunDoc)
    migration_runs_table =
        Table.define("migration_runs", migration_runs_schema)
        |> Table.with_index("by_name", ["name"])
        |> Table.with_index("by_status", ["status"])

    runs_by_name : Table.Index(MigrationRunDoc)
    runs_by_name = Table.index_ref(migration_runs_table, "by_name")

    runs_by_status : Table.Index(MigrationRunDoc)
    runs_by_status = Table.index_ref(migration_runs_table, "by_status")

    # -------------------------------------------------------------------------
    # Endpoint Wire Schemas
    # -------------------------------------------------------------------------

    get_args_schema : Schema
    get_args_schema = Schema.record([
        Schema.field("name", Schema.str),
    ])

    migration_status_result_schema : Schema
    migration_status_result_schema = Schema.record([
        Schema.field("found", Schema.bool),
        Schema.field("registered", Schema.bool),
        Schema.field("id", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("cursor", Schema.str),
        Schema.field("processed_count", Schema.int),
        Schema.field("batch_size", Schema.int),
        Schema.field("batches_run", Schema.int),
        Schema.field("started_at_ms", Schema.int),
        Schema.field("completed_at_ms", Schema.int),
        Schema.field("last_error", Schema.str),
    ])

    start_args_schema : Schema
    start_args_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("batch_size", Schema.int),
        Schema.field("dry_run", Schema.bool),
        Schema.field("force", Schema.bool),
    ])

    start_result_schema : Schema
    start_result_schema = Schema.record([
        Schema.field("run_id", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("batch_size", Schema.int),
        Schema.field("dry_run", Schema.bool),
        Schema.field("job_id", Schema.str),
    ])

    cancel_args_schema : Schema
    cancel_args_schema = Schema.record([
        Schema.field("name", Schema.str),
    ])

    run_batch_args_schema : Schema
    run_batch_args_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("dry_run", Schema.bool),
    ])

    run_batch_result_schema : Schema
    run_batch_result_schema = Schema.record([
        Schema.field("status", Schema.str),
        Schema.field("processed_count", Schema.int),
        Schema.field("batches_run", Schema.int),
        Schema.field("is_done", Schema.bool),
    ])

    # -------------------------------------------------------------------------
    # Pure Validation, Clamping & State-Transition Helpers
    # -------------------------------------------------------------------------

    max_batch_size : I64
    max_batch_size = 500

    clamp_batch_size : I64, I64 -> I64
    clamp_batch_size = |requested, default_size| {
        eff_default =
            if default_size <= 0 {
                100
            } else if default_size > max_batch_size {
                max_batch_size
            } else {
                default_size
            }
        if requested <= 0 {
            eff_default
        } else if requested > max_batch_size {
            max_batch_size
        } else {
            requested
        }
    }

    i64_to_u64_clamped : I64 -> U64
    i64_to_u64_clamped = |n| {
        clamped =
            if n < 1 {
                1
            } else if n > max_batch_size {
                max_batch_size
            } else {
                n
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

    validate_name : Str -> Try(Str, Str)
    validate_name = |raw| {
        trimmed = Str.trim(raw)
        if Str.is_empty(trimmed) {
            Err("migration name cannot be empty")
        } else if Str.count_utf8_bytes(trimmed) > 128 {
            Err("migration name exceeds maximum length of 128 bytes")
        } else {
            Ok(trimmed)
        }
    }

    ## Validate whether a migration in `current_status` may transition to `"running"`.
    ## Refuses `"running"` unconditionally (cancel first), and refuses `"completed"` unless `force` is `True`.
    validate_start_transition : Str, Bool -> Try({}, Str)
    validate_start_transition = |current_status, force|
        match current_status {
            "running" => Err("migration is already running; cancel it before restarting")
            "completed" =>
                if force {
                    Ok({})
                } else {
                    Err("migration already completed; pass force: true to re-run")
                }
            "idle" => Ok({})
            "failed" => Ok({})
            "canceled" => Ok({})
            other => Err("invalid migration status `${other}`")
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

    ## Build a read-only no-op-write `MutationCtx` for `dry_run: True` executions.
    ## Reads hit live data while writes/scheduler/storage mutations become safe no-ops.
    make_dry_run_ctx : Ctx.MutationCtx -> Ctx.MutationCtx
    make_dry_run_ctx = |ctx| {
        db: {
            namespace: ctx.db.namespace,
            get_raw!: ctx.db.get_raw!,
            query_raw!: ctx.db.query_raw!,
            paginate_raw!: ctx.db.paginate_raw!,
            search_raw!: ctx.db.search_raw!,
            insert_raw!: |_, _, _| Ok("dry_run_id"),
            patch_raw!: |_, _, _, _| Ok({}),
            replace_raw!: |_, _, _, _| Ok({}),
            delete_raw!: |_, _, _| Ok({}),
        },
        scheduler: {
            run_after!: |_, _, _| Ok("dry_run_job"),
            run_at!: |_, _, _| Ok("dry_run_job"),
            cancel!: |_| Ok({}),
        },
        storage: {
            generate_upload_url!: || Ok(""),
            get_url!: ctx.storage.get_url!,
            delete!: |_| Ok({}),
        },
        auth!: ctx.auth!,
        now_ms!: ctx.now_ms!,
    }

    # -------------------------------------------------------------------------
    # Component Mount & Builder API
    # -------------------------------------------------------------------------

    ## Mount an isolated instance of the Migrations component under `namespace` (defaults to `"migrations"`).
    mount : Str -> Mount
    mount = |raw_namespace| {
        trimmed = Str.trim(raw_namespace)
        ns = if Str.is_empty(trimmed) { "migrations" } else { trimmed }
        {
            namespace: ns,
            require_auth_for_admin: True,
            admin_roles: ["admin"],
            default_batch_size: 100,
            migrations: [],
            spec: Component.define(
                ns,
                "concave-migrations",
                [Table.spec(migration_runs_table)],
            ),
        }
    }

    ## Override the list of roles permitted to invoke admin migration endpoints.
    with_admin_roles : Mount, List(Str) -> Mount
    with_admin_roles = |m, roles| {
        namespace: m.namespace,
        require_auth_for_admin: m.require_auth_for_admin,
        admin_roles: roles,
        default_batch_size: m.default_batch_size,
        migrations: m.migrations,
        spec: m.spec,
    }

    ## Toggle admin authentication requirement (defaults to `True`).
    with_require_auth : Mount, Bool -> Mount
    with_require_auth = |m, req_auth| {
        namespace: m.namespace,
        require_auth_for_admin: req_auth,
        admin_roles: m.admin_roles,
        default_batch_size: m.default_batch_size,
        migrations: m.migrations,
        spec: m.spec,
    }

    ## Configure the default batch size when `start` is called with `batch_size <= 0` (clamped to `[1, 500]`).
    with_default_batch_size : Mount, I64 -> Mount
    with_default_batch_size = |m, batch_size| {
        namespace: m.namespace,
        require_auth_for_admin: m.require_auth_for_admin,
        admin_roles: m.admin_roles,
        default_batch_size: clamp_batch_size(batch_size, 100),
        migrations: m.migrations,
        spec: m.spec,
    }

    ## Register a named resumable batched migration with a custom batch step function.
    ## `batch_fn!` receives the root app's `Ctx.MutationCtx`, the current opaque cursor (`""` on first batch),
    ## and the clamped `batch_size`, and returns `BatchStepResult`.
    register :
        Mount,
        Str,
        (Ctx.MutationCtx, Str, U64 => Try(BatchStepResult, Str))
        -> Mount
    register = |m, name, batch_fn!| {
        entry : MigrationEntry
        entry = {
            name: Str.trim(name),
            batch_fn!: Box.box(batch_fn!),
        }
        var $next = []
        var $replaced = False
        for existing in m.migrations {
            if existing.name == entry.name {
                $next = List.append($next, entry)
                $replaced = True
            } else {
                $next = List.append($next, existing)
            }
        }
        if !$replaced {
            $next = List.append($next, entry)
        }
        {
            namespace: m.namespace,
            require_auth_for_admin: m.require_auth_for_admin,
            admin_roles: m.admin_roles,
            default_batch_size: m.default_batch_size,
            migrations: $next,
            spec: m.spec,
        }
    }

    ## Ergonomic helper that paginates `table` in ascending `_creationTime` order and applies
    ## `transform_doc!(ctx, doc)` to each document in the batch inside a single ACID OCC transaction.
    table_migration :
        Table(doc),
        (Ctx.MutationCtx, doc => Try({}, Str))
        -> (Ctx.MutationCtx, Str, U64 => Try(BatchStepResult, Str))
        where [doc.Json.Parseable([InvalidJson(Str)])]
    table_migration = |table, transform_doc!| {
        step! : Ctx.MutationCtx, Str, U64 => Try(BatchStepResult, Str)
        step! = |ctx, cursor, batch_size| {
            page_res =
                Db.query(table)
                |> Db.asc()
                |> Db.paginate!(Ctx.as_reader(ctx.db), cursor, batch_size)?
            var $count = 0.I64
            for doc in page_res.page {
                transform_doc!(ctx, doc)?
                $count = $count + 1
            }
            Ok({
                processed: $count,
                next_cursor: page_res.next_cursor,
                is_done: page_res.is_done,
            })
        }
        step!
    }

    # -------------------------------------------------------------------------
    # Endpoint Implementations
    # -------------------------------------------------------------------------

    status_inner! : Bool, List(Str), I64, List(Str), Ctx.QueryCtx, EmptyArgs => Try(List(MigrationRunDoc), Str)
    status_inner! = |req_auth, admin_roles, default_batch_size, registered_names, ctx, _| {
        require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        docs =
            Db.query(migration_runs_table)
            |> Db.asc()
            |> Db.collect!(ctx.db)?

        var $out = []
        for reg_name in registered_names {
            var $matched = False
            for doc in docs {
                if doc.name == reg_name {
                    $out = List.append($out, doc)
                    $matched = True
                }
            }
            if !$matched {
                $out = List.append($out, {
                    id: "",
                    created_at: 0,
                    name: reg_name,
                    status: "idle",
                    cursor: "",
                    processed_count: 0,
                    batch_size: default_batch_size,
                    batches_run: 0,
                    started_at_ms: 0,
                    completed_at_ms: 0,
                    last_error: "",
                })
            }
        }
        for doc in docs {
            if !List.any(registered_names, |n| n == doc.name) {
                $out = List.append($out, doc)
            }
        }
        Ok($out)
    }

    get_inner! : Bool, List(Str), I64, List(Str), Ctx.QueryCtx, GetArgs => Try(MigrationStatusResult, Str)
    get_inner! = |req_auth, admin_roles, default_batch_size, registered_names, ctx, args| {
        require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        name = validate_name(args.name)?
        is_registered = List.any(registered_names, |n| n == name)

        existing =
            Db.from_index(runs_by_name)
            |> Db.eq([Key.str(name)])
            |> Db.first!(ctx.db)?

        match existing {
            Found(doc) =>
                Ok({
                    found: True,
                    registered: is_registered,
                    id: doc.id,
                    name: doc.name,
                    status: doc.status,
                    cursor: doc.cursor,
                    processed_count: doc.processed_count,
                    batch_size: doc.batch_size,
                    batches_run: doc.batches_run,
                    started_at_ms: doc.started_at_ms,
                    completed_at_ms: doc.completed_at_ms,
                    last_error: doc.last_error,
                })
            NotFound =>
                Ok({
                    found: is_registered,
                    registered: is_registered,
                    id: "",
                    name,
                    status: "idle",
                    cursor: "",
                    processed_count: 0,
                    batch_size: default_batch_size,
                    batches_run: 0,
                    started_at_ms: 0,
                    completed_at_ms: 0,
                    last_error: "",
                })
        }
    }

    start_inner! : Str, Bool, List(Str), I64, List(Str), Ctx.MutationCtx, StartArgs => Try(StartResult, Str)
    start_inner! = |ns, req_auth, admin_roles, default_batch_size, registered_names, ctx, args| {
        require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        name = validate_name(args.name)?
        if !List.any(registered_names, |n| n == name) {
            return Err("unknown migration `${name}`")
        }

        eff_batch_size = clamp_batch_size(args.batch_size, default_batch_size)
        now = Ctx.now_ms!(ctx)

        existing =
            Db.from_index(runs_by_name)
            |> Db.eq([Key.str(name)])
            |> Db.first!(Ctx.as_reader(ctx.db))?

        run_id =
            match existing {
                Found(doc) => {
                    validate_start_transition(doc.status, args.force)?
                    Db.patch!(ctx.db, migration_runs_table, doc.id, {
                        status: "running",
                        cursor: "",
                        processed_count: 0,
                        batch_size: eff_batch_size,
                        batches_run: 0,
                        started_at_ms: now,
                        completed_at_ms: 0,
                        last_error: "",
                    })?
                    doc.id
                }
                NotFound =>
                    Db.insert!(ctx.db, migration_runs_table, {
                        name,
                        status: "running",
                        cursor: "",
                        processed_count: 0,
                        batch_size: eff_batch_size,
                        batches_run: 0,
                        started_at_ms: now,
                        completed_at_ms: 0,
                        last_error: "",
                    })?
            }

        job_id = Ctx.run_after!(ctx, 0, "${ns}._runBatch", {
            name,
            dry_run: args.dry_run,
        })?

        Ok({
            run_id,
            name,
            status: "running",
            batch_size: eff_batch_size,
            dry_run: args.dry_run,
            job_id,
        })
    }

    cancel_inner! : Bool, List(Str), List(Str), Ctx.MutationCtx, CancelArgs => Try(Bool, Str)
    cancel_inner! = |req_auth, admin_roles, registered_names, ctx, args| {
        require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        name = validate_name(args.name)?
        if !List.any(registered_names, |n| n == name) {
            return Err("unknown migration `${name}`")
        }

        existing =
            Db.from_index(runs_by_name)
            |> Db.eq([Key.str(name)])
            |> Db.first!(Ctx.as_reader(ctx.db))?

        match existing {
            Found(doc) =>
                if doc.status == "running" {
                    now = Ctx.now_ms!(ctx)
                    Db.patch!(ctx.db, migration_runs_table, doc.id, {
                        status: "canceled",
                        completed_at_ms: now,
                    })?
                    Ok(True)
                } else {
                    Ok(False)
                }
            NotFound => Ok(False)
        }
    }

    run_batch_inner! : Str, I64, List(MigrationEntry), Ctx.MutationCtx, RunBatchArgs => Try(RunBatchResult, Str)
    run_batch_inner! = |ns, default_batch_size, migrations, ctx, args| {
        scoped_ctx = Ctx.scope_mutation(ctx, ns)
        now = Ctx.now_ms!(ctx)

        existing =
            Db.from_index(runs_by_name)
            |> Db.eq([Key.str(args.name)])
            |> Db.first!(Ctx.as_reader(scoped_ctx.db))?

        run =
            match existing {
                Found(doc) => doc
                NotFound =>
                    return Ok({
                        status: "idle",
                        processed_count: 0,
                        batches_run: 0,
                        is_done: True,
                    })
            }

        if run.status != "running" {
            return Ok({
                status: run.status,
                processed_count: run.processed_count,
                batches_run: run.batches_run,
                is_done: True,
            })
        }

        for entry in migrations {
            if entry.name == args.name {
                eff_batch_size = clamp_batch_size(run.batch_size, default_batch_size)
                batch_u64 = i64_to_u64_clamped(eff_batch_size)
                eff_ctx = if args.dry_run { make_dry_run_ctx(ctx) } else { ctx }
                batch_fn! = Box.unbox(entry.batch_fn!)

                batch_res = match batch_fn!(eff_ctx, run.cursor, batch_u64) {
                    Ok(step) => {
                        next_processed = run.processed_count + step.processed
                        next_batches = run.batches_run + 1
                        if step.is_done {
                            Db.patch!(scoped_ctx.db, migration_runs_table, run.id, {
                                status: "completed",
                                cursor: "",
                                processed_count: next_processed,
                                batches_run: next_batches,
                                completed_at_ms: now,
                                last_error: "",
                            })?
                            Ok({
                                status: "completed",
                                processed_count: next_processed,
                                batches_run: next_batches,
                                is_done: True,
                            })
                        } else if Str.is_empty(step.next_cursor) or (!Str.is_empty(run.cursor) and step.next_cursor == run.cursor) {
                            Db.patch!(scoped_ctx.db, migration_runs_table, run.id, {
                                status: "failed",
                                processed_count: next_processed,
                                batches_run: next_batches,
                                completed_at_ms: now,
                                last_error: "migration `${args.name}` cursor did not advance",
                            })?
                            Ok({
                                status: "failed",
                                processed_count: next_processed,
                                batches_run: next_batches,
                                is_done: True,
                            })
                        } else {
                            Db.patch!(scoped_ctx.db, migration_runs_table, run.id, {
                                status: "running",
                                cursor: step.next_cursor,
                                processed_count: next_processed,
                                batches_run: next_batches,
                                last_error: "",
                            })?
                            _ = Ctx.run_after!(ctx, 0, "${ns}._runBatch", {
                                name: args.name,
                                dry_run: args.dry_run,
                            })?
                            Ok({
                                status: "running",
                                processed_count: next_processed,
                                batches_run: next_batches,
                                is_done: False,
                            })
                        }
                    }
                    Err(err_msg) => {
                        Db.patch!(scoped_ctx.db, migration_runs_table, run.id, {
                            status: "failed",
                            completed_at_ms: now,
                            last_error: err_msg,
                        })?
                        Ok({
                            status: "failed",
                            processed_count: run.processed_count,
                            batches_run: run.batches_run,
                            is_done: True,
                        })
                    }
                }
                return batch_res
            }
        }

        Db.patch!(scoped_ctx.db, migration_runs_table, run.id, {
            status: "failed",
            completed_at_ms: now,
            last_error: "migration `${args.name}` is not registered",
        })?
        Ok({
            status: "failed",
            processed_count: run.processed_count,
            batches_run: run.batches_run,
            is_done: True,
        })
    }

    # -------------------------------------------------------------------------
    # App Attachment
    # -------------------------------------------------------------------------

    ## Attach the mounted Migrations component's isolated `migration_runs` table,
    ## admin-gated public queries/mutations (`status`, `get`, `start`, `cancel`),
    ## and internal root-scoped batch runner (`_runBatch`) to an `App`.
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        req_auth = m.require_auth_for_admin
        admin_roles = m.admin_roles
        default_batch = m.default_batch_size
        migrations = m.migrations
        registered_names = List.map(migrations, |e| e.name)
        run_doc_schema = Table.doc_schema_scoped(migration_runs_table, ns)

        spec
        |> App.component(m.spec)
        |> App.component_query(
            ns,
            "${ns}.status",
            Schema.record([]),
            Schema.list(run_doc_schema),
            |ctx, args| status_inner!(req_auth, admin_roles, default_batch, registered_names, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.get",
            get_args_schema,
            migration_status_result_schema,
            |ctx, args| get_inner!(req_auth, admin_roles, default_batch, registered_names, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.start",
            start_args_schema,
            start_result_schema,
            |ctx, args| start_inner!(ns, req_auth, admin_roles, default_batch, registered_names, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.cancel",
            cancel_args_schema,
            Schema.bool,
            |ctx, args| cancel_inner!(req_auth, admin_roles, registered_names, ctx, args),
        )
        |> App.internal_mutation(
            "${ns}._runBatch",
            run_batch_args_schema,
            run_batch_result_schema,
            |ctx, args| run_batch_inner!(ns, default_batch, migrations, ctx, args),
        )
    }
}

# -------------------------------------------------------------------------
# Pure-Roc Unit Tests
# -------------------------------------------------------------------------

expect {
    # Batch size clamping: fallback to default, upper clamp to 500, exact preservation in range
    Migrations.clamp_batch_size(0, 100) == 100
    and Migrations.clamp_batch_size(-5, 25) == 25
    and Migrations.clamp_batch_size(0, 0) == 100
    and Migrations.clamp_batch_size(1000, 100) == 500
    and Migrations.clamp_batch_size(3, 100) == 3
    and Migrations.i64_to_u64_clamped(3) == 3
    and Migrations.i64_to_u64_clamped(500) == 500
    and Migrations.i64_to_u64_clamped(0) == 1
    and Migrations.i64_to_u64_clamped(999) == 500
}

expect {
    # State transition validation: running always blocked, completed requires force, others allowed
    ok_check = |res|
        match res {
            Ok(_) => True
            Err(_) => False
        }
    err_check = |res|
        match res {
            Ok(_) => False
            Err(_) => True
        }

    err_check(Migrations.validate_start_transition("running", False))
    and err_check(Migrations.validate_start_transition("running", True))
    and err_check(Migrations.validate_start_transition("completed", False))
    and ok_check(Migrations.validate_start_transition("completed", True))
    and ok_check(Migrations.validate_start_transition("idle", False))
    and ok_check(Migrations.validate_start_transition("failed", False))
    and ok_check(Migrations.validate_start_transition("canceled", False))
    and err_check(Migrations.validate_start_transition("bogus", False))
}

expect {
    # Mount defaults, custom admin roles, migration registration & component manifest shape
    noop_step! : Ctx.MutationCtx, Str, U64 => Try(Migrations.BatchStepResult, Str)
    noop_step! = |_, _, _| Ok({ processed: 0, next_cursor: "", is_done: True })

    m =
        Migrations.mount("")
        |> Migrations.with_admin_roles(["admin", "ops"])
        |> Migrations.with_default_batch_size(50)
        |> Migrations.register("backfill_demo", noop_step!)

    spec = App.new("migrations-unit-test") |> Migrations.attach(m)
    has_internal_runner = List.any(
        spec.mutations,
        |entry|
            entry.meta.name == "migrations._runBatch"
            and entry.meta.namespace == ""
            and match entry.meta.visibility {
                Internal => True
                Public => False
            },
    )

    m.namespace == "migrations"
    and m.require_auth_for_admin
    and m.default_batch_size == 50
    and List.len(m.admin_roles) == 2
    and List.len(m.migrations) == 1
    and m.spec.pkg_name == "concave-migrations"
    and List.len(m.spec.tables) == 1
    and List.len(spec.components) == 1
    and List.len(spec.queries) == 2
    and List.len(spec.mutations) == 3
    and has_internal_runner
}
