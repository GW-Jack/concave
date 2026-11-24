# Concave Roc API Guide (`0.1.0_RC1`)

Concave splits cleanly into two Roc layers:

1. **`packages/concave-sdk`** — Pure Roc package defining `Schema`, `Key`, `Table`, `Ctx`, `Db`, `Component`, and `App`. Reusable Components depend *only* on `concave-sdk` so they remain pure and unit-testable with `roc test`.
2. **`platform/main.roc`** — Native Roc platform linking `libhost.a` (zero-dependency Zig runtime) and providing `--serve` and `--introspect` entrypoints.

---

## 1. Schemas, Tables & Typed Indexes

System fields `id : Str` and `created_at : I64` are automatically managed by the host and merged into every returned document.

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

### `Schema` Constructors
- Primitives: `Schema.null`, `Schema.bool`, `Schema.int`, `Schema.float`, `Schema.str`, `Schema.any`
- Document IDs: `Schema.id("table")`, `Schema.scoped_id("namespace", "table")`
- Containers: `Schema.list(item)`, `Schema.optional(inner)`
- Records: `Schema.record([Schema.field("a", Schema.str), Schema.opt_field("b", Schema.int)])`
- Unions: `Schema.union([Schema.variant("Ok"), Schema.variant_with("Err", Schema.str)])`
- Document helper: `Table.doc_schema(tbl)` / `Table.doc_schema_scoped(tbl, ns)` (prepends `id` and `created_at`)

---

## 2. Static Effect Isolation (`Ctx`)

Roc's type & effect system statically enforces what each function kind can do:

| Context | Capabilities | Guarantees |
| --- | --- | --- |
| **`Ctx.QueryCtx`** | `db : DbReader`, `storage : StorageReader`, `auth!`, `now_ms!` | Read-only, deterministic snapshot, automatically reactive over WebSockets. |
| **`Ctx.MutationCtx`** | `db : DbWriter`, `scheduler : Scheduler`, `storage : StorageWriter`, `auth!`, `now_ms!` | ACID transaction with serializable OCC retries, read-your-own-writes, and atomic scheduled jobs. |
| **`Ctx.ActionCtx`** | `http_fetch!`, `run_query!`, `run_mutation!`, `storage : StorageWriter`, `auth!`, `now_ms!` | Non-deterministic external HTTP/HTTPS I/O; invokes transactional queries & mutations re-entrantly. |

### Helpers on `Ctx`
- `Ctx.require_auth!(ctx.auth!)` — returns `Try(Ctx.AuthIdentity, Str)` (`{ subject, issuer, name }`).
- `Ctx.as_reader(ctx.db)` — derives a `DbReader` from a `DbWriter`.
- `Ctx.as_query_ctx(ctx)` — derives a `QueryCtx` from a `MutationCtx` so read helpers work in both.
- `Ctx.scope_query(ctx, ns)` / `Ctx.scope_mutation(ctx, ns)` — scopes DB access to a component's isolated namespace while staying in the same ACID transaction.

---

## 3. Database Operations (`Db` & `Key`)

### Point Reads & Writes
```roc
# Read (works directly on `ctx.db` in both QueryCtx and MutationCtx!)
maybe_doc = Db.get!(ctx.db, rooms_table, room_id)? # Found(RoomDoc) | NotFound

# Writes (MutationCtx only)
id = Db.insert!(ctx.db, rooms_table, { name: "general", topic: "Welcome" })?
_ = Db.patch!(ctx.db, rooms_table, id, { topic: "Updated topic" })?       # Err("NotFound") if missing
_ = Db.replace!(ctx.db, rooms_table, id, { name: "general", topic: "Replaced" })?
_ = Db.delete!(ctx.db, rooms_table, id)?                                  # idempotent Ok({})
```

### Indexed Range Queries
Every range scan records its exact `(namespace, table, index_name, start, end)` bounds in the transaction's `ReadSet`:

```roc
docs =
    Db.from_index(rooms_by_name)
    |> Db.gte([Key.str("a")])
    |> Db.lt([Key.str("m")])
    |> Db.asc
    |> Db.take(25)
    |> Db.collect!(ctx.db)?
```

Available query builder combinators:
- Source: `Db.query(table)` (scans `by_creation_time`) or `Db.from_index(index_ref)`
- Bounds: `Db.eq(prefix)`, `Db.gte(lower)`, `Db.gt(lower)`, `Db.lte(upper)`, `Db.lt(upper)`
- Key values: `Key.null`, `Key.bool(b)`, `Key.int(i)`, `Key.float(f)`, `Key.str(s)`, `Key.id(id)`
- Order & limit: `Db.asc`, `Db.desc`, `Db.take(n)`
- Execution: `Db.collect!(db)`, `Db.first!(db)`

### Reactive Cursor Pagination (`Db.paginate!`)
```roc
# Returns `Try(Db.Page(doc), Str)` where `Page(doc) : { page : List(doc), next_cursor : Str, is_done : Bool }`
page =
    Db.from_index(notes_by_seq)
    |> Db.asc
    |> Db.paginate!(ctx.db, args.cursor, 20)?
```
Pass `cursor: ""` for the first page, then pass `page.next_cursor` for subsequent pages until `page.is_done == Bool.True`.

### Reactive Full-Text Search (`Db.search!`)
```roc
# Case-insensitive multi-token search over a string field; respects RYOW and tracks ReadSet!
matches = Db.search!(ctx.db, notes_table, "body", args.q, 25)?
```

---

## 4. Transactional Scheduler & Crons

Inside any `MutationCtx`:
```roc
# Scheduled atomically with the mutation (dropped automatically if the mutation returns `Err`):
job_id = ctx.scheduler.run_after!(5000, "emails.send_welcome", "{\"user_id\":${Json.to_str(id)}}")?
job_id2 = ctx.scheduler.run_at!(target_epoch_ms, "billing.charge", "{}")?
_ = ctx.scheduler.cancel!(job_id)?
```

Register recurring Crons on `App`:
```roc
|> App.cron("nightly_cleanup", 86400000, "maintenance.prune", "{}")
```

Scheduled jobs and crons are stored in `_system._scheduled_jobs` and claimed atomically via OCC so multi-replica clusters execute each job at most once.

---

## 5. Blob / File Storage (`ctx.storage`)

- **Mutations & Actions** (`StorageWriter`):
  - `ctx.storage.generate_upload_url!()` -> returns an HMAC-signed local upload URL (`/_storage/upload/<token>`) or a zero-dep AWS SigV4 presigned `PUT` URL when `CONCAVE_S3_*` is configured.
  - `ctx.storage.get_url!(storage_id)` -> returns a download URL (`/_storage/<id>` or SigV4 presigned `GET` URL).
  - `ctx.storage.delete!(storage_id)` -> deletes the blob.
- **Queries** (`StorageReader`):
  - `ctx.storage.get_url!(storage_id)` -> read-only download URL lookup.

---

## 6. Custom HTTP Routes / Webhooks (`App.http_route`)

Route handlers receive `Ctx.ActionCtx` and `App.HttpRouteRequest` (`{ method, path, query, body, content_type }`), and return `Try(App.HttpRouteResponse, Str)` (`{ status, content_type, body }`):

```roc
stripe_webhook! : Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponse, Str)
stripe_webhook! = |ctx, req| {
    _ = ctx.run_mutation!("billing.handle_event", req.body)?
    Ok({ status: 200, content_type: "application/json", body: "{\"ok\":true}" })
}

# Exact or trailing `*` prefix paths; method `"*"` matches any HTTP method:
|> App.http_route("POST", "/webhooks/stripe", stripe_webhook!)
|> App.http_route("GET", "/public/v1/*", public_api!)
```

---

## 7. Capability-Injected Components

Components are pure Roc packages exposing `mount` and `attach` helpers:

```roc
chat_presence = Presence.mount("presence", 30000)
send_limiter = RateLimiter.mount("rate_limit", 12, 60000)
analytics = Analytics.mount("analytics")
monitor = Monitor.mount("monitor")

concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> App.table(rooms_table)
    |> Presence.attach(chat_presence)
    |> RateLimiter.attach(send_limiter)
    |> Analytics.attach(analytics)
    |> Monitor.attach_with_cron(monitor, 30000, 3600000)
    |> App.query("rooms.list", Schema.record([]), Schema.list(Table.doc_schema(rooms_table)), list_rooms!)
```

Multiple instances of the same component can be mounted under distinct namespaces with host-enforced table isolation inside the same ACID transaction.
