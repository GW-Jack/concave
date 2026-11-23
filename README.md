# Concave

[![CI](https://github.com/GW-Jack/concave/actions/workflows/ci.yml/badge.svg)](https://github.com/GW-Jack/concave/actions/workflows/ci.yml)
![Roc 0.1.0_RC1](https://img.shields.io/badge/Roc-0.1.0__RC1-7c3aed)
![Zig 0.17.1](https://img.shields.io/badge/Zig-0.17.1-f7a41d)
![Zero Dependencies](https://img.shields.io/badge/dependencies-0-10b981)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

### Ship a realtime full-stack app in one binary — without the stack sprawl.

Building a modern web app usually means wiring together a REST/GraphQL server, an ORM, WebSockets, client cache invalidation, a background job queue, a webhook handler, file uploads, an analytics SDK, an error tracker, a bundler, and 400 MB of `node_modules` — all before you build your actual product.

**Concave replaces that whole pile with one [Roc](https://www.roc-lang.org/) backend and a single ~2 MB native binary.**

Write ordinary, type-safe Roc functions. Concave keeps your database and every connected browser tab in sync automatically, compiles in a blink, runs on your laptop with zero setup, and scales out on Postgres when you're ready to launch.

---

## What it feels like

You write a normal query in Roc:

```roc
list_messages! : Ctx.QueryCtx, { room : Str } => Try(List(Message), Str)
list_messages! = |ctx, args|
    Db.from_index(messages_by_room)
    |> Db.eq([Key.str(args.room)])
    |> Db.asc
    |> Db.collect!(ctx.db)
```

And a mutation that enforces a rate limit, saves the message, and schedules a follow-up job — **all in one atomic transaction**:

```roc
send_message! : Ctx.MutationCtx, { room : Str, body : Str } => Try(Str, Str)
send_message! = |ctx, args| {
    user = Ctx.require_auth!(ctx.auth!)?
    _ = RateLimiter.enforce!(limiter, ctx, user.subject)?
    id = Db.insert!(ctx.db, messages_table, { room: args.room, body: args.body })?
    _ = ctx.scheduler.run_after!(5000, "notifications.digest", "{\"id\":${Json.to_str(id)}}")?
    Ok(id)
}
```

Then subscribe directly from plain browser JavaScript — **no `npm install`, no bundler, no `useEffect` fetch dance**:

```js
import { ConcaveClient, signal, el, each, mount } from "/_concave/index.js";
import { api } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin);
const room = signal("general");

// Live over WebSockets. Switches rooms automatically when `room()` changes.
const messages = client.query(api.messages.list, () => ({ room: room() }));

mount(document.getElementById("app"), () =>
  el("ul", null,
    each(() => messages().data ?? [], (m) => m.id, (m) =>
      el("li", null, () => m().body),
    ),
  ),
);
```

When a message is sent from another tab, a webhook, or a cron job:
- Only people in `#general` get pushed an update — people in `#random` aren't touched.
- If `send_message!` returns an error, the rate-limit tick, the insert, *and* the scheduled job all roll back together.
- Your editor gets full autocomplete and type checking from auto-generated `api.d.ts` and `dataModel.d.ts`.

---

## What you get to delete

- **No manual WebSockets or cache invalidation.** Queries are live subscriptions by default, with optimistic updates that reconcile or roll back automatically.
- **No `node_modules` or frontend build pipeline.** Concave serves its tiny reactive UI runtime straight from `/_concave/index.js` alongside your `.js` + `.d.ts` files.
- **No Redis or separate worker fleet.** Delayed jobs (`ctx.scheduler`) and recurring crons (`App.cron`) live right inside your app's transactions.
- **No bolted-on SaaS sprawl on day one.** Drop-in pure-Roc components give you live **Presence**, **Rate Limiting**, **PostHog-style Analytics & Feature Flags**, and **Sentry-style Error & Log Monitoring** — all sharing your database and your transactions.
- **No local Docker needed to code.** Develop against a single local file with instant hot reloads and a built-in Dev Dashboard at `/_dashboard`. When it's time to deploy, set `DATABASE_URL` to Postgres (Neon, PlanetScale, Cloud SQL, or self-hosted) and ship a single ~7.6 MB Docker image.
- **No runtime surprises.** Roc's compiler prevents queries from mutating data or making stray network calls, and Concave's core engine is backed by machine-checked formal proofs (Lean 4, Maude, Z3) and live Postgres testing.

---

## See it live in 30 seconds

Requires [Roc `0.1.0_RC1`](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1) and [Zig `0.17.1`](https://ziglang.org/download/).

```sh
git clone https://github.com/GW-Jack/concave.git
cd concave
make dev-chat
```

Open **http://127.0.0.1:3210** in two browser tabs side by side:
1. Chat between tabs and watch messages, online presence, typing indicators, and rate limiting update instantaneously.
2. Type `/preview https://example.com` to trigger an external HTTP Action that fetches metadata and writes back into the room.
3. Visit **http://127.0.0.1:3210/_dashboard** to inspect every table, run any query or mutation, open live subscriptions, and watch scheduled jobs in real time.

### Spin up your own app

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

Save any `.roc` file and Concave rebuilds, regenerates your typed client API, and reloads automatically.

---

## Everything you need to go from idea to production

| Built right in | Why it's nice |
| --- | --- |
| **Live Queries & Optimistic UI** | Instant local feedback with consistent, glitch-free live updates across every tab and server replica. |
| **Built-in Dev Dashboard (`/_dashboard`)** | Browse tables, invoke functions, stream live subscriptions, test webhooks, and monitor jobs without installing a separate tool. |
| **Jobs, Crons, Webhooks & File Uploads** | Transactional `ctx.scheduler`, `App.cron`, custom `App.http_route` webhooks, and signed file uploads (`ctx.storage`, local or S3/R2/GCS). |
| **Search & Pagination** | Reactive `Db.search!` and cursor-based `Db.paginate!` that update live as matching documents arrive. |
| **Drop-in Auth** | Works out of the box with Clerk, Auth0, Supabase, Google, or custom JWTs (HS256, RS256, EdDSA, ES256 + live JWKS rotation), plus zero-config dev tokens locally. |
| **Composable Components** | Mount [Presence](packages/presence/), [Rate Limiter](packages/rate-limiter/), [Analytics & Feature Flags](docs/ANALYTICS.md), and [Error & Log Monitoring](docs/OBSERVABILITY.md) with isolated tables inside your own ACID transactions. |

---

## Documentation

Ready to build? Start with **[Getting Started](docs/GETTING_STARTED.md)**.

- [**Getting Started**](docs/GETTING_STARTED.md) — From `concave init` to your first live app, webhook, background job, and file upload.
- [**Roc API Guide**](docs/ROC_API.md) — Tables, indexes, queries, mutations, pagination, search, scheduler, crons, storage, and HTTP routes.
- [**Browser Client & Signals**](docs/CLIENT_SDK.md) — Live queries, optimistic updates, signals, and surgical DOM helpers.
- [**Analytics & Feature Flags**](docs/ANALYTICS.md) — PostHog-style event tracking, funnels, retention, and reactive feature flags.
- [**Observability & Monitoring**](docs/OBSERVABILITY.md) — Grouped error tracking, live logs, alerts, and Prometheus metrics.
- [**Deploying to Production**](docs/DEPLOY_CLOUD_RUN.md) — Cloud Run / Docker, Postgres, JWKS auth, S3/R2 storage, and all environment variables.
- [**Architecture**](docs/ARCHITECTURE.md) & [**Wire Protocol**](docs/PROTOCOL.md) — Deep dive into how Concave works under the hood.
- [**Verification & Formal Proofs**](docs/VERIFICATION.md) — How we prove correctness with Lean 4, Maude, Z3, simulation testing, and live Postgres 16.

---

## Contributing & License

Pull requests and ideas are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) to run `make test` and get oriented.

MIT License — see [LICENSE](LICENSE).
