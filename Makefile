.PHONY: host host-release test test-rust test-roc test-client test-e2e codegen-chat dev-chat

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    ROC_TARGET := arm64mac
  else
    ROC_TARGET := x64mac
  endif
else
  ifeq ($(UNAME_M),aarch64)
    ROC_TARGET := arm64linux
  else
    ROC_TARGET := x64linux
  endif
endif

## Build Rust `libhost.a` and install into `platform/targets/$(ROC_TARGET)/`
host:
	cargo build -p concave-host
	mkdir -p platform/targets/$(ROC_TARGET)
	cp target/debug/libconcave_host.a platform/targets/$(ROC_TARGET)/libhost.a

## Build release `libhost.a` for production binaries
host-release:
	cargo build --release -p concave-host
	mkdir -p platform/targets/$(ROC_TARGET)
	cp target/release/libconcave_host.a platform/targets/$(ROC_TARGET)/libhost.a

test-rust:
	cargo test --workspace

test-roc:
	roc check packages/concave-sdk/main.roc
	roc test packages/concave-sdk/Schema.roc
	roc test packages/concave-sdk/Key.roc
	roc test packages/concave-sdk/Table.roc
	roc check packages/presence/main.roc
	roc test packages/presence/Presence.roc
	roc check packages/rate-limiter/main.roc
	roc test packages/rate-limiter/RateLimiter.roc
	roc check platform/main.roc
	roc check examples/chat-app/backend/main.roc

test-client:
	node --experimental-strip-types --test client/concave-client/test/signals.test.ts

test-e2e: host codegen-chat
	node --experimental-strip-types --test --test-timeout=15000 tests/e2e_chat_platform.mjs

test: test-rust test-roc test-client test-e2e

codegen-chat: host
	cargo run -p concave-cli -- codegen \
		--entry examples/chat-app/backend/main.roc \
		--out examples/chat-app/frontend/src/_generated

## Single-command live dev server: serves WebSockets, HTTP API, embedded `/_concave/*.js`, and the chat UI on :3210
dev-chat: host
	cargo run -p concave-cli -- dev \
		--entry examples/chat-app/backend/main.roc \
		--out examples/chat-app/frontend/src/_generated \
		--port 3210 \
		--db examples/chat-app/.concave/dev.db \
		--static-dir examples/chat-app/frontend
