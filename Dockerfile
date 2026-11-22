# syntax=docker/dockerfile:1
# Multi-stage zero-dependency production build for deploying any Concave Roc app
# to Google Cloud Run (or Fly.io / Railway / Cloudflare Containers) backed by
# Serverless PostgreSQL. Uses only Zig 0.17.1 + Roc 0.1.0_RC1 — zero Cargo, zero npm!

ARG APP_ENTRY=examples/chat-app/backend/main.roc
ARG FRONTEND_DIR=examples/chat-app/frontend
ARG ROC_VERSION=0.1.0_RC1
ARG ZIG_VERSION=0.17.1

FROM debian:bookworm-slim AS builder
ARG TARGETARCH
ARG APP_ENTRY
ARG FRONTEND_DIR
ARG ROC_VERSION
ARG ZIG_VERSION

WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.17.1 and Roc 0.1.0_RC1 for the container architecture (amd64 / arm64).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) \
        ZIG_ARCH="x86_64"; \
        ROC_ASSET="roc-linux_x86_64-${ROC_VERSION}.tar.gz"; \
        ROC_TARGET="x64linux" ;; \
      arm64) \
        ZIG_ARCH="aarch64"; \
        ROC_ASSET="roc-linux_arm64-${ROC_VERSION}.tar.gz"; \
        ROC_TARGET="arm64linux" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/zig /opt/roc; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ --strip-components=1 -C /opt/zig; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    curl -fsSL "https://github.com/roc-lang/roc/releases/download/${ROC_VERSION}/${ROC_ASSET}" \
      | tar -xz --strip-components=1 -C /opt/roc; \
    ln -s /opt/roc/roc /usr/local/bin/roc; \
    echo "${ROC_TARGET}" > /opt/roc-target; \
    zig version; \
    roc version

COPY . .

# 1. Build zero-dependency release Zig host (`libhost.a`) and `concave` CLI.
RUN set -eux; \
    ROC_TARGET="$(cat /opt/roc-target)"; \
    zig build -Doptimize=ReleaseSafe; \
    mkdir -p "platform/targets/${ROC_TARGET}"; \
    cp zig-out/lib/libhost.a "platform/targets/${ROC_TARGET}/libhost.a"

# 2. Compile the Roc backend + Zig host into a standalone native binary and generate typed client API.
RUN set -eux; \
    ROC_TARGET="$(cat /opt/roc-target)"; \
    mkdir -p /out/frontend; \
    roc build --opt=speed --target="${ROC_TARGET}" --output=/out/concave-server "${APP_ENTRY}"; \
    cp -r "${FRONTEND_DIR}/." /out/frontend/; \
    ./zig-out/bin/concave codegen \
      --entry "${APP_ENTRY}" \
      --out "/out/frontend/src/_generated" \
      --opt=dev

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /out/concave-server /app/concave-server
COPY --from=builder /out/frontend /app/frontend

ENV PORT=8080
ENV CONCAVE_HOST=0.0.0.0
ENV CONCAVE_STATIC_DIR=/app/frontend
ENV CONCAVE_COMMIT_POLL_MS=100

EXPOSE 8080

ENTRYPOINT ["/app/concave-server", "--serve"]
