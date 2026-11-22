# Contributing to Concave

Thanks for your interest in contributing to **Concave**!

## Core Constraint: Zero External Dependencies

Concave intentionally builds with **zero third-party dependencies**:
- **Backend SDK & Components**: Pure [Roc `0.1.0_RC1`](https://github.com/roc-lang/roc/releases/tag/0.1.0_RC1) standard library.
- **Host, Runtime & CLI**: Pure [Zig `0.17.1`](https://ziglang.org/download/) standard library (`std`). No C libraries, no Cargo crates, no third-party Zig packages.
- **Client Runtime & Dev Dashboard**: Vanilla browser ESM (`.js` + `.d.ts`). No `npm`, no `node_modules`, no bundler or transpiler.

Please keep all PRs strictly within this zero-dependency boundary.

## Prerequisites

- **Roc `0.1.0_RC1`** on `PATH`
- **Zig `0.17.1`** on `PATH`
- **Node.js `22+`** (only used to run the client/E2E test runner)
- **Optional (formal proofs & Postgres differential suite)**:
  - [Lean 4](https://lean-lang.org/) (`v4.36.0`)
  - [Maude](https://github.com/maude-lang/Maude) (`3.5.1`)
  - [Z3](https://github.com/Z3Prover/z3) (`5.1.0`)
  - Docker / Colima (for `make test-pg-docker` and `Dockerfile` smoke tests)

## Running Tests

```sh
# 1. Core suite: Zig unit/DST/crash/fuzz + Roc tests + JS client tests + E2E + WS conformance + FFI stress
make test

# 2. Machine-checked formal proofs & model checks (Lean 4 + Maude + Z3)
make verify-formal

# 3. Live PostgreSQL 16 (TLS 1.3 + SCRAM-SHA-256) + PgBouncer + 2-replica differential suite
make test-pg-docker
```

## Updating the Roc Platform C-ABI

Whenever hosted effects (`platform/Host.roc`) or provided entrypoints (`platform/main.roc`) change:
1. Run `roc check platform/main.roc`.
2. Regenerate `zig/host/roc_platform_abi.zig` using `roc glue`.
3. Update the corresponding C-ABI exports in `zig/host/host.zig`.
4. Rebuild `libhost.a` with `make host` and run `make test`.

## Pull Request Checklist

- [ ] Zero third-party dependencies added.
- [ ] `make test` passes locally.
- [ ] Formal specs (`make verify-formal`) pass if you changed key encoding, `ReadSet`/`WriteSet`, OCC, signals, optimistic sync, or analytics identity/flags.
- [ ] Documentation in `README.md` and `docs/` updated for any new APIs, CLI flags, or environment variables.
