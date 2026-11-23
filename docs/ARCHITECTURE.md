# Concave Architecture

This document captures the technical architecture of **Concave**, a **zero-dependency**, Convex-style reactive backend platform for Roc `0.1.0_RC1` powered by Zig `0.17.1`'s standard library.

## 1. Design Principles

1. **Zero External Dependencies**: Only Roc `0.1.0_RC1` stdlib, Zig `0.17.1` stdlib, and native browser ESM (`.js` + `.d.ts`). No Cargo crates, no C libraries (no `libsqlite3`, no OpenSSL), no `npm`, no `node_modules`, no bundler.
2. **Authentic Roc Platform Model**: External Roc apps import Concave as a native Roc platform (`platform/main.roc` + `libhost.a`) and depend on the pure `concave-sdk` package. `roc build` compiles your app and runtime into a single self-contained native server executable (~1.9 MB in `ReleaseSafe`).
3. **Capabilities & Purity**: Roc's effect system statically enforces the Convex function hierarchy:
   - `QueryCtx` — read-only DB (`get!`, `collect!`, `paginate!`, `search!`), read-only `storage.get_url!`, `auth!`, `now_ms!`.
   - `MutationCtx` — transactional DB read/write + OCC + RYOW + transactional `scheduler` + `storage` + `auth!`.
   - `ActionCtx` — external HTTP/HTTPS + re-entrant `run_query!` / `run_mutation!` + `storage` + `auth!`.
4. **Zero Roc Source Parsing**: Typed client codegen (`api.js`, `api.d.ts`, `dataModel.d.ts`) runs the compiled binary in `--introspect` mode to read its manifest JSON IR of all tables, indexes, mounted components, functions, crons, and HTTP routes.
5. **Roc-Native Ergonomics**: Typed `Table(doc)` and `Table.Index(doc)` handles, flat pipe registration (`App.new(...) |> ...`), built-in `Json` codecs, and pure-Roc capability-injected Components.

---

## 2. Platform / Package / Application / Component Boundary

```text
+-------------------------------------------------------------------+
|  User Application (main.roc)                                      |
|  - Imports: platform concave, pkg concave-sdk, component pkgs     |
|  - Defines: Tables, Indexes, Queries, Mutations, Actions,         |
|             Crons, Custom HTTP Routes                             |
|  - Mounts: Components under explicit namespaces                   |
+----------------------------+--------------------------------------+
                             |
             +---------------+---------------+
             v                               v
+----------------------------+   +----------------------------------+
|  Pure Roc Packages         |   |  Concave Platform (platform/)    |
|  - concave-sdk             |   |  - Exposes Concave runtime entry |
|  - presence                |   |  - Declares hosted C-ABI effects |
|  - rate-limiter            |   |  - Links Zig `libhost.a`         |
|  - analytics (PostHog)     |   +---------------+------------------+
|  - monitor (Observability) |                   | C-ABI (`ZigGlue.roc`)
+----------------------------+                   v
                                 +----------------------------------+
                                 |  Zero-Dep Zig Host & Runtime     |
                                 |  - zig/host (FFI, signals, drain)|
                                 |  - zig/runtime (HTTP/WS/Auth/    |
                                 |    Engine/Scheduler/Metrics)     |
                                 |  - zig/core (WAL + Pooled PG     |
                                 |    Wire v3 + BlobStore/SigV4)    |
                                 +----------------------------------+
```

### Capability-Injected Components
- Every Component is an ordinary pure Roc package depending only on `concave-sdk`.
- Components receive scoped capabilities (`Ctx.scope_query` / `Ctx.scope_mutation`) tagged with their mounted namespace (e.g., `"presence"`, `"rate_limit"`, `"analytics"`, `"monitor"`).
- Multiple instances of the same Component can be mounted under distinct namespaces.
- The Zig host enforces strict namespace isolation on every DB operation (`(deployment_id, namespace, table)`), while executing parent and component reads/writes inside the **same ACID transaction** and tracking all of them in the same `ReadSet`/`WriteSet`.

---

## 3. Storage Architecture (`zig/core/`)

Storage is abstracted behind a unified `Storage` union (`zig/core/storage.zig`) with two zero-dependency implementations:

- **`WalStore` (`zig/core/wal_store.zig`)**: Embedded crash-safe append-only write-ahead log + partitioned $O(\log N)$ binary-searched ordered indexes for zero-config local dev (`concave dev`) and single-node deployments. Uses an `RwLock` for parallel concurrent reads, zero-clone wire-JSON index streaming (`scanIndexToWireJson`), lock-free `latestCommitTs()`, **Leader-Follower WAL Group Commit** (batching concurrent writers into a single `write()` + `fsync()` outside `RwLock`), persistent open WAL file handle with in-place `<8-hex-crc32>|<json>\n` framing, torn-write truncation safety, atomic snapshot compaction (`<path>.compact.tmp` -> `fsync` -> `rename`), and a bounded sliding-window `commit_log`.
- **`PgStore` (`zig/core/pg_wire.zig`)**: Production and horizontal cloud deployments speaking **PostgreSQL Wire Protocol v3** directly over TCP or **TLS 1.3** (`std.crypto.tls.Client`, `sslmode=disable|require|verify-ca|verify-full`), with **SCRAM-SHA-256** (including mutual server signature verification), MD5, and Cleartext auth. Uses a thread-safe **bounded connection pool** (`CONCAVE_PG_MAX_CONNECTIONS`, default `8`) with automatic unhealthy-connection eviction and retry, compatible with standard Postgres, Neon, and PgBouncer transaction-mode poolers.

### Core 3-Table Schema
Every table includes `deployment_id` as the leading key so multi-tenant deployments shard cleanly by `deployment_id`:

1. **`documents`**: `(deployment_id, namespace, table_name, doc_id)` -> `body_json`, `creation_time_ms`
2. **`index_entries`**: `(deployment_id, namespace, table_name, index_name, encoded_key_bytes, doc_id)` — ordered lexicographically via `zig/core/key.zig` (formally proven in Lean 4 & Z3).
3. **`commit_log`**: `(deployment_id, commit_ts)` -> `writes_json` (pre-image & post-image affected doc IDs and index keys) — powers both serializable OCC validation and cross-instance `commit_log` tailing without `LISTEN/NOTIFY` or server-side prepared statements.

### System Tables & Blob Storage
- Built-in `"_system"` tables (`_scheduled_jobs` indexed by `by_status_run_at` & `by_cron`, and `_storage`) participate in the exact same OCC transactions as user tables.
- **`BlobStore` (`zig/core/blob_store.zig` + `zig/core/sigv4.zig`)** supports local disk storage with HMAC-SHA256 signed upload tokens (`/_storage/upload/<token>`) and zero-dep **AWS SigV4** presigned URLs for S3, Cloudflare R2, and GCS.

---

## 4. Reactivity, OCC, Scheduler & Threading (`zig/runtime/`)

### Document-ID + Index-Range Read-Set Tracking (`engine.zig`)
- Every `Query` runs against a consistent `snapshot_ts` and records exact point reads and index-range bounds in its `ReadSet` (including `Db.paginate!` and `Db.search!`).
- Every `Mutation` buffers writes with read-your-own-writes (`tx.zig`). At commit, storage validates that no commit since `snapshot_ts` intersects the mutation's `ReadSet`; conflicts automatically retry up to 8 times.
- On commit, the subscription engine re-evaluates only subscriptions whose `ReadSet` intersects the committed `WriteSet`, ensures cross-subscription snapshot consistency (preventing torn reads), and pushes atomic `transition { to_ts, updates }` batches over WebSockets.
- A background `commit_log` tailer (`CONCAVE_COMMIT_POLL_MS`) synchronizes sibling horizontal replicas while WebSocket clients are connected (zero DB polling when idle).

### Transactional Scheduler & Crons (`engine.zig`)
- `ctx.scheduler.run_after!` / `run_at!` / `cancel!` write directly to `_system._scheduled_jobs` inside the enclosing mutation's `TxContext`, guaranteeing rollback atomicity.
- A background scheduler worker (`CONCAVE_SCHEDULER_POLL_MS`) seeds manifest `App.cron` entries and claims due `"pending"` jobs via OCC (`pending` -> `running` -> `completed`/`failed`, atomically scheduling the next cron tick on completion) so multi-replica clusters never double-run jobs.

### Production Auth (`auth.zig`) & Observability (`metrics.zig`)
- Zero-dep JWT verification supports **HS256**, **RS256** (`std.crypto.Certificate.rsa`), **EdDSA** (`std.crypto.sign.Ed25519`), and **ES256** (`EcdsaP256Sha256`) backed by a thread-safe `JwksCache` with automatic `kid`-miss key rotation refresh.
- Lock-free atomic counters & latency histograms (`zig/runtime/metrics.zig`) expose Prometheus/OpenMetrics at `/_internal/metrics` and structured JSON logs (`CONCAVE_LOG_FORMAT=json`) with zero hot-path allocations.

### Roc Threading, Re-Entrancy & Graceful Drain (`zig/host/host.zig`)
- Roc `0.1.0_RC1` execution is coordinated by a re-entrant mutex (`g_roc_mutex` + thread-local depth) and `t_env_stack[16]`. Blocking I/O (`http_fetch`) and re-entrant engine calls (`run_query`, `run_mutation`) release `g_roc_mutex` before re-entering the engine to guarantee deadlock freedom.
- POSIX `SIGTERM`/`SIGINT` handlers trigger a clean drain: stop accepting new connections, send WebSocket `Close` frames to all active clients, stop & join background tailer/scheduler threads, release storage pools, and exit `0`.

---

## 5. Client Runtime, Dashboard & CLI

- **Bespoke Client Runtime (`client/concave-client`)**: Bundled, minified, and pre-gzipped at build time (`zig/tools/minify_assets.zig`) into a single **5.8 KB gzipped** zero-waterfall ESM file at `/_concave/index.js` with strong SHA-256 `ETag`/`304` caching — glitch-free push-pull signals, binary WebSocket framing (`?proto=bin`), automatic resubscription, optimistic update reconciliation, and surgical DOM helpers (`el`, `each`, `show`, `mount`).
- **Unified Multi-Protocol Transport (`server.zig`, `http2.zig`, `ws.zig`, `compress.zig`)**: Serves HTTP/1.1 Keep-Alive, HTTP/2 (`h2c` prior knowledge with RFC 7541 HPACK + comptime Huffman trie), and RFC 6455 WebSockets (`/ws`, supporting both JSON text frames and zero-JSON-envelope binary `CBIN` v1 frames) on the same port with `TCP_NODELAY`, zero-copy pre-gzipped assets, and dynamic gzip compression.
- **Zero-JSON Roc <-> Zig FFI (`host.zig`, `Db.roc`, `App.roc`)**: Uses length-prefixed `!1:` wire framing for `db_query!`/`db_paginate!`/`db_search!`, zero-clone `WalStore` wire streaming, and optional `Db.collect_raw!` + `App.query_raw` zero-parse pass-through queries.
- **Embedded Live Dev Dashboard (`client/concave-dashboard`)**: Embedded at `/_dashboard` — real-time stats, Data Browser, Function Runner + live WS subscriptions, Scheduler/Crons monitor, and HTTP Route tester.
- **Zero-Dep CLI (`zig/cli/main.zig`)**: `concave init`, `concave dev` (hot-reload + codegen + serve), `concave codegen`, and `concave build`.
