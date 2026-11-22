.PHONY: host host-release test test-zig test-roc test-client test-e2e test-ws test-stress test-pg-docker verify-formal codegen-chat dev-chat

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  ZIG_HOST_FLAGS :=
  MUSL_LIB :=
  ifeq ($(UNAME_M),arm64)
    ROC_TARGET := arm64mac
  else
    ROC_TARGET := x64mac
  endif
else
  ifeq ($(UNAME_M),aarch64)
    ROC_TARGET := arm64musl
    ZIG_HOST_FLAGS := -Dtarget=aarch64-linux-musl
    MUSL_LIB := /usr/lib/aarch64-linux-musl
  else
    ROC_TARGET := x64musl
    ZIG_HOST_FLAGS := -Dtarget=x86_64-linux-musl
    MUSL_LIB := /usr/lib/x86_64-linux-musl
  endif
endif

## Build zero-dependency Zig `libhost.a` and `concave` CLI
host:
	zig build $(ZIG_HOST_FLAGS)
	mkdir -p platform/targets/$(ROC_TARGET)
	cp zig-out/lib/libhost.a platform/targets/$(ROC_TARGET)/libhost.a
	@if [ -n "$(MUSL_LIB)" ]; then cp "$(MUSL_LIB)/rcrt1.o" "platform/targets/$(ROC_TARGET)/crt1.o" && cp "$(MUSL_LIB)/libc.a" "platform/targets/$(ROC_TARGET)/libc.a"; fi

## Build ReleaseSafe `libhost.a` and `concave` CLI for production binaries
host-release:
	zig build -Doptimize=ReleaseSafe $(ZIG_HOST_FLAGS)
	mkdir -p platform/targets/$(ROC_TARGET)
	cp zig-out/lib/libhost.a platform/targets/$(ROC_TARGET)/libhost.a
	@if [ -n "$(MUSL_LIB)" ]; then cp "$(MUSL_LIB)/rcrt1.o" "platform/targets/$(ROC_TARGET)/crt1.o" && cp "$(MUSL_LIB)/libc.a" "platform/targets/$(ROC_TARGET)/libc.a"; fi

test-zig:
	zig build test

test-roc:
	roc check packages/concave-sdk/main.roc
	roc test packages/concave-sdk/Schema.roc
	roc test packages/concave-sdk/Key.roc
	roc test packages/concave-sdk/Table.roc
	roc check packages/presence/main.roc
	roc test packages/presence/Presence.roc
	roc check packages/rate-limiter/main.roc
	roc test packages/rate-limiter/RateLimiter.roc
	roc check packages/analytics/main.roc
	roc test packages/analytics/Props.roc
	roc test packages/analytics/Hash.roc
	roc test packages/analytics/Flags.roc
	roc test packages/analytics/Insights.roc
	roc test packages/analytics/Analytics.roc
	roc check platform/main.roc
	roc check examples/chat-app/backend/main.roc
	roc check tests/fixtures/analytics-app/main.roc

test-client:
	node --test client/concave-client/test/*.test.mjs

test-e2e: host codegen-chat
	node --test --test-timeout=15000 tests/e2e_chat_platform.mjs
	node --test --test-timeout=20000 tests/e2e_analytics.mjs

test-ws: host
	node --test --test-timeout=15000 tests/ws_conformance.mjs

test-stress: host codegen-chat
	node --test --test-timeout=20000 tests/stress_roc_ffi.mjs

## Wave 3: Real PostgreSQL 16 (SCRAM-SHA-256) + PgBouncer (transaction mode) differential & 2-replica test (requires Docker)
test-pg-docker: host codegen-chat
	node --test --test-timeout=90000 tests/wave3_pg_docker.mjs

test: test-zig test-roc test-client test-e2e test-ws test-stress

## Run all Wave 2 machine-checked formal proofs & model checks (Lean 4, Maude, Z3)
verify-formal:
	lean specs/lean/KeyCodec.lean
	lean specs/lean/ReadSetSoundness.lean
	maude -no-banner specs/maude/signals.maude
	maude -no-banner specs/maude/optimistic_sync.maude
	maude -no-banner specs/maude/concave_cluster.maude
	z3 specs/z3/key_and_occ.smt2

codegen-chat: host
	./zig-out/bin/concave codegen \
		--entry examples/chat-app/backend/main.roc \
		--out examples/chat-app/frontend/src/_generated

## Single-command live dev server: serves WebSockets, HTTP API, embedded `/_concave/*.js`, and the chat UI on :3210
dev-chat: host
	./zig-out/bin/concave dev \
		--entry examples/chat-app/backend/main.roc \
		--out examples/chat-app/frontend/src/_generated \
		--port 3210 \
		--db examples/chat-app/.concave/dev.wal \
		--static-dir examples/chat-app/frontend
