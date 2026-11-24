## Capability contexts enforcing static effect isolation across Queries, Mutations, and Actions,
## and namespace isolation for mounted Components.

Ctx := [Ctx].{
    AuthIdentity : {
        subject : Str,
        issuer : Str,
        name : Str,
    }

    HttpRequest : {
        method : Str,
        url : Str,
        body : Str,
    }

    HttpResponse : {
        status : U64,
        body : Str,
    }

    ## Transactional job scheduler (committed atomically with the enclosing mutation).
    Scheduler : {
        run_after! : I64, Str, Str => Try(Str, Str),
        run_at! : I64, Str, Str => Try(Str, Str),
        cancel! : Str => Try({}, Str),
    }

    ## Read-only blob storage capability (available in Queries).
    StorageReader : {
        get_url! : Str => Try(Str, Str),
    }

    ## Full blob storage capability (available in Mutations and Actions).
    StorageWriter : {
        generate_upload_url! : () => Try(Str, Str),
        get_url! : Str => Try(Str, Str),
        delete! : Str => Try({}, Str),
    }

    ## Structural read-capable DB constraint satisfied by both `DbReader` and `DbWriter`.
    DbReadable(r) : {
        namespace : Str,
        get_raw! : Str, Str, Str => Try(Str, Str),
        query_raw! : Str => Try(Str, Str),
        paginate_raw! : Str => Try(Str, Str),
        search_raw! : Str => Try(Str, Str),
        ..r
    }

    ## Read-only database capability (scoped to a single component namespace, "" for root app).
    DbReader : {
        namespace : Str,
        get_raw! : Str, Str, Str => Try(Str, Str),
        query_raw! : Str => Try(Str, Str),
        paginate_raw! : Str => Try(Str, Str),
        search_raw! : Str => Try(Str, Str),
    }

    ## Read + write transactional database capability (scoped to a single component namespace).
    DbWriter : {
        namespace : Str,
        get_raw! : Str, Str, Str => Try(Str, Str),
        query_raw! : Str => Try(Str, Str),
        paginate_raw! : Str => Try(Str, Str),
        search_raw! : Str => Try(Str, Str),
        insert_raw! : Str, Str, Str => Try(Str, Str),
        patch_raw! : Str, Str, Str, Str => Try({}, Str),
        replace_raw! : Str, Str, Str, Str => Try({}, Str),
        delete_raw! : Str, Str, Str => Try({}, Str),
    }

    ## Context passed to reactive read-only Queries.
    QueryCtx : {
        db : DbReader,
        storage : StorageReader,
        auth! : () => Try(AuthIdentity, [Unauthenticated]),
        now_ms! : () => I64,
    }

    ## Context passed to ACID transactional Mutations.
    MutationCtx : {
        db : DbWriter,
        scheduler : Scheduler,
        storage : StorageWriter,
        auth! : () => Try(AuthIdentity, [Unauthenticated]),
        now_ms! : () => I64,
    }

    ## Context passed to non-deterministic external Actions.
    ActionCtx : {
        storage : StorageWriter,
        auth! : () => Try(AuthIdentity, [Unauthenticated]),
        now_ms! : () => I64,
        http_fetch! : HttpRequest => Try(HttpResponse, Str),
        run_query! : Str, Str => Try(Str, Str),
        run_mutation! : Str, Str => Try(Str, Str),
    }

    ## Extract a read-only `DbReader` from a `DbWriter` (so read helpers work in both contexts).
    as_reader : DbWriter -> DbReader
    as_reader = |w| {
        namespace: w.namespace,
        get_raw!: w.get_raw!,
        query_raw!: w.query_raw!,
        paginate_raw!: w.paginate_raw!,
        search_raw!: w.search_raw!,
    }

    ## Derive a `QueryCtx` from a `MutationCtx` (enabling mutations to call read-only query helpers).
    as_query_ctx : MutationCtx -> QueryCtx
    as_query_ctx = |m| {
        db: as_reader(m.db),
        storage: { get_url!: m.storage.get_url! },
        auth!: m.auth!,
        now_ms!: m.now_ms!,
    }

    ## Scope a `QueryCtx` to a mounted component's isolated namespace.
    scope_query : QueryCtx, Str -> QueryCtx
    scope_query = |ctx, namespace| {
        db: {
            namespace,
            get_raw!: ctx.db.get_raw!,
            query_raw!: ctx.db.query_raw!,
            paginate_raw!: ctx.db.paginate_raw!,
            search_raw!: ctx.db.search_raw!,
        },
        storage: ctx.storage,
        auth!: ctx.auth!,
        now_ms!: ctx.now_ms!,
    }

    ## Scope a `MutationCtx` to a mounted component's isolated namespace (same ACID transaction!).
    scope_mutation : MutationCtx, Str -> MutationCtx
    scope_mutation = |ctx, namespace| {
        db: {
            namespace,
            get_raw!: ctx.db.get_raw!,
            query_raw!: ctx.db.query_raw!,
            paginate_raw!: ctx.db.paginate_raw!,
            search_raw!: ctx.db.search_raw!,
            insert_raw!: ctx.db.insert_raw!,
            patch_raw!: ctx.db.patch_raw!,
            replace_raw!: ctx.db.replace_raw!,
            delete_raw!: ctx.db.delete_raw!,
        },
        scheduler: ctx.scheduler,
        storage: ctx.storage,
        auth!: ctx.auth!,
        now_ms!: ctx.now_ms!,
    }

    ## Require an authenticated caller or return an error string.
    require_auth! : (() => Try(AuthIdentity, [Unauthenticated])) => Try(AuthIdentity, Str)
    require_auth! = |auth!|
        match auth!() {
            Ok(id) => Ok(id)
            Err(Unauthenticated) => Err("Unauthenticated")
        }

    ## Read current Unix epoch milliseconds from any context (`QueryCtx`, `MutationCtx`, or `ActionCtx`).
    now_ms! : { now_ms! : () => I64, ..r } => I64
    now_ms! = |ctx| {
        f! = ctx.now_ms!
        f!()
    }

    ## Schedule a mutation or action after `delay_ms` with a typed `Json.Encodable` args value
    ## (committed atomically with the enclosing mutation).
    run_after! : { scheduler : Scheduler, ..r }, I64, Str, args => Try(Str, Str)
        where [args.Json.Encodable(enc_err)]
    run_after! = |ctx, delay_ms, fn_name, args| {
        encoded = match Json.to_str_try(args) {
            Ok(s) => s
            Err(_) => return Err("failed to encode scheduled job args for `${fn_name}`")
        }
        f! = ctx.scheduler.run_after!
        f!(delay_ms, fn_name, encoded)
    }

    ## Schedule a mutation or action after `delay_ms` with a pre-encoded JSON args string.
    run_after_raw! : { scheduler : Scheduler, ..r }, I64, Str, Str => Try(Str, Str)
    run_after_raw! = |ctx, delay_ms, fn_name, args_json| {
        f! = ctx.scheduler.run_after!
        f!(delay_ms, fn_name, args_json)
    }

    ## Schedule a mutation or action at `run_at_ms` (Unix epoch ms) with a typed `Json.Encodable` args value.
    run_at! : { scheduler : Scheduler, ..r }, I64, Str, args => Try(Str, Str)
        where [args.Json.Encodable(enc_err)]
    run_at! = |ctx, run_at_ms, fn_name, args| {
        encoded = match Json.to_str_try(args) {
            Ok(s) => s
            Err(_) => return Err("failed to encode scheduled job args for `${fn_name}`")
        }
        f! = ctx.scheduler.run_at!
        f!(run_at_ms, fn_name, encoded)
    }

    ## Schedule a mutation or action at `run_at_ms` with a pre-encoded JSON args string.
    run_at_raw! : { scheduler : Scheduler, ..r }, I64, Str, Str => Try(Str, Str)
    run_at_raw! = |ctx, run_at_ms, fn_name, args_json| {
        f! = ctx.scheduler.run_at!
        f!(run_at_ms, fn_name, args_json)
    }

    ## Cancel a pending scheduled job by ID inside a mutation.
    cancel_job! : { scheduler : Scheduler, ..r }, Str => Try({}, Str)
    cancel_job! = |ctx, job_id| {
        f! = ctx.scheduler.cancel!
        f!(job_id)
    }

    ## Generate a signed blob upload URL inside a `MutationCtx` or `ActionCtx`.
    generate_upload_url! : { storage : StorageWriter, ..r } => Try(Str, Str)
    generate_upload_url! = |ctx| {
        f! = ctx.storage.generate_upload_url!
        f!()
    }

    ## Resolve a blob download URL inside any context (`QueryCtx`, `MutationCtx`, or `ActionCtx`).
    get_storage_url! : { storage : { get_url! : Str => Try(Str, Str), ..s }, ..r }, Str => Try(Str, Str)
    get_storage_url! = |ctx, storage_id| {
        f! = ctx.storage.get_url!
        f!(storage_id)
    }

    ## Delete a stored blob by ID inside a `MutationCtx` or `ActionCtx`.
    delete_storage! : { storage : StorageWriter, ..r }, Str => Try({}, Str)
    delete_storage! = |ctx, storage_id| {
        f! = ctx.storage.delete!
        f!(storage_id)
    }

    ## Perform an outbound HTTP/HTTPS request inside an `ActionCtx`.
    http_fetch! : ActionCtx, HttpRequest => Try(HttpResponse, Str)
    http_fetch! = |ctx, req| {
        f! = ctx.http_fetch!
        f!(req)
    }

    ## Invoke a registered query re-entrantly from an `ActionCtx` with typed `Json.Encodable` args.
    ## Returns the JSON-encoded query result string.
    run_query! : ActionCtx, Str, args => Try(Str, Str)
        where [args.Json.Encodable(enc_err)]
    run_query! = |ctx, name, args| {
        encoded = match Json.to_str_try(args) {
            Ok(s) => s
            Err(_) => return Err("failed to encode query args for `${name}`")
        }
        f! = ctx.run_query!
        f!(name, encoded)
    }

    ## Invoke a registered query re-entrantly from an `ActionCtx` with a pre-encoded JSON args string.
    run_query_raw! : ActionCtx, Str, Str => Try(Str, Str)
    run_query_raw! = |ctx, name, args_json| {
        f! = ctx.run_query!
        f!(name, args_json)
    }

    ## Invoke a registered mutation re-entrantly from an `ActionCtx` with typed `Json.Encodable` args.
    ## Returns the JSON-encoded mutation result string.
    run_mutation! : ActionCtx, Str, args => Try(Str, Str)
        where [args.Json.Encodable(enc_err)]
    run_mutation! = |ctx, name, args| {
        encoded = match Json.to_str_try(args) {
            Ok(s) => s
            Err(_) => return Err("failed to encode mutation args for `${name}`")
        }
        f! = ctx.run_mutation!
        f!(name, encoded)
    }

    ## Invoke a registered mutation re-entrantly from an `ActionCtx` with a pre-encoded JSON args string.
    run_mutation_raw! : ActionCtx, Str, Str => Try(Str, Str)
    run_mutation_raw! = |ctx, name, args_json| {
        f! = ctx.run_mutation!
        f!(name, args_json)
    }
}
