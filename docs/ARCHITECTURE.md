# Concave Architecture

This document captures the aligned design decisions and technical architecture for **Concave**, a **zero-dependency**, Convex-style reactive backend platform for Roc `0.1.0_RC1` powered by Zig `0.17.1`'s standard library.

## 1. Design Principles

1. **Zero External Dependencies**: Only Roc `0.1.0_RC1` stdlib, Zig `0.17.1` stdlib, and native browser ESM (`.js` + `.d.ts`). No Cargo crates, no C libraries (no `libsqlite3`, no OpenSSL), no `npm`, no `node_modules`, no bundler.
2. **Authentic Roc Platform Model**: External Roc apps import Concave as a native Roc platform (`platform/main.roc` + `libhost.a`) and depend on the pure `concave-sdk` package. `roc build` produces a single self-contained native server executable (~1.9 MB in ReleaseSafe) per application.
3. **Capabilities & Purity**: Roc's effect system statically enforces the Convex function hierarchy:
   - `QueryCtx` — read-only DB access + `auth!` + deterministic snapshot timestamp.
   - `MutationCtx` — transactional DB read/write + `auth!` + deterministic commit time & IDs.
   - `ActionCtx` — external HTTP/HTTPS + invoking queries/mutations + `auth!`.
4. **Zero Roc Source Parsing**: Typed client codegen (`api.js`, `api.d.ts`, `dataModel.d.ts`) is driven by running the compiled app binary in `--introspect` mode, which emits a language-agnostic JSON IR of all tables, indexes, mounted components, and function input/output schemas.
5. **Roc-Native Ergonomics**: Nominal `Id(table)` types, typed `Table(doc)` and `Table.Index(doc)` handles, typed Component handles, plain effectful Roc handlers (`!`, `Try`/`?`), flat pipe registration (`App.new(...) |> ...`), and Roc `0.1.0_RC1` built-in `Json` codecs.

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
|  - rate-limiter (Component)|   |  - Links Zig `libhost.a`         |
+----------------------------+   +---------------+------------------+
                                                 | C-ABI (`ZigGlue.roc`)
                                                 v
                                 +----------------------------------+
                                 |  Zero-Dep Zig Host & Runtime     |
                                 |  - zig/host (FFI / thread lock)  |
                                 |  - zig/runtime (HTTP/WS/Auth)    |
                                 |  - zig/core (WAL + PG Wire v3)   |
                                 +----------------------------------+
```

### Capability-Injected Components
- Every Component is an ordinary pure Roc package depending only on `concave-sdk`.
- Components receive scoped capabilities (`QueryCtx` / `MutationCtx`) tagged with their mounted namespace (e.g., `"presence"`, `"rate_limit"`).
- Multiple instances of the same Component can be mounted under different namespaces.
- The Zig host enforces strict namespace isolation on every DB operation (`(deployment_id, namespace, table)`), while executing parent and component reads/writes inside the **same ACID transaction** and tracking all of them in the same `ReadSet`/`WriteSet`.

---

## 3. Storage Architecture (`zig/core/`)

Storage is abstracted behind a unified `Storage` union (`zig/core/storage.zig`) with two zero-dependency implementations:
- **`WalStore` (`zig/core/wal_store.zig`)**: Embedded crash-safe write-ahead log + ordered in-memory document & index store with atomic WAL replay/compaction for zero-config local dev (`concave dev`) and offline tests.
- **`PgStore` (`zig/core/pg_wire.zig`)**: Production and cloud deployments speaking **PostgreSQL Wire Protocol v3** directly over TCP or **TLS 1.3** (`std.crypto.tls.Client`), with **SCRAM-SHA-256**, MD5, and Cleartext auth, compatible with standard Postgres, Neon, and tenant-sharded PlanetScale Postgres.

### Core 3-Table Schema
Every table includes `deployment_id` as the leading key so multi-tenant deployments can shard cleanly by `deployment_id` without distributed cross-shard 2PC:

1. **`documents`**:
   - `(deployment_id, namespace, table_name, doc_id)` -> `body_json`, `creation_time_ms`, `version`
2. **`index_entries`**:
   - `(deployment_id, namespace, table_name, index_name, encoded_key_bytes, doc_id)`
   - Ordered lexicographically using a deterministic key codec (`zig/core/key.zig`) supporting `Null`, `Bool`, `Int` (order-preserving big-endian), `Float` (IEEE-754 sortable), `Str` (UTF-8 with escape-terminated framing), and `Id`.
3. **`commit_log`**:
   - `(deployment_id, commit_ts)` -> `writes_json` (compact summary of modified `(namespace, table, doc_id)` and affected old/new index keys).
   - Works identically across single-node `WalStore`, pooled serverless Postgres (PgBouncer transaction mode), and tenant-sharded Postgres (no reliance on `LISTEN/NOTIFY` or server-side prepared statements).

---

## 4. Reactivity & OCC Consistency Engine (`zig/runtime/engine.zig`)

### Document-ID + Index-Range Read-Set Tracking
- Every `Query` executes against a consistent snapshot (`snapshot_ts`) and records a `ReadSet`:
  - Point lookups: `(namespace, table, doc_id)`
  - Index range scans: `(namespace, table, index_name, start_key_bound, end_key_bound)`
- Every `Mutation` runs inside a transaction with its own `ReadSet` + buffered `WriteSet` + read-your-own-writes overlay:
  - At commit, the host validates that no commit since `snapshot_ts` intersects the mutation's `ReadSet` (serializable **OCC**); on conflict, the mutation retries cleanly up to 8 attempts.
  - On commit, the host persists changes atomically, increments `commit_ts`, appends the `WriteSet` to `commit_log`, and notifies the subscription engine.
- The subscription engine checks active query subscriptions whose `ReadSet` overlaps the committed `WriteSet`, re-evaluates only affected queries at the new `commit_ts`, and pushes **consistent transition batches** (`transition { to_ts, updates }`) over WebSockets so clients never observe torn state across multiple active queries.
- For horizontal autoscaling on Cloud Run, a background `commit_log` tailer polls `commitsSince(last_seen_ts)` only while WebSocket clients are connected, pushing transitions for mutations committed on sibling replicas.

### Roc Threading & Re-Entrancy Model (`zig/host/host.zig`)
Per Roc `0.1.0_RC1`'s glue contract, Roc execution is serialized via a re-entrant mutex (`g_roc_mutex` + thread-local lock depth) paired with a thread-local `TxContext` stack (`t_env_stack[16]`). This lets HTTP/WebSocket worker threads handle connections concurrently while allowing `Action` handlers to make blocking HTTP/HTTPS calls (`std.http.Client`) and re-entrantly invoke `run_query!` / `run_mutation!` cleanly on the same call stack without deadlocks.

---

## 5. Wire Protocol & Bespoke Client Runtime (`client/concave-client`)

- **WebSocket Sync (`/ws`)**:
  - Client -> Server: `authenticate`, `subscribe { sub_id, name, args }`, `unsubscribe { sub_id }`, `mutation { req_id, name, args }`, `action { req_id, name, args }`, `ping`.
  - Server -> Client: `auth_result`, `transition { to_ts, updates }`, `mutation_result { req_id, ok, value, commit_ts }`, `action_result { req_id, ok, value }`, `pong`.
- **HTTP Endpoints**:
  - `POST /api/query/:name`, `POST /api/mutation/:name`, `POST /api/action/:name`, `GET /health`, `GET /ready`.
- **Bespoke Zero-Dependency Reactive UI Runtime (`concave-client`)**:
  - Fine-grained reactive primitives: `signal`, `computed`, `effect`, `batch`, `createRoot`.
  - Direct server-driven query binding: `client.query(api.messages.list, () => ({ room_id: roomId() }))` returns a reactive signal with automatic resubscription, reconnect/resync, and optimistic update overlays.
  - Surgical DOM helpers (`el`, `each`, `show`, `mount`) with zero Virtual DOM and zero React dependency.
  - **Zero `npm` / zero bundler / zero transpiler**: `zig/runtime/server.zig` embeds `/_concave/{index,signals,client,dom}.js` via `@embedFile` and serves your frontend's native ESM `.js` + `.d.ts` files directly from `--static-dir`.

---

## 6. CLI & Developer Workflow (`zig/cli/main.zig`)

- `concave init <dir>` — scaffolds a new external Concave app + frontend.
- `concave dev` — watches `.roc` files via mtime polling, runs `roc build`, executes `<app> --introspect` to regenerate `_generated/{api.js,api.d.ts,dataModel.d.ts}`, and supervises `<app> --serve`.
- `concave codegen` — runs `--introspect` and emits typed ESM + `.d.ts` client bindings.
- `concave build` — builds a production standalone binary.

---

## 7. Sample Application (`examples/chat-app`)

A real-time multi-room chat application demonstrating every Concave feature:
- **Index-range reactivity**: Multiple rooms (`#general`, `#roc-lang`, etc.) where posting in one room only invalidates subscribers of that room.
- **Mounted Components**:
  - `packages/presence` — tracks online users & typing status per room in isolated component tables.
  - `packages/rate-limiter` — enforces per-user message budgets inside the exact same ACID transaction as message insertion.
- **External Action**: `/preview <url>` slash command performing an external HTTP/HTTPS fetch and writing the result back via a re-entrant mutation.
- **Auth**: Lightweight dev identity token (`ctx.auth!`) with HS256 JWT verification ready for production.
- **Frontend**: Multi-tab reactive UI built directly on `concave-client`'s native ESM signal & surgical DOM runtime.
