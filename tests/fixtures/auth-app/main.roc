app [concave_app] {
    pf: platform "../../../platform/main.roc",
    sdk: "../../../packages/concave-sdk/main.roc",
    auth: "../../../packages/auth/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table
import auth.Auth
import auth.OAuth

## Mounted Auth v2 component with isolated namespace `"auth"`, Ed25519 JWKS,
## fast E2E-friendly reuse window (250ms) and lockout threshold (3 attempts),
## dev OTP exposure, and a local mock OAuth2 + PKCE provider.
app_auth : Auth.Mount
app_auth =
    Auth.mount("auth")
    |> Auth.with_issuer("concave-auth-e2e")
    |> Auth.with_audience("concave-auth-e2e-app")
    |> Auth.with_reuse_window_ms(250)
    |> Auth.with_rate_limit(3, 900000, 900000)
    |> Auth.with_expose_otp_for_dev(True)
    |> Auth.with_magic_link_base_url("http://127.0.0.1:13241/auth/magic-link/verify")
    |> Auth.with_secure_cookies(False)
    |> Auth.with_oauth_provider(
        OAuth.custom({
            id: "mock",
            authorize_url: "http://127.0.0.1:13299/authorize",
            token_url: "http://127.0.0.1:13299/token",
            userinfo_url: "http://127.0.0.1:13299/userinfo",
            scopes: ["openid", "email", "profile"],
            client_id: "mock-client-id",
            client_secret_name: "MOCK_OAUTH_SECRET",
            redirect_uri: "http://127.0.0.1:13241/auth/oauth/mock/callback",
        }),
    )

## App-owned `users` table (separate from Auth component's isolated `auth_*` tables).
UserDoc : {
    id : Str,
    created_at : I64,
    user_id : Str,
    email : Str,
    display_name : Str,
    bio : Str,
}

users_schema : Schema
users_schema = Schema.record([
    Schema.field("user_id", Schema.str),
    Schema.field("email", Schema.str),
    Schema.field("display_name", Schema.str),
    Schema.field("bio", Schema.str),
])

users_table : Table(UserDoc)
users_table =
    Table.define("users", users_schema)
    |> Table.with_index("by_user_id", ["user_id"])

users_by_user_id : Table.Index(UserDoc)
users_by_user_id = Table.index_ref(users_table, "by_user_id")

UpsertProfileArgs : {
    display_name : Str,
    bio : Str,
}

upsert_profile_args_schema : Schema
upsert_profile_args_schema = Schema.record([
    Schema.field("display_name", Schema.str),
    Schema.field("bio", Schema.str),
])

MeResult : {
    user_id : Str,
    session_id : Str,
    email : Str,
    email_verified : Bool,
    name : Str,
    display_name : Str,
    bio : Str,
}

me_result_schema : Schema
me_result_schema = Schema.record([
    Schema.field("user_id", Schema.str),
    Schema.field("session_id", Schema.str),
    Schema.field("email", Schema.str),
    Schema.field("email_verified", Schema.bool),
    Schema.field("name", Schema.str),
    Schema.field("display_name", Schema.str),
    Schema.field("bio", Schema.str),
])

## Upsert caller's profile in the app-owned `users` table inside the same ACID
## transaction as `Auth.require_active_session_mut!`.
upsert_profile! : Ctx.MutationCtx, UpsertProfileArgs => Try(Str, Str)
upsert_profile! = |ctx, args| {
    id = Auth.require_active_session_mut!(app_auth, ctx)?
    existing =
        Db.from_index(users_by_user_id)
        |> Db.eq([Key.str(id.subject)])
        |> Db.first!(ctx.db)?
    match existing {
        Found(doc) => {
            Db.patch!(ctx.db, users_table, doc.id, {
                display_name: args.display_name,
                bio: args.bio,
            })?
            Ok(doc.id)
        }
        NotFound =>
            Db.insert!(ctx.db, users_table, {
                user_id: id.subject,
                email: id.email,
                display_name: args.display_name,
                bio: args.bio,
            })
    }
}

## Reactive query verifying active session in the exact same transaction & ReadSet
## as reading the app's own `users` table. Immediately rejects still-unexpired JWTs
## once the backing session is revoked!
me_query! : Ctx.QueryCtx, {} => Try(MeResult, Str)
me_query! = |ctx, _| {
    id = Auth.require_active_session!(app_auth, ctx)?
    found =
        Db.from_index(users_by_user_id)
        |> Db.eq([Key.str(id.subject)])
        |> Db.first!(ctx.db)?
    match found {
        Found(doc) =>
            Ok({
                user_id: id.subject,
                session_id: id.session_id,
                email: id.email,
                email_verified: id.email_verified,
                name: id.name,
                display_name: doc.display_name,
                bio: doc.bio,
            })
        NotFound =>
            Ok({
                user_id: id.subject,
                session_id: id.session_id,
                email: id.email,
                email_verified: id.email_verified,
                name: id.name,
                display_name: id.name,
                bio: "",
            })
    }
}

whoami_query! : Ctx.QueryCtx, {} => Try(Str, Str)
whoami_query! = |ctx, _|
    match Auth.current_user_id!(app_auth, ctx)? {
        SignedIn(uid) => Ok(uid)
        SignedOut => Ok("")
    }

## Root app action that intentionally does NOT declare `AUTH_JWT_PRIVATE_KEY` in `App.with_secret`.
## Must be rejected by Concave's per-namespace secret allowlist isolation!
try_read_auth_secret! : Ctx.ActionCtx, {} => Try(Str, Str)
try_read_auth_secret! = |ctx, _|
    Ctx.secret_get!(ctx, "AUTH_JWT_PRIVATE_KEY")

concave_app : () -> App
concave_app = ||
    App.new("concave-auth-v2-test")
    |> App.table(users_table)
    |> Auth.attach_with_cron(app_auth, 3600000)
    |> App.mutation("users.upsertProfile", upsert_profile_args_schema, Schema.id("users"), upsert_profile!)
    |> App.query("users.me", Schema.record([]), me_result_schema, me_query!)
    |> App.query("users.whoami", Schema.record([]), Schema.str, whoami_query!)
    |> App.action("debug.tryReadAuthSecret", Schema.record([]), Schema.str, try_read_auth_secret!)
