# Concave

[![CI](https://github.com/GW-Jack/concave/actions/workflows/ci.yml/badge.svg)](https://github.com/GW-Jack/concave/actions/workflows/ci.yml)
![Roc 0.1.0_RC1](https://img.shields.io/badge/Roc-0.1.0__RC1-7c3aed)
![Zig 0.17.1](https://img.shields.io/badge/Zig-0.17.1-f7a41d)
![Zero Dependencies](https://img.shields.io/badge/dependencies-0-10b981)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

**Concave** is a **zero-dependency**, Convex-style reactive backend platform for [Roc](https://www.roc-lang.org/) (`0.1.0_RC1`), powered by a pure **Zig `0.17.1`** stdlib runtime, dual embedded WAL / native PostgreSQL Wire v3 storage, serializable OCC transactions, capability-injected Roc components, and a bespoke native browser ESM reactive client.

**Zero Cargo crates. Zero `npm`. Zero `node_modules`. Zero C libraries. Zero bundler.**

```text
  Roc App (main.roc) + Pure-Roc Components (presence, rate-limiter, analytics, monitor)
        │  roc build  (native platform + libhost.a)
        ▼
  Single ~1.9 MB Native Server Binary  (7.6 MB compressed Alpine static-PIE Docker image)
        ├── HTTP/1.1 + RFC 6455 WebSockets (/ws, /api/*, App.http_route webhooks)
        ├── Embedded Native ESM Client (/_concave/*.js) & Live Dev Dashboard (/_dashboard)
        ├── Transactional Scheduler & Crons (_system._scheduled_jobs) + Blob Storage (Local / S3 SigV4)
        ├── Auth (HS256, RS256, EdDSA, ES256 + live JWKS) & Operator Telemetry (/_internal/metrics)
        └── Unified ACID Storage: Embedded CRC32 WalStore  <──or──>  Pooled PgStore (PG Wire v3 + TLS 1.3 + SCRAM-SHA-256)
```

---

## Why Concave?

| Pillar | What Concave Ships (All Pure Stdlib) |
| --- | --- |
| **Native Roc Platform** | `roc build` links your Roc backend + Zig `libhost.a` into a single self-contained native binary (`--serve`, `--introspect`). |
| **Static Effect Isolation** | `QueryCtx` (read-only), `MutationCtx` (ACID + OCC + RYOW + transactional `scheduler`), and `ActionCtx` (HTTP/HTTPS + re-entrant `run_query!`/`run_mutation!`) enforced by Roc's type & effect system. |
| **Surgical Reactivity** | Exact Document-ID + lexicographic Index-Range `ReadSet` tracking pushes consistent `commit_ts` transition batches over WebSockets — including across multiple horizontal replicas via `commit_log` tailing. |
| **Dual ACID Storage** | Zero-config embedded **`WalStore`** (CRC32-framed WAL + atomic snapshot compaction) for dev/single-node, and pooled **`PgStore`** (PostgreSQL Wire v3 + TLS 1.3 + SCRAM-SHA-256, PgBouncer transaction-mode safe) for horizontal cloud scale. |
| **Platform Batteries Included** | Transactional `ctx.scheduler` & `App.cron`, custom `App.http_route` webhooks, `ctx.storage` blob storage (local HMAC-signed uploads + zero-dep AWS SigV4 for S3/R2/GCS), reactive `Db.paginate!` & `Db.search!`. |
| **Production Auth** | Zero-dep **HS256**, **RS256**, **EdDSA (Ed25519)**, and **ES256 (P-256)** JWT verification with live **JWKS** (`CONCAVE_JWKS_URL`) caching, automatic `kid` key rotation, and `iss`/`aud` checks. |
| **Live Dev Dashboard & Telemetry** | Embedded zero-dep reactive console at **`/_dashboard`** (Data Browser, Function Runner + live WS subscriptions, Jobs/Crons, HTTP Routes) + lock-free Prometheus/OpenMetrics at **`/_internal/metrics`** + graceful `SIGTERM` drain. |
| **Zero-`npm` Reactive Browser ESM** | Embedded `/_concave/index.js` ships glitch-free fine-grained signals, optimistic mutation overlays, and surgical DOM helpers (`el`, `each`, `show`, `mount`) alongside `--introspect` generated `api.js`, `api.d.ts`, and `dataModel.d.ts`. |
| **Capability-Injected Components** | Reusable pure-Roc packages with host-enforced namespace isolation inside your app's exact ACID transactions: `presence`, `rate-limiter`, `analytics` (PostHog-style events, funnels, retention, feature flags), and `monitor` (errors, logs, metrics, alerts). |
| **Formally Verified** | Machine-checked **Lean 4** proofs, **Maude** model checks, **Z3** SMT proofs, Zig deterministic simulation testing (DST) & WAL crash/fuzz tests, RFC 6455 conformance, FFI concurrency stress, and live Docker **PostgreSQL 16 + PgBouncer** differential tests. |

---

## Quickstart

### Prerequisites
- [Roc `0.1.0_RC1`](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1) on `PATH`
- [Zig `0.17.1`](https://ziglang.org/download/) on `PATH`
- Node.js `22+` *(optional — only needed to run the automated client/E2E test runner)*

### 1. Run the Multi-Room Reactive Chat Demo

```sh
make dev-chat
```

This builds `libhost.a` and the `concave` CLI, compiles `examples/chat-app/backend/main.roc`, runs `--introspect` codegen, watches `.roc` files for hot reloads, and starts the server:
- **Chat App**: http://127.0.0.1:3210 (open two tabs to test live index-range reactivity, typing presence, rate limiting, optimistic updates, and `/preview <url>` HTTP Actions)
- **Live Dev Dashboard**: http://127.0.0.1:3210/_dashboard
- **Prometheus Metrics**: http://127.0.0.1:3210/_internal/metrics

### 2. Scaffold Your Own App

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

### 3. Run the Full Verification Suite

```sh
make test            # Zig unit/DST/crash/fuzz + Roc tests + JS property tests + 6 E2E suites + WS conformance + FFI stress
make verify-formal   # Lean 4 proofs + Maude model checks + Z3 SMT obligations
make test-pg-docker  # Live Docker PostgreSQL 16 (TLS 1.3 + SCRAM-SHA-256) + PgBouncer + 2-replica differential suite
```

---

## Show Me the Code

### Backend (`backend/main.roc`)

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

list_notes! : Ctx.QueryCtx, { room : Str } => Try(List(NoteDoc), Str)
list_notes! = |ctx, args|
    Db.from_index(notes_by_room)
    |> Db.eq([Key.str(args.room)])
    |> Db.asc
    |> Db.collect!(ctx.db)

add_note! : Ctx.MutationCtx, { room : Str, body : Str } => Try(Str, Str)
add_note! = |ctx, args| {
    id = Db.insert!(ctx.db, notes_table, { room: args.room, body: args.body })?
    # Committed atomically with the insert — rolled back automatically if this mutation fails:
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

### Frontend (`frontend/src/main.js` — zero `npm`, zero bundler)

```js
import { ConcaveClient, signal, el, each, mount } from "/_concave/index.js";
import { api } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin);
const room = signal("general");

// Automatically subscribes over WebSockets and resubscribes whenever `room()` changes:
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

## Repository Layout

```text
concave/
├── build.zig                  # Builds zero-dep `libhost.a`, `concave` CLI, `pg-diff`, and Zig tests
├── Dockerfile                 # Multi-stage static-PIE Linux image (debian:trixie-slim -> alpine:3.21)
├── Makefile                   # Build, test, formal verification, and dev targets
├── platform/                  # Roc 0.1.0_RC1 platform (`main.roc`, `Host.roc`, `targets/`)
├── packages/
│   ├── concave-sdk/           # Pure Roc SDK (`Schema`, `Key`, `Table`, `Ctx`, `Db`, `Component`, `App`)
│   ├── presence/              # Reusable pure-Roc Presence component
│   ├── rate-limiter/          # Reusable pure-Roc transactional Rate Limiter component
│   ├── analytics/             # Reusable pure-Roc PostHog-style Product Analytics & Feature Flags component
│   └── monitor/               # Reusable pure-Roc Application Monitoring component (errors, logs, metrics, alerts)
├── zig/
│   ├── core/                  # Key codec, Manifest, ReadSet/OCC, WalStore (CRC32 + compaction), PgStore (PG Wire v3 + TLS 1.3 + pool), BlobStore + SigV4
│   ├── runtime/               # HTTP/1.1 + RFC 6455 WS server, reactivity + scheduler engine, Auth (HS256/RS256/EdDSA/ES256 + JWKS), lock-free Prometheus metrics
│   ├── host/                  # Roc 0.1.0_RC1 C-ABI staticlib (`libhost.a`) + graceful SIGTERM drain
│   ├── codegen/               # `--introspect` JSON IR -> typed ESM + `.d.ts` (`api.js`, `api.d.ts`, `dataModel.d.ts`)
│   ├── cli/                   # Zero-dep `concave` CLI (`init`, `dev`, `codegen`, `build`)
│   └── verify/                # Zig property tests, WAL crash recovery, DST, protocol fuzzers, PG differential runner
├── client/
│   ├── concave-client/        # Zero-dep native browser ESM WebSocket sync + signals + surgical DOM (with `.d.ts`)
│   └── concave-dashboard/     # Embedded zero-dep live developer dashboard served at `/_dashboard`
├── specs/                     # Formal specifications: Lean 4, Maude, Z3, and TLA+
├── examples/
│   └── chat-app/              # Real-time multi-room chat app demonstrating all Concave capabilities
├── tests/                     # E2E, property, RFC 6455 WS conformance, FFI stress, and Docker PG16 tests
└── docs/                      # Complete developer, protocol, verification, and deployment guides
```

---

## Documentation

- [**Getting Started**](docs/GETTING_STARTED.md) — From `concave init` to your first live reactive app, scheduler, webhook, file upload, and `/_dashboard`.
- [**Roc API Guide**](docs/ROC_API.md) — Complete `concave-sdk` reference: `Schema`, `Table`, `Key`, `Ctx`, `Db` (including `paginate!` & `search!`), `Component`, and `App` (`cron`, `http_route`).
- [**Browser Client & Signals SDK**](docs/CLIENT_SDK.md) — Zero-`npm` `/_concave/index.js` reactivity, optimistic updates, surgical DOM, and typed JSDoc/TypeScript codegen.
- [**Architecture & Design**](docs/ARCHITECTURE.md) — Platform boundary, `WalStore`/`PgStore` 3-table design, `ReadSet`/OCC reactivity, scheduler, and threading model.
- [**Wire Protocol & HTTP Reference**](docs/PROTOCOL.md) — WebSocket `/ws` frames, RPC endpoints, `/_storage/*`, `/_dashboard`, `/_admin/*`, and `/_internal/*`.
- [**PostHog-Style Analytics Component**](docs/ANALYTICS.md) — Events, identity/aliases, live funnels & retention, and reactive feature flags (`packages/analytics`).
- [**Observability & Monitoring**](docs/OBSERVABILITY.md) — Layer 1 platform Prometheus telemetry + Layer 2 application monitoring component (`packages/monitor`).
- [**Production Deployment & Configuration**](docs/DEPLOY_CLOUD_RUN.md) — Cloud Run / Docker deployment, Serverless Postgres, all environment variables, and production hardening checklist.
- [**Verification & Formal Proofs**](docs/VERIFICATION.md) — Lean 4 theorems, Maude model checks, Z3 SMT proofs, DST, fuzzing, and live PG16 differential testing.

---

## License

MIT — see [LICENSE](LICENSE).
