# Auth v2 Component (`packages/auth`)

`packages/auth` is a production-grade, zero-dependency pure-Roc **Authentication & Session Management** component for Concave, modeled after Convex Auth v2.

All authentication state (`auth_sessions`, `auth_accounts`, `auth_refresh_tokens`, `auth_verification_codes`, `auth_rate_limits`, `auth_totp_factors`) lives inside the mounted component's host-enforced namespace, while your application owns its own `users` table and verifies active sessions inside the exact same ACID transactions and reactive WebSocket ReadSets.

---

## Architecture

1. **Isolated `auth_*` Tables vs. App-Owned `users` Table**:
   - The component owns 6 isolated tables under its namespace (default `"auth"`):
     - `auth_sessions` — Active & revoked sessions (`user_id`, `expires_at_ms`, `revoked_at_ms`, `user_agent`).
     - `auth_accounts` — Credential & provider linkages (`user_id`, `provider`, `provider_account_id`, `email`, `email_verified`, `name`, `secret_hash`, `roles`).
     - `auth_refresh_tokens` — SHA-256 hashed single-use rotating refresh tokens (`session_id`, `token_hash`, `parent_token_id`, `expires_at_ms`, `used_at_ms`, `revoked`).
     - `auth_verification_codes` — Hashed email OTPs, magic-link tokens, single-use OAuth2 PKCE verifiers, and 60s single-use OAuth exchange codes (`identifier`, `code_hash`, `kind`, `provider`, `verifier`, `redirect_to`, `expires_at_ms`, `consumed`).
     - `auth_rate_limits` — Per-account brute-force attempt windows and lockout timestamps (`key`, `window_start_ms`, `attempts`, `locked_until_ms`).
     - `auth_totp_factors` — Per-user RFC 6238 TOTP MFA secrets encrypted at rest with `XChaCha20-Poly1305` (`user_id`, `secret_ciphertext`, `enabled`, `last_used_step`).
   - Your root app defines its own `users` table (keyed by `id.subject`) with custom profile fields, never coupling business schemas to auth internals.
2. **Ed25519 (`EdDSA`) Signing Keys & Automatic JWKS Discovery**:
   - The component allowlists `AUTH_JWT_PRIVATE_KEY` (a 32-byte Ed25519 seed in hex or base64/base64url) scoped strictly to the `"auth"` namespace via `Component.with_secrets` — root app actions cannot read it unless explicitly allowlisted.
   - In production, provision `AUTH_JWT_PRIVATE_KEY` in Google Cloud Secret Manager (`CONCAVE_GCP_PROJECT`) or tmpfs (`CONCAVE_SECRETS_DIR`); in offline local dev, store it in the encrypted dev vault (`concave secrets set AUTH_JWT_PRIVATE_KEY --value ...`).
   - `Auth.attach` automatically serves `GET /.well-known/jwks.json` (`Cache-Control: public, max-age=300`) exposing the derived Ed25519 public JWK (`kty: "OKP"`, `crv: "Ed25519"`, `alg: "EdDSA"`). Point `CONCAVE_JWKS_URL` (or `CONCAVE_JWT_ED25519_PUBLIC_KEY`) at this key so Concave's host verifies every access JWT natively with zero external IdP required.

---

## Mounting & Configuration in Roc

```roc
app [concave_app] {
    pf: platform "./platform/main.roc",
    sdk: "./packages/concave-sdk/main.roc",
    auth: "./packages/auth/main.roc",
}

import sdk.App
import sdk.Ctx
import auth.Auth
import auth.OAuth

app_auth : Auth.Mount
app_auth =
    Auth.mount("auth")
    |> Auth.with_issuer("https://app.example.com")
    |> Auth.with_audience("my-app")
    |> Auth.with_access_ttl_ms(900000)          # 15 minutes
    |> Auth.with_reuse_window_ms(10000)         # 10-second refresh grace window
    |> Auth.with_rate_limit(5, 900000, 900000)  # 5 failures / 15m -> 15m lockout
    |> Auth.with_otp_webhook_url("https://mail.example.com/hooks/otp")
    |> Auth.with_oauth_provider(
        OAuth.github({
            client_id: "Ov23li...",
            client_secret_name: "GITHUB_CLIENT_SECRET",
            redirect_uri: "https://app.example.com/auth/oauth/github/callback",
        }),
    )

concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> Auth.attach_with_cron(app_auth, 3600000) # or Auth.attach(app_auth)
```

### Configuration Builders

| Builder / Function | Default | Description |
| --- | --- | --- |
| `Auth.mount(namespace)` | `"auth"` | Create a mount with secure production defaults (`Auth.default_config`). |
| `Auth.mount_with(namespace, cfg)` | — | Mount with an explicit `Auth.Config` record (supports customizing `refresh_ttl_ms`, `otp_ttl_ms`, `jwt_kid`, `jwks_path`, `oauth_route_prefix`, etc.). |
| `Auth.with_jwt_secret_name(m, name)` | `"AUTH_JWT_PRIVATE_KEY"` | Override the allowlisted Ed25519 seed secret name. |
| `Auth.with_issuer(m, iss)` | `"concave-auth"` | Set the JWT `iss` claim (match `CONCAVE_JWT_ISSUER`). |
| `Auth.with_audience(m, aud)` | `"concave-app"` | Set the JWT `aud` claim (match `CONCAVE_JWT_AUDIENCE`). |
| `Auth.with_access_ttl_ms(m, ms)` | `900000` (15 min) | Short-lived access JWT lifetime (minimum `1000` ms). |
| `Auth.with_reuse_window_ms(m, ms)` | `10000` (10 sec) | Grace window tolerating concurrent multi-tab/retry refresh calls with the same token before triggering replay revocation. |
| `Auth.with_rate_limit(m, max, window_ms, lockout_ms)` | `5`, `900000`, `900000` | Per-account brute-force lockout policy for password & OTP verification. |
| `Auth.with_otp_webhook_url(m, url)` | `""` | Outbound webhook URL (`POST` JSON `{ email, code, expires_at_ms }`) to deliver 6-digit email OTP codes. |
| `Auth.with_magic_link_base_url(m, url)` | `""` | Base URL used to build `magic_url` (`<base>?token=...`) for magic-link email sign-in. |
| `Auth.with_magic_link_webhook(m, url)` | `""` | Outbound webhook URL (`POST` JSON `{ email, token, magic_url, expires_at_ms }`) to deliver magic links. |
| `Auth.with_expose_otp_for_dev(m, bool)` | `False` | When `True`, returns generated OTP (`dev_code`) and magic-link (`dev_token`/`magic_url`) for local dev/testing. Keep `False` in production. |
| `Auth.with_secure_cookies(m, bool)` | `True` | Controls the `; Secure` attribute on OAuth2 CSRF state cookies (set `False` only on local `http://127.0.0.1`). |
| `Auth.with_oauth_success_redirect(m, path)` | `"/"` | Default safe relative post-OAuth redirect path. |
| `Auth.with_default_roles(m, roles)` | `["user"]` | Default `roles` list assigned to newly created accounts and embedded in access JWTs. |
| `Auth.with_oauth_provider(m, provider)` | `[]` | Register an OAuth2 + PKCE provider and automatically add `provider.client_secret_name` to the component's secret allowlist. |
| `Auth.attach(app, m)` | — | Attach tables, internal/public endpoints, JWKS route, and OAuth routes to `App`. |
| `Auth.attach_with_cron(app, m, interval_ms)` | — | Same as `Auth.attach` plus a recurring `App.cron` job invoking `<ns>._cronCleanupExpired` to prune expired codes, sessions, and old refresh tokens. |

> To customize `refresh_ttl_ms` (default `2592000000` / 30 days), `otp_ttl_ms` (default `600000` / 10 min), `jwt_kid` (default `"concave-auth-v1"`), `jwks_path` (default `"/.well-known/jwks.json"`), or `oauth_route_prefix` (default `"/auth/oauth"`), pass a full `Auth.Config` record to `Auth.mount_with`.

---

## Authentication Flows

### 1. Email + Password (Argon2id + Per-Account Lockout)
- **`<ns>.signUpPassword`** (`{ email, password, name, user_agent }`): Validates email and password length (`8..1024` bytes), hashes the password with host **Argon2id** (`t=2, m=19456 KiB, p=1`), creates the `auth_accounts`, `auth_sessions`, and hashed `auth_refresh_tokens` records atomically, and returns an `AuthTokenResult` (`{ access_token, refresh_token, session_id, user_id, expires_at_ms, email, name }`).
- **`<ns>.signInPassword`** (`{ email, password, user_agent }`): Enforces per-email brute-force rate limiting (`pw:<email>`), verifies the Argon2id hash, resets the failure counter on success, and mints a fresh session + access JWT + refresh token.

### 2. Rotating Refresh Tokens, Grace Window & Replay Revocation
- **`<ns>.refresh`** (`{ refresh_token }`):
  - **Unused token on active session**: Marks the old token `used_at_ms = now`, inserts a child refresh token (`parent_token_id`), and returns a fresh `access_token` + new `refresh_token`.
  - **Recently-used token within `reuse_window_ms` (default 10s)**: Returns a fresh `access_token` with `refresh_token: ""` without revoking the session — preventing false revocations from concurrent browser tabs or retried network requests.
  - **Replayed token outside `reuse_window_ms` (or already revoked)**: Atomically revokes the **entire session and all refresh tokens in its family**, commits the revocation, and rejects the request.

### 3. Instant Reactive Global Sign-Out & Session Management
- **`<ns>.signOut`** (`{}`): Revokes the caller's current session (`revoked_at_ms = now`) and all refresh tokens belonging to it.
- **`<ns>.signOutAll`** (`{}`): Revokes every active session for the authenticated user across all devices and browser tabs; returns the count of revoked sessions.
- **`<ns>.listSessions`** (`{}`): Reactive query returning the caller's active sessions (`{ id, user_id, created_at, expires_at_ms, user_agent, is_current }`) with all secrets redacted.
- **`<ns>.sessionStatus`** (`{}`): Reactive query subscribed by `/_concave/auth.js` (`{ active, user_id, session_id }`). Because `auth_sessions` is tracked in the WebSocket subscription's ReadSet, calling `signOut`, `signOutAll`, or triggering refresh replay revocation pushes `{ active: false }` to every connected tab immediately — without waiting for the short-lived access JWT to expire.

### 4. Email OTP Verification
- **`<ns>.requestOtp`** (`{ email }`): Generates a CSPRNG 6-digit numeric code, stores its SHA-256 hash in `auth_verification_codes` (`otp_ttl_ms` default 10 min), and optionally `POST`s `{ email, code, expires_at_ms }` to `otp_webhook_url`. Returns `{ sent, expires_at_ms, dev_code }` (`dev_code` is `""` unless `expose_otp_for_dev` is `True`).
- **`<ns>.verifyOtp`** (`{ email, code, name, user_agent }`): Enforces per-email lockout (`otp:<email>`), compares SHA-256 digests in constant time (`ctx.crypto.ct_eq!`), marks the code consumed, verifies `email_verified: True` (linking to an existing account with that email if present), and creates a new session.

### 5. Modular OAuth2 + PKCE S256
Built-in provider constructors in `auth.OAuth`:
- `OAuth.google({ client_id, client_secret_name, redirect_uri })`
- `OAuth.github({ client_id, client_secret_name, redirect_uri })`
- `OAuth.discord({ client_id, client_secret_name, redirect_uri })`
- `OAuth.custom({ id, authorize_url, token_url, userinfo_url, scopes, client_id, client_secret_name, redirect_uri })`

For each registered provider, `Auth.attach` mounts two routes under `oauth_route_prefix` (default `/auth/oauth`):
- **`GET /auth/oauth/<provider>/start?redirect_to=/dashboard`**: Generates CSPRNG `state` and PKCE `verifier`, computes `code_challenge` (`S256`), stores the hashed state + verifier in `auth_verification_codes` (10 min TTL), sets an `HttpOnly; SameSite=Lax` `concave_oauth_state` CSRF cookie (with `; Secure` unless disabled), and `302`-redirects to the provider's authorize URL. Validates `redirect_to` via `OAuth.is_safe_redirect` to prevent open redirects.
- **`GET /auth/oauth/<provider>/callback`**: Clears the state cookie, verifies `state` against the CSRF cookie in constant time (`ct_eq!`), consumes the single-use PKCE record, exchanges the code with `code_verifier` + `client_secret` (fetched from `ctx.secrets`), fetches userinfo, upserts the provider account (auto-linking by email **only** when both the provider asserts `email_verified: True` and the existing account is verified), and either:
  - For browsers: AEAD-encrypts the verified identity payload, stores a **60-second single-use exchange code** (`oauth_exchange`), and redirects (`302`, `Cache-Control: no-store`) to `<redirect_to>?oauth_code=...` without exposing access or refresh tokens in any URL. The browser redeems it once via **`<ns>.exchangeOAuthCode`** (`auth.consumeOAuthCallback()`), which strips `?oauth_code=` from history and mints the session.
  - Returns `200 application/json` (`AuthTokenResult`) directly when `Accept: application/json` is sent.

### 6. Passwordless Magic Links
- **`<ns>.requestMagicLink`** (`{ email, redirect_to }`): Rate-limited (`ml:<email>`), stores a 15-minute SHA-256 hashed single-use token, optionally POSTs `{ email, token, magic_url, expires_at_ms }` to `magic_link_webhook_url`, and returns `{ sent, expires_at_ms, dev_token, magic_url }`.
- **`<ns>.verifyMagicLink`** (`{ token, name, user_agent }`): Atomically consumes the single-use token, verifies the email account, and returns `AuthTokenResult`.
- **`GET /auth/magic-link/verify?token=...`**: Browser-friendly verification route returning either `200 application/json` (when `Accept: application/json`) or a `302` redirect to `<redirect_to>?oauth_code=...` for single-use redemption via `exchangeOAuthCode`.

### 7. Pure-Roc TOTP MFA (RFC 6238 / HMAC-SHA1)
Implemented in zero-dependency pure Roc (`auth.Totp`) compatible with Google Authenticator, 1Password, and Authy, with TOTP secrets encrypted at rest via `ctx.crypto.aead_encrypt!` (`XChaCha20-Poly1305`):
- **`<ns>.enrollTotp`** (`{}`): Requires active session; generates a 20-byte CSPRNG secret, stores the AEAD-encrypted unconfirmed factor, and returns `{ secret_base32, otpauth_uri }`.
- **`<ns>.confirmTotp`** (`{ code }`): Verifies the initial 6-digit TOTP code (±1 30s step) and enables MFA on the account.
- **`<ns>.verifyTotp`** (`{ code }`): Rate-limited verification enforcing `step > last_used_step` to block code replay within the same 30-second window.
- **`<ns>.disableTotp`** (`{ code }`): Verifies a current code and deletes the enrolled TOTP factor.

---

## Server-Side ACID Guards

Unlike stateless JWT-only verification, `Auth` provides transactional guards that check `auth_sessions` inside your query or mutation's exact ACID transaction and reactive ReadSet:

```roc
me_query! : Ctx.QueryCtx, {} => Try(MeResult, Str)
me_query! = |ctx, _| {
    # Immediately rejects still-unexpired JWTs the instant a session is revoked,
    # AND subscribes this query to the session row so live tabs update automatically!
    id = Auth.require_active_session!(app_auth, ctx)?
    found =
        Db.from_index(users_by_user_id)
        |> Db.eq([Key.str(id.subject)])
        |> Db.first!(ctx.db)?
    ...
}

upsert_profile! : Ctx.MutationCtx, UpsertProfileArgs => Try(Str, Str)
upsert_profile! = |ctx, args| {
    id = Auth.require_active_session_mut!(app_auth, ctx)?
    ...
}
```

Available server helpers on `Auth`:
- `Auth.require_active_session!(mount, ctx)` — `QueryCtx => Try(Ctx.AuthIdentity, Str)`
- `Auth.require_active_session_mut!(mount, ctx)` — `MutationCtx => Try(Ctx.AuthIdentity, Str)`
- `Auth.current_user_id!(mount, ctx)` — `QueryCtx => Try([SignedIn(Str), SignedOut], Str)`
- `Auth.current_user_id_mut!(mount, ctx)` — `MutationCtx => Try([SignedIn(Str), SignedOut], Str)`
- `Auth.get_session_status!(mount, db, session_id, now_ms)` — `DbReadable(r) => Try(Auth.SessionStatus, Str)`

---

## Browser & Node Client Helper (`/_concave/auth.js`)

The Zig host embeds `packages/auth/client.js` at `/_concave/auth.js` alongside `/_concave/index.js`:

```js
import { ConcaveClient } from "/_concave/index.js";
import { createAuth } from "/_concave/auth.js";
import { api } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin);
const auth = createAuth(client, api.auth, {
  storage: window.localStorage, // optional; defaults to in-memory only
  onSignedOut: ({ reason }) => console.log("Signed out:", reason),
});

// Redeem single-use `?oauth_code=...` on page load (strips query param via history.replaceState):
await auth.consumeOAuthCallback();

// Password sign-up / sign-in:
await auth.signUpPassword({ email: "alice@example.com", password: "correct horse", name: "Alice" });
await auth.signInPassword({ email: "alice@example.com", password: "correct horse" });

// Email OTP & Magic Links:
const otp = await auth.requestOtp("alice@example.com");
await auth.verifyOtp({ email: "alice@example.com", code: "123456" });
await auth.requestMagicLink({ email: "alice@example.com", redirect_to: "/dashboard" });

// TOTP MFA (RFC 6238):
const { secret_base32, otpauth_uri } = await auth.enrollTotp();
await auth.confirmTotp("123456");
await auth.verifyTotp("654321");

// OAuth2 PKCE redirect link:
window.location.href = auth.oauthUrl("github", { redirectTo: "/dashboard" });

// Live session list & global sign-out:
const sessions = auth.subscribeSessions();
await auth.signOut();
await auth.signOutAll();
```

`createAuth` automatically:
1. Wires a deduplicated `fetchToken` callback into `client.setTokenFetcher(...)` so `ConcaveClient` refreshes short-lived access JWTs proactively before expiry (preserving live query caches for same-user rotations).
2. Subscribes to `api.auth.sessionStatus` while authenticated and immediately clears local tokens and calls `client.setAuth(null)` if the backing session is revoked from another tab or device.
3. Exposes `sessionStatus`, `refresh`, `listSessions`, `subscribeSessions`, `oauthUrl`, `exchangeOAuthCode`, `consumeOAuthCallback`, `requestMagicLink`, `verifyMagicLink`, `enrollTotp`, `confirmTotp`, `verifyTotp`, `disableTotp`, `setTokens`, `getRefreshToken`, `getSessionId`, `getUserId`, and `dispose`.
