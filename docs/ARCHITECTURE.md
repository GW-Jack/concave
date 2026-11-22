# Concave Architecture

This document captures the aligned design decisions and technical architecture for **Concave**, a Convex-style reactive backend platform for Roc `0.1.0_RC1`.

## 1. Design Principles

1. **Authentic Roc Platform Model**: External Roc apps import Concave as a native Roc platform (`platform/main.roc` + `libhost.a`) and depend on the pure `concave-sdk` package. `roc build` produces a single self-contained native server executable per application.
2. **Capabilities & Purity**: Roc's effect system statically enforces the Convex function hierarchy:
   - `QueryCtx` — read-only DB access + `auth!` + deterministic snapshot timestamp.
   - `MutationCtx` — transactional DB read/write + `auth!` + deterministic commit time & IDs.
   - `ActionCtx` — external HTTP + invoking queries/mutations + `auth!`.
3. **Zero Roc Source Parsing**: Typed client codegen (`api.ts`, `dataModel.ts`) is driven by running the compiled app binary in `--introspect` mode, which emits a language-agnostic JSON IR of all tables, indexes, mounted components, and function input/output schemas.
4. **Roc-Native Ergonomics**: Nominal `Id(table)` types, typed `Table(doc)` and `Index(doc, key)` handles, typed Component handles, plain effectful Roc handlers (`!`, `Try`/`?`), flat pipe registration (`Concave.app() |> ...`), and Roc `0.1.0_RC1` built-in `Json` / compiler-derived `parser_for` & `encoder_for` codecs.

---

## 2. Platform / Package / Application / Component Boundary

```text
+-------------------------------------------------------------------+
|  User Application (main.roc)                                      |
|  - Imports: platform concave, pkg concave-sdk, component pkgs     |
|  - Defines: Tables, Indexes, Queries, Mutations, Actions          |
|  - Mounts: Components under explicit namespaces                   |
+----------------------------+--------------------------------------+
                             |
             +---------------+---------------+
             v                               v
+----------------------------+   +----------------------------------+
|  Pure Roc Packages         |   |  Concave Platform (platform/)    |
|  - concave-sdk             |   |  - Exposes Concave runtime entry |
|  - presence (Component)    |   |  - Declares hosted C-ABI effects |
|  - rate-limiter (Component)|   |  - Links Rust `libhost.a`        |
+----------------------------+   +---------------+------------------+
                                                 | C-ABI (`RustGlue.roc`)
                                                 v
                                 +----------------------------------+
                                 |  Rust Host & Runtime (crates/)   |
                                 |  - concave-host (FFI / worker)   |
                                 |  - concave-runtime (Axum/WS/Auth)|
                                 |  - concave-core (Storage/OCC)    |
                                 +----------------------------------+
```

### Capability-Injected Components
- Every Component is an ordinary pure Roc package depending only on `concave-sdk`.
- Components receive scoped capabilities (`QueryCtx` / `MutationCtx`) tagged with their mounted namespace (e.g., `"presence"`, `"rate_limit"`).
- Multiple instances of the same Component can be mounted under different namespaces.
- The Rust host enforces strict namespace isolation on every DB operation (`(deployment_id, namespace, table)`), while executing parent and component reads/writes inside the **same ACID transaction** and tracking all of them in the same `ReadSet`/`WriteSet`.

---

## 3. Storage Architecture (`concave-core`)

Storage is abstracted behind an async `StorageBackend` trait with two built-in implementations:
- **SQLite (`rusqlite`, WAL mode)**: zero-config local dev (`concave dev`) and fast offline integration tests.
- **PostgreSQL (`sqlx`)**: production and cloud deployments, compatible with standard Postgres, Neon, and tenant-sharded PlanetScale Postgres.

### Core 3-Table Schema
Every table includes `deployment_id` as the leading key so multi-tenant deployments can shard cleanly by `deployment_id` without distributed cross-shard 2PC:

1. **`documents`**:
   - `(deployment_id, namespace, table_name, doc_id)` -> `body_json`, `creation_time_ms`, `version`
2. **`index_entries`**:
   - `(deployment_id, namespace, table_name, index_name, encoded_key_bytes, doc_id)`
   - Ordered lexicographically using a deterministic key codec supporting `Null`, `Bool`, `Int` (order-preserving big-endian), `Float` (IEEE-754 sortable), `Str` (UTF-8 with escape-terminated framing), and `Id`.
3. **`commit_log`**:
   - `(deployment_id, commit_ts)` -> `writes_json` (compact summary of modified `(namespace, table, doc_id)` and affected old/new index keys).
   - Works identically across single-node SQLite, pooled serverless Postgres (PgBouncer transaction mode), and tenant-sharded Postgres (no reliance on `LISTEN/NOTIFY`).

An in-memory host read cache can wrap `StorageBackend` transparently using `commit_log` tailing when deploying against high-RTT remote Postgres.

---

## 4. Reactivity & OCC Consistency Engine

### Document-ID + Index-Range Read-Set Tracking
- Every `Query` executes against a consistent snapshot (`snapshot_ts`) and records a `ReadSet`:
  - Point lookups: `(namespace, table, doc_id)`
  - Index range scans: `(namespace, table, index_name, start_key_bound, end_key_bound)`
- Every `Mutation` runs inside a transaction with its own `ReadSet` + buffered `WriteSet`:
  - At commit, the host validates that no commit since `snapshot_ts` intersects the mutation's `ReadSet` (serializable **OCC**); on conflict, the mutation retries cleanly up to a bounded retry limit.
  - On commit, the host persists changes atomically, increments `commit_ts`, appends the `WriteSet` to `commit_log`, and notifies the subscription engine.
- The subscription engine checks active query subscriptions whose `ReadSet` overlaps the committed `WriteSet`, re-evaluates only affected queries at the new `commit_ts`, and pushes **consistent transition batches** (`Transition { from_ts, to_ts, updates }`) over WebSockets so clients never observe torn state across multiple active queries.

### Roc Threading & Ownership Model
Per Roc `0.1.0_RC1`'s glue contract, Roc execution and refcounted values are single-threaded per `RocHost` context. `concave-host` runs a dedicated Roc execution worker thread bridged to the async `tokio`/`axum` runtime via channels, keeping all WebSocket, HTTP, and async DB I/O non-blocking while ensuring 100% sound Roc ARC/memory management.

---

## 5. Wire Protocol & Bespoke Client Runtime (`client/concave-client`)

- **WebSocket Sync (`/ws`)**:
  - Client -> Server: `Authenticate`, `Subscribe { id, name, args }`, `Unsubscribe { id }`, `Mutation { req_id, name, args }`, `Action { req_id, name, args }`, `Ping`.
  - Server -> Client: `AuthResult`, `Transition { to_ts, updates }`, `MutationResult { req_id, result, commit_ts }`, `ActionResult { req_id, result }`, `Pong`.
- **HTTP Endpoints**:
  - `POST /api/query/:name`, `POST /api/mutation/:name`, `POST /api/action/:name`, `GET /health`.
- **Bespoke Zero-Dependency Reactive UI Runtime (`concave-client`) & Rust `oxc` TS Serving**:
  - Fine-grained reactive primitives: `signal`, `computed`, `effect`, `batch`, `createRoot`.
  - Direct server-driven query binding: `client.query(api.messages.list, () => ({ room_id: roomId() }))` returns a reactive signal with automatic resubscription, reconnect/resync, and optimistic update overlays.
  - Surgical DOM helpers (`el`, `each`, `show`, `mount`) with zero Virtual DOM and zero React dependency.
  - **Zero `npm` / zero bundler**: `concave-runtime` embeds `/_concave/{index,signals,client,dom}.ts` and transparently transpiles any `.ts` / `.tsx` file in `--static-dir` on the fly in Rust via `oxc` (`crates/concave-runtime/src/ts.rs`).

---

## 6. CLI & Developer Workflow (`concave-cli`)

- `concave init <dir>` — scaffolds a new external Concave app + frontend.
- `concave dev` — watches `.roc` files, runs `roc build`, executes `<app> --introspect` to regenerate `_generated/api.ts` and `_generated/dataModel.ts`, and supervises `<app> --serve`.
- `concave codegen` — runs `--introspect` and emits typed client bindings.
- `concave build` — builds a production standalone binary.

---

## 7. Sample Application (`examples/chat-app`)

A real-time multi-room chat application demonstrating every Concave feature:
- **Index-range reactivity**: Multiple rooms (`#general`, `#roc`, etc.) where posting in one room only invalidates subscribers of that room.
- **Mounted Components**:
  - `packages/presence` — tracks online users & typing status per room in isolated component tables.
  - `packages/rate-limiter` — enforces per-user message budgets inside the exact same ACID transaction as message insertion.
- **External Action**: URL metadata preview / slash command performing an external HTTP fetch and writing the result back via a mutation.
- **Auth**: Lightweight dev identity token (`ctx.auth!`) with pluggable JWT verification ready for production.
- **Frontend**: Multi-tab reactive UI built directly on `concave-client`'s bespoke signal & surgical DOM runtime.
