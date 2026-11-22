# Getting Started with Concave

This guide walks you from zero to a running, live-reactive Concave app with zero external dependencies.

## 1. Prerequisites

Install:
- [Roc `0.1.0_RC1`](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1)
- [Zig `0.17.1`](https://ziglang.org/download/)

Clone the repository and build the native Zig host (`libhost.a`) and `concave` CLI:

```sh
git clone https://github.com/GW-Jack/concave.git
cd concave
make host
```

## 2. Scaffold a New Application

```sh
./zig-out/bin/concave init my-app \
  --platform ../../platform/main.roc \
  --sdk ../../packages/concave-sdk/main.roc
```

> **Note:** Roc `0.1.0_RC1` requires relative paths (from `<app>/backend/main.roc`) or HTTPS URLs for `platform` and package imports.

This creates:
- `my-app/backend/main.roc` — your Roc backend defining tables, queries, and mutations.
- `my-app/frontend/index.html` & `my-app/frontend/src/main.js` — a native browser ESM frontend using `/_concave/index.js`.

## 3. Start the Live Dev Server

```sh
./zig-out/bin/concave dev \
  --entry my-app/backend/main.roc \
  --out my-app/frontend/src/_generated \
  --static-dir my-app/frontend \
  --port 3210
```

`concave dev` automatically:
1. Compiles `backend/main.roc` against Concave's native Zig platform host (`libhost.a`).
2. Runs `<binary> --introspect` to emit typed `api.js`, `api.d.ts`, and `dataModel.d.ts` into `frontend/src/_generated/`.
3. Starts the live server backed by an embedded ACID WAL at `.concave/dev.wal`.
4. Watches your `.roc` files and hot-rebuilds + restarts whenever you save.

Open:
- **Your App**: http://127.0.0.1:3210
- **Built-in Live Dev Dashboard**: http://127.0.0.1:3210/_dashboard

## 4. Add a Table, Indexed Query, and Mutation

In `my-app/backend/main.roc`:

```roc
TodoDoc : {
    id : Str,
    created_at : I64,
    list_id : Str,
    text : Str,
    done : Bool,
}

todos_schema : Schema
todos_schema = Schema.record([
    Schema.field("list_id", Schema.str),
    Schema.field("text", Schema.str),
    Schema.field("done", Schema.bool),
])

todos_table : Table(TodoDoc)
todos_table =
    Table.define("todos", todos_schema)
    |> Table.with_index("by_list", ["list_id"])

todos_by_list : Table.Index(TodoDoc)
todos_by_list = Table.index_ref(todos_table, "by_list")
```

Write a read-only reactive Query and an ACID Mutation:

```roc
list_todos! : Ctx.QueryCtx, { list_id : Str } => Try(List(TodoDoc), Str)
list_todos! = |ctx, args|
    Db.from_index(todos_by_list)
    |> Db.eq([Key.str(args.list_id)])
    |> Db.asc
    |> Db.collect!(ctx.db)

add_todo! : Ctx.MutationCtx, { list_id : Str, text : Str } => Try(Str, Str)
add_todo! = |ctx, args|
    Db.insert!(ctx.db, todos_table, {
        list_id: args.list_id,
        text: args.text,
        done: Bool.False,
    })
```

Register them on `concave_app`:

```roc
concave_app : () -> App
concave_app = ||
    App.new("my-todos")
    |> App.table(todos_table)
    |> App.query("todos.list", Schema.record([Schema.field("list_id", Schema.str)]), Schema.list(Table.doc_schema(todos_table)), list_todos!)
    |> App.mutation("todos.add", Schema.record([Schema.field("list_id", Schema.str), Schema.field("text", Schema.str)]), Schema.id("todos"), add_todo!)
```

Because `list_todos!` queries `todos_by_list |> Db.eq([Key.str(args.list_id)])`, Concave records the exact index range in its `ReadSet`. Inserting a todo into `"work"` pushes a live WebSocket update **only** to clients subscribed to `"work"`, never waking `"personal"` subscribers.

## 5. Add Scheduled Jobs, Crons, Webhooks & File Storage

### Transactional Scheduling & Recurring Crons
Schedule work atomically inside any mutation — if the mutation returns `Err(...)`, the scheduled job is rolled back with it:

```roc
job_id = ctx.scheduler.run_after!(60000, "todos.send_reminder", "{\"todo_id\":${Json.to_str(id)}}")?
# Cancel later if needed:
_ = ctx.scheduler.cancel!(job_id)?
```

Declare recurring background crons on `App`:

```roc
|> App.cron("cleanup", 3600000, "todos.prune_old", "{}")
```

### Custom HTTP Routes / Webhooks
Handle external webhooks (Stripe, GitHub, Slack, etc.) directly in Roc with full `ActionCtx` access:

```roc
webhook_handler! : Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponse, Str)
webhook_handler! = |ctx, req| {
    id = ctx.run_mutation!("todos.add", req.body)?
    Ok({ status: 201, content_type: "application/json", body: "{\"id\":${id}}" })
}

# On App:
|> App.http_route("POST", "/webhooks/todos", webhook_handler!)
```

### Built-in Blob Storage
Generate an HMAC-signed upload URL in a mutation or action, `POST`/`PUT` bytes directly from the browser, and retrieve download URLs in queries:

```roc
# Mutation:
upload_url = ctx.storage.generate_upload_url!()?
# Query:
download_url = ctx.storage.get_url!(doc.attachment_id)?
# Mutation:
_ = ctx.storage.delete!(doc.attachment_id)?
```

Locally, blobs are stored in `CONCAVE_STORAGE_DIR` (default `.concave/storage`). In production, set `CONCAVE_S3_*` environment variables to automatically issue zero-dep AWS SigV4 presigned URLs for S3, Cloudflare R2, or GCS.

## 6. Inspect Everything in `/_dashboard`

Visit http://127.0.0.1:3210/_dashboard while running locally to:
- Browse every table (root tables, component namespaces, and `_system._scheduled_jobs`)
- Run any Query, Mutation, or Action — or open a **live WebSocket subscription** right inside the browser
- Monitor pending/running/completed/failed scheduled jobs and registered crons
- Test custom HTTP webhook routes interactively

## 7. Build a Standalone Production Binary

```sh
./zig-out/bin/concave build --entry my-app/backend/main.roc --output my-server --opt speed
./my-server --serve --port 8080 --static-dir my-app/frontend
```

To scale horizontally with PostgreSQL and Docker/Cloud Run, see [Production Deployment & Configuration](DEPLOY_CLOUD_RUN.md).
