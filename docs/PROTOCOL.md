# Concave Wire Protocol

Concave exposes both a real-time WebSocket sync endpoint (`/ws`) and HTTP RPC endpoints (`/api/query/:name`, `/api/mutation/:name`, `/api/action/:name`, `/api/manifest`, `/health`).

## WebSocket Endpoint (`GET /ws`)

All frames are UTF-8 JSON objects discriminated by `"type"`.

### Client -> Server

| Frame | Fields | Description |
| --- | --- | --- |
| `authenticate` | `token: string \| null` | Authenticates the session (`Bearer <jwt>` or `dev:<subject>:<name>`). Re-evaluates all active subscriptions under the new identity. |
| `subscribe` | `sub_id: string`, `name: string`, `args: any` | Registers a reactive query subscription and triggers an immediate initial `transition`. |
| `unsubscribe` | `sub_id: string` | Removes a subscription and releases server-side read-set tracking. |
| `mutation` | `req_id: string`, `name: string`, `args: any` | Runs an ACID mutation (with automatic OCC conflict retries) and returns `mutation_result`. |
| `action` | `req_id: string`, `name: string`, `args: any` | Runs an external Action asynchronously and returns `action_result`. |
| `ping` | `ts: number` | Keepalive ping; server responds with `pong`. |

### Server -> Client

| Frame | Fields | Description |
| --- | --- | --- |
| `auth_result` | `ok: boolean`, `identity?: AuthIdentity`, `error?: string` | Result of `authenticate`. |
| `transition` | `to_ts: number`, `updates: QueryUpdate[]` | Consistent snapshot batch advancing all affected subscriptions for this client atomically to `to_ts`. |
| `mutation_result` | `req_id: string`, `ok: boolean`, `value?: any`, `error?: string`, `commit_ts?: number` | Result of a mutation, including the authoritative `commit_ts` used by clients to reconcile optimistic updates. |
| `action_result` | `req_id: string`, `ok: boolean`, `value?: any`, `error?: string` | Result of an Action invocation. |
| `pong` | `ts: number` | Response to `ping`. |
| `error` | `message: string` | Protocol-level error frame. |
