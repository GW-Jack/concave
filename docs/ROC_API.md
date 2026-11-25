# Concave Roc API Guide (`0.1.0_RC1`)

Concave splits cleanly into two Roc layers:

1. **`packages/concave-sdk`** — Pure Roc package defining `Schema`, `Key`, `Table`, `Ctx`, `Db`, `Component`, and `App`. Reusable Components depend *only* on `concave-sdk` so they remain pure and unit-testable with `roc test`.
2. **`platform/main.roc`** — Native Roc platform linking `libhost.a` (zero-dependency Zig runtime) and providing `--serve` and `--introspect` entrypoints.

---

## 1. Schemas, Tables & Typed Indexes

System fields `id : Str` and `created_at : I64` are automatically managed by the host and merged into every returned document.

```roc
import sdk.Schema
import sdk.Table

RoomDoc : {
    id : Str,
    created_at : I64,
    name : Str,
    topic : Str,
}

rooms_table : Table(RoomDoc)
rooms_table =
    Table.define(
        "rooms",
        Schema.record([
            Schema.field("name", Schema.str),
            Schema.field("topic", Schema.str),
        ]),
    )
    |> Table.with_index("by_name", ["name"])

rooms_by_name : Table.Index(RoomDoc)
rooms_by_name = Table.index_ref(rooms_table, "by_name")
```

### `Schema` Constructors
- Primitives: `Schema.null`, `Schema.bool`, `Schema.int`, `Schema.float`, `Schema.str`, `Schema.any`
- Document IDs: `Schema.id("table")`, `Schema.scoped_id("namespace", "table")`
- Containers: `Schema.list(item)`, `Schema.optional(inner)`
- Records: `Schema.record([Schema.field("a", Schema.str), Schema.opt_field("b", Schema.int)])`
- Unions: `Schema.union([Schema.variant("Ok"), Schema.variant_with("Err", Schema.str)])`
- Document helper: `Table.doc_schema(tbl)` / `Table.doc_schema_scoped(tbl, ns)` (prepends `id` and `created_at`)

---

## 2. Static Effect Isolation (`Ctx`)

Roc's type & effect system statically enforces what each function kind can do:

| Context | Capabilities | Guarantees |
| --- | --- | --- |
| **`Ctx.QueryCtx`** | `db : DbReader`, `storage : StorageReader`, `auth!`, `now_ms!` | Read-only, deterministic snapshot, automatically reactive over WebSockets. |
| **`Ctx.MutationCtx`** | `db : DbWriter`, `scheduler : Scheduler`, `storage : StorageWriter`, `auth!`, `now_ms!` | ACID transaction with serializable OCC retries, read-your-own-writes, and atomic scheduled jobs. |
| **`Ctx.ActionCtx`** | `http_fetch!`, `http_request!`, `secrets : Secrets`, `crypto : CryptoCap`, `run_query!`, `run_mutation!`, `storage : StorageWriter`, `auth!`, `now_ms!` | Non-deterministic external HTTP/HTTPS I/O, allowlisted secrets, and host crypto; invokes transactional queries & mutations re-entrantly. |

### `AuthIdentity` & Role Helpers on `Ctx`

`Ctx.AuthIdentity` carries verified JWT / dev-token identity claims:

```roc
AuthIdentity : {
    subject : Str,
    issuer : Str,
    name : Str,
    email : Str,
    email_verified : Bool,
    session_id : Str,
    roles : List(Str),
}
```

- `Ctx.require_auth!(ctx.auth!)` — returns `Try(Ctx.AuthIdentity, Str)` (returns `Err("Unauthenticated")` if missing).
- `Ctx.has_role(id, role)` / `Ctx.has_any_role(id, roles)` — pure `Bool` checks against `id.roles`.
- `Ctx.require_role!(ctx.auth!, role)` / `Ctx.require_any_role!(ctx.auth!, roles)` — require authentication plus role membership.
- `Ctx.as_reader(ctx.db)` — derives a `DbReader` from a `DbWriter`.
- `Ctx.as_query_ctx(ctx)` — derives a `QueryCtx` from a `MutationCtx` so read helpers work in both.
- `Ctx.scope_query(ctx, ns)` / `Ctx.scope_mutation(ctx, ns)` — scopes DB access to a component's isolated namespace while staying in the same ACID transaction.

---

## 3. Database Operations (`Db` & `Key`)

### Point Reads & Writes
```roc
# Read (works directly on `ctx.db` in both QueryCtx and MutationCtx!)
maybe_doc = Db.get!(ctx.db, rooms_table, room_id)? # Found(RoomDoc) | NotFound

# Writes (MutationCtx only)
id = Db.insert!(ctx.db, rooms_table, { name: "general", topic: "Welcome" })?
_ = Db.patch!(ctx.db, rooms_table, id, { topic: "Updated topic" })?       # Err("NotFound") if missing
_ = Db.replace!(ctx.db, rooms_table, id, { name: "general", topic: "Replaced" })?
_ = Db.delete!(ctx.db, rooms_table, id)?                                  # idempotent Ok({})
```

### Indexed Range Queries
Every range scan records its exact `(namespace, table, index_name, start, end)` bounds in the transaction's `ReadSet`:

```roc
docs =
    Db.from_index(rooms_by_name)
    |> Db.gte([Key.str("a")])
    |> Db.lt([Key.str("m")])
    |> Db.asc
    |> Db.take(25)
    |> Db.collect!(ctx.db)?
```

Available query builder combinators:
- Source: `Db.query(table)` (scans `by_creation_time`) or `Db.from_index(index_ref)`
- Bounds: `Db.eq(prefix)`, `Db.gte(lower)`, `Db.gt(lower)`, `Db.lte(upper)`, `Db.lt(upper)`
- Key values: `Key.null`, `Key.bool(b)`, `Key.int(i)`, `Key.float(f)`, `Key.str(s)` (use `Key.str` for all indexed string and `Schema.id` foreign-key fields), `Key.id(id)` (system `id` tiebreaker)
- Order & limit: `Db.asc()`, `Db.desc()`, `Db.take(n)`
- Execution: `Db.collect!(db)`, `Db.collect_raw!(db)`, `Db.first!(db)` (returns `Try([Found(doc), NotFound], Str)` — register nullable endpoints with `App.query_optional` / `App.mutation_optional` so `NotFound` encodes as JSON `null` and `Found(doc)` unwraps to `doc`)

### Reactive Cursor Pagination (`Db.paginate!`)
```roc
# Returns `Try(Db.Page(doc), Str)` where `Page(doc) : { page : List(doc), next_cursor : Str, is_done : Bool }`
page =
    Db.from_index(notes_by_seq)
    |> Db.asc
    |> Db.paginate!(ctx.db, args.cursor, 20)?
```
Pass `cursor: ""` for the first page, then pass `page.next_cursor` for subsequent pages until `page.is_done == Bool.True`.

### Reactive Full-Text Search (`Db.search!`)
```roc
# Case-insensitive multi-token search over a string field; respects RYOW and tracks ReadSet!
matches = Db.search!(ctx.db, notes_table, "body", args.q, 25)?
```

---

## 4. Transactional Scheduler & Crons

Inside any `MutationCtx`:
```roc
# Scheduled atomically with the mutation (dropped automatically if the mutation returns `Err`):
job_id = Ctx.run_after!(ctx, 5000, "emails.send_welcome", { user_id: id })?
job_id2 = Ctx.run_at!(ctx, target_epoch_ms, "billing.charge", {})?
_ = Ctx.cancel_job!(ctx, job_id)?
```

Register recurring Crons on `App`:
```roc
|> App.cron("nightly_cleanup", 86400000, "maintenance.prune", "{}")
```

Scheduled jobs and crons are stored in `_system._scheduled_jobs` and claimed atomically via OCC so multi-replica clusters execute each job at most once.

---

## 5. Blob / File Storage (`Ctx` storage helpers)

- **Mutations & Actions** (`StorageWriter`):
  - `Ctx.generate_upload_url!(ctx)` -> returns an HMAC-signed local upload URL (`/_storage/upload/<token>`) or a zero-dep AWS SigV4 presigned `PUT` URL when `CONCAVE_S3_*` is configured. Clients `POST`/`PUT` bytes to the URL and receive `200 {"storage_id":"<id>"}`.
  - `Ctx.get_storage_url!(ctx, storage_id)` -> returns a download URL (`/_storage/<id>` or SigV4 presigned `GET` URL).
  - `Ctx.delete_storage!(ctx, storage_id)` -> deletes the blob.
- **Queries** (`StorageReader`):
  - `Ctx.get_storage_url!(ctx, storage_id)` -> read-only download URL lookup.

---

## 6. Outbound HTTP & Custom HTTP Routes / Webhooks

### Outbound HTTP from Actions (`Ctx.http_fetch!` & `Ctx.http_request!`)

Inside any `Ctx.ActionCtx`:
- `Ctx.http_fetch!(ctx, { method: "GET", url, body: "" })` -> `Try(Ctx.HttpResponse, Str)` (`{ status : U64, body : Str }`).
- `Ctx.http_request!(ctx, { method, url, headers, body })` -> `Try(Ctx.HttpResponseEx, Str)` (`{ status : U64, headers : List(Ctx.HttpHeader), body : Str }`), supporting arbitrary request/response headers (`{ name : Str, value : Str }`):

```roc
resp = Ctx.http_request!(ctx, {
    method: "POST",
    url: "https://api.example.com/v1/events",
    headers: [
        { name: "Authorization", value: "Bearer ${api_key}" },
        { name: "Content-Type", value: "application/json" },
    ],
    body: payload_json,
})?
```

### Custom HTTP Routes (`App.http_route` & `App.http_route_with_headers`)

Route handlers receive `Ctx.ActionCtx` and `App.HttpRouteRequest` (`{ method, path, query, body, content_type, headers : List(App.HttpHeader) }`). Use `App.header_value(req, "stripe-signature")` for case-insensitive request header lookup.

- `App.http_route(method, path, handler!)` returns `Try(App.HttpRouteResponse, Str)` (`{ status, content_type, body }`).
- `App.http_route_with_headers(method, path, handler!)` returns `Try(App.HttpRouteResponseEx, Str)` (`{ status, content_type, headers : List(App.HttpHeader), body }`) for setting `Location`, `Set-Cookie`, `Cache-Control`, etc.
- Component-scoped variants `App.component_http_route`, `App.component_http_route_with_headers`, `App.component_action`, and `App.component_internal_action` bind the route or action to a component's namespace so secret allowlists are isolated per component.

```roc
stripe_webhook! : Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponse, Str)
stripe_webhook! = |ctx, req| {
    sig = match App.header_value(req, "stripe-signature") {
        Ok(v) => v
        Err(NotFound) => return Err("Missing signature")
    }
    secret = Ctx.secret_get!(ctx, "STRIPE_WEBHOOK_SECRET")?
    hmac! = ctx.crypto.hmac_sha256!
    ct_eq! = ctx.crypto.ct_eq!
    expected = hmac!(secret, req.body)?
    if !ct_eq!(sig, expected)? {
        return Err("Invalid webhook signature")
    }
    _ = Ctx.run_mutation_raw!(ctx, "billing.handle_event", req.body)?
    Ok({ status: 200, content_type: "application/json", body: "{\"ok\":true}" })
}

# Exact or trailing `*` prefix paths; method `"*"` matches any HTTP method:
|> App.http_route("POST", "/webhooks/stripe", stripe_webhook!)
|> App.http_route_with_headers("GET", "/redirect/*", redirect_handler!)
```

---

## 7. Action Secrets Capability (`ctx.secrets`)

Secrets are available **only** inside `Ctx.ActionCtx` (Actions and HTTP routes) — never in Queries or Mutations — and are statically enforced against per-namespace allowlists declared in `AppManifest`:

```roc
concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> App.with_secret("STRIPE_WEBHOOK_SECRET")
    |> App.with_secrets(["RESEND_API_KEY", "OPENAI_API_KEY@3"])
```

- **Root app allowlist**: `App.with_secret(app, name)` / `App.with_secrets(app, names)`.
- **Component allowlist**: `Component.with_secrets(spec, names)` — strictly isolated to that component's actions and HTTP routes (root app actions cannot read a component's secrets and vice versa).
- **Reading in an Action / HTTP route**: `Ctx.secret_get!(ctx, "RESEND_API_KEY")?` (or bind `get_secret! = ctx.secrets.get!`).

### Supported Secret Reference Formats
- Short name: `"STRIPE_KEY"` -> version `"latest"` in `CONCAVE_GCP_PROJECT` (or `GOOGLE_CLOUD_PROJECT`).
- Pinned version: `"STRIPE_KEY@3"` -> version `"3"`.
- Full Google Cloud Secret Manager resource path: `"projects/<proj>/secrets/<name>/versions/<ver>"`.

### Resolution Precedence & Bootstrap (`gcp-secret://...`)
1. In-memory TTL cache (5-minute default, zeroized on eviction/shutdown).
2. Mounted tmpfs directory: `CONCAVE_SECRETS_DIR/<name>` (e.g. Cloud Run `--set-secrets=/run/secrets/...`).
3. Google Cloud Secret Manager REST API (`CONCAVE_GCP_PROJECT`, authenticating via `GOOGLE_APPLICATION_CREDENTIALS`, ADC, or GCE/Cloud Run metadata server).
4. Offline encrypted local dev vault (`CONCAVE_SECRETS_VAULT`, XChaCha20-Poly1305 + PBKDF2-HMAC-SHA256, managed via `concave secrets set|list|delete`).

Bootstrap server env vars (`DATABASE_URL`, `CONCAVE_JWT_SECRET`, `CONCAVE_JWT_ED25519_PUBLIC_KEY`, `CONCAVE_STORAGE_SECRET`, `CONCAVE_ADMIN_KEY`, `CONCAVE_OPERATOR_TOKEN`) also accept `"gcp-secret://<ref>"` values, which are resolved through the same provider at startup.

---

## 8. Action Crypto Capability (`ctx.crypto`)

Zero-dependency host cryptography is available on `Ctx.ActionCtx` (`ctx.crypto : Ctx.CryptoCap`) backed by Zig's `std.crypto`. Remember to bind record-field functions to a local variable (`f! = ctx.crypto.sha256!`) before calling them in Roc `0.1.0_RC1`:

| Field | Signature | Behavior |
| --- | --- | --- |
| `random_bytes!` | `U64 => Try(Str, Str)` | CSPRNG `1..=1024` bytes encoded as unpadded base64url. |
| `sha256!` | `Str => Try(Str, Str)` | Lowercase hex SHA-256 digest. |
| `sha256_b64url!` | `Str => Try(Str, Str)` | Unpadded base64url SHA-256 digest (ideal for PKCE S256). |
| `hmac_sha256!` | `Str, Str => Try(Str, Str)` | Lowercase hex HMAC-SHA-256 (`key, data`). |
| `ct_eq!` | `Str, Str => Try(Bool, Str)` | Constant-time string equality (`a, b`). |
| `hash_password!` | `Str => Try(Str, Str)` | Argon2id PHC string hash (`t=2, m=19456 KiB, p=1`). |
| `verify_password!` | `Str, Str => Try(Bool, Str)` | Constant-time Argon2id verification (`password, phc_hash`). |
| `ed25519_jwk!` | `Str, Str => Try(Str, Str)` | Derive public Ed25519 JWK JSON from 32-byte seed (hex/b64) & `kid`. |
| `jwt_sign_ed25519!` | `Str, Str, Str => Try(Str, Str)` | Sign an `EdDSA` JWT (`seed, kid, claims_json`). |
| `aead_encrypt!` | `Str, Str, Str => Try(Str, Str)` | XChaCha20-Poly1305 AEAD encrypt (`key32, plaintext, aad`) -> `"v1.<nonce>.<ct_tag>"`. |
| `aead_decrypt!` | `Str, Str, Str => Try(Str, Str)` | XChaCha20-Poly1305 AEAD decrypt (`key32, ciphertext, aad`). |

---

## 9. Capability-Injected Components

Components are pure Roc packages exposing `mount` and `attach` helpers:

```roc
app_auth = Auth.mount("auth")
app_migrations = Migrations.mount("migrations")
chat_presence = Presence.mount("presence", 30000)
send_limiter = RateLimiter.mount("rate_limit", 12, 60000)
analytics = Analytics.mount("analytics")
monitor = Monitor.mount("monitor")

concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> App.table(rooms_table)
    |> Auth.attach_with_cron(app_auth, 3600000)
    |> Migrations.attach(app_migrations)
    |> Presence.attach(chat_presence)
    |> RateLimiter.attach(send_limiter)
    |> Analytics.attach(analytics)
    |> Monitor.attach_with_cron(monitor, 30000, 3600000)
    |> App.query("rooms.list", Schema.record([]), Schema.list(Table.doc_schema(rooms_table)), list_rooms!)
```

Multiple instances of the same component can be mounted under distinct namespaces with host-enforced table and secret isolation inside the same ACID transaction.

---

## 10. Roc `0.1.0_RC1` Serialization & Syntax Notes

Keep these Roc `0.1.0_RC1` quirks in mind when writing handlers and polymorphic `Json.Encodable` calls (`Db.insert!`, `Db.patch!`, `Ctx.run_query!`, `Ctx.run_mutation!`, `Ctx.run_after!`):

- **Use `Bool.True` / `Bool.False` inside polymorphic record literals**: Plain `True`/`False` are open tag literals unless constrained to `Bool`. Inside inline records passed to `Db.insert!`, `Db.patch!`, or `Ctx.run_mutation!`, write `Bool.True` / `Bool.False` so JSON encodes `true`/`false` instead of `"True"`/`"False"`.
- **Single-field records require an explicit colon**: Write `{ id: id }` or `{ email: email }` — `{ id }` without a colon is parsed as a block returning `id`!
- **Annotate integer literals when polymorphic**: Inside untyped records passed directly to `Json.Encodable` helpers (e.g. `Db.insert!` or `Ctx.run_mutation!`), use typed values (e.g. `0.I64` or a typed variable) if Roc cannot infer a concrete integer type.
- **No dot-calls on record function fields**: `ctx.http_fetch!(req)` is UFCS dispatch in Roc `0.1.0_RC1`; use `Ctx.http_fetch!(ctx, req)` or bind `f! = ctx.crypto.sha256!` first.
