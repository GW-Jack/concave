---
name: concave
description: >-
  Build realtime full-stack web apps with Concave: a single-binary Roc 0.1.0_RC1
  backend + zero-dependency Zig runtime + <6.5 KB gzipped native browser ESM
  signals & surgical DOM frontend (`/_concave/index.js`). Use when scaffolding,
  coding, running, or debugging a Concave application.
---

# Building Full-Stack Realtime Apps with Concave

Concave pairs a type-safe **Roc (`0.1.0_RC1`)** backend with a zero-dependency native browser ESM frontend (`/_concave/index.js`, `<6.5 KB` gzipped / `~22 KB` raw) — no `npm`, no `node_modules`, no bundler, no Virtual DOM.

---

## 1. CLI Workflow

Requires `roc` (`0.1.0_RC1`) and the `concave` CLI binary. Every subcommand and compiled server binary supports `-h` / `--help`.

### Scaffold a New App
```sh
concave init my-app \
  --template minimal \
  --platform <relative-path-to-platform/main.roc> \
  --sdk <relative-path-to-packages/concave-sdk/main.roc>
```
- Templates: `minimal` (default), `chat`, `kanban`.
- **Important:** Roc `0.1.0_RC1` requires relative paths (resolved from `<app>/backend/main.roc`) or HTTPS URLs in `app { pf: platform "...", sdk: "..." }`.

### Generate Typed Client API (`codegen`)
Compiles `backend/main.roc`, runs `--introspect`, and writes `api.js`, `api.d.ts`, and `dataModel.d.ts`:
```sh
concave codegen \
  --entry my-app/backend/main.roc \
  --out my-app/frontend/src/_generated
```

### Live Dev Server (`dev`)
Watches `.roc` files (rebuilds + regenerates API on change) AND watches `--static-dir` with automatic live reload (CSS hot-swap without losing DOM state; JS/HTML full reload; `Cache-Control: no-cache` on static files):
```sh
concave dev \
  --entry my-app/backend/main.roc \
  --out my-app/frontend/src/_generated \
  --static-dir my-app/frontend \
  --port 3210
```
- App: `http://127.0.0.1:3210`
- Built-in Dev Dashboard: `http://127.0.0.1:3210/_dashboard`

### Build & Run Production Binary
```sh
concave build --entry my-app/backend/main.roc --output my-server --opt dev
./my-server --serve --host 127.0.0.1 --port 3210 --db .concave/app.wal --static-dir my-app/frontend
```
Pass `--live-reload` to enable static file watching and `Cache-Control: no-cache` on static files when running the compiled binary directly. Run `./my-server --help` for all flags.

---

## 2. Backend: Roc (`0.1.0_RC1`) API

Every backend exposes `concave_app : () -> App`:

```roc
app [concave_app] {
    pf: platform "<relative>/platform/main.roc",
    sdk: "<relative>/packages/concave-sdk/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table
```

### Tables, Schemas & Indexes
System fields `id : Str` and `created_at : I64` are managed automatically by the host and included in every returned document.

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

#### `Schema` Constructors
- Primitives: `Schema.null` (Roc `{}`), `Schema.bool`, `Schema.int`, `Schema.float`, `Schema.str`, `Schema.any`
- IDs: `Schema.id("table")`, `Schema.scoped_id("namespace", "table")`
- Containers: `Schema.list(item)`, `Schema.optional(inner)`
- Records: `Schema.record([Schema.field("a", Schema.str), Schema.opt_field("b", Schema.int)])` (empty args = `Schema.record([])` matching Roc `{}`)
- Unions: `Schema.union([Schema.variant("Ok"), Schema.variant_with("Err", Schema.str)])`
- Document schema helper: `Table.doc_schema(tbl)` (prepends `id` and `created_at`)

### Complete Query & Mutation Handler Examples
In Roc `0.1.0_RC1`, effectful functions use `=>` in type signatures, `|ctx, args|` for lambdas, `?` to propagate `Try(ok, Str)` errors, `match` for tag unions, and `for item in list { ... }` / `var $count = 0` (no inline `: Type` on `var`) for loops.

```roc
# Read-only reactive Query (args = `{}` when taking no arguments)
list_todos! : Ctx.QueryCtx, { list_id : Str } => Try(List(TodoDoc), Str)
list_todos! = |ctx, args|
    Db.from_index(todos_by_list)
    |> Db.eq([Key.str(args.list_id)])
    |> Db.asc()
    |> Db.take(100)
    |> Db.collect!(ctx.db)

# Nullable / Optional Query (use `App.query_optional` so `NotFound` encodes as JSON `null` and `Found(doc)` unwraps!)
latest_todo! : Ctx.QueryCtx, { list_id : Str } => Try([Found(TodoDoc), NotFound], Str)
latest_todo! = |ctx, args|
    Db.from_index(todos_by_list)
    |> Db.eq([Key.str(args.list_id)])
    |> Db.desc()
    |> Db.first!(ctx.db)

# Zero-parse pass-through Query (faster for simple lists; register with `App.query_raw`)
list_all_raw! : Ctx.QueryCtx, {} => Try(Str, Str)
list_all_raw! = |ctx, _|
    Db.query(todos_table)
    |> Db.desc()
    |> Db.collect_raw!(ctx.db)

# ACID Mutation with validation + read-modify-write (`Db.get!` works directly on `ctx.db`)
toggle_todo! : Ctx.MutationCtx, { id : Str } => Try(Bool, Str)
toggle_todo! = |ctx, args| {
    maybe_doc = Db.get!(ctx.db, todos_table, args.id)?
    match maybe_doc {
        NotFound => Err("Todo not found")
        Found(doc) => {
            next_done = !doc.done
            _ = Db.patch!(ctx.db, todos_table, args.id, { done: next_done })?
            Ok(next_done)
        }
    }
}

add_many! : Ctx.MutationCtx, { list_id : Str, items : List(Str) } => Try(I64, Str)
add_many! = |ctx, args| {
    var $count = 0
    for text in args.items {
        trimmed = Str.trim(text)
        if !Str.is_empty(trimmed) {
            _ = Db.insert!(ctx.db, todos_table, { list_id: args.list_id, text: trimmed, done: False })?
            $count = $count + 1
        }
    }
    Ok($count)
}
```

### Capabilities & Helpers (`Ctx`)
> **Roc `0.1.0_RC1` syntax notes:**
> - Dot-call syntax (`ctx.http_fetch!(...)`) is UFCS method dispatch in Roc `0.1.0_RC1`, not a record-field function call. Always use the `Ctx.*` wrapper functions below (or bind a record field to a local `f! = ctx.foo!` before calling it).
> - Single-field records require an explicit colon (`{ id: id }`) — `{ id }` without a colon is parsed as a block returning `id`!
> - Built-in `Json.to_str`, `Json.to_str_try`, and `Json.parse` are available globally in Roc `0.1.0_RC1`.

- **`Ctx.QueryCtx`**: Read-only, reactive over WebSockets (`db : DbReader`, `storage : StorageReader`, `auth!`, `now_ms!`).
- **`Ctx.MutationCtx`**: ACID transaction with OCC retries and read-your-own-writes (`db : DbWriter`, `scheduler`, `storage : StorageWriter`, `auth!`, `now_ms!`).
- **`Ctx.ActionCtx`**: External HTTP/HTTPS I/O (`http_fetch!`, `run_query!`, `run_mutation!`, `storage : StorageWriter`, `auth!`, `now_ms!`).

#### Auth & Time
- `Ctx.require_auth!(ctx.auth!)` -> `Try(Ctx.AuthIdentity, Str)` where `AuthIdentity : { subject : Str, issuer : Str, name : Str }`.
  - Dev token format: `"dev:<subject>:<name>"` (pass via `new ConcaveClient(url, { authToken })`, `client.setAuth(...)`, or HTTP header `Authorization: Bearer dev:alice:Alice`).
- `Ctx.now_ms!(ctx)` -> `I64` (Unix epoch ms; works in all 3 contexts).
- `Ctx.as_reader(ctx.db)`, `Ctx.as_query_ctx(ctx)` (for passing a `MutationCtx` into helpers taking `QueryCtx`).

#### Transactional Scheduler (inside `MutationCtx`)
Jobs commit atomically with the mutation (rolled back on `Err`):
- `Ctx.run_after!(ctx, delay_ms, "fn.name", args_record)` -> `Try(Str, Str)` (returns `job_id`; automatically JSON-encodes `args_record`). Use `Ctx.run_after_raw!(ctx, delay_ms, fn_name, args_json)` for pre-encoded JSON.
- `Ctx.run_at!(ctx, run_at_ms, "fn.name", args_record)` / `Ctx.run_at_raw!(...)` -> `Try(Str, Str)`.
- `Ctx.cancel_job!(ctx, job_id)` -> `Try({}, Str)`.

#### Blob / File Storage (`Ctx` + HTTP Upload Protocol)
- `Ctx.generate_upload_url!(ctx)` -> `Try(Str, Str)` (`MutationCtx` or `ActionCtx`).
- `Ctx.get_storage_url!(ctx, storage_id)` -> `Try(Str, Str)` (any context).
- `Ctx.delete_storage!(ctx, storage_id)` -> `Try({}, Str)` (`MutationCtx` or `ActionCtx`).
- **Browser upload protocol:** `POST` or `PUT` raw file bytes to the signed URL returned by `generate_upload_url!` (with `Content-Type` header); the server responds `200 {"storage_id": "<id>"}`. `GET` on the URL returned by `get_storage_url!` serves the bytes (and `404` after deletion).

#### External HTTP Actions & Custom HTTP Webhooks
- `Ctx.http_fetch!(ctx, { method: "GET", url, body: "" })` -> `Try(Ctx.HttpResponse, Str)` where `HttpRequest : { method : Str, url : Str, body : Str }` and `HttpResponse : { status : U64, body : Str }` (use `resp.status.to_str()` for string conversion).
- `Ctx.run_query!(ctx, "fn.name", args_record)` / `Ctx.run_mutation!(ctx, "fn.name", args_record)` -> `Try(Str, Str)` (auto-encodes `args_record` as JSON and returns the **JSON-encoded** result string; use `Ctx.run_query_raw!` / `Ctx.run_mutation_raw!` when forwarding raw JSON strings such as `req.body`).
- `App.http_route(method, path, handler!)` handler signature:
  ```roc
  webhook! : Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponse, Str)
  # HttpRouteRequest  : { method : Str, path : Str, query : Str, body : Str, content_type : Str }
  # HttpRouteResponse : { status : U64, content_type : Str, body : Str }
  webhook! = |ctx, req| {
      id_json = Ctx.run_mutation_raw!(ctx, "todos.add", req.body)?
      Ok({ status: 201, content_type: "application/json", body: "{\"ok\":true,\"id\":${id_json}}" })
  }
  ```

### Multi-File Roc `0.1.0_RC1` Modules
Do **not** use deprecated `module [...]` headers or top-level type aliases in helper files. Define a headerless **nominal type module** matching the filename (e.g. `backend/Bookmark.roc`):
```roc
import sdk.Schema
import sdk.Table

Bookmark :: [Bookmark].{
    Doc : { id : Str, created_at : I64, url : Str, title : Str }
    table : Table(Doc)
    table = Table.define("bookmarks", Schema.record([Schema.field("url", Schema.str), Schema.field("title", Schema.str)]))
}
```
Import it in `backend/main.roc` with `import Bookmark` and reference `Bookmark.Doc`, `Bookmark.table`.

### Database Operations & Edge-Case Semantics (`Db` & `Key`)
- All `Db` read functions (`Db.get!`, `Db.collect!`, `Db.collect_raw!`, `Db.first!`, `Db.paginate!`, `Db.search!`) accept `Ctx.DbReadable(r)` and work directly on `ctx.db` in **both** `QueryCtx` and `MutationCtx`.
- `Db.get!(ctx.db, table, id)` -> `Try([Found(doc), NotFound], Str)`.
- `Db.first!(ctx.db)` (on a `QueryBuilder`) -> `Try([Found(doc), NotFound], Str)`. When returning a `[Found(doc), NotFound]` result directly to JS, register the endpoint with **`App.query_optional`** / **`App.mutation_optional`** (do NOT pass `[Found(doc), NotFound]` to `App.query(..., Schema.optional(...))` or Roc will serialize `"NotFound"` / `{"Found": ...}`).
- `Db.insert!(ctx.db, table, body)` -> `Try(Str, Str)` (returns generated document ID; `body` omits system fields `id` and `created_at`).
- `Db.patch!(ctx.db, table, id, fields)` -> `Try({}, Str)`; returns `Err("NotFound")` if `id` does not exist.
- `Db.replace!(ctx.db, table, id, body)` -> `Try({}, Str)`; replaces all user fields (`body` omits `id` and `created_at`; original `created_at` is preserved); returns `Err("NotFound")` if `id` does not exist.
- `Db.delete!(ctx.db, table, id)` -> `Try({}, Str)`; idempotent (`Ok({})` even if `id` does not exist).
- `Db.search!(ctx.db, table, "field", query_text, limit_u64)` -> reactive case-insensitive multi-token search; empty `query_text` (`""`) returns up to `limit_u64` docs descending by `created_at`.
- `Db.paginate!(ctx.db, cursor, page_size_u64)` -> `Try({ page : List(Doc), next_cursor : Str, is_done : Bool }, Str)` (note: `page_size` is **`U64`**, not `I64`; pass `""` for first page).
- Query combinators: `Db.query(table)`, `Db.from_index(idx)`, `Db.eq(keys)`, `Db.gte(keys)`, `Db.gt(keys)`, `Db.lte(keys)`, `Db.lt(keys)`, `Db.asc()`, `Db.desc()`, `Db.take(n_u64)`, `Db.collect!(db)`, `Db.collect_raw!(db)`, `Db.first!(db)`.
- Key constructors: `Key.null`, `Key.bool(b)`, `Key.int(i)`, `Key.float(f)`, `Key.str(s)`, `Key.id(id)`.
  - **Important (`Schema.id` vs `Key.str`):** Foreign-key fields declared with `Schema.id("polls")` produce branded `Id<"polls">` types in TypeScript, and are indexed as JSON strings — always query secondary indexes on those fields with **`Key.str(poll_id)`** (never `Key.id`, which is reserved for the internal system `id` tiebreaker!).

### Registering the App
```roc
concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> App.table(todos_table)
    |> App.query("todos.list", list_args_schema, Schema.list(Table.doc_schema(todos_table)), list_todos!)
    |> App.query_optional("todos.latest", list_args_schema, Table.doc_schema(todos_table), latest_todo!)
    |> App.query_raw("todos.listAll", Schema.record([]), Schema.list(Table.doc_schema(todos_table)), list_all_raw!)
    |> App.mutation("todos.addMany", add_args_schema, Schema.int, add_many!)
    |> App.mutation("todos.toggle", Schema.record([Schema.field("id", Schema.id("todos"))]), Schema.bool, toggle_todo!)
    |> App.action("todos.sync", sync_args_schema, Schema.str, sync_todos!)
    # App.cron(name : Str, interval_ms : I64, fn_name : Str, args_json : Str)
    # Persisted in `_system._scheduled_jobs` for multi-replica at-most-once execution.
    |> App.cron("cleanup", 3600000, "todos.prune", "{}")
    |> App.http_route("POST", "/webhooks/todos", webhook!)
```

---

## 3. Frontend: Browser ESM Client & Signals (`/_concave/index.js`)

Serve plain HTML + `.js` + `.css` from `--static-dir`. Import directly from `/_concave/index.js` and `./_generated/api.js`.

### Connecting & Bound API (`createApi`)
```js
import { ConcaveClient } from "/_concave/index.js";
import { createApi } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin, {
  authToken: "dev:alice:Alice", // optional in dev mode
  // liveReload: true,          // default: true (CSS hot-swap or page reload in dev)
  // onReload: (ev) => {},      // optional custom reload hook ({ type: "reload", reason: "css" | "static" })
});
const db = createApi(client);
```
- Reactive client signals: `client.status()` (`"connecting" | "connected" | "reconnecting" | "closed"`), `client.commitTs()`, `client.identity()`.
- Lifecycle & auth: `client.setAuth(token | null)`, `client.close()`.
- Bound functions on `db`:
  - **Queries:** `const notes = db.notes.list()` or reactive args `db.todos.list(() => activeList() ? { list_id: activeList() } : null)`.
    - Returns an accessor `() => { status: "paused" | "loading" | "ready" | "error", data, error }` with `.dispose()` for manual teardown outside `createRoot`/`mount`.
    - When a reactive args accessor returns `null` or `undefined`, the subscription unsubscribes cleanly and `status` becomes **`"paused"`** (never stuck on `"loading"`).
    - One-shot query: `await db.notes.list.once()` / `await db.todos.list.once({ list_id })`.
  - **Mutations:** `await db.todos.add({ list_id, text }, options?)`.
  - **Actions:** `await db.todos.sync({ ... })`.
  - Every bound function exposes `.ref` (and raw `api` is also exported from `./_generated/api.js`).

### Optimistic Updates
Both standalone `optimisticAppend(...)` and `client.optimisticAppend(...)` are exported and accept either a bound query (`db.todos.list`) or raw ref (`api.todos.list`):
```js
// Shorthand for appending to a live list query (item can be a value or `(prev) => item`):
await db.todos.add(
  { list_id: id, text },
  client.optimisticAppend(db.todos.list, { list_id: id }, {
    id: `opt-${Date.now()}`,
    created_at: Date.now(),
    list_id: id,
    text,
    done: false,
  }),
);

// Or custom reducer:
await db.todos.toggle({ id }, {
  optimisticUpdate(store) {
    const prev = store.getQuery(db.todos.list, { list_id }) ?? [];
    store.setQuery(db.todos.list, { list_id }, prev.map((t) =>
      t.id === id ? { ...t, done: !t.done } : t
    ));
  },
});
```

### Fine-Grained Signals
- `signal(initial, equals?)` — `s()`, `s.set(v)`, `s.update(fn)`, `s.peek()`
- `computed(fn, equals?)` — lazy, memoized, glitch-free derived signal
- `effect(fn)` — re-runs on tracked signal changes; return a cleanup fn or call `onCleanup(fn)`
- `batch(fn)`, `untrack(fn)`, `createRoot(fn)`, `onCleanup(fn)`

### Surgical DOM Helpers (No Virtual DOM)
Components are plain JS functions that run **once** and return DOM nodes. Pass static values directly and wrap reactive values in zero-arg getters `() => ...`:

```js
import { bindChecked, bindValue, computed, each, mount, show, signal, tags } from "/_concave/index.js";

const { button, div, form, h1, input, label, li, main, option, p, select, span, ul } = tags;

const draft = signal("");
const priority = signal("med");
const showDone = signal(true);

mount(document.getElementById("app"), () =>
  main({ class: "app" },
    h1(() => `Todos (${client.status()})`),
    form({
      onSubmit: async (e) => {
        e.preventDefault();
        const text = draft().trim();
        if (!text) return;
        draft.set("");
        await db.todos.add({ list_id: "work", text });
      },
    },
      input({ placeholder: "New todo…", ...bindValue(draft) }),
      select({ ...bindValue(priority) },
        option({ value: "low" }, "Low"),
        option({ value: "med" }, "Medium"),
        option({ value: "high" }, "High"),
      ),
      button({ type: "submit", disabled: () => !draft().trim() }, "Add"),
    ),
    label(input({ type: "checkbox", ...bindChecked(showDone) }), " Show completed"),
    show(
      () => todos().status === "ready",
      () => ul(
        each(
          () => (todos().data ?? []).filter((t) => showDone() || !t.done),
          (t) => t.id,
          (todo) => li(span(() => todo().text)),
        ),
      ),
      () => p(() => todos().status === "paused" ? "Select a list" : "Loading…"),
    ),
  ),
);
```

- **`tags` / `el` prop conventions:**
  - `tags` Proxy makes `props` optional: `div("hi")` or `div({ class: "card" }, "hi")`.
  - Event listeners use `on*` (case-insensitive after `on`, e.g. `onClick`, `onInput`, `onSubmit`) and auto-remove on scope cleanup.
  - `class` / `className`, `style` (string or object), `value`, `disabled`, `checked`, `hidden`, and `ref: (node) => ...` are handled directly; `value` and `ref` are applied **after** children are appended so `<select {...bindValue(sig)}>` selects the initial `<option>` cleanly.
  - Other boolean attributes set `""` when `true` and remove the attribute when `false`/`null`/`undefined`.
- `bindValue(sig, onInput?)` / `bindChecked(sig, onChange?)`: Two-way binding helpers for inputs, `<select>`, and checkboxes.
- `each(itemsAccessor, keyFn, renderItem)`: Keyed list reconciliation; `renderItem` receives a reactive accessor `() => item`.
- `show(whenAccessor, renderThen, renderElse?)`: Conditional branch with automatic `createRoot` teardown.
- `mount(container, renderRoot)`: Mounts inside a `createRoot` and returns `dispose()`.

### Wire Endpoints (for Testing / Custom Clients)
- WebSocket sync & RPC: `ws(s)://<host>/ws` (binary default via `?proto=bin`, or JSON text frames). Live reload pushes `{"type":"reload","reason":"css" | "static"}`.
- HTTP RPC: `POST /api/query/<name>`, `POST /api/mutation/<name>`, `POST /api/action/<name>` with JSON body and optional `Authorization: Bearer <token>` header; responds `{"ok":true,"value":...}` or `{"ok":false,"error":"..."}`.
- Blob storage: `POST`/`PUT` bytes to signed `/_storage/upload/<token>` -> `{"storage_id":"<id>"}`; `GET /_storage/<id>` downloads bytes.
- Health / readiness / operator telemetry: `GET /health`, `GET /ready`, `GET /_internal/status`, `GET /_internal/metrics`.
- Embedded SDK assets: `/_concave/index.js`, `/_concave/analytics.js`, `/_concave/monitor.js`.

---

## 4. Built-in Composable Components & Custom Components

Concave ships four zero-dependency pure-Roc component packages (each gets host-enforced table namespace isolation while participating in your app's exact same ACID transactions):

```roc
app [concave_app] {
    pf: platform "<relative>/platform/main.roc",
    sdk: "<relative>/packages/concave-sdk/main.roc",
    presence: "<relative>/packages/presence/main.roc",
    ratelimit: "<relative>/packages/rate-limiter/main.roc",
    analytics: "<relative>/packages/analytics/main.roc",
    monitor: "<relative>/packages/monitor/main.roc",
}
```

### Mounting & Attaching
```roc
import presence.Presence
import ratelimit.RateLimiter
import analytics.Analytics
import analytics.Props
import monitor.Monitor
import monitor.Attrs

doc_presence = Presence.mount("presence", 30000)         # (namespace, ttl_ms)
save_limiter = RateLimiter.mount("rate_limit", 10, 60000) # (namespace, max_requests, window_ms)
app_analytics = Analytics.mount("analytics")
app_monitor = Monitor.mount("monitor")

concave_app = ||
    App.new("my-app")
    |> Presence.attach(doc_presence)
    |> RateLimiter.attach(save_limiter)
    |> Analytics.attach(app_analytics)
    |> Monitor.attach(app_monitor) # or Monitor.attach_with_cron(app_monitor, 30000, 3600000)
```

### Server-Side Transactional Helpers (Inside Your Mutations)
- **RateLimiter**: `_ = RateLimiter.enforce!(save_limiter, ctx, user.subject)?` (returns `Err("Rate limit exceeded")` and rolls back the enclosing mutation when quota is exhausted). Exposes query `<ns>.status` (`{ key }`).
- **Presence**: Exposes `<ns>.heartbeat` (`{ room_id, typing }`), `<ns>.leave` (`{ room_id }`), and `<ns>.listOnline` (`{ room_id }`).
- **Analytics**:
  - `Analytics.is_flag_enabled!(app_analytics, Ctx.as_query_ctx(ctx), "flag-key", user.subject)?`
  - `Analytics.track_event!(app_analytics, ctx, user.subject, "event_name", [Props.prop("k", "v")])?`
  - Exposes `<ns>.capture`, `<ns>.identify`, `<ns>.upsertFlag`, `<ns>.listFlags`, `<ns>.evaluateAllFlags`, `<ns>.summary`, `<ns>.recentEvents`, `<ns>.trends`, `<ns>.funnel`, `<ns>.retention`.
  - Embedded browser/Node client at `/_concave/analytics.js`:
    ```js
    import { createAnalytics } from "/_concave/analytics.js";
    const posthog = createAnalytics(client, api.analytics);
    await posthog.identify("alice", { set: { name: "Alice" }, setOnce: { first_seen: "web" } });
    await posthog.capture("doc_saved", { doc_id });
    const flags = posthog.subscribeFlags(); // or subscribeFlags({}, () => distinctId)
    const canExport = posthog.isEnabled(flags().data, "export-markdown", true); // also accepts flags()
    const summary = posthog.subscribeSummary({ top_n: 8 });
    ```
- **Monitor**:
  - `Monitor.log_info!(app_monitor, ctx, "service", "message", [Attrs.attr("k", "v")])?` *(5 args — no `trace_id`; use `Monitor.record_span!` for traced spans)*
  - `Monitor.record_metric!(app_monitor, ctx, "metric_name", "gauge", 42.0, "service", [])?`
  - Exposes `<ns>.captureError`, `<ns>.log`, `<ns>.recordMetric`, `<ns>.overview`, `<ns>.listIssues`, `<ns>.recentLogs`, `<ns>.searchLogs`, `<ns>.metricSeries`, `<ns>.upsertAlertRule`, `<ns>.evaluateAlerts`.
  - Embedded browser/Node client at `/_concave/monitor.js`:
    ```js
    import { createMonitor } from "/_concave/monitor.js";
    const monitor = createMonitor(client, api.monitor, { service: "web", release: "1.0.0", captureGlobalErrors: true });
    monitor.addBreadcrumb("ui", "Clicked save");
    await monitor.captureException(err, { attrs: { doc_id } });
    const overview = monitor.subscribeOverview({ window_ms: 3600000, top_n: 5 });
    const logs = monitor.subscribeLogs({ service: "web", limit: 20 });
    ```

### Writing Custom Components
Use a headerless nominal type module (`backend/AuditLog.roc`). Note that `app` is a **reserved keyword** in Roc `0.1.0_RC1` (name the `App` parameter `application` or `a`). `App.component_query` and `App.component_mutation` automatically scope `ctx` to `ns` AND auto-prefix `name` with `"${ns}."` when not already prefixed; use `Table.doc_schema_scoped(tbl, ns)` so generated `api.d.ts` uses `Id<"ns::table">`:

```roc
import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table

AuditLog :: [AuditLog].{
    EntryDoc : { id : Str, created_at : I64, doc_id : Str, actor : Str, action : Str }
    Mount : { namespace : Str, spec : Component.ComponentSpec }

    entries_table : Table(EntryDoc)
    entries_table =
        Table.define("entries", Schema.record([
            Schema.field("doc_id", Schema.str),
            Schema.field("actor", Schema.str),
            Schema.field("action", Schema.str),
        ]))
        |> Table.with_index("by_doc", ["doc_id"])

    by_doc : Table.Index(EntryDoc)
    by_doc = Table.index_ref(entries_table, "by_doc")

    mount : Str -> Mount
    mount = |namespace| { namespace, spec: Component.define(namespace, "audit-log", [Table.spec(entries_table)]) }

    # Transactional helper callable inside any app mutation (same ACID tx!)
    record! : Mount, Ctx.MutationCtx, Str, Str, Str => Try(Str, Str)
    record! = |m, ctx, doc_id, actor, action| {
        scoped = Ctx.scope_mutation(ctx, m.namespace)
        Db.insert!(scoped.db, entries_table, { doc_id, actor, action })
    }

    attach : App, Mount -> App
    attach = |application, m|
        application
        |> App.component(m.spec)
        |> App.component_query(
            m.namespace,
            "byDoc", # auto-registered as `<namespace>.byDoc` with `ctx` already scoped
            Schema.record([Schema.field("doc_id", Schema.str)]),
            Schema.list(Table.doc_schema_scoped(entries_table, m.namespace)),
            |ctx, args| Db.from_index(by_doc) |> Db.eq([Key.str(args.doc_id)]) |> Db.asc() |> Db.collect!(ctx.db),
        )
}
```

