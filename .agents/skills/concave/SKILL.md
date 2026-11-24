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
In Roc `0.1.0_RC1`, effectful functions use `=>` in type signatures, `|ctx, args|` for lambdas, `?` to propagate `Try(ok, Str)` errors, and `match` for tag unions.

```roc
# Read-only reactive Query (args = `{}` when taking no arguments)
list_todos! : Ctx.QueryCtx, { list_id : Str } => Try(List(TodoDoc), Str)
list_todos! = |ctx, args|
    Db.from_index(todos_by_list)
    |> Db.eq([Key.str(args.list_id)])
    |> Db.asc()
    |> Db.take(100)
    |> Db.collect!(ctx.db)

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

add_todo! : Ctx.MutationCtx, { list_id : Str, text : Str } => Try(Str, Str)
add_todo! = |ctx, args| {
    trimmed = Str.trim(args.text)
    if Str.is_empty(trimmed) {
        return Err("Todo text cannot be empty")
    }
    Db.insert!(ctx.db, todos_table, {
        list_id: args.list_id,
        text: trimmed,
        done: False,
    })
}
```

### Capabilities (`Ctx`)
- **`Ctx.QueryCtx`**: Read-only, reactive over WebSockets. Capabilities: `ctx.db : DbReader`, `ctx.storage`, `ctx.auth!`, `ctx.now_ms!`.
- **`Ctx.MutationCtx`**: ACID transaction with OCC retries and read-your-own-writes. Capabilities: `ctx.db : DbWriter`, `ctx.scheduler`, `ctx.storage`, `ctx.auth!`, `ctx.now_ms!`.
- **`Ctx.ActionCtx`**: External HTTP I/O (`ctx.http_fetch!`), re-entrant `ctx.run_query!`, `ctx.run_mutation!`.
- Helpers: `Ctx.require_auth!(ctx.auth!)`, `Ctx.as_reader(ctx.db)`, `Ctx.as_query_ctx(ctx)`.
- All `Db` read functions (`Db.get!`, `Db.collect!`, `Db.collect_raw!`, `Db.first!`, `Db.paginate!`, `Db.search!`) accept `Ctx.DbReadable(r)`, so they work directly with `ctx.db` in **both** `QueryCtx` and `MutationCtx` (while write ops remain statically restricted to `MutationCtx`).

### Database Operations & Edge-Case Semantics (`Db` & `Key`)
- `Db.get!(ctx.db, table, id)` -> `Try([Found(doc), NotFound], Str)`.
- `Db.insert!(ctx.db, table, body)` -> `Try(Str, Str)` (returns generated document ID).
- `Db.patch!(ctx.db, table, id, fields)` -> `Try({}, Str)`; returns `Err("NotFound")` if `id` does not exist.
- `Db.replace!(ctx.db, table, id, body)` -> `Try({}, Str)`; returns `Err("NotFound")` if `id` does not exist.
- `Db.delete!(ctx.db, table, id)` -> `Try({}, Str)`; idempotent (`Ok({})` even if `id` does not exist).
- `Db.search!(ctx.db, table, "field", query_text, limit)` -> reactive case-insensitive multi-token search; empty `query_text` (`""`) returns up to `limit` docs descending by `created_at`.
- `Db.paginate!(ctx.db, cursor, page_size)` -> `Try({ page : List(Doc), next_cursor : Str, is_done : Bool }, Str)` (pass `""` for first page).
- Query combinators: `Db.query(table)`, `Db.from_index(idx)`, `Db.eq(keys)`, `Db.gte(keys)`, `Db.gt(keys)`, `Db.lte(keys)`, `Db.lt(keys)`, `Db.asc()`, `Db.desc()`, `Db.take(n)`, `Db.collect!(db)`, `Db.collect_raw!(db)`, `Db.first!(db)`.
- Key constructors: `Key.null`, `Key.bool(b)`, `Key.int(i)`, `Key.float(f)`, `Key.str(s)`, `Key.id(id)`.

### Registering the App
```roc
concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> App.table(todos_table)
    |> App.query("todos.list", list_args_schema, Schema.list(Table.doc_schema(todos_table)), list_todos!)
    |> App.query_raw("todos.listAll", Schema.record([]), Schema.list(Table.doc_schema(todos_table)), list_all_raw!)
    |> App.mutation("todos.add", add_args_schema, Schema.id("todos"), add_todo!)
    |> App.mutation("todos.toggle", Schema.record([Schema.field("id", Schema.id("todos"))]), Schema.bool, toggle_todo!)
    |> App.action("todos.sync", sync_args_schema, Schema.str, sync_todos!)
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
- HTTP RPC: `POST /api/query/<name>`, `POST /api/mutation/<name>`, `POST /api/action/<name>`.
- Health / readiness: `GET /health`, `GET /ready`.
- Embedded SDK assets: `/_concave/index.js`, `/_concave/analytics.js`, `/_concave/monitor.js`.
