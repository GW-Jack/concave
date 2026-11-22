# Concave

**Concave** is a Convex-style reactive backend platform for [Roc](https://www.roc-lang.org/) (`0.1.0_RC1`), backed by a native Rust host runtime, pluggable SQLite/PostgreSQL storage, fine-grained read-set reactivity with OCC transactions, capability-injected Roc Components, and a bespoke zero-dependency reactive TypeScript client runtime.

## Highlights

- **Native Roc Platform (`libhost.a`)**: `roc build` compiles your Roc backend and Concave's Rust runtime into a single standalone server executable (`--serve`, `--introspect`).
- **Static Effect Isolation**:
  - **Queries** receive read-only `Ctx.QueryCtx` (deterministic, cacheable, reactive).
  - **Mutations** receive transactional `Ctx.MutationCtx` (ACID read/write + OCC conflict detection + read-your-own-writes).
  - **Actions** receive `Ctx.ActionCtx` (external HTTP I/O + re-entrant `run_query!` / `run_mutation!`).
  - **Auth** (`ctx.auth!`) exposes pluggable HS256 JWT or lightweight dev-mode caller identity across all three.
- **Capability-Injected Components**: Reusable pure-Roc packages depending only on `concave-sdk`, mounted with explicit namespaces and enforced by the host with strict per-component table isolation inside the same ACID transaction.
- **Idiomatic Roc `0.1.0_RC1` API**: Typed `Table(doc)` and `Table.Index(doc)` handles, flat pipe registration, built-in `Json` serialization (`Json.parse` / `Json.to_str_try`), and runtime `--introspect` -> typed TypeScript codegen (`api.ts`, `dataModel.ts`) with zero Roc source parsing.
- **Pluggable Persistence**: Clean `StorageBackend` trait (`documents`, `index_entries`, `commit_log` with `deployment_id` shard key) supporting zero-config **SQLite** locally and **PostgreSQL** (Neon, PlanetScale Postgres, self-hosted via `DATABASE_URL`) in production.
- **Surgical Reactivity & Zero-`npm` TypeScript**: Exact Document-ID + Index-Range read-set tracking over lexicographically encoded index keys, delivering consistent `commit_ts` WebSocket transitions to a bespoke zero-dependency TypeScript signal & surgical DOM runtime (`/_concave/index.ts`). Concave's Rust server transpiles `.ts` files to browser ESM on the fly using `oxc` — **zero `npm`, zero `node_modules`, zero bundler**.

## Repository Layout

```text
concave/
├── platform/              # Roc 0.1.0_RC1 platform (`main.roc`, `Host.roc`, `targets/`)
├── packages/
│   ├── concave-sdk/       # Pure Roc SDK (`Schema`, `Key`, `Table`, `Ctx`, `Db`, `Component`, `App`)
│   ├── presence/          # Reusable pure-Roc Presence component package
│   └── rate-limiter/      # Reusable pure-Roc Rate Limiter component package
├── crates/
│   ├── concave-core/      # StorageBackend (SQLite + Postgres), key codec, ReadSet/OCC, commit_log
│   ├── concave-runtime/   # Axum HTTP/WS server, subscription engine, JWT/dev auth, Actions HTTP client
│   ├── concave-host/      # Roc 0.1.0_RC1 C-ABI staticlib (`libhost.a`) via `RustGlue.roc`
│   ├── concave-codegen/   # `--introspect` JSON IR -> typed TypeScript (`api.ts`, `dataModel.ts`)
│   └── concave-cli/       # `concave` CLI (`init`, `dev`, `codegen`, `build`)
├── client/
│   └── concave-client/    # Zero-dep TS WebSocket sync engine + fine-grained signal & DOM runtime
├── examples/
│   └── chat-app/          # Multi-room reactive chat sample app (Roc backend + bespoke signal UI)
├── docs/                  # Architecture, wire protocol, and Roc API documentation
└── tests/                 # End-to-end integration tests
```

## Quickstart

### Prerequisites
- [Roc `0.1.0_RC1`](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1) on `PATH`
- Rust toolchain (`cargo` / `rustc`)
- Node.js 22+

### Build Host & Run Full Test Suite

```sh
make test
```

### Run the Reactive Multi-Room Chat Sample App

Single command — starts the live-reloading Roc backend, generates typed `api.ts` & `dataModel.ts`, and serves the TypeScript frontend + embedded `/_concave/index.ts` directly on `http://127.0.0.1:3210` with on-the-fly Rust `oxc` transpilation (zero `npm`, zero `node_modules`, zero bundler):

```sh
make dev-chat
```

Open `http://127.0.0.1:3210` in two browser tabs side by side to test live index-range reactivity, typing presence, transactional rate limiting, optimistic updates, and `/preview https://example.com` Actions.

To run against PostgreSQL (e.g., Neon, PlanetScale Postgres, or local PG) instead of SQLite, set `DATABASE_URL` (and optionally `CONCAVE_DEPLOYMENT_ID`).

## Documentation

- [Architecture & Design](docs/ARCHITECTURE.md)
- [Roc API Guide](docs/ROC_API.md)
- [WebSocket & HTTP Wire Protocol](docs/PROTOCOL.md)
