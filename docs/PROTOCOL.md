# Concave Wire Protocol & HTTP Reference

Concave exposes a unified **HTTP/1.1 Keep-Alive + HTTP/2 (`h2c` prior knowledge) + RFC 6455 WebSocket** server on the same port from every compiled native binary, with automatic `Content-Encoding: gzip` and `ETag` / `304 Not Modified` caching.

---

## 1. WebSocket Sync Endpoint (`GET /ws` & `GET /ws?proto=bin`)

Concave supports **both** UTF-8 JSON text frames (`opcode 0x01`, discriminated by `"type"`) and compact **CBIN v1 binary frames** (`opcode 0x02`, automatically negotiated by `ConcaveClient` via `?proto=bin` or triggered on the first binary frame). Binary framing eliminates outer JSON envelope parsing and `args` re-serialization on the server while supporting one-shot queries (`0x07` -> `0x87`) over the same persistent socket.

### Client -> Server (JSON text or CBIN v1 binary)

| Frame | Binary Tag | Fields | Description |
| --- | --- | --- | --- |
| `authenticate` | `0x01` | `token: string \| null` | Authenticates the session (`Bearer <jwt>` or `dev:<subject>:<name>`). Re-evaluates all active subscriptions under the new identity and emits a fresh `transition`. |
| `subscribe` | `0x02` | `sub_id: string`, `name: string`, `args: any` | Registers a reactive query subscription and triggers an immediate initial `transition`. |
| `unsubscribe` | `0x03` | `sub_id: string` | Removes a subscription and releases server-side `ReadSet` tracking. |
| `mutation` | `0x04` | `req_id: string`, `name: string`, `args: any` | Executes an ACID mutation (with automatic OCC conflict retries) and replies with `mutation_result`. |
| `action` | `0x05` | `req_id: string`, `name: string`, `args: any` | Executes an external Action and replies with `action_result`. |
| `ping` | `0x06` | `ts: number` | Keepalive ping; server responds with `pong`. |
| `query` | `0x07` | `req_id: string`, `name: string`, `args: any` | Executes a one-shot read-only query over the persistent WebSocket and replies with `query_result`. |

### Server -> Client

| Frame | Binary Tag | Fields | Description |
| --- | --- | --- | --- |
| `auth_result` | `0x81` | `ok: boolean`, `identity?: AuthIdentity`, `error?: string` | Result of `authenticate`. |
| `transition` | `0x83` | `to_ts: number`, `updates: QueryUpdate[]` | Consistent snapshot batch advancing all affected subscriptions for this client atomically to `to_ts`. |
| `mutation_result` | `0x84` | `req_id: string`, `ok: boolean`, `value?: any`, `error?: string`, `commit_ts?: number` | Result of a mutation, including the authoritative `commit_ts` used by clients to reconcile optimistic updates. |
| `action_result` | `0x85` | `req_id: string`, `ok: boolean`, `value?: any`, `error?: string` | Result of an Action invocation. |
| `pong` | `0x86` | `ts: number` | Response to `ping`. |
| `query_result` | `0x87` | `req_id: string`, `ok: boolean`, `value?: any`, `error?: string` | Result of a one-shot `query` call over WebSocket. |
| `error` | `0x8F` | `message: string` | Protocol-level error frame (e.g. malformed JSON or unknown binary opcode). |

On graceful server shutdown (`SIGTERM`/`SIGINT`), Concave sends an RFC 6455 WebSocket `Close` frame (`opcode 0x08`) to every connected client before exiting cleanly.

---

## 2. HTTP Endpoints

### RPC & Introspection

| Method & Path | Auth | Description |
| --- | --- | --- |
| `POST /api/query/:name` | Optional `Authorization` | Execute a Query one-shot; body is JSON args. Returns `{ "ok": true, "value": ... }` or `{ "ok": false, "error": "..." }`. |
| `POST /api/mutation/:name` | Optional `Authorization` | Execute an ACID Mutation. Returns `{ "ok": true, "value": ..., "commit_ts": N }`. |
| `POST /api/action/:name` | Optional `Authorization` | Execute an external Action. Returns `{ "ok": true, "value": ... }`. |
| `GET /api/manifest` | Public | Returns the full `--introspect` JSON manifest (`app_name`, `tables`, `components`, `functions`, `crons`, `http_routes`). |
| `GET /health` | Public | Liveness probe (`200 {"status":"ok"}`). |
| `GET /ready` | Public | Readiness probe verifying storage connectivity (`200 {"status":"ready","commit_ts":N}` or `503`). |

### Embedded Browser ESM & Dashboard

| Method & Path | Auth | Description |
| --- | --- | --- |
| `GET /_concave/{index,signals,client,dom}.js` | Public | Embedded zero-dependency browser ESM reactive client runtime. |
| `GET /_concave/analytics.js` | Public | Embedded helper for `packages/analytics`. |
| `GET /_concave/monitor.js` | Public | Embedded helper for `packages/monitor`. |
| `GET /_dashboard` | Public UI (data gated by `/_admin/*`) | Embedded zero-dependency Live Dev Dashboard (`index.html`, `styles.css`, `app.js`). |

### Admin & Operator Inspection Endpoints

| Method & Path | Guard | Description |
| --- | --- | --- |
| `GET /_admin/stats` | `CONCAVE_ADMIN_KEY` (or dev mode) | Live `commit_ts`, `active_clients`, `active_subscriptions`, plus manifest metadata. |
| `GET /_admin/table?ns=&table=&limit=` | `CONCAVE_ADMIN_KEY` (or dev mode) | Scans up to `limit` (max 500) newest documents in any root, component, or `_system` table. |
| `GET /_admin/jobs` | `CONCAVE_ADMIN_KEY` (or dev mode) | Lists `_system._scheduled_jobs` documents. |
| `GET /_internal/metrics` | `CONCAVE_OPERATOR_TOKEN` (fallback `CONCAVE_ADMIN_KEY` or dev mode) | Lock-free Prometheus / OpenMetrics runtime telemetry. |
| `GET /_internal/status` | `CONCAVE_OPERATOR_TOKEN` (fallback `CONCAVE_ADMIN_KEY` or dev mode) | Compact JSON operator health snapshot. |

### Blob Storage & Custom Routes

| Method & Path | Description |
| --- | --- |
| `POST` / `PUT /_storage/upload/:token` | Verifies HMAC-SHA256 upload token (generated by `ctx.storage.generate_upload_url!`), writes raw body + `Content-Type` to local storage, returns `{"storage_id":"..."}`. |
| `GET /_storage/:id` | Serves stored local blob bytes with original `Content-Type` (`404` if deleted/missing). |
| Custom `App.http_route` paths | Dispatched before static file fallback; supports exact or trailing `*` prefix paths and method `*` wildcards. |
| Static files (`GET /*`) | Served from `--static-dir` / `CONCAVE_STATIC_DIR` with strict percent-decoding and path-traversal rejection (`403`). |

---

## 3. Authentication Tokens (`Authorization: Bearer <token>`)

- **HS256 JWT**: Verified in constant time using `CONCAVE_JWT_SECRET`.
- **RS256 (RSA-1024/2048/3072/4096), EdDSA (Ed25519), ES256 (P-256)**: Verified against `CONCAVE_JWKS_URL` (cached with automatic `kid`-miss key rotation refresh) or static `CONCAVE_JWKS_JSON`.
- **Claims**: Validates `exp`, `nbf`, non-empty `sub`, optional `iss` (`CONCAVE_JWT_ISSUER`), and optional `aud` (`CONCAVE_JWT_AUDIENCE`, string or array). Rejects `alg: "none"` and mismatched algorithms.
- **Dev Tokens** (`dev:<subject>` or `dev:<subject>:<display_name>`): Enabled only when `CONCAVE_ALLOW_DEV_TOKENS` is not `false`/`0`.
