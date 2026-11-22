# Production Deployment & Configuration

Concave compiles your Roc backend, zero-dependency Zig runtime, embedded `/_concave/*.js` client, and `/_dashboard` console into a **single static-PIE Linux binary** (~7.6 MB compressed `alpine:3.21` Docker image) that scales horizontally (`0 -> N` instances) on **Google Cloud Run**, Fly.io, Railway, or Kubernetes backed by PostgreSQL.

---

## How Horizontal Autoscaling Works

1. **Shared ACID Storage (Pooled Pure-Zig PG Wire v3 + TLS 1.3)**: Every replica connects to PostgreSQL (`DATABASE_URL`) via Concave's zero-dependency `PgStore` (`zig/core/pg_wire.zig`) with a bounded connection pool (`CONCAVE_PG_MAX_CONNECTIONS`), native TLS 1.3 (`sslmode=require|verify-ca|verify-full`), and SCRAM-SHA-256 authentication.
2. **Serverless Pooler Safe**: `PgStore` uses stateless queries with zero server-side prepared statements, working cleanly behind transaction-mode poolers (PlanetScale PgBouncer, Neon `-pooler`, Supabase Supavisor).
3. **Cross-Instance Reactivity & Multi-Replica Scheduler**:
   - Each instance tails `commit_log` (`CONCAVE_COMMIT_POLL_MS`) **only while WebSocket clients are connected** — zero idle DB traffic for scale-to-zero.
   - Scheduled jobs & `App.cron` entries are claimed atomically via OCC so multiple replicas never double-execute the same job.
4. **Health, Telemetry & Graceful Drain**:
   - Liveness: `GET /health`
   - Readiness (verifies DB connectivity & reports `commit_ts`): `GET /ready`
   - Operator Telemetry: `GET /_internal/metrics` (Prometheus / OpenMetrics) & `GET /_internal/status`
   - Graceful `SIGTERM` drain: closes WebSocket clients with RFC 6455 Close frames, joins background workers, and exits cleanly with code `0`.

---

## Deploying to Google Cloud Run

### 1. Provision Serverless PostgreSQL
- **PlanetScale for Postgres (GCP)** or **Neon** (using the pooled `-pooler` URL with `?sslmode=require`) or **Cloud SQL for PostgreSQL**.

### 2. Deploy with `gcloud run deploy`

```sh
gcloud run deploy concave-app \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --min-instances 0 \
  --max-instances 10 \
  --concurrency 250 \
  --timeout 3600 \
  --session-affinity \
  --set-env-vars "CONCAVE_DEPLOYMENT_ID=prod,CONCAVE_COMMIT_POLL_MS=100,CONCAVE_ALLOW_DEV_TOKENS=false,CONCAVE_LOG_FORMAT=json,CONCAVE_JWKS_URL=https://your-idp.example.com/.well-known/jwks.json,CONCAVE_JWT_ISSUER=https://your-idp.example.com,CONCAVE_JWT_AUDIENCE=concave-prod" \
  --set-secrets "DATABASE_URL=concave-database-url:latest,CONCAVE_ADMIN_KEY=concave-admin-key:latest,CONCAVE_OPERATOR_TOKEN=concave-operator-token:latest"
```

### Building a Custom App Image

```sh
docker build \
  --build-arg APP_ENTRY=backend/main.roc \
  --build-arg FRONTEND_DIR=frontend \
  -t my-concave-app .
```

---

## Complete Environment Variable Reference

### Server & Networking
| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `3210` (Docker: `8080`) | HTTP/WebSocket bind port. |
| `CONCAVE_HOST` | `0.0.0.0` if `PORT` set, else `127.0.0.1` | Bind IP address. |
| `CONCAVE_STATIC_DIR` | *(unset)* | Directory of native browser ESM frontend assets to serve. |
| `CONCAVE_PUBLIC_URL` | `http://<host>:<port>` | External base URL used when constructing local `/_storage/*` URLs. |

### Storage (`PgStore` & `WalStore`)
| Variable | Default | Description |
| --- | --- | --- |
| `DATABASE_URL` | *(unset -> embedded `WalStore`)* | PostgreSQL connection URL (`postgres://user:pass@host:5432/db?sslmode=require`). |
| `CONCAVE_DEPLOYMENT_ID` | `default` | Leading tenant/shard key across all database tables. |
| `CONCAVE_PG_MAX_CONNECTIONS` | `8` | Maximum pooled PostgreSQL connections per replica. |
| `CONCAVE_DB_PATH` | `.concave/dev.wal` | On-disk WAL file path when using embedded `WalStore`. |
| `CONCAVE_WAL_COMPACT_THRESHOLD` | `1000` | Auto-compact WAL after N commits (`0` disables auto-compaction). |

### Reactivity & Scheduler
| Variable | Default | Description |
| --- | --- | --- |
| `CONCAVE_COMMIT_POLL_MS` | `100` | Cross-instance `commit_log` poll interval in ms (`0` to disable). |
| `CONCAVE_SCHEDULER_POLL_MS` | `200` | Background scheduler & cron poll interval in ms (`0` to disable). |

### Authentication & Access Control
| Variable | Default | Description |
| --- | --- | --- |
| `CONCAVE_ALLOW_DEV_TOKENS` | `true` | Set to `false` in production to reject `dev:*` tokens and disable unauthenticated `/_admin/*` & `/_internal/*`. |
| `CONCAVE_JWT_SECRET` | *(unset)* | Shared secret for verifying `HS256` JWTs. |
| `CONCAVE_JWKS_URL` | *(unset)* | Live JWKS endpoint URL for `RS256`, `EdDSA` (Ed25519), and `ES256` (P-256) JWTs with automatic key rotation. |
| `CONCAVE_JWKS_JSON` | *(unset)* | Static inline JWKS JSON (for airgapped environments or fixed keys). |
| `CONCAVE_JWT_ISSUER` | *(unset)* | Required `iss` claim value on verified JWTs. |
| `CONCAVE_JWT_AUDIENCE` | *(unset)* | Required `aud` claim value (string or array element) on verified JWTs. |
| `CONCAVE_ADMIN_KEY` | *(unset)* | Bearer token (or `?key=`) required to access `/_admin/*` endpoints powering `/_dashboard`. |
| `CONCAVE_OPERATOR_TOKEN` | *(unset -> falls back to `CONCAVE_ADMIN_KEY`)* | Bearer token (or `?token=`) required to access `/_internal/metrics` and `/_internal/status`. |

### Blob Storage (Local & S3 / R2 / GCS SigV4)
| Variable | Default | Description |
| --- | --- | --- |
| `CONCAVE_STORAGE_DIR` | `.concave/storage` | Local disk directory for uploaded blobs when S3 is not configured. |
| `CONCAVE_S3_ENDPOINT` | *(unset)* | S3-compatible endpoint URL (AWS S3, Cloudflare R2, GCS XML API) for zero-dep SigV4 presigned URLs. |
| `CONCAVE_S3_BUCKET` | *(unset)* | Target bucket name. |
| `CONCAVE_S3_REGION` | `auto` | Signing region (e.g. `us-east-1`, `auto` for Cloudflare R2). |
| `CONCAVE_S3_ACCESS_KEY` | *(unset)* | Access Key ID for SigV4 signing. |
| `CONCAVE_S3_SECRET_KEY` | *(unset)* | Secret Access Key for SigV4 signing. |

### Observability
| Variable | Default | Description |
| --- | --- | --- |
| `CONCAVE_LOG_FORMAT` | *(plain text)* | Set to `json` for single-line Cloud Logging-compatible structured RPC logs on `stderr`. |

---

## Production Hardening Checklist

- [ ] Set `DATABASE_URL` with `?sslmode=require` (or `verify-full`) for TLS 1.3 transport encryption.
- [ ] Set `CONCAVE_ALLOW_DEV_TOKENS=false` and configure `CONCAVE_JWKS_URL` (plus `CONCAVE_JWT_ISSUER` / `CONCAVE_JWT_AUDIENCE`) or `CONCAVE_JWT_SECRET`.
- [ ] Set `CONCAVE_ADMIN_KEY` and `CONCAVE_OPERATOR_TOKEN` via Secret Manager.
- [ ] Configure `CONCAVE_S3_*` if your app uses `ctx.storage` across stateless horizontally scaled replicas.
- [ ] Set `CONCAVE_LOG_FORMAT=json` and scrape `/_internal/metrics` from Cloud Monitoring / Prometheus.
- [ ] Enable `--session-affinity` on Cloud Run for sticky WebSocket connections.
