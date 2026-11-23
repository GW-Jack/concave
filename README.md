# Concave

[![CI](https://github.com/GW-Jack/concave/actions/workflows/ci.yml/badge.svg)](https://github.com/GW-Jack/concave/actions/workflows/ci.yml)
![Roc 0.1.0_RC1](https://img.shields.io/badge/Roc-0.1.0__RC1-7c3aed)
![Zig 0.17.1](https://img.shields.io/badge/Zig-0.17.1-f7a41d)
![Zero Dependencies](https://img.shields.io/badge/dependencies-0-10b981)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

**A realtime backend for [Roc](https://www.roc-lang.org/) that just stays in sync.**

Write your database queries, mutations, webhooks, and background jobs in clean functional Roc. Concave turns your app into a single standalone server that pushes live updates straight to your frontend — with **no `node_modules`, no bundler, no ORM, and no external database to set up on your laptop**.

---

## Why use Concave?

- **Realtime by default, without the glue code.** Subscribe to any query from the browser and your UI updates automatically whenever the underlying data changes. No manual WebSocket plumbing, no stale caches, no polling loops.
- **Safety built into the language.** Roc's effect system makes sure read queries stay pure, mutations run as atomic transactions, and external HTTP calls stay cleanly separated in Actions.
- **Zero setup to get started.** One command compiles your backend, generates typed frontend bindings, starts a local database, hot-reloads on save, and opens a built-in Dev Dashboard.
- **Batteries included for real apps.** Scheduled jobs, recurring crons, custom webhooks, file uploads (local disk or S3/R2/GCS), pagination, full-text search, and JWT/JWKS auth (Clerk, Auth0, Supabase, Google, etc.) all come built in.
- **Plug-and-play components.** Need live typing indicators, rate limiting, PostHog-style analytics & feature flags, or error & log monitoring? Drop in a pure-Roc component and use it right inside your existing transactions.
- **Grow from laptop to cloud without rewriting.** Develop against a single local file; when you're ready to ship, set `DATABASE_URL` to Postgres (Neon, PlanetScale, Cloud SQL, or self-hosted) and deploy a tiny container that scales smoothly.

---

## Try it in 30 seconds

You'll need [Roc `0.1.0_RC1`](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1) and [Zig `0.17.1`](https://ziglang.org/download/) installed.

```sh
git clone https://github.com/GW-Jack/concave.git
cd concave
make dev-chat
```

Now open **http://127.0.0.1:3210** in two browser tabs side by side:
- Send messages and watch live updates, typing indicators, and rate limiting happen instantly across tabs.
- Try `/preview https://example.com` to see an external HTTP Action in action.
- Open **http://127.0.0.1:3210/_dashboard** to browse your tables, run functions, subscribe live, and inspect background jobs.

### Start your own project

```sh
make host
./zig-out/bin/concave init my-app \
  --platform ../../platform/main.roc \
  --sdk ../../packages/concave-sdk/main.roc
./zig-out/bin/concave dev \
  --entry my-app/backend/main.roc \
  --out my-app/frontend/src/_generated \
  --static-dir my-app/frontend
```

---

## What it feels like to write

### 1. Define your data and functions in Roc (`backend/main.roc`)

```roc
app [concave_app] {
    pf: platform "../platform/main.roc",
    sdk: "../packages/concave-sdk/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table

NoteDoc : { id : Str, created_at : I64, room : Str, body : Str }

notes_table : Table(NoteDoc)
notes_table =
    Table.define("notes", Schema.record([
        Schema.field("room", Schema.str),
        Schema.field("body", Schema.str),
    ]))
    |> Table.with_index("by_room", ["room"])

notes_by_room = Table.index_ref(notes_table, "by_room")

# Read-only and automatically reactive:
list_notes! : Ctx.QueryCtx, { room : Str } => Try(List(NoteDoc), Str)
list_notes! = |ctx, args|
    Db.from_index(notes_by_room)
    |> Db.eq([Key.str(args.room)])
    |> Db.asc
    |> Db.collect!(ctx.db)

# Transactional by default — even scheduled jobs roll back if this returns Err:
add_note! : Ctx.MutationCtx, { room : Str, body : Str } => Try(Str, Str)
add_note! = |ctx, args| {
    id = Db.insert!(ctx.db, notes_table, { room: args.room, body: args.body })?
    _ = ctx.scheduler.run_after!(5000, "notes.notify", "{\"id\":${Json.to_str(id)}}")?
    Ok(id)
}

concave_app : () -> App
concave_app = ||
    App.new("notes-app")
    |> App.table(notes_table)
    |> App.query("notes.list", Schema.record([Schema.field("room", Schema.str)]), Schema.list(Table.doc_schema(notes_table)), list_notes!)
    |> App.mutation("notes.add", Schema.record([Schema.field("room", Schema.str), Schema.field("body", Schema.str)]), Schema.id("notes"), add_note!)
```

### 2. Subscribe straight from the browser (`frontend/src/main.js`)

No build step or `npm install` needed — Concave serves its tiny reactive client directly from `/_concave/index.js` alongside your generated typed API:

```js
import { ConcaveClient, signal, el, each, mount } from "/_concave/index.js";
import { api } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin);
const room = signal("general");

// Stays live over WebSockets and automatically switches rooms when `room()` changes:
const notes = client.query(api.notes.list, () => ({ room: room() }));

mount(document.getElementById("app"), () =>
  el("ul", null,
    each(() => notes().data ?? [], (n) => n.id, (n) =>
      el("li", null, () => n().body),
    ),
  ),
);
```

---

## Included out of the box

| Feature | What it gives you |
| --- | --- |
| **Live Dev Dashboard (`/_dashboard`)** | Inspect tables, test queries/mutations/actions, watch live subscriptions, and check scheduled jobs right in your browser. |
| **Scheduler & Crons** | Schedule one-off delayed jobs inside mutations or declare recurring background tasks with `App.cron`. |
| **Webhooks & File Storage** | Handle external webhooks (`App.http_route`) and signed file uploads (`ctx.storage`) locally or with S3/R2/GCS. |
| **Built-in Components** | Ready-to-mount pure-Roc packages for [Presence](packages/presence/), [Rate Limiting](packages/rate-limiter/), [Analytics & Feature Flags](docs/ANALYTICS.md), and [Error/Log Monitoring](docs/OBSERVABILITY.md). |
| **Zero-Dependency Runtime** | Built entirely on Roc and Zig standard libraries — fast compiles, tiny ~1.9 MB binaries, and no dependency supply-chain headaches. |

---

## Documentation

New to Concave? Start with **[Getting Started](docs/GETTING_STARTED.md)**.

- [**Getting Started**](docs/GETTING_STARTED.md) — Build your first app step by step.
- [**Roc API Guide**](docs/ROC_API.md) — Tables, queries, mutations, pagination, search, scheduler, crons, storage, and webhooks.
- [**Browser Client & Signals**](docs/CLIENT_SDK.md) — Live subscriptions, optimistic updates, signals, and DOM helpers.
- [**Analytics & Feature Flags**](docs/ANALYTICS.md) — PostHog-style events, funnels, retention, and live feature flags.
- [**Observability & Monitoring**](docs/OBSERVABILITY.md) — Grouped error tracking, logs, alerts, and Prometheus metrics.
- [**Deploying to Production**](docs/DEPLOY_CLOUD_RUN.md) — Docker, Cloud Run, Postgres, auth (JWKS), and all config options.
- [**Under the Hood: Architecture**](docs/ARCHITECTURE.md) & [**Wire Protocol**](docs/PROTOCOL.md) — How the storage engine, reactivity, and WebSocket sync work.
- [**Formal Verification & Testing**](docs/VERIFICATION.md) — For the curious: how we test and prove core guarantees with Lean 4, Maude, Z3, simulation testing, and live Postgres.

---

## Contributing & License

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for local test commands (`make test`) and our zero-dependency guidelines.

MIT License — see [LICENSE](LICENSE).
