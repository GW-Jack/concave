# Concave Roc API Guide (`0.1.0_RC1`)

Concave splits cleanly into two Roc layers:

1. **`packages/concave-sdk`** — Pure Roc package defining `Schema`, `Key`, `Table`, `Ctx`, `Db`, `Component`, and `App`. Reusable Components depend *only* on `concave-sdk` so they remain pure and unit-testable with `roc test`.
2. **`platform/main.roc`** — Native Roc platform linking `libhost.a` (Rust runtime) and providing `--serve` and `--introspect` entrypoints.

## Defining Tables & Typed Indexes

```roc
import sdk.Schema
import sdk.Table

RoomDoc : {
    id : Str,
    created_at : I64,
    name : Str,
    topic : Str,
}

rooms_table : Table(RoomDoc)
rooms_table =
    Table.define(
        "rooms",
        Schema.record([
            Schema.field("name", Schema.str),
            Schema.field("topic", Schema.str),
        ]),
    )
    |> Table.with_index("by_name", ["name"])

rooms_by_name : Table.Index(RoomDoc)
rooms_by_name = Table.index_ref(rooms_table, "by_name")
```

System fields `id` and `created_at` are automatically managed by the host and merged into every returned document.

## Static Effect Isolation

- **Queries** receive `Ctx.QueryCtx` (`ctx.db : Ctx.DbReader`, `ctx.auth!`, `ctx.now_ms!`) — cannot perform writes or HTTP I/O.
- **Mutations** receive `Ctx.MutationCtx` (`ctx.db : Ctx.DbWriter`, `ctx.auth!`, `ctx.now_ms!`) — run inside an ACID transaction with automatic OCC conflict detection and read-your-own-writes semantics.
- **Actions** receive `Ctx.ActionCtx` (`ctx.http_fetch!`, `ctx.run_query!`, `ctx.run_mutation!`, `ctx.auth!`, `ctx.now_ms!`) — perform external HTTP I/O and invoke transactional queries/mutations.

## Capability-Injected Components

Components are pure Roc packages exposing a `mount` function and an `attach` helper:

```roc
chat_presence = Presence.mount("presence", 30000)
send_limiter = RateLimiter.mount("rate_limit", 12, 60000)
```

- When calling a component inside a parent mutation (e.g. `RateLimiter.enforce!(send_limiter, ctx, user.subject)`), `Ctx.scope_mutation(ctx, m.namespace)` scopes all DB operations to the component's isolated namespace while remaining inside the **exact same ACID transaction**.
- Multiple instances of the same component can be mounted under distinct namespaces.

## Wiring the Application & Running Codegen

```roc
concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> App.table(rooms_table)
    |> Presence.attach(chat_presence)
    |> RateLimiter.attach(send_limiter)
    |> App.query("rooms.list", Schema.record([]), Schema.list(Table.doc_schema(rooms_table)), list_rooms!)
```

Run codegen and dev server:

```sh
concave codegen --entry backend/main.roc --out frontend/src/_generated
concave dev --entry backend/main.roc --out frontend/src/_generated
```
