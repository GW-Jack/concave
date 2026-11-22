# Deploying Concave to Google Cloud Run + Serverless PostgreSQL

Concave compiles your Roc application and Rust runtime into a single Linux binary that scales horizontally (`0 -> N` instances) on **Google Cloud Run** backed by serverless PostgreSQL (**PlanetScale for Postgres** or **Neon**).

## How Horizontal Autoscaling Works

1. **Shared ACID Storage**: All Cloud Run instances connect to the same PostgreSQL database (`DATABASE_URL`) using our 3-table schema (`documents`, `index_entries`, `commit_log`), led by `deployment_id` for clean tenant-level sharding.
2. **Serverless Pooler Safe**: `PostgresStorage` sets `statement_cache_capacity(0)` and `min_connections(0)` so it works cleanly behind transaction-mode poolers (PlanetScale PgBouncer, Neon `-pooler`) and lets idle compute scale to zero.
3. **Cross-Instance Reactivity**: Each instance runs a lightweight background `commit_log` tailer (`CONCAVE_COMMIT_POLL_MS`, default `100ms`) that polls `commits_since(last_seen_ts)` **only while clients are connected** — pushing live `Transition` frames to local WebSocket subscribers when another Cloud Run replica commits a mutation, while emitting zero DB traffic when idle.
4. **Zero-`npm` Frontend Serving**: The container serves your static TypeScript frontend (`CONCAVE_STATIC_DIR=/app/frontend`) and `/_concave/*.ts` directly, stripping TS on the fly in Rust via `oxc`.
5. **Graceful Drain & Health Probes**:
   - Liveness: `GET /health`
   - Readiness (verifies DB connectivity): `GET /ready`
   - Graceful `SIGTERM` shutdown drains active connections cleanly on scale-down.

---

## Deploying to Cloud Run

### 1. Provision Serverless PostgreSQL
Pick either:
- **PlanetScale for Postgres (GCP)**: choose the same GCP region as Cloud Run (e.g., `us-central1` or `us-east1`) for ~1–3ms DB latency and a horizontal sharding path.
- **Neon**: choose `aws-us-east-1` paired with Cloud Run `us-east4` / `us-east1` for `$0` scale-to-zero dev/preview deployments, using the pooled (`-pooler`) connection string.

### 2. Deploy with `gcloud run deploy`

```sh
gcloud run deploy concave-chat \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --min-instances 0 \
  --max-instances 10 \
  --concurrency 250 \
  --timeout 3600 \
  --session-affinity \
  --set-env-vars "CONCAVE_DEPLOYMENT_ID=prod,CONCAVE_COMMIT_POLL_MS=100,CONCAVE_PG_MAX_CONNECTIONS=10,CONCAVE_ALLOW_DEV_TOKENS=true" \
  --set-secrets "DATABASE_URL=concave-database-url:latest"
```

> **Production Auth:** Set `CONCAVE_JWT_SECRET` (via Secret Manager) and `CONCAVE_ALLOW_DEV_TOKENS=false` to require signed HS256 JWTs on `ctx.auth!`.

### Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `3210` (or Cloud Run `8080`) | HTTP/WebSocket bind port |
| `CONCAVE_HOST` | `0.0.0.0` (when `PORT` set) | Bind IP address |
| `DATABASE_URL` | *(unset -> SQLite)* | PostgreSQL connection URL (Neon / PlanetScale PG / Cloud SQL) |
| `CONCAVE_DEPLOYMENT_ID` | `default` | Leading shard/tenant key for all tables |
| `CONCAVE_PG_MAX_CONNECTIONS` | `10` | Per-instance Postgres pool size |
| `CONCAVE_COMMIT_POLL_MS` | `100` | Cross-instance `commit_log` tail interval in ms (`0` to disable) |
| `CONCAVE_STATIC_DIR` | *(unset)* | Static frontend directory served with on-the-fly Rust `oxc` TS stripping |
| `CONCAVE_JWT_SECRET` | *(unset)* | HS256 secret for verifying production JWTs |
| `CONCAVE_ALLOW_DEV_TOKENS` | `true` | Set to `false` in production to reject `dev:*` tokens |

### Deploying Your Own App

Override build args to build a different Roc entrypoint and frontend directory:

```sh
docker build \
  --build-arg APP_ENTRY=backend/main.roc \
  --build-arg FRONTEND_DIR=frontend \
  -t my-concave-app .
```
