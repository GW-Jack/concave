import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table

## Reusable pure-Roc Rate Limiter Component.
## Enforces fixed-window per-key rate limits inside the caller's exact ACID transaction,
## while keeping its `buckets` table strictly isolated inside its mounted component namespace.

RateLimiter := [RateLimiter].{
    BucketDoc : {
        id : Str,
        created_at : I64,
        key : Str,
        count : I64,
        window_start_ms : I64,
    }

    LimitResult : {
        allowed : Bool,
        remaining : I64,
        reset_at_ms : I64,
    }

    StatusArgs : {
        key : Str,
    }

    Mount : {
        namespace : Str,
        max_requests : I64,
        window_ms : I64,
        spec : Component.ComponentSpec,
    }

    buckets_schema : Schema
    buckets_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("count", Schema.int),
        Schema.field("window_start_ms", Schema.int),
    ])

    buckets_table : Table(BucketDoc)
    buckets_table =
        Table.define("buckets", buckets_schema)
        |> Table.with_index("by_key", ["key"])

    by_key : Table.Index(BucketDoc)
    by_key = Table.index_ref(buckets_table, "by_key")

    limit_result_schema : Schema
    limit_result_schema = Schema.record([
        Schema.field("allowed", Schema.bool),
        Schema.field("remaining", Schema.int),
        Schema.field("reset_at_ms", Schema.int),
    ])

    status_args_schema : Schema
    status_args_schema = Schema.record([
        Schema.field("key", Schema.str),
    ])

    ## Mount an isolated RateLimiter component with `max_requests` (>= 1) per `window_ms` (>= 1).
    mount : Str, I64, I64 -> Mount
    mount = |namespace, max_requests, window_ms| {
        namespace,
        max_requests: if max_requests < 1 { 1 } else { max_requests },
        window_ms: if window_ms < 1 { 1 } else { window_ms },
        spec: Component.define(
            namespace,
            "concave-rate-limiter",
            [Table.spec(buckets_table)],
        ),
    }

    ## Transactionally check and consume 1 token for `key` inside the caller's ACID mutation.
    ## Scopes DB operations to `m.namespace` automatically so buckets cannot collide with app tables.
    check_and_consume! : Mount, Ctx.MutationCtx, Str => Try(LimitResult, Str)
    check_and_consume! = |m, parent_ctx, key| {
        ctx = Ctx.scope_mutation(parent_ctx, m.namespace)
        now_ms! = ctx.now_ms!
        now = now_ms!()

        existing =
            Db.from_index(by_key)
            |> Db.eq([Key.str(key)])
            |> Db.first!(Ctx.as_reader(ctx.db))?

        match existing {
            NotFound => {
                _ = Db.insert!(ctx.db, buckets_table, {
                    key,
                    count: 1.I64,
                    window_start_ms: now,
                })?
                Ok({
                    allowed: True,
                    remaining: m.max_requests - 1,
                    reset_at_ms: now + m.window_ms,
                })
            }
            Found(bucket) => {
                if now - bucket.window_start_ms >= m.window_ms {
                    Db.patch!(ctx.db, buckets_table, bucket.id, {
                        count: 1.I64,
                        window_start_ms: now,
                    })?
                    Ok({
                        allowed: True,
                        remaining: m.max_requests - 1,
                        reset_at_ms: now + m.window_ms,
                    })
                } else if bucket.count >= m.max_requests {
                    Ok({
                        allowed: False,
                        remaining: 0,
                        reset_at_ms: bucket.window_start_ms + m.window_ms,
                    })
                } else {
                    next_count = bucket.count + 1
                    Db.patch!(ctx.db, buckets_table, bucket.id, {
                        count: next_count,
                    })?
                    Ok({
                        allowed: True,
                        remaining: m.max_requests - next_count,
                        reset_at_ms: bucket.window_start_ms + m.window_ms,
                    })
                }
            }
        }
    }

    ## Convenience helper that returns `Err("Rate limit exceeded...")` when quota is exhausted.
    ## Note: because Concave mutations are ACID transactions, returning `Err(...)` rolls back
    ## the enclosing mutation (including counter increments). For failed-attempt throttling
    ## (e.g. login brute-force protection), call `check_and_consume!` and return an `Ok(...)`
    ## error value so the consumed token commits.
    enforce! : Mount, Ctx.MutationCtx, Str => Try(LimitResult, Str)
    enforce! = |m, ctx, key| {
        res = check_and_consume!(m, ctx, key)?
        if res.allowed {
            Ok(res)
        } else {
            Err("Rate limit exceeded — please wait a moment before sending again")
        }
    }

    ## Inspect the remaining quota for the caller's own key (or any key for `"admin"` role)
    ## without consuming a token.
    status! : Mount, Ctx.QueryCtx, StatusArgs => Try(LimitResult, Str)
    status! = |m, ctx, args| {
        user = Ctx.require_auth!(ctx.auth!)?
        target_key =
            if Ctx.has_role(user, "admin") and !Str.is_empty(Str.trim(args.key)) {
                Str.trim(args.key)
            } else if Str.is_empty(Str.trim(args.key)) or Str.trim(args.key) == user.subject {
                user.subject
            } else {
                return Err("Forbidden: cannot inspect another user's rate-limit quota")
            }

        now_ms! = ctx.now_ms!
        now = now_ms!()
        existing =
            Db.from_index(by_key)
            |> Db.eq([Key.str(target_key)])
            |> Db.first!(ctx.db)?

        match existing {
            NotFound =>
                Ok({
                    allowed: True,
                    remaining: m.max_requests,
                    reset_at_ms: now + m.window_ms,
                })
            Found(bucket) =>
                if now - bucket.window_start_ms >= m.window_ms {
                    Ok({
                        allowed: True,
                        remaining: m.max_requests,
                        reset_at_ms: now + m.window_ms,
                    })
                } else {
                    rem = if bucket.count >= m.max_requests { 0 } else { m.max_requests - bucket.count }
                    Ok({
                        allowed: rem > 0,
                        remaining: rem,
                        reset_at_ms: bucket.window_start_ms + m.window_ms,
                    })
                }
        }
    }

    ## Attach the mounted RateLimiter's isolated table and read-only status query to an `App`.
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        spec
        |> App.component(m.spec)
        |> App.component_query(
            ns,
            "${ns}.status",
            status_args_schema,
            limit_result_schema,
            |ctx, args| status!(m, ctx, args),
        )
    }
}

expect {
    m = RateLimiter.mount("rate_limit", 20, 60000)
    m.namespace == "rate_limit" and m.max_requests == 20
}
