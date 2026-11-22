# Verification & Formal Proofs

Concave is verified across **three complementary layers** — from machine-checked mathematical proofs down to live Docker PostgreSQL 16 + PgBouncer + multi-replica chaos tests.

## Quick Commands

```sh
# Layer 1 & 3: Zig unit/DST/crash/fuzz + Roc tests + JS property tests + E2E + WS conformance + FFI stress
make test

# Layer 2: Machine-checked formal proofs & model checks (Lean 4, Maude, Z3)
make verify-formal

# Layer 3: Real PostgreSQL 16 (TLS 1.3 + SCRAM-SHA-256) + PgBouncer (transaction mode) + 2-replica differential test
make test-pg-docker
```

All three suites run automatically in GitHub Actions ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)).

---

## Wave 1 — Property Testing, Crash Recovery, DST & Fuzzing

| Suite | Location | What It Verifies |
| --- | --- | --- |
| **Key Codec Properties** | `zig/verify/key_props.zig` | Strict order preservation, injectivity, escape framing, prefix-upper-bound bracketing across `Int64`, IEEE-754 `Float64`, `Str` (with NUL bytes), `Bool`, `Null`, `Id`, and composite tuples. |
| **WAL Crash Recovery & Compaction** | `zig/verify/wal_crash.zig`, `zig/core/wal_store.zig` | Truncation at **every single byte offset** (torn writes), bit-flip CRC32 rejection, atomic snapshot compaction recovery, and post-recovery `verifyIndexIntegrity()`. |
| **Deterministic Simulation Testing (DST)** | `zig/verify/dst_engine.zig` | Seeded multi-replica cluster simulation comparing live WebSocket transitions against a brute-force reference oracle under concurrent OCC mutations, cross-node `commit_log` replication, and disconnects. |
| **Protocol & Auth Security + Fuzzing** | `zig/verify/protocol_fuzz.zig` | JWT algorithm-confusion (`alg:none`, wrong alg), expired `exp`, future `nbf`, tampered signatures, RFC 6455 WS fragmentation/unmasking, static path traversal (`..`, `%2e%2e`, NUL), and 6 `std.testing.fuzz` targets. |
| **Client Signal & Sync Properties** | `client/concave-client/test/property.test.mjs` | Diamond glitch-freedom, 500-mutation randomized DAG oracle, 150-step optimistic mutation + out-of-order frame + disconnect rollback state machine, and keyed DOM identity preservation. |
| **Analytics Property Suite** | `tests/property_analytics.mjs` | Randomized identity/alias merging, deterministic rollout hashing, trends/funnel/retention invariants. |

---

## Wave 2 — Machine-Checked Formal Specifications (`specs/`)

| Tool | Spec Files | Proven Guarantees (0 `sorry`, 0 counterexamples) |
| --- | --- | --- |
| **Lean 4** (`v4.36.0`) | `specs/lean/KeyCodec.lean`, `specs/lean/ReadSetSoundness.lean`, `specs/lean/AnalyticsProofs.lean` | Lexicographic order preservation & injectivity of key encoding; `prefixUpperBound` exact bracketing; `ReadSet`/`WriteSet` intersection soundness for `docGet` & `rangeScan`; RYOW transaction refinement; analytics algebraic invariants. |
| **Maude** (`3.5.1`) | `specs/maude/signals.maude`, `specs/maude/optimistic_sync.maude`, `specs/maude/concave_cluster.maude`, `specs/maude/analytics_identity.maude` | Reproduces buggy counterexamples and proves **No solution** (exhaustively verified) in fixed models for: glitch-free topological signals, optimistic sync convergence & clean disconnect rollback, multi-replica consistency, and cycle-free alias identity resolution. |
| **Z3** (`5.1.0`) | `specs/z3/key_and_occ.smt2`, `specs/z3/analytics.smt2` | Exhaustive $2^{64} \times 2^{64}$ bit-vector proofs over `Int64` and IEEE-754 `Float64` sortable encoding, `KeyBound` soundness, 2-tx OCC serializability, saturating arithmetic, variant partitioning, and trends bucket conservation (all obligations `unsat`). |
| **TLA+** | `specs/tla/ConcaveCluster.tla` | Distributed multi-replica OCC + `commit_log` tailing + client snapshot monotonicity specification. |

---

## Wave 3 — Live End-to-End, Wire Conformance, Stress & Real Postgres

| Suite | Location | What It Verifies |
| --- | --- | --- |
| **Chat Platform E2E** | `tests/e2e_chat_platform.mjs` | Compiled Roc+Zig binary: WS reactivity, index-range isolation, mounted `presence` & `rate-limiter` components, OCC retries, HTTP Actions. |
| **Platform Features E2E** | `tests/e2e_platform_features.mjs` | Transactional `ctx.scheduler` + rollback atomicity + `cancel!`, recurring `App.cron`, `App.http_route` webhooks pushing live WS updates, `ctx.storage` signed upload/download/delete, `Db.paginate!`, and reactive `Db.search!`. |
| **Production Hardening E2E** | `tests/e2e_production_hardening.mjs` | Real RSA-2048 (`RS256`), Ed25519 (`EdDSA`), and P-256 (`ES256`) JWTs against a live JWKS server with live `kid` key rotation, `/_dashboard` + `/_admin/*` key guard, and graceful `SIGTERM` drain (WS Close + exit code `0`). |
| **Analytics & Monitor E2E** | `tests/e2e_analytics.mjs`, `tests/e2e_monitor.mjs` | PostHog-style analytics + flags component, Layer 1 Prometheus/OpenMetrics telemetry, and Layer 2 error/log/metric/alert monitoring component. |
| **RFC 6455 & HTTP/1.1 Conformance** | `tests/ws_conformance.mjs` | Raw TCP socket verification of WebSocket framing, masking, fragmentation, Ping/Pong, and HTTP path-traversal defenses. |
| **Roc FFI Concurrency Stress** | `tests/stress_roc_ffi.mjs` | 12 concurrent WS clients + OCC bursts + concurrent re-entrant Actions + abrupt disconnects verifying zero deadlocks or leaks. |
| **Live PostgreSQL 16 + PgBouncer Differential** | `tests/wave3_pg_docker.mjs`, `zig/verify/pg_diff.zig` | Asserts `PgStore ≡ WalStore` over 60 randomized ACID transactions against real Docker **PostgreSQL 16 (TLS 1.3 `sslmode=require` + SCRAM-SHA-256)** and **PgBouncer (`pool_mode=transaction`)**, plus 2 live compiled Roc+Zig replicas synchronizing via `commit_log`. |
