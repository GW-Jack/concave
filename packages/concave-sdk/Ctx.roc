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

    ## Read-only database capability (scoped to a single component namespace, "" for root app).
    DbReader : {
        namespace : Str,
        get_raw! : Str, Str, Str => Try(Str, Str),
        query_raw! : Str => Try(Str, Str),
    }

    ## Read + write transactional database capability (scoped to a single component namespace).
    DbWriter : {
        namespace : Str,
        get_raw! : Str, Str, Str => Try(Str, Str),
        query_raw! : Str => Try(Str, Str),
        insert_raw! : Str, Str, Str => Try(Str, Str),
        patch_raw! : Str, Str, Str, Str => Try({}, Str),
        replace_raw! : Str, Str, Str, Str => Try({}, Str),
        delete_raw! : Str, Str, Str => Try({}, Str),
    }

    ## Context passed to reactive read-only Queries.
    QueryCtx : {
        db : DbReader,
        auth! : () => Try(AuthIdentity, [Unauthenticated]),
        now_ms! : () => I64,
    }

    ## Context passed to ACID transactional Mutations.
    MutationCtx : {
        db : DbWriter,
        auth! : () => Try(AuthIdentity, [Unauthenticated]),
        now_ms! : () => I64,
    }

    ## Context passed to non-deterministic external Actions.
    ActionCtx : {
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
    }

    ## Derive a `QueryCtx` from a `MutationCtx` (enabling mutations to call read-only query helpers).
    as_query_ctx : MutationCtx -> QueryCtx
    as_query_ctx = |m| {
        db: as_reader(m.db),
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
        },
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
            insert_raw!: ctx.db.insert_raw!,
            patch_raw!: ctx.db.patch_raw!,
            replace_raw!: ctx.db.replace_raw!,
            delete_raw!: ctx.db.delete_raw!,
        },
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
}
