# syntax=docker/dockerfile:1
# Multi-stage zero-dependency production build for deploying any Concave Roc app
# to Google Cloud Run (or Fly.io / Railway / Cloudflare Containers) backed by
# Serverless PostgreSQL. Uses only Zig 0.17.1 + Roc 0.1.0_RC1 — zero Cargo, zero npm!

ARG APP_ENTRY=examples/chat-app/backend/main.roc
ARG FRONTEND_DIR=examples/chat-app/frontend
ARG ROC_VERSION=0.1.0_RC1
ARG ZIG_VERSION=0.17.1
# Optional pinned SHA-256 digests for reproducible / verified builds.
ARG ZIG_SHA256=""
ARG ROC_SHA256=""

FROM debian:trixie-slim AS builder
ARG TARGETARCH
ARG APP_ENTRY
ARG FRONTEND_DIR
ARG ROC_VERSION
ARG ZIG_VERSION
ARG ZIG_SHA256
ARG ROC_SHA256

WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    musl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.17.1 and Roc 0.1.0_RC1 for the container architecture (amd64 / arm64).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) \
        ZIG_ARCH="x86_64"; \
        ROC_ASSET="roc-linux_x86_64-${ROC_VERSION}.tar.gz"; \
        ROC_TARGET="x64musl" ;; \
      arm64) \
        ZIG_ARCH="aarch64"; \
        ROC_ASSET="roc-linux_arm64-${ROC_VERSION}.tar.gz"; \
        ROC_TARGET="arm64musl" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/zig /opt/roc /tmp/dl; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
      -o /tmp/dl/zig.tar.xz; \
    if [ -n "${ZIG_SHA256}" ]; then \
      echo "${ZIG_SHA256}  /tmp/dl/zig.tar.xz" | sha256sum -c -; \
    fi; \
    tar -xJf /tmp/dl/zig.tar.xz --no-same-owner --strip-components=1 -C /opt/zig; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    curl --proto '=https' --tlsv1.2 -fsSL \
      "https://github.com/roc-lang/roc/releases/download/${ROC_VERSION}/${ROC_ASSET}" \
      -o /tmp/dl/roc.tar.gz; \
    if [ -n "${ROC_SHA256}" ]; then \
      echo "${ROC_SHA256}  /tmp/dl/roc.tar.gz" | sha256sum -c -; \
    fi; \
    tar -xzf /tmp/dl/roc.tar.gz --no-same-owner --strip-components=1 -C /opt/roc; \
    rm -rf /tmp/dl; \
    ln -s /opt/roc/roc /usr/local/bin/roc; \
    echo "${ROC_TARGET}" > /opt/roc-target; \
    echo "${ZIG_ARCH}-linux-musl" > /opt/zig-target; \
    echo "/usr/lib/${ZIG_ARCH}-linux-musl" > /opt/musl-lib; \
    zig version; \
    roc version

COPY . .

# 1. Build zero-dependency static musl Zig host (`libhost.a`) and `concave` CLI.
RUN set -eux; \
    ROC_TARGET="$(cat /opt/roc-target)"; \
    ZIG_TARGET="$(cat /opt/zig-target)"; \
    MUSL_LIB="$(cat /opt/musl-lib)"; \
    zig build -Doptimize=ReleaseSafe -Dtarget="${ZIG_TARGET}"; \
    mkdir -p "platform/targets/${ROC_TARGET}"; \
    cp zig-out/lib/libhost.a "platform/targets/${ROC_TARGET}/libhost.a"; \
    cp "${MUSL_LIB}/rcrt1.o" "platform/targets/${ROC_TARGET}/crt1.o"; \
    cp "${MUSL_LIB}/libc.a" "platform/targets/${ROC_TARGET}/libc.a"

# 2. Compile the Roc backend + Zig host into a 100% static Linux binary and generate typed client API.
RUN set -eux; \
    ROC_TARGET="$(cat /opt/roc-target)"; \
    mkdir -p /out/frontend; \
    roc build --opt=speed --target="${ROC_TARGET}" --output=/out/concave-server "${APP_ENTRY}"; \
    cp -r "${FRONTEND_DIR}/." /out/frontend/; \
    find /out/frontend -mindepth 1 -name '.*' -exec rm -rf {} +; \
    ./zig-out/bin/concave codegen \
      --entry "${APP_ENTRY}" \
      --out "/out/frontend/src/_generated" \
      --opt=dev

FROM alpine:3.21 AS runtime

RUN apk add --no-cache ca-certificates \
    && addgroup -S concave \
    && adduser -S -G concave -H -s /sbin/nologin concave \
    && mkdir -p /app /data \
    && chown -R concave:concave /app /data

WORKDIR /app
COPY --from=builder --chown=concave:concave /out/concave-server /app/concave-server
COPY --from=builder --chown=concave:concave /out/frontend /app/frontend

USER concave

ENV PORT=8080
ENV CONCAVE_HOST=0.0.0.0
ENV CONCAVE_STATIC_DIR=/app/frontend
ENV CONCAVE_COMMIT_POLL_MS=100
ENV CONCAVE_ALLOW_DEV_TOKENS=false

EXPOSE 8080

ENTRYPOINT ["/app/concave-server", "--serve"]
