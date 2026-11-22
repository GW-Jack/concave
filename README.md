# Concave

**Concave** is a **zero-dependency**, Convex-style reactive backend platform for [Roc](https://www.roc-lang.org/) (`0.1.0_RC1`), powered by a pure **Zig `0.17.1`** stdlib host & runtime, dual embedded WAL / native PostgreSQL Wire v3 storage, fine-grained read-set reactivity with OCC transactions, capability-injected Roc Components, and a bespoke zero-dependency native ESM reactive client runtime.

**Zero Cargo crates. Zero `npm`. Zero `node_modules`. Zero C libraries.**

## Highlights

- **Native Roc Platform (`libhost.a` in Zig stdlib)**: `roc build` compiles your Roc backend and Concave's zero-dependency Zig runtime into a **~1.9 MB** standalone native server executable (`--serve`, `--introspect`).
- **Static Effect Isolation**:
  - **Queries** receive read-only `Ctx.QueryCtx` (`db` with `get!`, `collect!`, `paginate!`, `search!`, plus read-only `storage.get_url!`).
  - **Mutations** receive transactional `Ctx.MutationCtx` (ACID read/write + OCC conflict detection + read-your-own-writes + transactional `scheduler.run_after!`/`run_at!`/`cancel!` + `storage`).
  - **Actions & Custom HTTP Routes** receive `Ctx.ActionCtx` (external HTTP/HTTPS I/O + re-entrant `run_query!` / `run_mutation!` + `storage`), plus declarative `App.http_route` webhooks and `App.cron` recurring jobs.
  - **Production Auth** (`ctx.auth!`): zero-dep **HS256**, **RS256**, **EdDSA (Ed25519)**, and **ES256 (P-256)** JWT verification with live **JWKS (`CONCAVE_JWKS_URL`)** caching & automatic `kid` key rotation, plus `iss`/`aud` validation and optional dev tokens.
- **Built-in Blob Storage & Live Dev Dashboard**: Local disk blob storage with HMAC-signed upload tokens (`/_storage/...`) and zero-dep **AWS SigV4** presigned URLs for S3/R2/GCS, plus an embedded zero-dep reactive Dev Dashboard at **`/_dashboard`** (protected by `CONCAVE_ADMIN_KEY`).
- **Capability-Injected Components**: Reusable pure-Roc packages depending only on `concave-sdk`, mounted with explicit namespaces and enforced by the host with strict per-component table isolation inside the same ACID transaction.
- **Idiomatic Roc `0.1.0_RC1` API**: Typed `Table(doc)` and `Table.Index(doc)` handles, flat pipe registration, built-in `Json` serialization (`Json.parse` / `Json.to_str_try`), and runtime `--introspect` -> typed ESM + `.d.ts` codegen (`api.js`, `api.d.ts`, `dataModel.d.ts`) with zero Roc source parsing.
- **Zero-Dependency Dual Persistence**: Unified `Storage` engine (`documents`, `index_entries`, `commit_log` with `deployment_id` shard key) supporting:
  - **Embedded ACID WAL (`WalStore`)**: zero-config local dev (`concave dev`) and offline tests — CRC32-framed append-only WAL with atomic snapshot compaction, pure Zig stdlib, no SQLite/C deps.
  - **Native PostgreSQL (`PgStore`)**: production & horizontal autoscaling (PlanetScale Postgres, Neon, Cloud SQL via `DATABASE_URL`) with a bounded connection pool speaking **PostgreSQL Wire Protocol v3** + **TLS 1.3** (`std.crypto.tls.Client`) + **SCRAM-SHA-256** directly in Zig stdlib, plus graceful `SIGTERM` drain.
- **Surgical Reactivity & Native Browser ESM**: Exact Document-ID + Index-Range read-set tracking over lexicographically encoded index keys, delivering consistent `commit_ts` RFC 6455 WebSocket transitions to a bespoke zero-dependency reactive signal & surgical DOM runtime (`/_concave/index.js`). Served straight to the browser with companion `.d.ts` declarations — **zero `npm`, zero `node_modules`, zero transpiler, zero bundler**.

## Repository Layout

```text
concave/
├── build.zig              # Builds zero-dep `libhost.a`, `concave` CLI, and Zig unit tests
├── platform/              # Roc 0.1.0_RC1 platform (`main.roc`, `Host.roc`, `targets/`)
├── packages/
│   ├── concave-sdk/       # Pure Roc SDK (`Schema`, `Key`, `Table`, `Ctx`, `Db`, `Component`, `App`)
│   ├── presence/          # Reusable pure-Roc Presence component package
│   ├── rate-limiter/      # Reusable pure-Roc Rate Limiter component package
│   └── analytics/         # Reusable pure-Roc PostHog-style Product Analytics & Feature Flags component
├── zig/
│   ├── core/              # Lexicographic key codec, Manifest, ReadSet/OCC, WalStore, PgStore (PG Wire v3 + TLS 1.3 + SCRAM-SHA-256)
│   ├── runtime/           # HTTP/1.1 + RFC 6455 WS server, subscription engine + commit_log tailer, HS256 JWT auth, HTTP Actions client
│   ├── host/              # Roc 0.1.0_RC1 C-ABI staticlib (`libhost.a`) via `ZigGlue.roc`
│   ├── codegen/           # `--introspect` JSON IR -> typed ESM + `.d.ts` (`api.js`, `api.d.ts`, `dataModel.d.ts`)
│   └── cli/               # Zero-dep `concave` CLI (`init`, `dev`, `codegen`, `build`)
├── client/
│   └── concave-client/    # Zero-dep native ESM WebSocket sync engine + signal & DOM runtime (with `.d.ts`)
├── examples/
│   └── chat-app/          # Multi-room reactive chat sample app (Roc backend + bespoke signal UI)
├── docs/                  # Architecture, wire protocol, Roc API, and Cloud Run deployment docs
└── tests/                 # End-to-end integration tests
```

## Quickstart

### Prerequisites
- [Roc `0.1.0_RC1`](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1) on `PATH`
- [Zig `0.17.1`](https://ziglang.org/download/) on `PATH`
- Node.js 22+ (only needed to run the client/E2E test runner)

### Build Host & Run Full Test Suite

```sh
make test
```

### Run the Reactive Multi-Room Chat Sample App

Single command — compiles the Roc backend with the zero-dependency Zig host, generates `api.js`, `api.d.ts`, and `dataModel.d.ts`, watches `.roc` files for hot reloads, and serves the frontend + embedded `/_concave/index.js` directly on `http://127.0.0.1:3210`:

```sh
make dev-chat
```

Open `http://127.0.0.1:3210` in two browser tabs side by side to test live index-range reactivity, typing presence, transactional rate limiting, optimistic updates, and `/preview https://example.com` Actions.

To run against PostgreSQL (e.g., PlanetScale Postgres, Neon, or local PG) instead of the embedded WAL store, set `DATABASE_URL` (and optionally `CONCAVE_DEPLOYMENT_ID`).

## Documentation

- [Architecture & Design](docs/ARCHITECTURE.md)
- [Roc API Guide](docs/ROC_API.md)
- [PostHog-Style Analytics Component](docs/ANALYTICS.md)
- [WebSocket & HTTP Wire Protocol](docs/PROTOCOL.md)
- [Deploying to Google Cloud Run + Serverless Postgres](docs/DEPLOY_CLOUD_RUN.md)
