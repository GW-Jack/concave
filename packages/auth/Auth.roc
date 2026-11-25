import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table
import OAuth
import Token
import Totp

## Production-grade Convex Auth v2–style pure-Roc Authentication Component for Concave.
##
## Features:
## - Strictly isolated component namespace (default `"auth"`) owning 6 internal tables:
##   `auth_sessions`, `auth_accounts`, `auth_refresh_tokens`, `auth_verification_codes`,
##   `auth_rate_limits`, `auth_totp_factors`
## - App owns its own `users` table; server-side ACID helpers (`Auth.require_active_session!`,
##   `Auth.require_active_session_mut!`, `Auth.get_session_status!`, `Auth.current_user_id!`) verify
##   active sessions inside the exact same transaction as app queries & mutations
## - Google Secret Manager–backed Ed25519 signing keys (`AUTH_JWT_PRIVATE_KEY`) + `GET /.well-known/jwks.json`
## - Short-lived Ed25519 JWT access tokens + Convex Auth v2 single-use rotating refresh tokens
##   with 10-second reuse grace window and automatic full-session-family replay revocation
## - Brute-force lockout protection on password, OTP, Magic Link, and TOTP sign-in
## - Composable sign-in methods: Email + Password (Argon2id), OTP, Magic Link, Modular OAuth2 + PKCE
##   with single-use exchange code handoff, and pure-Roc RFC 6238 TOTP MFA (AEAD-encrypted at rest)
## - Instant reactive global sign-out via live-subscribed `auth.sessionStatus` query + `signOut`/`signOutAll`

Auth := [Auth].{
    # -------------------------------------------------------------------------
    # Document Types (Isolated Inside Component Namespace)
    # -------------------------------------------------------------------------

    SessionDoc : {
        id : Str,
        created_at : I64,
        user_id : Str,
        expires_at_ms : I64,
        revoked_at_ms : I64,
        user_agent : Str,
    }

    AccountDoc : {
        id : Str,
        created_at : I64,
        user_id : Str,
        provider : Str,
        provider_account_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
        secret_hash : Str,
        roles : List(Str),
    }

    RefreshTokenDoc : {
        id : Str,
        created_at : I64,
        session_id : Str,
        token_hash : Str,
        parent_token_id : Str,
        expires_at_ms : I64,
        used_at_ms : I64,
        revoked : Bool,
    }

    VerificationCodeDoc : {
        id : Str,
        created_at : I64,
        identifier : Str,
        code_hash : Str,
        kind : Str,
        provider : Str,
        verifier : Str,
        redirect_to : Str,
        expires_at_ms : I64,
        consumed : Bool,
    }

    RateLimitDoc : {
        id : Str,
        created_at : I64,
        key : Str,
        window_start_ms : I64,
        attempts : I64,
        locked_until_ms : I64,
    }

    TotpFactorDoc : {
        id : Str,
        created_at : I64,
        user_id : Str,
        secret_ciphertext : Str,
        enabled : Bool,
        last_used_step : I64,
    }

    # -------------------------------------------------------------------------
    # Public & Internal Wire Types
    # -------------------------------------------------------------------------

    SessionStatus : {
        active : Bool,
        user_id : Str,
        session_id : Str,
        expires_at_ms : I64,
        revoked_at_ms : I64,
    }

    PublicSessionStatus : {
        active : Bool,
        user_id : Str,
        session_id : Str,
    }

    PublicSession : {
        id : Str,
        user_id : Str,
        created_at : I64,
        expires_at_ms : I64,
        user_agent : Str,
        is_current : Bool,
    }

    AuthTokenResult : {
        access_token : Str,
        refresh_token : Str,
        session_id : Str,
        user_id : Str,
        expires_at_ms : I64,
        email : Str,
        name : Str,
    }

    SignUpPasswordArgs : {
        email : Str,
        password : Str,
        name : Str,
        user_agent : Str,
    }

    SignInPasswordArgs : {
        email : Str,
        password : Str,
        user_agent : Str,
    }

    RequestOtpArgs : {
        email : Str,
    }

    RequestOtpResult : {
        sent : Bool,
        expires_at_ms : I64,
        dev_code : Str,
    }

    VerifyOtpArgs : {
        email : Str,
        code : Str,
        name : Str,
        user_agent : Str,
    }

    RefreshArgs : {
        refresh_token : Str,
    }

    ExchangeOAuthCodeArgs : {
        code : Str,
        user_agent : Str,
    }

    RequestMagicLinkArgs : {
        email : Str,
        redirect_to : Str,
    }

    RequestMagicLinkResult : {
        sent : Bool,
        expires_at_ms : I64,
        dev_token : Str,
        magic_url : Str,
    }

    VerifyMagicLinkArgs : {
        token : Str,
        name : Str,
        user_agent : Str,
    }

    EnrollTotpResult : {
        secret_base32 : Str,
        otpauth_uri : Str,
    }

    TotpCodeArgs : {
        code : Str,
    }

    ConfirmTotpResult : {
        enabled : Bool,
    }

    VerifyTotpResult : {
        valid : Bool,
        step : I64,
    }

    DisableTotpResult : {
        disabled : Bool,
    }

    CleanupResult : {
        deleted_codes : I64,
        deleted_sessions : I64,
        deleted_tokens : I64,
    }

    # Internal-only wire types (never exposed on public HTTP/WS)
    RateKeyArgs : {
        key : Str,
    }

    RateCheckResult : {
        allowed : Bool,
        retry_after_ms : I64,
    }

    RateRecordResult : {
        locked : Bool,
        retry_after_ms : I64,
        attempts : I64,
    }

    FindPasswordAccountArgs : {
        email : Str,
    }

    FindPasswordAccountResult : {
        found : Bool,
        account_id : Str,
        user_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
        secret_hash : Str,
        roles : List(Str),
    }

    CreatePasswordAccountArgs : {
        email : Str,
        name : Str,
        secret_hash : Str,
        new_user_id : Str,
        refresh_token_hash : Str,
        user_agent : Str,
    }

    CreatedSessionInfo : {
        user_id : Str,
        session_id : Str,
        expires_at_ms : I64,
        email : Str,
        email_verified : Bool,
        name : Str,
        roles : List(Str),
    }

    CreateSessionArgs : {
        user_id : Str,
        refresh_token_hash : Str,
        user_agent : Str,
    }

    CreateSessionResult : {
        session_id : Str,
        expires_at_ms : I64,
    }

    RotateRefreshArgs : {
        token_hash : Str,
        new_token_hash : Str,
    }

    RotateRefreshResult : {
        outcome : Str,
        error : Str,
        user_id : Str,
        session_id : Str,
        expires_at_ms : I64,
        email : Str,
        email_verified : Bool,
        name : Str,
        roles : List(Str),
    }

    StoreCodeArgs : {
        identifier : Str,
        code_hash : Str,
        kind : Str,
        provider : Str,
        verifier : Str,
        redirect_to : Str,
        ttl_ms : I64,
    }

    FindLatestOtpArgs : {
        email : Str,
    }

    FindLatestOtpResult : {
        found : Bool,
        code_id : Str,
        code_hash : Str,
    }

    CompleteOtpArgs : {
        code_id : Str,
        email : Str,
        name : Str,
        new_user_id : Str,
        refresh_token_hash : Str,
        user_agent : Str,
    }

    ConsumeOAuthPkceArgs : {
        state_hash : Str,
        provider : Str,
    }

    ConsumeOAuthPkceResult : {
        valid : Bool,
        verifier : Str,
        redirect_to : Str,
        error : Str,
    }

    UpsertOAuthAccountArgs : {
        provider : Str,
        provider_account_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
        new_user_id : Str,
        refresh_token_hash : Str,
        user_agent : Str,
    }

    UpsertOAuthAccountOnlyArgs : {
        provider : Str,
        provider_account_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
        new_user_id : Str,
    }

    PendingExchangePayload : {
        user_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
        roles : List(Str),
    }

    ConsumeOAuthExchangeArgs : {
        code_hash : Str,
    }

    ConsumeOAuthExchangeResult : {
        valid : Bool,
        user_id : Str,
        verifier : Str,
        error : Str,
    }

    CompleteMagicLinkArgs : {
        code_hash : Str,
        name : Str,
        new_user_id : Str,
        refresh_token_hash : Str,
        user_agent : Str,
    }

    ConsumeMagicLinkAccountArgs : {
        code_hash : Str,
        name : Str,
        new_user_id : Str,
    }

    ConsumeMagicLinkAccountResult : {
        valid : Bool,
        user_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
        roles : List(Str),
        redirect_to : Str,
        error : Str,
    }

    GetTotpFactorArgs : {
        user_id : Str,
    }

    GetTotpFactorResult : {
        found : Bool,
        factor_id : Str,
        user_id : Str,
        secret_ciphertext : Str,
        enabled : Bool,
        last_used_step : I64,
    }

    UpsertPendingTotpArgs : {
        user_id : Str,
        secret_ciphertext : Str,
    }

    UpdateTotpStepArgs : {
        factor_id : Str,
        user_id : Str,
        step : I64,
    }

    DeleteTotpFactorArgs : {
        factor_id : Str,
        user_id : Str,
    }

    # -------------------------------------------------------------------------
    # Configuration & Component Mount Descriptor
    # -------------------------------------------------------------------------

    Config : {
        jwt_secret_name : Str,
        jwt_kid : Str,
        issuer : Str,
        audience : Str,
        access_ttl_ms : I64,
        refresh_ttl_ms : I64,
        reuse_window_ms : I64,
        otp_ttl_ms : I64,
        magic_link_ttl_ms : I64,
        max_failed_attempts : I64,
        rate_window_ms : I64,
        lockout_ms : I64,
        default_roles : List(Str),
        otp_webhook_url : Str,
        magic_link_base_url : Str,
        magic_link_webhook_url : Str,
        expose_otp_for_dev : Bool,
        secure_cookies : Bool,
        oauth_success_redirect : Str,
        jwks_path : Str,
        oauth_route_prefix : Str,
    }

    Mount : {
        namespace : Str,
        config : Config,
        oauth_providers : List(OAuth.ProviderConfig),
        spec : Component.ComponentSpec,
    }

    # -------------------------------------------------------------------------
    # Isolated Component Schemas & Tables
    # -------------------------------------------------------------------------

    sessions_schema : Schema
    sessions_schema = Schema.record([
        Schema.field("user_id", Schema.str),
        Schema.field("expires_at_ms", Schema.int),
        Schema.field("revoked_at_ms", Schema.int),
        Schema.field("user_agent", Schema.str),
    ])

    sessions_table : Table(SessionDoc)
    sessions_table =
        Table.define("auth_sessions", sessions_schema)
        |> Table.with_index("by_user", ["user_id"])
        |> Table.with_index("by_expires", ["expires_at_ms"])

    sessions_by_user : Table.Index(SessionDoc)
    sessions_by_user = Table.index_ref(sessions_table, "by_user")

    sessions_by_expires : Table.Index(SessionDoc)
    sessions_by_expires = Table.index_ref(sessions_table, "by_expires")

    accounts_schema : Schema
    accounts_schema = Schema.record([
        Schema.field("user_id", Schema.str),
        Schema.field("provider", Schema.str),
        Schema.field("provider_account_id", Schema.str),
        Schema.field("email", Schema.str),
        Schema.field("email_verified", Schema.bool),
        Schema.field("name", Schema.str),
        Schema.field("secret_hash", Schema.str),
        Schema.field("roles", Schema.list(Schema.str)),
    ])

    accounts_table : Table(AccountDoc)
    accounts_table =
        Table.define("auth_accounts", accounts_schema)
        |> Table.with_index("by_provider_account", ["provider", "provider_account_id"])
        |> Table.with_index("by_email", ["email"])
        |> Table.with_index("by_user", ["user_id"])

    accounts_by_provider_account : Table.Index(AccountDoc)
    accounts_by_provider_account = Table.index_ref(accounts_table, "by_provider_account")

    accounts_by_email : Table.Index(AccountDoc)
    accounts_by_email = Table.index_ref(accounts_table, "by_email")

    accounts_by_user : Table.Index(AccountDoc)
    accounts_by_user = Table.index_ref(accounts_table, "by_user")

    refresh_tokens_schema : Schema
    refresh_tokens_schema = Schema.record([
        Schema.field("session_id", Schema.str),
        Schema.field("token_hash", Schema.str),
        Schema.field("parent_token_id", Schema.str),
        Schema.field("expires_at_ms", Schema.int),
        Schema.field("used_at_ms", Schema.int),
        Schema.field("revoked", Schema.bool),
    ])

    refresh_tokens_table : Table(RefreshTokenDoc)
    refresh_tokens_table =
        Table.define("auth_refresh_tokens", refresh_tokens_schema)
        |> Table.with_index("by_token_hash", ["token_hash"])
        |> Table.with_index("by_session", ["session_id"])

    refresh_tokens_by_hash : Table.Index(RefreshTokenDoc)
    refresh_tokens_by_hash = Table.index_ref(refresh_tokens_table, "by_token_hash")

    refresh_tokens_by_session : Table.Index(RefreshTokenDoc)
    refresh_tokens_by_session = Table.index_ref(refresh_tokens_table, "by_session")

    verification_codes_schema : Schema
    verification_codes_schema = Schema.record([
        Schema.field("identifier", Schema.str),
        Schema.field("code_hash", Schema.str),
        Schema.field("kind", Schema.str),
        Schema.field("provider", Schema.str),
        Schema.field("verifier", Schema.str),
        Schema.field("redirect_to", Schema.str),
        Schema.field("expires_at_ms", Schema.int),
        Schema.field("consumed", Schema.bool),
    ])

    verification_codes_table : Table(VerificationCodeDoc)
    verification_codes_table =
        Table.define("auth_verification_codes", verification_codes_schema)
        |> Table.with_index("by_identifier_kind", ["identifier", "kind"])
        |> Table.with_index("by_code_hash", ["code_hash"])

    verification_codes_by_identifier_kind : Table.Index(VerificationCodeDoc)
    verification_codes_by_identifier_kind = Table.index_ref(verification_codes_table, "by_identifier_kind")

    verification_codes_by_code_hash : Table.Index(VerificationCodeDoc)
    verification_codes_by_code_hash = Table.index_ref(verification_codes_table, "by_code_hash")

    rate_limits_schema : Schema
    rate_limits_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("window_start_ms", Schema.int),
        Schema.field("attempts", Schema.int),
        Schema.field("locked_until_ms", Schema.int),
    ])

    rate_limits_table : Table(RateLimitDoc)
    rate_limits_table =
        Table.define("auth_rate_limits", rate_limits_schema)
        |> Table.with_index("by_key", ["key"])

    rate_limits_by_key : Table.Index(RateLimitDoc)
    rate_limits_by_key = Table.index_ref(rate_limits_table, "by_key")

    totp_factors_schema : Schema
    totp_factors_schema = Schema.record([
        Schema.field("user_id", Schema.str),
        Schema.field("secret_ciphertext", Schema.str),
        Schema.field("enabled", Schema.bool),
        Schema.field("last_used_step", Schema.int),
    ])

    totp_factors_table : Table(TotpFactorDoc)
    totp_factors_table =
        Table.define("auth_totp_factors", totp_factors_schema)
        |> Table.with_index("by_user", ["user_id"])

    totp_factors_by_user : Table.Index(TotpFactorDoc)
    totp_factors_by_user = Table.index_ref(totp_factors_table, "by_user")

    # -------------------------------------------------------------------------
    # Endpoint Wire Schemas (for Codegen & Introspection)
    # -------------------------------------------------------------------------

    auth_token_result_schema : Schema
    auth_token_result_schema = Schema.record([
        Schema.field("access_token", Schema.str),
        Schema.field("refresh_token", Schema.str),
        Schema.field("session_id", Schema.str),
        Schema.field("user_id", Schema.str),
        Schema.field("expires_at_ms", Schema.int),
        Schema.field("email", Schema.str),
        Schema.field("name", Schema.str),
    ])

    sign_up_password_args_schema : Schema
    sign_up_password_args_schema = Schema.record([
        Schema.field("email", Schema.str),
        Schema.field("password", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("user_agent", Schema.str),
    ])

    sign_in_password_args_schema : Schema
    sign_in_password_args_schema = Schema.record([
        Schema.field("email", Schema.str),
        Schema.field("password", Schema.str),
        Schema.field("user_agent", Schema.str),
    ])

    request_otp_args_schema : Schema
    request_otp_args_schema = Schema.record([
        Schema.field("email", Schema.str),
    ])

    request_otp_result_schema : Schema
    request_otp_result_schema = Schema.record([
        Schema.field("sent", Schema.bool),
        Schema.field("expires_at_ms", Schema.int),
        Schema.field("dev_code", Schema.str),
    ])

    verify_otp_args_schema : Schema
    verify_otp_args_schema = Schema.record([
        Schema.field("email", Schema.str),
        Schema.field("code", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("user_agent", Schema.str),
    ])

    refresh_args_schema : Schema
    refresh_args_schema = Schema.record([
        Schema.field("refresh_token", Schema.str),
    ])

    exchange_oauth_code_args_schema : Schema
    exchange_oauth_code_args_schema = Schema.record([
        Schema.field("code", Schema.str),
        Schema.field("user_agent", Schema.str),
    ])

    request_magic_link_args_schema : Schema
    request_magic_link_args_schema = Schema.record([
        Schema.field("email", Schema.str),
        Schema.field("redirect_to", Schema.str),
    ])

    request_magic_link_result_schema : Schema
    request_magic_link_result_schema = Schema.record([
        Schema.field("sent", Schema.bool),
        Schema.field("expires_at_ms", Schema.int),
        Schema.field("dev_token", Schema.str),
        Schema.field("magic_url", Schema.str),
    ])

    verify_magic_link_args_schema : Schema
    verify_magic_link_args_schema = Schema.record([
        Schema.field("token", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("user_agent", Schema.str),
    ])

    enroll_totp_result_schema : Schema
    enroll_totp_result_schema = Schema.record([
        Schema.field("secret_base32", Schema.str),
        Schema.field("otpauth_uri", Schema.str),
    ])

    totp_code_args_schema : Schema
    totp_code_args_schema = Schema.record([
        Schema.field("code", Schema.str),
    ])

    confirm_totp_result_schema : Schema
    confirm_totp_result_schema = Schema.record([
        Schema.field("enabled", Schema.bool),
    ])

    verify_totp_result_schema : Schema
    verify_totp_result_schema = Schema.record([
        Schema.field("valid", Schema.bool),
        Schema.field("step", Schema.int),
    ])

    disable_totp_result_schema : Schema
    disable_totp_result_schema = Schema.record([
        Schema.field("disabled", Schema.bool),
    ])

    public_session_schema : Schema
    public_session_schema = Schema.record([
        Schema.field("id", Schema.str),
        Schema.field("user_id", Schema.str),
        Schema.field("created_at", Schema.int),
        Schema.field("expires_at_ms", Schema.int),
        Schema.field("user_agent", Schema.str),
        Schema.field("is_current", Schema.bool),
    ])

    public_session_status_schema : Schema
    public_session_status_schema = Schema.record([
        Schema.field("active", Schema.bool),
        Schema.field("user_id", Schema.str),
        Schema.field("session_id", Schema.str),
    ])

    cleanup_result_schema : Schema
    cleanup_result_schema = Schema.record([
        Schema.field("deleted_codes", Schema.int),
        Schema.field("deleted_sessions", Schema.int),
        Schema.field("deleted_tokens", Schema.int),
    ])

    # -------------------------------------------------------------------------
    # Configuration Defaults & Builders
    # -------------------------------------------------------------------------

    default_config : Config
    default_config = {
        jwt_secret_name: "AUTH_JWT_PRIVATE_KEY",
        jwt_kid: "concave-auth-v1",
        issuer: "concave-auth",
        audience: "concave-app",
        access_ttl_ms: Token.default_access_ttl_ms,
        refresh_ttl_ms: Token.default_refresh_ttl_ms,
        reuse_window_ms: Token.default_reuse_window_ms,
        otp_ttl_ms: Token.default_otp_ttl_ms,
        magic_link_ttl_ms: Token.default_magic_link_ttl_ms,
        max_failed_attempts: Token.default_max_failed_attempts,
        rate_window_ms: Token.default_rate_window_ms,
        lockout_ms: Token.default_lockout_ms,
        default_roles: ["user"],
        otp_webhook_url: "",
        magic_link_base_url: "",
        magic_link_webhook_url: "",
        expose_otp_for_dev: False,
        secure_cookies: True,
        oauth_success_redirect: "/",
        jwks_path: "/.well-known/jwks.json",
        oauth_route_prefix: "/auth/oauth",
    }

    add_unique_secret : List(Str), Str -> List(Str)
    add_unique_secret = |items, name| {
        trimmed = Str.trim(name)
        if Str.is_empty(trimmed) or List.any(items, |x| x == trimmed) {
            items
        } else {
            List.append(items, trimmed)
        }
    }

    build_component_spec : Str, Config, List(OAuth.ProviderConfig) -> Component.ComponentSpec
    build_component_spec = |namespace, cfg, providers| {
        var $secrets = add_unique_secret([], cfg.jwt_secret_name)
        for p in providers {
            $secrets = add_unique_secret($secrets, p.client_secret_name)
        }
        Component.define(
            namespace,
            "concave-auth",
            [
                Table.spec(sessions_table),
                Table.spec(accounts_table),
                Table.spec(refresh_tokens_table),
                Table.spec(verification_codes_table),
                Table.spec(rate_limits_table),
                Table.spec(totp_factors_table),
            ],
        )
        |> Component.with_secrets($secrets)
    }

    ## Mount an isolated Auth v2 component under `namespace` (typically `"auth"`) with secure defaults.
    mount : Str -> Mount
    mount = |namespace| mount_with(namespace, default_config)

    ## Mount an isolated Auth v2 component with explicit `Config`.
    mount_with : Str, Config -> Mount
    mount_with = |namespace, cfg| {
        ns = if Str.is_empty(Str.trim(namespace)) { "auth" } else { Str.trim(namespace) }
        norm_cfg = {
            jwt_secret_name: if Str.is_empty(Str.trim(cfg.jwt_secret_name)) { "AUTH_JWT_PRIVATE_KEY" } else { Str.trim(cfg.jwt_secret_name) },
            jwt_kid: if Str.is_empty(Str.trim(cfg.jwt_kid)) { "concave-auth-v1" } else { Str.trim(cfg.jwt_kid) },
            issuer: if Str.is_empty(Str.trim(cfg.issuer)) { "concave-auth" } else { Str.trim(cfg.issuer) },
            audience: if Str.is_empty(Str.trim(cfg.audience)) { "concave-app" } else { Str.trim(cfg.audience) },
            access_ttl_ms: if cfg.access_ttl_ms < 1000 { Token.default_access_ttl_ms } else { cfg.access_ttl_ms },
            refresh_ttl_ms: if cfg.refresh_ttl_ms < 1000 { Token.default_refresh_ttl_ms } else { cfg.refresh_ttl_ms },
            reuse_window_ms: if cfg.reuse_window_ms < 0 { 0 } else { cfg.reuse_window_ms },
            otp_ttl_ms: if cfg.otp_ttl_ms < 1000 { Token.default_otp_ttl_ms } else { cfg.otp_ttl_ms },
            magic_link_ttl_ms: if cfg.magic_link_ttl_ms < 1000 { Token.default_magic_link_ttl_ms } else { cfg.magic_link_ttl_ms },
            max_failed_attempts: if cfg.max_failed_attempts <= 0 { Token.default_max_failed_attempts } else { cfg.max_failed_attempts },
            rate_window_ms: if cfg.rate_window_ms <= 0 { Token.default_rate_window_ms } else { cfg.rate_window_ms },
            lockout_ms: if cfg.lockout_ms <= 0 { Token.default_lockout_ms } else { cfg.lockout_ms },
            default_roles: cfg.default_roles,
            otp_webhook_url: Str.trim(cfg.otp_webhook_url),
            magic_link_base_url: Str.trim(cfg.magic_link_base_url),
            magic_link_webhook_url: Str.trim(cfg.magic_link_webhook_url),
            expose_otp_for_dev: cfg.expose_otp_for_dev,
            secure_cookies: cfg.secure_cookies,
            oauth_success_redirect: if OAuth.is_safe_redirect(cfg.oauth_success_redirect) { cfg.oauth_success_redirect } else { "/" },
            jwks_path: if Str.is_empty(Str.trim(cfg.jwks_path)) { "/.well-known/jwks.json" } else { Str.trim(cfg.jwks_path) },
            oauth_route_prefix: if Str.is_empty(Str.trim(cfg.oauth_route_prefix)) { "/auth/oauth" } else { Str.trim(cfg.oauth_route_prefix) },
        }
        {
            namespace: ns,
            config: norm_cfg,
            oauth_providers: [],
            spec: build_component_spec(ns, norm_cfg, []),
        }
    }

    update_config : Mount, Config -> Mount
    update_config = |m, cfg| {
        namespace: m.namespace,
        config: cfg,
        oauth_providers: m.oauth_providers,
        spec: build_component_spec(m.namespace, cfg, m.oauth_providers),
    }

    ## Register an OAuth2 + PKCE provider and automatically allowlist its `client_secret_name`.
    with_oauth_provider : Mount, OAuth.ProviderConfig -> Mount
    with_oauth_provider = |m, provider| {
        next_providers = List.append(m.oauth_providers, provider)
        {
            namespace: m.namespace,
            config: m.config,
            oauth_providers: next_providers,
            spec: build_component_spec(m.namespace, m.config, next_providers),
        }
    }

    with_jwt_secret_name : Mount, Str -> Mount
    with_jwt_secret_name = |m, secret_name| {
        c = m.config
        update_config(m, {
            jwt_secret_name: Str.trim(secret_name),
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_issuer : Mount, Str -> Mount
    with_issuer = |m, issuer| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: Str.trim(issuer),
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_audience : Mount, Str -> Mount
    with_audience = |m, audience| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: Str.trim(audience),
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_access_ttl_ms : Mount, I64 -> Mount
    with_access_ttl_ms = |m, ttl_ms| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: if ttl_ms < 1000 { 1000 } else { ttl_ms },
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_reuse_window_ms : Mount, I64 -> Mount
    with_reuse_window_ms = |m, window_ms| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: if window_ms < 0 { 0 } else { window_ms },
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_rate_limit : Mount, I64, I64, I64 -> Mount
    with_rate_limit = |m, max_attempts, window_ms, lockout_ms| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: if max_attempts <= 0 { 1 } else { max_attempts },
            rate_window_ms: if window_ms <= 0 { Token.default_rate_window_ms } else { window_ms },
            lockout_ms: if lockout_ms <= 0 { Token.default_lockout_ms } else { lockout_ms },
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_otp_webhook_url : Mount, Str -> Mount
    with_otp_webhook_url = |m, url| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: Str.trim(url),
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_magic_link_base_url : Mount, Str -> Mount
    with_magic_link_base_url = |m, base_url| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: Str.trim(base_url),
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_magic_link_webhook : Mount, Str -> Mount
    with_magic_link_webhook = |m, url| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: Str.trim(url),
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_expose_otp_for_dev : Mount, Bool -> Mount
    with_expose_otp_for_dev = |m, expose| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: expose,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_secure_cookies : Mount, Bool -> Mount
    with_secure_cookies = |m, secure| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: secure,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_oauth_success_redirect : Mount, Str -> Mount
    with_oauth_success_redirect = |m, path| {
        c = m.config
        safe = if OAuth.is_safe_redirect(path) { path } else { "/" }
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: c.default_roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: safe,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    with_default_roles : Mount, List(Str) -> Mount
    with_default_roles = |m, roles| {
        c = m.config
        update_config(m, {
            jwt_secret_name: c.jwt_secret_name,
            jwt_kid: c.jwt_kid,
            issuer: c.issuer,
            audience: c.audience,
            access_ttl_ms: c.access_ttl_ms,
            refresh_ttl_ms: c.refresh_ttl_ms,
            reuse_window_ms: c.reuse_window_ms,
            otp_ttl_ms: c.otp_ttl_ms,
            magic_link_ttl_ms: c.magic_link_ttl_ms,
            max_failed_attempts: c.max_failed_attempts,
            rate_window_ms: c.rate_window_ms,
            lockout_ms: c.lockout_ms,
            default_roles: roles,
            otp_webhook_url: c.otp_webhook_url,
            magic_link_base_url: c.magic_link_base_url,
            magic_link_webhook_url: c.magic_link_webhook_url,
            expose_otp_for_dev: c.expose_otp_for_dev,
            secure_cookies: c.secure_cookies,
            oauth_success_redirect: c.oauth_success_redirect,
            jwks_path: c.jwks_path,
            oauth_route_prefix: c.oauth_route_prefix,
        })
    }

    # -------------------------------------------------------------------------
    # Server-Side ACID Helpers for Parent App Queries & Mutations
    # -------------------------------------------------------------------------

    ## Read a session's live active status inside the caller's exact ACID transaction
    ## (and reactive ReadSet, so queries calling this automatically update on sign-out!).
    get_session_status! : Mount, Ctx.DbReadable(r), Str, I64 => Try(SessionStatus, Str)
    get_session_status! = |m, db, session_id, now_ms| {
        if Str.is_empty(session_id) {
            return Ok({
                active: False,
                user_id: "",
                session_id: "",
                expires_at_ms: 0,
                revoked_at_ms: 0,
            })
        }
        scoped_db : Ctx.DbReader
        scoped_db = {
            namespace: m.namespace,
            get_raw!: db.get_raw!,
            query_raw!: db.query_raw!,
            paginate_raw!: db.paginate_raw!,
            search_raw!: db.search_raw!,
        }
        match Db.get!(scoped_db, sessions_table, session_id)? {
            NotFound =>
                Ok({
                    active: False,
                    user_id: "",
                    session_id,
                    expires_at_ms: 0,
                    revoked_at_ms: 0,
                })
            Found(sess) => {
                active = Token.is_session_active(
                    {
                        id: sess.id,
                        user_id: sess.user_id,
                        expires_at_ms: sess.expires_at_ms,
                        revoked_at_ms: sess.revoked_at_ms,
                    },
                    now_ms,
                )
                Ok({
                    active,
                    user_id: sess.user_id,
                    session_id: sess.id,
                    expires_at_ms: sess.expires_at_ms,
                    revoked_at_ms: sess.revoked_at_ms,
                })
            }
        }
    }

    ## Require an authenticated caller whose backing `auth_sessions` row is active (unrevoked & unexpired).
    ## Rejects still-unexpired JWTs immediately after `signOut`, `signOutAll`, or refresh replay revocation!
    require_active_session! : Mount, Ctx.QueryCtx => Try(Ctx.AuthIdentity, Str)
    require_active_session! = |m, ctx| {
        id = Ctx.require_auth!(ctx.auth!)?
        if Str.is_empty(id.session_id) {
            return Err("Session required")
        }
        now = Ctx.now_ms!(ctx)
        status = get_session_status!(m, ctx.db, id.session_id, now)?
        if status.active and status.user_id == id.subject {
            Ok(id)
        } else {
            Err("Session revoked or expired")
        }
    }

    ## Same transactional active-session verification for ACID Mutations.
    require_active_session_mut! : Mount, Ctx.MutationCtx => Try(Ctx.AuthIdentity, Str)
    require_active_session_mut! = |m, ctx|
        require_active_session!(m, Ctx.as_query_ctx(ctx))

    ## Return `SignedIn(user_id)` if the caller has a valid, active session, otherwise `SignedOut`.
    current_user_id! : Mount, Ctx.QueryCtx => Try([SignedIn(Str), SignedOut], Str)
    current_user_id! = |m, ctx| {
        auth! = ctx.auth!
        match auth!() {
            Err(Unauthenticated) => Ok(SignedOut)
            Ok(id) => {
                if Str.is_empty(id.session_id) {
                    return Ok(SignedOut)
                }
                now = Ctx.now_ms!(ctx)
                status = get_session_status!(m, ctx.db, id.session_id, now)?
                if status.active and status.user_id == id.subject {
                    Ok(SignedIn(id.subject))
                } else {
                    Ok(SignedOut)
                }
            }
        }
    }

    ## Same helper for ACID Mutations.
    current_user_id_mut! : Mount, Ctx.MutationCtx => Try([SignedIn(Str), SignedOut], Str)
    current_user_id_mut! = |m, ctx|
        current_user_id!(m, Ctx.as_query_ctx(ctx))

    # -------------------------------------------------------------------------
    # Internal Helpers
    # -------------------------------------------------------------------------

    rate_policy_from_config : Config -> Token.RateLimitPolicy
    rate_policy_from_config = |cfg| {
        max_attempts: cfg.max_failed_attempts,
        window_ms: cfg.rate_window_ms,
        lockout_ms: cfg.lockout_ms,
    }

    fallback_display_name : Str, Str -> Str
    fallback_display_name = |raw_name, email| {
        trimmed = Str.trim(raw_name)
        if !Str.is_empty(trimmed) {
            return trimmed
        }
        parts = Str.split_on(email, "@")
        match List.first(parts) {
            Ok(local) => if Str.is_empty(local) { email } else { local }
            Err(_) => email
        }
    }

    revoke_session_and_tokens! : Ctx.DbWriter, Str, I64 => Try(Bool, Str)
    revoke_session_and_tokens! = |db, session_id, now| {
        was_active =
            match Db.get!(db, sessions_table, session_id)? {
                NotFound => False
                Found(sess) =>
                    if sess.revoked_at_ms == 0 {
                        Db.patch!(db, sessions_table, session_id, { revoked_at_ms: now })?
                        True
                    } else {
                        False
                    }
            }
        tokens =
            Db.from_index(refresh_tokens_by_session)
            |> Db.eq([Key.str(session_id)])
            |> Db.collect!(db)?
        for tok in tokens {
            if !tok.revoked {
                Db.patch!(db, refresh_tokens_table, tok.id, { revoked: Bool.True })?
            }
        }
        Ok(was_active)
    }

    load_primary_account! : Ctx.DbReadable(r), Str, List(Str) => Try({ email : Str, email_verified : Bool, name : Str, roles : List(Str) }, Str)
    load_primary_account! = |db, user_id, default_roles| {
        accs =
            Db.from_index(accounts_by_user)
            |> Db.eq([Key.str(user_id)])
            |> Db.take(10)
            |> Db.collect!(db)?
        var $email = ""
        var $email_verified = False
        var $name = ""
        var $roles = default_roles
        var $has_roles = False
        for acc in accs {
            if Str.is_empty($email) and !Str.is_empty(acc.email) {
                $email = acc.email
            }
            if acc.email_verified {
                $email_verified = True
            }
            if Str.is_empty($name) and !Str.is_empty(acc.name) {
                $name = acc.name
            }
            if !$has_roles and !List.is_empty(acc.roles) {
                $roles = acc.roles
                $has_roles = True
            }
        }
        Ok({
            email: $email,
            email_verified: $email_verified,
            name: if Str.is_empty($name) { $email } else { $name },
            roles: $roles,
        })
    }

    mint_access_jwt! : Config, Ctx.ActionCtx, { user_id : Str, session_id : Str, email : Str, email_verified : Bool, name : Str, roles : List(Str) } => Try({ access_token : Str, expires_at_ms : I64 }, Str)
    mint_access_jwt! = |cfg, ctx, info| {
        now = Ctx.now_ms!(ctx)
        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        random_bytes! = ctx.crypto.random_bytes!
        jti = random_bytes!(16)?
        claims_json = Token.build_jwt_claims_json_with_jti(
            {
                subject: info.user_id,
                session_id: info.session_id,
                email: info.email,
                email_verified: info.email_verified,
                name: info.name,
                roles: info.roles,
                issuer: cfg.issuer,
                audience: cfg.audience,
                issued_at_ms: now,
                ttl_ms: cfg.access_ttl_ms,
            },
            jti,
        )
        sign! = ctx.crypto.jwt_sign_ed25519!
        jwt = sign!(seed, cfg.jwt_kid, claims_json)?
        Ok({
            access_token: jwt,
            expires_at_ms: now + cfg.access_ttl_ms,
        })
    }

    magic_link_verify_path : Config -> Str
    magic_link_verify_path = |cfg| {
        trimmed =
            if Str.ends_with(cfg.oauth_route_prefix, "/") {
                Str.drop_suffix(cfg.oauth_route_prefix, "/")
            } else {
                cfg.oauth_route_prefix
            }
        base =
            if Str.ends_with(trimmed, "/oauth") {
                Str.drop_suffix(trimmed, "/oauth")
            } else {
                trimmed
            }
        if Str.is_empty(base) {
            "/auth/magic-link/verify"
        } else {
            "${base}/magic-link/verify"
        }
    }

    require_active_session_action! : Str, Ctx.ActionCtx => Try(Ctx.AuthIdentity, Str)
    require_active_session_action! = |ns, ctx| {
        id = Ctx.require_auth!(ctx.auth!)?
        if Str.is_empty(id.session_id) {
            return Err("Session required")
        }
        status_raw = Ctx.run_query_raw!(ctx, "${ns}.sessionStatus", "{}")?
        status : PublicSessionStatus
        status = match Json.parse(status_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode session status: ${msg}")
        }
        if status.active and status.user_id == id.subject and status.session_id == id.session_id {
            Ok(id)
        } else {
            Err("Session revoked or expired")
        }
    }

    ## Generate a single-use 60-second `oac_...` exchange code whose AEAD-encrypted
    ## user payload is stored in `auth_verification_codes` (tokens never touch any URL).
    issue_oauth_exchange_code! : Str, Config, Ctx.ActionCtx, Str, PendingExchangePayload => Try(Str, Str)
    issue_oauth_exchange_code! = |ns, cfg, ctx, provider_id, payload| {
        rand_bytes! = ctx.crypto.random_bytes!
        oac_rand = rand_bytes!(32)?
        oauth_code = "oac_${oac_rand}"
        sha256! = ctx.crypto.sha256!
        code_hash = sha256!(oauth_code)?

        payload_json = match Json.to_str_try(payload) {
            Ok(s) => s
            Err(_) => return Err("failed to encode OAuth exchange payload")
        }
        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        aead_encrypt! = ctx.crypto.aead_encrypt!
        encrypted_payload = aead_encrypt!(seed, payload_json, "oauth_exchange:${code_hash}")?

        store_args : StoreCodeArgs
        store_args = {
            identifier: payload.user_id,
            code_hash,
            kind: "oauth_exchange",
            provider: provider_id,
            verifier: encrypted_payload,
            redirect_to: "",
            ttl_ms: Token.default_oauth_exchange_ttl_ms,
        }
        _ = Ctx.run_mutation!(ctx, "${ns}._storeVerificationCode", store_args)?
        Ok(oauth_code)
    }

    # -------------------------------------------------------------------------
    # Internal Queries & Mutations (Blocked on Public HTTP/WS)
    # -------------------------------------------------------------------------

    check_rate_limit_inner! : Config, Ctx.QueryCtx, RateKeyArgs => Try(RateCheckResult, Str)
    check_rate_limit_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        found =
            Db.from_index(rate_limits_by_key)
            |> Db.eq([Key.str(args.key)])
            |> Db.first!(ctx.db)?
        match found {
            NotFound => Ok({ allowed: True, retry_after_ms: 0 })
            Found(doc) =>
                match Token.check_rate_limit(
                    {
                        window_start_ms: doc.window_start_ms,
                        attempts: doc.attempts,
                        locked_until_ms: doc.locked_until_ms,
                    },
                    rate_policy_from_config(cfg),
                    now,
                ) {
                    Allowed => Ok({ allowed: True, retry_after_ms: 0 })
                    LockedOut(rem) => Ok({ allowed: False, retry_after_ms: rem })
                }
        }
    }

    record_failed_attempt_inner! : Config, Ctx.MutationCtx, RateKeyArgs => Try(RateRecordResult, Str)
    record_failed_attempt_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        pol = rate_policy_from_config(cfg)
        found =
            Db.from_index(rate_limits_by_key)
            |> Db.eq([Key.str(args.key)])
            |> Db.first!(ctx.db)?
        match found {
            NotFound => {
                next = Token.record_failed_attempt(
                    { window_start_ms: 0, attempts: 0, locked_until_ms: 0 },
                    pol,
                    now,
                )
                _ = Db.insert!(ctx.db, rate_limits_table, {
                    key: args.key,
                    window_start_ms: next.window_start_ms,
                    attempts: next.attempts,
                    locked_until_ms: next.locked_until_ms,
                })?
                locked = next.locked_until_ms > now
                retry_after = if locked { next.locked_until_ms - now } else { 0 }
                Ok({ locked, retry_after_ms: retry_after, attempts: next.attempts })
            }
            Found(doc) => {
                next = Token.record_failed_attempt(
                    {
                        window_start_ms: doc.window_start_ms,
                        attempts: doc.attempts,
                        locked_until_ms: doc.locked_until_ms,
                    },
                    pol,
                    now,
                )
                Db.patch!(ctx.db, rate_limits_table, doc.id, {
                    window_start_ms: next.window_start_ms,
                    attempts: next.attempts,
                    locked_until_ms: next.locked_until_ms,
                })?
                locked = next.locked_until_ms > now
                retry_after = if locked { next.locked_until_ms - now } else { 0 }
                Ok({ locked, retry_after_ms: retry_after, attempts: next.attempts })
            }
        }
    }

    reset_rate_limit_inner! : Ctx.MutationCtx, RateKeyArgs => Try(Bool, Str)
    reset_rate_limit_inner! = |ctx, args| {
        now = Ctx.now_ms!(ctx)
        found =
            Db.from_index(rate_limits_by_key)
            |> Db.eq([Key.str(args.key)])
            |> Db.first!(ctx.db)?
        match found {
            NotFound => Ok(True)
            Found(doc) => {
                reset = Token.reset_rate_limit(now)
                Db.patch!(ctx.db, rate_limits_table, doc.id, {
                    window_start_ms: reset.window_start_ms,
                    attempts: reset.attempts,
                    locked_until_ms: reset.locked_until_ms,
                })?
                Ok(True)
            }
        }
    }

    find_password_account_inner! : Ctx.QueryCtx, FindPasswordAccountArgs => Try(FindPasswordAccountResult, Str)
    find_password_account_inner! = |ctx, args| {
        email = Token.normalize_email(args.email)
        found =
            Db.from_index(accounts_by_provider_account)
            |> Db.eq([Key.str("password"), Key.str(email)])
            |> Db.first!(ctx.db)?
        match found {
            NotFound =>
                Ok({
                    found: False,
                    account_id: "",
                    user_id: "",
                    email: "",
                    email_verified: False,
                    name: "",
                    secret_hash: "",
                    roles: [],
                })
            Found(acc) =>
                Ok({
                    found: True,
                    account_id: acc.id,
                    user_id: acc.user_id,
                    email: acc.email,
                    email_verified: acc.email_verified,
                    name: acc.name,
                    secret_hash: acc.secret_hash,
                    roles: acc.roles,
                })
        }
    }

    create_password_account_and_session_inner! : Config, Ctx.MutationCtx, CreatePasswordAccountArgs => Try(CreatedSessionInfo, Str)
    create_password_account_and_session_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        email = Token.normalize_email(args.email)

        existing =
            Db.from_index(accounts_by_provider_account)
            |> Db.eq([Key.str("password"), Key.str(email)])
            |> Db.first!(ctx.db)?
        match existing {
            Found(_) => return Err("An account with this email already exists")
            NotFound => {}
        }

        display_name = fallback_display_name(args.name, email)
        user_id = args.new_user_id

        _ = Db.insert!(ctx.db, accounts_table, {
            user_id,
            provider: "password",
            provider_account_id: email,
            email,
            email_verified: Bool.False,
            name: display_name,
            secret_hash: args.secret_hash,
            roles: cfg.default_roles,
        })?

        session_expires = now + cfg.refresh_ttl_ms
        session_id = Db.insert!(ctx.db, sessions_table, {
            user_id,
            expires_at_ms: session_expires,
            revoked_at_ms: 0,
            user_agent: args.user_agent,
        })?

        _ = Db.insert!(ctx.db, refresh_tokens_table, {
            session_id,
            token_hash: args.refresh_token_hash,
            parent_token_id: "",
            expires_at_ms: session_expires,
            used_at_ms: 0,
            revoked: Bool.False,
        })?

        Ok({
            user_id,
            session_id,
            expires_at_ms: session_expires,
            email,
            email_verified: False,
            name: display_name,
            roles: cfg.default_roles,
        })
    }

    create_session_inner! : Config, Ctx.MutationCtx, CreateSessionArgs => Try(CreateSessionResult, Str)
    create_session_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        session_expires = now + cfg.refresh_ttl_ms
        session_id = Db.insert!(ctx.db, sessions_table, {
            user_id: args.user_id,
            expires_at_ms: session_expires,
            revoked_at_ms: 0,
            user_agent: args.user_agent,
        })?
        _ = Db.insert!(ctx.db, refresh_tokens_table, {
            session_id,
            token_hash: args.refresh_token_hash,
            parent_token_id: "",
            expires_at_ms: session_expires,
            used_at_ms: 0,
            revoked: Bool.False,
        })?
        Ok({
            session_id,
            expires_at_ms: session_expires,
        })
    }

    ## Convex Auth v2 refresh token rotation + replay detection mutation.
    ## Returns `Ok({ outcome: "revoked", ... })` on replay so the session/family revocation COMMITS
    ## atomically instead of rolling back! The calling public `auth.refresh` Action converts that into `Err`.
    rotate_refresh_token_inner! : Config, Ctx.MutationCtx, RotateRefreshArgs => Try(RotateRefreshResult, Str)
    rotate_refresh_token_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        empty_err = |outcome, err_msg| {
            outcome,
            error: err_msg,
            user_id: "",
            session_id: "",
            expires_at_ms: 0,
            email: "",
            email_verified: False,
            name: "",
            roles: [],
        }

        tok_found =
            Db.from_index(refresh_tokens_by_hash)
            |> Db.eq([Key.str(args.token_hash)])
            |> Db.first!(ctx.db)?
        tok = match tok_found {
            NotFound => return Ok(empty_err("rejected", "Invalid refresh token"))
            Found(t) => t
        }

        sess = match Db.get!(ctx.db, sessions_table, tok.session_id)? {
            NotFound => return Ok(empty_err("rejected", "Session not found"))
            Found(s) => s
        }

        decision = Token.evaluate_refresh(
            {
                id: sess.id,
                user_id: sess.user_id,
                expires_at_ms: sess.expires_at_ms,
                revoked_at_ms: sess.revoked_at_ms,
            },
            {
                id: tok.id,
                session_id: tok.session_id,
                parent_token_id: tok.parent_token_id,
                expires_at_ms: tok.expires_at_ms,
                used_at_ms: tok.used_at_ms,
                revoked: tok.revoked,
            },
            now,
            cfg.reuse_window_ms,
        )

        match decision {
            RotateNewToken => {
                Db.patch!(ctx.db, refresh_tokens_table, tok.id, { used_at_ms: now })?
                next_exp = now + cfg.refresh_ttl_ms
                _ = Db.insert!(ctx.db, refresh_tokens_table, {
                    session_id: sess.id,
                    token_hash: args.new_token_hash,
                    parent_token_id: tok.id,
                    expires_at_ms: next_exp,
                    used_at_ms: 0,
                    revoked: Bool.False,
                })?
                acc_info = load_primary_account!(ctx.db, sess.user_id, cfg.default_roles)?
                Ok({
                    outcome: "rotated",
                    error: "",
                    user_id: sess.user_id,
                    session_id: sess.id,
                    expires_at_ms: sess.expires_at_ms,
                    email: acc_info.email,
                    email_verified: acc_info.email_verified,
                    name: acc_info.name,
                    roles: acc_info.roles,
                })
            }
            GraceReuseAccessOnly => {
                acc_info = load_primary_account!(ctx.db, sess.user_id, cfg.default_roles)?
                Ok({
                    outcome: "grace",
                    error: "",
                    user_id: sess.user_id,
                    session_id: sess.id,
                    expires_at_ms: sess.expires_at_ms,
                    email: acc_info.email,
                    email_verified: acc_info.email_verified,
                    name: acc_info.name,
                    roles: acc_info.roles,
                })
            }
            RevokeFamily(reason) => {
                _ = revoke_session_and_tokens!(ctx.db, sess.id, now)?
                Ok(empty_err("revoked", reason))
            }
            Reject(reason) => Ok(empty_err("rejected", reason))
        }
    }

    store_verification_code_inner! : Ctx.MutationCtx, StoreCodeArgs => Try(Str, Str)
    store_verification_code_inner! = |ctx, args| {
        now = Ctx.now_ms!(ctx)
        ttl = if args.ttl_ms < 1000 { Token.default_otp_ttl_ms } else { args.ttl_ms }
        Db.insert!(ctx.db, verification_codes_table, {
            identifier: args.identifier,
            code_hash: args.code_hash,
            kind: args.kind,
            provider: args.provider,
            verifier: args.verifier,
            redirect_to: args.redirect_to,
            expires_at_ms: now + ttl,
            consumed: Bool.False,
        })
    }

    find_latest_otp_inner! : Ctx.QueryCtx, FindLatestOtpArgs => Try(FindLatestOtpResult, Str)
    find_latest_otp_inner! = |ctx, args| {
        now = Ctx.now_ms!(ctx)
        email = Token.normalize_email(args.email)
        codes =
            Db.from_index(verification_codes_by_identifier_kind)
            |> Db.eq([Key.str(email), Key.str("otp")])
            |> Db.desc()
            |> Db.take(10)
            |> Db.collect!(ctx.db)?
        for c in codes {
            if !c.consumed and c.expires_at_ms > now {
                return Ok({
                    found: True,
                    code_id: c.id,
                    code_hash: c.code_hash,
                })
            }
        }
        Ok({
            found: False,
            code_id: "",
            code_hash: "",
        })
    }

    complete_otp_sign_in_inner! : Config, Ctx.MutationCtx, CompleteOtpArgs => Try(CreatedSessionInfo, Str)
    complete_otp_sign_in_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        email = Token.normalize_email(args.email)

        code_doc = match Db.get!(ctx.db, verification_codes_table, args.code_id)? {
            NotFound => return Err("Verification code not found")
            Found(d) => d
        }
        if code_doc.consumed or code_doc.expires_at_ms <= now or code_doc.identifier != email or code_doc.kind != "otp" {
            return Err("Invalid or expired verification code")
        }
        Db.patch!(ctx.db, verification_codes_table, code_doc.id, { consumed: Bool.True })?

        # Reset OTP brute-force counter on verified code.
        rl_found =
            Db.from_index(rate_limits_by_key)
            |> Db.eq([Key.str("otp:${email}")])
            |> Db.first!(ctx.db)?
        match rl_found {
            Found(rl) => {
                reset = Token.reset_rate_limit(now)
                Db.patch!(ctx.db, rate_limits_table, rl.id, {
                    window_start_ms: reset.window_start_ms,
                    attempts: reset.attempts,
                    locked_until_ms: reset.locked_until_ms,
                })?
            }
            NotFound => {}
        }

        # Find existing OTP account, or link to an existing account with this email, or create a new user.
        otp_acc =
            Db.from_index(accounts_by_provider_account)
            |> Db.eq([Key.str("otp"), Key.str(email)])
            |> Db.first!(ctx.db)?

        resolved = match otp_acc {
            Found(acc) => {
                if !acc.email_verified {
                    Db.patch!(ctx.db, accounts_table, acc.id, { email_verified: Bool.True })?
                }
                {
                    user_id: acc.user_id,
                    name: acc.name,
                    roles: if List.is_empty(acc.roles) { cfg.default_roles } else { acc.roles },
                }
            }
            NotFound => {
                by_email =
                    Db.from_index(accounts_by_email)
                    |> Db.eq([Key.str(email)])
                    |> Db.first!(ctx.db)?
                display_name = fallback_display_name(args.name, email)
                match by_email {
                    Found(existing) => {
                        if !existing.email_verified {
                            Db.patch!(ctx.db, accounts_table, existing.id, { email_verified: Bool.True })?
                        }
                        _ = Db.insert!(ctx.db, accounts_table, {
                            user_id: existing.user_id,
                            provider: "otp",
                            provider_account_id: email,
                            email,
                            email_verified: Bool.True,
                            name: if Str.is_empty(existing.name) { display_name } else { existing.name },
                            secret_hash: "",
                            roles: existing.roles,
                        })?
                        {
                            user_id: existing.user_id,
                            name: if Str.is_empty(existing.name) { display_name } else { existing.name },
                            roles: if List.is_empty(existing.roles) { cfg.default_roles } else { existing.roles },
                        }
                    }
                    NotFound => {
                        _ = Db.insert!(ctx.db, accounts_table, {
                            user_id: args.new_user_id,
                            provider: "otp",
                            provider_account_id: email,
                            email,
                            email_verified: Bool.True,
                            name: display_name,
                            secret_hash: "",
                            roles: cfg.default_roles,
                        })?
                        {
                            user_id: args.new_user_id,
                            name: display_name,
                            roles: cfg.default_roles,
                        }
                    }
                }
            }
        }

        session_expires = now + cfg.refresh_ttl_ms
        session_id = Db.insert!(ctx.db, sessions_table, {
            user_id: resolved.user_id,
            expires_at_ms: session_expires,
            revoked_at_ms: 0,
            user_agent: args.user_agent,
        })?
        _ = Db.insert!(ctx.db, refresh_tokens_table, {
            session_id,
            token_hash: args.refresh_token_hash,
            parent_token_id: "",
            expires_at_ms: session_expires,
            used_at_ms: 0,
            revoked: Bool.False,
        })?

        Ok({
            user_id: resolved.user_id,
            session_id,
            expires_at_ms: session_expires,
            email,
            email_verified: True,
            name: resolved.name,
            roles: resolved.roles,
        })
    }

    consume_oauth_pkce_inner! : Ctx.MutationCtx, ConsumeOAuthPkceArgs => Try(ConsumeOAuthPkceResult, Str)
    consume_oauth_pkce_inner! = |ctx, args| {
        now = Ctx.now_ms!(ctx)
        found =
            Db.from_index(verification_codes_by_code_hash)
            |> Db.eq([Key.str(args.state_hash)])
            |> Db.first!(ctx.db)?
        match found {
            NotFound =>
                Ok({
                    valid: False,
                    verifier: "",
                    redirect_to: "",
                    error: "Invalid OAuth state",
                })
            Found(doc) => {
                if doc.consumed {
                    return Ok({
                        valid: False,
                        verifier: "",
                        redirect_to: "",
                        error: "OAuth state already consumed",
                    })
                }
                if doc.kind != "oauth_pkce" or doc.provider != args.provider {
                    return Ok({
                        valid: False,
                        verifier: "",
                        redirect_to: "",
                        error: "OAuth provider state mismatch",
                    })
                }
                if doc.expires_at_ms <= now {
                    return Ok({
                        valid: False,
                        verifier: "",
                        redirect_to: "",
                        error: "OAuth state expired",
                    })
                }
                Db.patch!(ctx.db, verification_codes_table, doc.id, { consumed: Bool.True })?
                Ok({
                    valid: True,
                    verifier: doc.verifier,
                    redirect_to: doc.redirect_to,
                    error: "",
                })
            }
        }
    }

    upsert_oauth_account_db! : Config, Ctx.DbWriter, UpsertOAuthAccountOnlyArgs => Try(PendingExchangePayload, Str)
    upsert_oauth_account_db! = |cfg, db, args| {
        email = Token.normalize_email(args.email)
        display_name = fallback_display_name(args.name, if Str.is_empty(email) { args.provider_account_id } else { email })

        existing_provider =
            Db.from_index(accounts_by_provider_account)
            |> Db.eq([Key.str(args.provider), Key.str(args.provider_account_id)])
            |> Db.first!(db)?

        resolved = match existing_provider {
            Found(acc) => {
                next_email = if Str.is_empty(email) { acc.email } else { email }
                next_verified = acc.email_verified or args.email_verified
                next_name = if Str.is_empty(args.name) { acc.name } else { display_name }
                Db.patch!(db, accounts_table, acc.id, {
                    email: next_email,
                    email_verified: next_verified,
                    name: next_name,
                })?
                {
                    user_id: acc.user_id,
                    email: next_email,
                    email_verified: next_verified,
                    name: next_name,
                    roles: if List.is_empty(acc.roles) { cfg.default_roles } else { acc.roles },
                }
            }
            NotFound => {
                # Only auto-link by email when the OAuth provider asserts `email_verified: True`
                # AND an existing verified account shares the email (prevents account takeover!).
                linked_user =
                    if args.email_verified and !Str.is_empty(email) {
                        match (
                            Db.from_index(accounts_by_email)
                            |> Db.eq([Key.str(email)])
                            |> Db.first!(db)?
                        ) {
                            Found(ex) =>
                                if ex.email_verified {
                                    Found({ user_id: ex.user_id, roles: ex.roles })
                                } else {
                                    NotFound
                                }
                            NotFound => NotFound
                        }
                    } else {
                        NotFound
                    }

                uid = match linked_user {
                    Found(lu) => lu.user_id
                    NotFound => args.new_user_id
                }
                roles = match linked_user {
                    Found(lu) => if List.is_empty(lu.roles) { cfg.default_roles } else { lu.roles }
                    NotFound => cfg.default_roles
                }

                _ = Db.insert!(db, accounts_table, {
                    user_id: uid,
                    provider: args.provider,
                    provider_account_id: args.provider_account_id,
                    email,
                    email_verified: args.email_verified,
                    name: display_name,
                    secret_hash: "",
                    roles,
                })?
                {
                    user_id: uid,
                    email,
                    email_verified: args.email_verified,
                    name: display_name,
                    roles,
                }
            }
        }
        Ok(resolved)
    }

    upsert_oauth_account_inner! : Config, Ctx.MutationCtx, UpsertOAuthAccountOnlyArgs => Try(PendingExchangePayload, Str)
    upsert_oauth_account_inner! = |cfg, ctx, args|
        upsert_oauth_account_db!(cfg, ctx.db, args)

    upsert_oauth_account_and_session_inner! : Config, Ctx.MutationCtx, UpsertOAuthAccountArgs => Try(CreatedSessionInfo, Str)
    upsert_oauth_account_and_session_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        resolved = upsert_oauth_account_db!(cfg, ctx.db, {
            provider: args.provider,
            provider_account_id: args.provider_account_id,
            email: args.email,
            email_verified: args.email_verified,
            name: args.name,
            new_user_id: args.new_user_id,
        })?

        session_expires = now + cfg.refresh_ttl_ms
        session_id = Db.insert!(ctx.db, sessions_table, {
            user_id: resolved.user_id,
            expires_at_ms: session_expires,
            revoked_at_ms: 0.I64,
            user_agent: args.user_agent,
        })?
        _ = Db.insert!(ctx.db, refresh_tokens_table, {
            session_id,
            token_hash: args.refresh_token_hash,
            parent_token_id: "",
            expires_at_ms: session_expires,
            used_at_ms: 0.I64,
            revoked: Bool.False,
        })?

        Ok({
            user_id: resolved.user_id,
            session_id,
            expires_at_ms: session_expires,
            email: resolved.email,
            email_verified: resolved.email_verified,
            name: resolved.name,
            roles: resolved.roles,
        })
    }

    consume_oauth_exchange_code_inner! : Ctx.MutationCtx, ConsumeOAuthExchangeArgs => Try(ConsumeOAuthExchangeResult, Str)
    consume_oauth_exchange_code_inner! = |ctx, args| {
        now = Ctx.now_ms!(ctx)
        found =
            Db.from_index(verification_codes_by_code_hash)
            |> Db.eq([Key.str(args.code_hash)])
            |> Db.first!(ctx.db)?
        match found {
            NotFound =>
                Ok({
                    valid: False,
                    user_id: "",
                    verifier: "",
                    error: "Invalid or expired OAuth exchange code",
                })
            Found(doc) => {
                if doc.consumed {
                    return Ok({
                        valid: False,
                        user_id: "",
                        verifier: "",
                        error: "OAuth exchange code already consumed",
                    })
                }
                if doc.kind != "oauth_exchange" {
                    return Ok({
                        valid: False,
                        user_id: "",
                        verifier: "",
                        error: "Invalid OAuth exchange code",
                    })
                }
                if doc.expires_at_ms <= now {
                    return Ok({
                        valid: False,
                        user_id: "",
                        verifier: "",
                        error: "OAuth exchange code expired",
                    })
                }
                Db.patch!(ctx.db, verification_codes_table, doc.id, { consumed: Bool.True })?
                Ok({
                    valid: True,
                    user_id: doc.identifier,
                    verifier: doc.verifier,
                    error: "",
                })
            }
        }
    }

    upsert_magic_link_account_db! : Config, Ctx.DbWriter, Str, Str, Str => Try({ user_id : Str, name : Str, roles : List(Str) }, Str)
    upsert_magic_link_account_db! = |cfg, db, email, raw_name, new_user_id| {
        ml_acc =
            Db.from_index(accounts_by_provider_account)
            |> Db.eq([Key.str("magic_link"), Key.str(email)])
            |> Db.first!(db)?

        match ml_acc {
            Found(acc) => {
                if !acc.email_verified {
                    Db.patch!(db, accounts_table, acc.id, { email_verified: Bool.True })?
                }
                Ok({
                    user_id: acc.user_id,
                    name: acc.name,
                    roles: if List.is_empty(acc.roles) { cfg.default_roles } else { acc.roles },
                })
            }
            NotFound => {
                by_email =
                    Db.from_index(accounts_by_email)
                    |> Db.eq([Key.str(email)])
                    |> Db.first!(db)?
                display_name = fallback_display_name(raw_name, email)
                match by_email {
                    Found(existing) => {
                        if !existing.email_verified {
                            Db.patch!(db, accounts_table, existing.id, { email_verified: Bool.True })?
                        }
                        resolved_name = if Str.is_empty(existing.name) { display_name } else { existing.name }
                        resolved_roles = if List.is_empty(existing.roles) { cfg.default_roles } else { existing.roles }
                        _ = Db.insert!(db, accounts_table, {
                            user_id: existing.user_id,
                            provider: "magic_link",
                            provider_account_id: email,
                            email,
                            email_verified: Bool.True,
                            name: resolved_name,
                            secret_hash: "",
                            roles: resolved_roles,
                        })?
                        Ok({
                            user_id: existing.user_id,
                            name: resolved_name,
                            roles: resolved_roles,
                        })
                    }
                    NotFound => {
                        _ = Db.insert!(db, accounts_table, {
                            user_id: new_user_id,
                            provider: "magic_link",
                            provider_account_id: email,
                            email,
                            email_verified: Bool.True,
                            name: display_name,
                            secret_hash: "",
                            roles: cfg.default_roles,
                        })?
                        Ok({
                            user_id: new_user_id,
                            name: display_name,
                            roles: cfg.default_roles,
                        })
                    }
                }
            }
        }
    }

    complete_magic_link_sign_in_inner! : Config, Ctx.MutationCtx, CompleteMagicLinkArgs => Try(CreatedSessionInfo, Str)
    complete_magic_link_sign_in_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        found =
            Db.from_index(verification_codes_by_code_hash)
            |> Db.eq([Key.str(args.code_hash)])
            |> Db.first!(ctx.db)?
        code_doc = match found {
            NotFound => return Err("Invalid or expired magic link")
            Found(d) => d
        }
        if code_doc.consumed or code_doc.expires_at_ms <= now or code_doc.kind != "magic_link" {
            return Err("Invalid or expired magic link")
        }
        Db.patch!(ctx.db, verification_codes_table, code_doc.id, { consumed: Bool.True })?

        email = Token.normalize_email(code_doc.identifier)
        resolved = upsert_magic_link_account_db!(cfg, ctx.db, email, args.name, args.new_user_id)?

        session_expires = now + cfg.refresh_ttl_ms
        session_id = Db.insert!(ctx.db, sessions_table, {
            user_id: resolved.user_id,
            expires_at_ms: session_expires,
            revoked_at_ms: 0.I64,
            user_agent: args.user_agent,
        })?
        _ = Db.insert!(ctx.db, refresh_tokens_table, {
            session_id,
            token_hash: args.refresh_token_hash,
            parent_token_id: "",
            expires_at_ms: session_expires,
            used_at_ms: 0.I64,
            revoked: Bool.False,
        })?

        Ok({
            user_id: resolved.user_id,
            session_id,
            expires_at_ms: session_expires,
            email,
            email_verified: True,
            name: resolved.name,
            roles: resolved.roles,
        })
    }

    consume_magic_link_account_inner! : Config, Ctx.MutationCtx, ConsumeMagicLinkAccountArgs => Try(ConsumeMagicLinkAccountResult, Str)
    consume_magic_link_account_inner! = |cfg, ctx, args| {
        now = Ctx.now_ms!(ctx)
        found =
            Db.from_index(verification_codes_by_code_hash)
            |> Db.eq([Key.str(args.code_hash)])
            |> Db.first!(ctx.db)?
        code_doc = match found {
            NotFound =>
                return Ok({
                    valid: False,
                    user_id: "",
                    email: "",
                    email_verified: False,
                    name: "",
                    roles: [],
                    redirect_to: "",
                    error: "Invalid or expired magic link",
                })
            Found(d) => d
        }
        if code_doc.consumed or code_doc.expires_at_ms <= now or code_doc.kind != "magic_link" {
            return Ok({
                valid: False,
                user_id: "",
                email: "",
                email_verified: False,
                name: "",
                roles: [],
                redirect_to: "",
                error: "Invalid or expired magic link",
            })
        }
        Db.patch!(ctx.db, verification_codes_table, code_doc.id, { consumed: Bool.True })?

        email = Token.normalize_email(code_doc.identifier)
        resolved = upsert_magic_link_account_db!(cfg, ctx.db, email, args.name, args.new_user_id)?

        Ok({
            valid: True,
            user_id: resolved.user_id,
            email,
            email_verified: True,
            name: resolved.name,
            roles: resolved.roles,
            redirect_to: code_doc.redirect_to,
            error: "",
        })
    }

    get_totp_factor_inner! : Ctx.QueryCtx, GetTotpFactorArgs => Try(GetTotpFactorResult, Str)
    get_totp_factor_inner! = |ctx, args| {
        found =
            Db.from_index(totp_factors_by_user)
            |> Db.eq([Key.str(args.user_id)])
            |> Db.first!(ctx.db)?
        match found {
            NotFound =>
                Ok({
                    found: False,
                    factor_id: "",
                    user_id: "",
                    secret_ciphertext: "",
                    enabled: False,
                    last_used_step: 0,
                })
            Found(doc) =>
                Ok({
                    found: True,
                    factor_id: doc.id,
                    user_id: doc.user_id,
                    secret_ciphertext: doc.secret_ciphertext,
                    enabled: doc.enabled,
                    last_used_step: doc.last_used_step,
                })
        }
    }

    upsert_pending_totp_factor_inner! : Ctx.MutationCtx, UpsertPendingTotpArgs => Try(Str, Str)
    upsert_pending_totp_factor_inner! = |ctx, args| {
        found =
            Db.from_index(totp_factors_by_user)
            |> Db.eq([Key.str(args.user_id)])
            |> Db.first!(ctx.db)?
        match found {
            Found(doc) => {
                if doc.enabled {
                    return Err("TOTP is already enabled for this account")
                }
                Db.patch!(ctx.db, totp_factors_table, doc.id, {
                    secret_ciphertext: args.secret_ciphertext,
                    enabled: Bool.False,
                    last_used_step: 0.I64,
                })?
                Ok(doc.id)
            }
            NotFound =>
                Db.insert!(ctx.db, totp_factors_table, {
                    user_id: args.user_id,
                    secret_ciphertext: args.secret_ciphertext,
                    enabled: Bool.False,
                    last_used_step: 0.I64,
                })
        }
    }

    enable_totp_factor_inner! : Ctx.MutationCtx, UpdateTotpStepArgs => Try(Bool, Str)
    enable_totp_factor_inner! = |ctx, args| {
        doc = match Db.get!(ctx.db, totp_factors_table, args.factor_id)? {
            NotFound => return Err("TOTP enrollment not found")
            Found(d) => d
        }
        if doc.user_id != args.user_id {
            return Err("Forbidden")
        }
        if doc.enabled {
            return Err("TOTP is already enabled")
        }
        Db.patch!(ctx.db, totp_factors_table, doc.id, {
            enabled: Bool.True,
            last_used_step: args.step,
        })?
        Ok(True)
    }

    consume_totp_step_inner! : Ctx.MutationCtx, UpdateTotpStepArgs => Try(Bool, Str)
    consume_totp_step_inner! = |ctx, args| {
        doc = match Db.get!(ctx.db, totp_factors_table, args.factor_id)? {
            NotFound => return Err("TOTP is not enabled for this account")
            Found(d) => d
        }
        if doc.user_id != args.user_id or !doc.enabled {
            return Err("TOTP is not enabled for this account")
        }
        if args.step <= doc.last_used_step {
            return Err("TOTP code already used")
        }
        Db.patch!(ctx.db, totp_factors_table, doc.id, {
            last_used_step: args.step,
        })?
        Ok(True)
    }

    delete_totp_factor_inner! : Ctx.MutationCtx, DeleteTotpFactorArgs => Try(Bool, Str)
    delete_totp_factor_inner! = |ctx, args| {
        doc = match Db.get!(ctx.db, totp_factors_table, args.factor_id)? {
            NotFound => return Err("TOTP is not enabled for this account")
            Found(d) => d
        }
        if doc.user_id != args.user_id {
            return Err("Forbidden")
        }
        Db.delete!(ctx.db, totp_factors_table, doc.id)?
        Ok(True)
    }

    cron_cleanup_expired_inner! : Ctx.MutationCtx, {} => Try(CleanupResult, Str)
    cron_cleanup_expired_inner! = |ctx, _| {
        now = Ctx.now_ms!(ctx)
        var $deleted_codes = 0.I64
        var $deleted_sessions = 0.I64
        var $deleted_tokens = 0.I64

        codes = Db.query(verification_codes_table) |> Db.asc() |> Db.take(200) |> Db.collect!(ctx.db)?
        for c in codes {
            if c.expires_at_ms <= now or c.consumed {
                Db.delete!(ctx.db, verification_codes_table, c.id)?
                $deleted_codes = $deleted_codes + 1
            }
        }

        exp_sessions =
            Db.from_index(sessions_by_expires)
            |> Db.lt([Key.int(now)])
            |> Db.take(200)
            |> Db.collect!(ctx.db)?
        for s in exp_sessions {
            Db.delete!(ctx.db, sessions_table, s.id)?
            $deleted_sessions = $deleted_sessions + 1
        }

        token_cutoff = now - 86400000 # retain revoked/expired tokens 24h for replay auditing
        tokens = Db.query(refresh_tokens_table) |> Db.asc() |> Db.take(200) |> Db.collect!(ctx.db)?
        for t in tokens {
            if t.expires_at_ms <= now or (t.revoked and t.created_at <= token_cutoff) {
                Db.delete!(ctx.db, refresh_tokens_table, t.id)?
                $deleted_tokens = $deleted_tokens + 1
            }
        }

        Ok({
            deleted_codes: $deleted_codes,
            deleted_sessions: $deleted_sessions,
            deleted_tokens: $deleted_tokens,
        })
    }

    # -------------------------------------------------------------------------
    # Public Mutations & Reactive Queries
    # -------------------------------------------------------------------------

    sign_out_inner! : Ctx.MutationCtx, {} => Try(Bool, Str)
    sign_out_inner! = |ctx, _| {
        id = Ctx.require_auth!(ctx.auth!)?
        if Str.is_empty(id.session_id) {
            return Ok(False)
        }
        now = Ctx.now_ms!(ctx)
        match Db.get!(ctx.db, sessions_table, id.session_id)? {
            NotFound => Ok(False)
            Found(sess) =>
                if sess.user_id != id.subject {
                    Err("Forbidden: session does not belong to caller")
                } else {
                    revoke_session_and_tokens!(ctx.db, sess.id, now)
                }
        }
    }

    sign_out_all_inner! : Ctx.MutationCtx, {} => Try(I64, Str)
    sign_out_all_inner! = |ctx, _| {
        id = Ctx.require_auth!(ctx.auth!)?
        now = Ctx.now_ms!(ctx)
        sessions =
            Db.from_index(sessions_by_user)
            |> Db.eq([Key.str(id.subject)])
            |> Db.collect!(ctx.db)?
        var $revoked_count = 0.I64
        for sess in sessions {
            changed = revoke_session_and_tokens!(ctx.db, sess.id, now)?
            if changed {
                $revoked_count = $revoked_count + 1
            }
        }
        Ok($revoked_count)
    }

    list_sessions_inner! : Ctx.QueryCtx, {} => Try(List(PublicSession), Str)
    list_sessions_inner! = |ctx, _| {
        id = Ctx.require_auth!(ctx.auth!)?
        now = Ctx.now_ms!(ctx)
        sessions =
            Db.from_index(sessions_by_user)
            |> Db.eq([Key.str(id.subject)])
            |> Db.collect!(ctx.db)?
        var $out = []
        for s in sessions {
            if s.revoked_at_ms == 0 and s.expires_at_ms > now {
                $out = List.append($out, {
                    id: s.id,
                    user_id: s.user_id,
                    created_at: s.created_at,
                    expires_at_ms: s.expires_at_ms,
                    user_agent: s.user_agent,
                    is_current: s.id == id.session_id,
                })
            }
        }
        Ok($out)
    }

    session_status_inner! : Ctx.QueryCtx, {} => Try(PublicSessionStatus, Str)
    session_status_inner! = |ctx, _| {
        auth! = ctx.auth!
        match auth!() {
            Err(Unauthenticated) =>
                Ok({
                    active: False,
                    user_id: "",
                    session_id: "",
                })
            Ok(id) => {
                if Str.is_empty(id.session_id) {
                    return Ok({
                        active: False,
                        user_id: id.subject,
                        session_id: "",
                    })
                }
                now = Ctx.now_ms!(ctx)
                active = match Db.get!(ctx.db, sessions_table, id.session_id)? {
                    NotFound => False
                    Found(sess) =>
                        sess.user_id == id.subject
                        and Token.is_session_active(
                            {
                                id: sess.id,
                                user_id: sess.user_id,
                                expires_at_ms: sess.expires_at_ms,
                                revoked_at_ms: sess.revoked_at_ms,
                            },
                            now,
                        )
                }
                Ok({
                    active,
                    user_id: id.subject,
                    session_id: id.session_id,
                })
            }
        }
    }

    # -------------------------------------------------------------------------
    # Public Actions (Scoped to Component Namespace for Secrets + Crypto)
    # -------------------------------------------------------------------------

    sign_up_password_action! : Str, Config, Ctx.ActionCtx, SignUpPasswordArgs => Try(AuthTokenResult, Str)
    sign_up_password_action! = |ns, cfg, ctx, args| {
        email = Token.normalize_email(args.email)
        if !Token.is_valid_email(email) {
            return Err("Invalid email address")
        }
        pw_len = List.len(Str.to_utf8(args.password))
        if pw_len < 8 {
            return Err("Password must be at least 8 characters")
        }
        if pw_len > 1024 {
            return Err("Password is too long")
        }

        hash_pw! = ctx.crypto.hash_password!
        secret_hash = hash_pw!(args.password)?

        rand_bytes! = ctx.crypto.random_bytes!
        uid_rand = rand_bytes!(16)?
        rt_rand = rand_bytes!(32)?
        new_user_id = "usr_${uid_rand}"
        raw_refresh_token = "rt_${rt_rand}"

        sha256! = ctx.crypto.sha256!
        refresh_token_hash = sha256!(raw_refresh_token)?

        created_raw = Ctx.run_mutation!(ctx, "${ns}._createPasswordAccountAndSession", {
            email,
            name: args.name,
            secret_hash,
            new_user_id,
            refresh_token_hash,
            user_agent: args.user_agent,
        })?
        created : CreatedSessionInfo
        created = match Json.parse(created_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode created session: ${msg}")
        }

        minted = mint_access_jwt!(cfg, ctx, {
            user_id: created.user_id,
            session_id: created.session_id,
            email: created.email,
            email_verified: created.email_verified,
            name: created.name,
            roles: created.roles,
        })?

        Ok({
            access_token: minted.access_token,
            refresh_token: raw_refresh_token,
            session_id: created.session_id,
            user_id: created.user_id,
            expires_at_ms: minted.expires_at_ms,
            email: created.email,
            name: created.name,
        })
    }

    sign_in_password_action! : Str, Config, Ctx.ActionCtx, SignInPasswordArgs => Try(AuthTokenResult, Str)
    sign_in_password_action! = |ns, cfg, ctx, args| {
        email = Token.normalize_email(args.email)
        if !Token.is_valid_email(email) or Str.is_empty(args.password) {
            return Err("Invalid email or password")
        }

        rate_key = "pw:${email}"
        rl_raw = Ctx.run_query!(ctx, "${ns}._checkRateLimit", { key: rate_key })?
        rl : RateCheckResult
        rl = match Json.parse(rl_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode rate limit check: ${msg}")
        }
        if !rl.allowed {
            return Err("Too many failed attempts; account temporarily locked")
        }

        acc_raw = Ctx.run_query!(ctx, "${ns}._findPasswordAccount", { email: email })?
        acc : FindPasswordAccountResult
        acc = match Json.parse(acc_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode account lookup: ${msg}")
        }
        if !acc.found or Str.is_empty(acc.secret_hash) {
            rec_raw = Ctx.run_mutation!(ctx, "${ns}._recordFailedAttempt", { key: rate_key })?
            rec : RateRecordResult
            rec = match Json.parse(rec_raw) {
                Ok(v) => v
                Err(_) => { locked: False, retry_after_ms: 0, attempts: 0 }
            }
            if rec.locked {
                return Err("Too many failed attempts; account temporarily locked")
            }
            return Err("Invalid email or password")
        }

        verify_pw! = ctx.crypto.verify_password!
        valid_pw = verify_pw!(args.password, acc.secret_hash)?
        if !valid_pw {
            rec_raw = Ctx.run_mutation!(ctx, "${ns}._recordFailedAttempt", { key: rate_key })?
            rec : RateRecordResult
            rec = match Json.parse(rec_raw) {
                Ok(v) => v
                Err(_) => { locked: False, retry_after_ms: 0, attempts: 0 }
            }
            if rec.locked {
                return Err("Too many failed attempts; account temporarily locked")
            }
            return Err("Invalid email or password")
        }

        _ = Ctx.run_mutation!(ctx, "${ns}._resetRateLimit", { key: rate_key })?

        rand_bytes! = ctx.crypto.random_bytes!
        rt_rand = rand_bytes!(32)?
        raw_refresh_token = "rt_${rt_rand}"
        sha256! = ctx.crypto.sha256!
        refresh_token_hash = sha256!(raw_refresh_token)?

        sess_raw = Ctx.run_mutation!(ctx, "${ns}._createSession", {
            user_id: acc.user_id,
            refresh_token_hash,
            user_agent: args.user_agent,
        })?
        sess : CreateSessionResult
        sess = match Json.parse(sess_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode session creation: ${msg}")
        }

        minted = mint_access_jwt!(cfg, ctx, {
            user_id: acc.user_id,
            session_id: sess.session_id,
            email: acc.email,
            email_verified: acc.email_verified,
            name: acc.name,
            roles: if List.is_empty(acc.roles) { cfg.default_roles } else { acc.roles },
        })?

        Ok({
            access_token: minted.access_token,
            refresh_token: raw_refresh_token,
            session_id: sess.session_id,
            user_id: acc.user_id,
            expires_at_ms: minted.expires_at_ms,
            email: acc.email,
            name: acc.name,
        })
    }

    request_otp_action! : Str, Config, Ctx.ActionCtx, RequestOtpArgs => Try(RequestOtpResult, Str)
    request_otp_action! = |ns, cfg, ctx, args| {
        email = Token.normalize_email(args.email)
        if !Token.is_valid_email(email) {
            return Err("Invalid email address")
        }

        now = Ctx.now_ms!(ctx)
        rand_bytes! = ctx.crypto.random_bytes!
        entropy = rand_bytes!(16)?
        code = Token.derive_otp_digits(entropy)
        sha256! = ctx.crypto.sha256!
        code_hash = sha256!(code)?

        _ = Ctx.run_mutation!(ctx, "${ns}._storeVerificationCode", {
            identifier: email,
            code_hash,
            kind: "otp",
            provider: "otp",
            verifier: "",
            redirect_to: "",
            ttl_ms: cfg.otp_ttl_ms,
        })?

        expires_at_ms = now + cfg.otp_ttl_ms
        if !Str.is_empty(cfg.otp_webhook_url) {
            payload = "{\"email\":${Json.to_str(email)},\"code\":${Json.to_str(code)},\"expires_at_ms\":${expires_at_ms.to_str()}}"
            resp = Ctx.http_request!(ctx, {
                method: "POST",
                url: cfg.otp_webhook_url,
                headers: [{ name: "Content-Type", value: "application/json" }],
                body: payload,
            })?
            if resp.status < 200 or resp.status >= 300 {
                return Err("OTP delivery webhook failed with status ${resp.status.to_str()}")
            }
        }

        Ok({
            sent: True,
            expires_at_ms,
            dev_code: if cfg.expose_otp_for_dev { code } else { "" },
        })
    }

    verify_otp_action! : Str, Config, Ctx.ActionCtx, VerifyOtpArgs => Try(AuthTokenResult, Str)
    verify_otp_action! = |ns, cfg, ctx, args| {
        email = Token.normalize_email(args.email)
        trimmed_code = Str.trim(args.code)
        if !Token.is_valid_email(email) or Str.is_empty(trimmed_code) {
            return Err("Invalid or expired verification code")
        }

        rate_key = "otp:${email}"
        rl_raw = Ctx.run_query!(ctx, "${ns}._checkRateLimit", { key: rate_key })?
        rl : RateCheckResult
        rl = match Json.parse(rl_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode rate limit check: ${msg}")
        }
        if !rl.allowed {
            return Err("Too many failed attempts; account temporarily locked")
        }

        otp_raw = Ctx.run_query!(ctx, "${ns}._findLatestOtp", { email: email })?
        otp : FindLatestOtpResult
        otp = match Json.parse(otp_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode OTP lookup: ${msg}")
        }
        if !otp.found {
            _ = Ctx.run_mutation!(ctx, "${ns}._recordFailedAttempt", { key: rate_key })?
            return Err("Invalid or expired verification code")
        }

        sha256! = ctx.crypto.sha256!
        provided_hash = sha256!(trimmed_code)?
        ct_eq! = ctx.crypto.ct_eq!
        matched = ct_eq!(provided_hash, otp.code_hash)?
        if !matched {
            rec_raw = Ctx.run_mutation!(ctx, "${ns}._recordFailedAttempt", { key: rate_key })?
            rec : RateRecordResult
            rec = match Json.parse(rec_raw) {
                Ok(v) => v
                Err(_) => { locked: False, retry_after_ms: 0, attempts: 0 }
            }
            if rec.locked {
                return Err("Too many failed attempts; account temporarily locked")
            }
            return Err("Invalid or expired verification code")
        }

        rand_bytes! = ctx.crypto.random_bytes!
        uid_rand = rand_bytes!(16)?
        rt_rand = rand_bytes!(32)?
        new_user_id = "usr_${uid_rand}"
        raw_refresh_token = "rt_${rt_rand}"
        refresh_token_hash = sha256!(raw_refresh_token)?

        created_raw = Ctx.run_mutation!(ctx, "${ns}._completeOtpSignIn", {
            code_id: otp.code_id,
            email,
            name: args.name,
            new_user_id,
            refresh_token_hash,
            user_agent: args.user_agent,
        })?
        created : CreatedSessionInfo
        created = match Json.parse(created_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode OTP session: ${msg}")
        }

        minted = mint_access_jwt!(cfg, ctx, {
            user_id: created.user_id,
            session_id: created.session_id,
            email: created.email,
            email_verified: created.email_verified,
            name: created.name,
            roles: created.roles,
        })?

        Ok({
            access_token: minted.access_token,
            refresh_token: raw_refresh_token,
            session_id: created.session_id,
            user_id: created.user_id,
            expires_at_ms: minted.expires_at_ms,
            email: created.email,
            name: created.name,
        })
    }

    refresh_action! : Str, Config, Ctx.ActionCtx, RefreshArgs => Try(AuthTokenResult, Str)
    refresh_action! = |ns, cfg, ctx, args| {
        raw_token = Str.trim(args.refresh_token)
        if Str.is_empty(raw_token) {
            return Err("Missing refresh token")
        }

        sha256! = ctx.crypto.sha256!
        token_hash = sha256!(raw_token)?

        rand_bytes! = ctx.crypto.random_bytes!
        next_rand = rand_bytes!(32)?
        next_refresh_token = "rt_${next_rand}"
        next_token_hash = sha256!(next_refresh_token)?

        rot_raw = Ctx.run_mutation!(ctx, "${ns}._rotateRefreshToken", {
            token_hash,
            new_token_hash: next_token_hash,
        })?
        rot : RotateRefreshResult
        rot = match Json.parse(rot_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode refresh rotation: ${msg}")
        }

        if rot.outcome == "rotated" or rot.outcome == "grace" {
            minted = mint_access_jwt!(cfg, ctx, {
                user_id: rot.user_id,
                session_id: rot.session_id,
                email: rot.email,
                email_verified: rot.email_verified,
                name: rot.name,
                roles: rot.roles,
            })?
            out_rt = if rot.outcome == "rotated" { next_refresh_token } else { "" }
            Ok({
                access_token: minted.access_token,
                refresh_token: out_rt,
                session_id: rot.session_id,
                user_id: rot.user_id,
                expires_at_ms: minted.expires_at_ms,
                email: rot.email,
                name: rot.name,
            })
        } else {
            Err(if Str.is_empty(rot.error) { "Refresh token rejected" } else { rot.error })
        }
    }

    exchange_oauth_code_action! : Str, Config, Ctx.ActionCtx, ExchangeOAuthCodeArgs => Try(AuthTokenResult, Str)
    exchange_oauth_code_action! = |ns, cfg, ctx, args| {
        trimmed_code = Str.trim(args.code)
        if Str.is_empty(trimmed_code) {
            return Err("Missing OAuth exchange code")
        }

        sha256! = ctx.crypto.sha256!
        code_hash = sha256!(trimmed_code)?

        consume_args : ConsumeOAuthExchangeArgs
        consume_args = { code_hash: code_hash }
        consumed_raw = Ctx.run_mutation!(ctx, "${ns}._consumeOAuthExchangeCode", consume_args)?
        consumed : ConsumeOAuthExchangeResult
        consumed = match Json.parse(consumed_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode OAuth exchange consumption: ${msg}")
        }
        if !consumed.valid {
            return Err(if Str.is_empty(consumed.error) { "Invalid or expired OAuth exchange code" } else { consumed.error })
        }

        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        aead_decrypt! = ctx.crypto.aead_decrypt!
        payload_json = aead_decrypt!(seed, consumed.verifier, "oauth_exchange:${code_hash}")?
        payload : PendingExchangePayload
        payload = match Json.parse(payload_json) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode OAuth exchange payload: ${msg}")
        }
        if payload.user_id != consumed.user_id or Str.is_empty(payload.user_id) {
            return Err("OAuth exchange payload mismatch")
        }

        rand_bytes! = ctx.crypto.random_bytes!
        rt_rand = rand_bytes!(32)?
        raw_refresh_token = "rt_${rt_rand}"
        refresh_token_hash = sha256!(raw_refresh_token)?

        create_sess_args : CreateSessionArgs
        create_sess_args = {
            user_id: payload.user_id,
            refresh_token_hash,
            user_agent: args.user_agent,
        }
        sess_raw = Ctx.run_mutation!(ctx, "${ns}._createSession", create_sess_args)?
        sess : CreateSessionResult
        sess = match Json.parse(sess_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode session creation: ${msg}")
        }

        minted = mint_access_jwt!(cfg, ctx, {
            user_id: payload.user_id,
            session_id: sess.session_id,
            email: payload.email,
            email_verified: payload.email_verified,
            name: payload.name,
            roles: if List.is_empty(payload.roles) { cfg.default_roles } else { payload.roles },
        })?

        Ok({
            access_token: minted.access_token,
            refresh_token: raw_refresh_token,
            session_id: sess.session_id,
            user_id: payload.user_id,
            expires_at_ms: minted.expires_at_ms,
            email: payload.email,
            name: payload.name,
        })
    }

    request_magic_link_action! : Str, Config, Ctx.ActionCtx, RequestMagicLinkArgs => Try(RequestMagicLinkResult, Str)
    request_magic_link_action! = |ns, cfg, ctx, args| {
        email = Token.normalize_email(args.email)
        if !Token.is_valid_email(email) {
            return Err("Invalid email address")
        }

        rate_key = "ml:${email}"
        rl_args : RateKeyArgs
        rl_args = { key: rate_key }
        rl_raw = Ctx.run_query!(ctx, "${ns}._checkRateLimit", rl_args)?
        rl : RateCheckResult
        rl = match Json.parse(rl_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode rate limit check: ${msg}")
        }
        if !rl.allowed {
            return Err("Too many magic link requests; please try again later")
        }

        safe_redirect =
            if OAuth.is_safe_redirect(args.redirect_to) {
                args.redirect_to
            } else {
                cfg.oauth_success_redirect
            }

        now = Ctx.now_ms!(ctx)
        rand_bytes! = ctx.crypto.random_bytes!
        tok_rand = rand_bytes!(32)?
        token = "ml_${tok_rand}"
        sha256! = ctx.crypto.sha256!
        code_hash = sha256!(token)?

        store_args : StoreCodeArgs
        store_args = {
            identifier: email,
            code_hash,
            kind: "magic_link",
            provider: "magic_link",
            verifier: "",
            redirect_to: safe_redirect,
            ttl_ms: cfg.magic_link_ttl_ms,
        }
        _ = Ctx.run_mutation!(ctx, "${ns}._storeVerificationCode", store_args)?

        expires_at_ms = now + cfg.magic_link_ttl_ms
        base_verify_url =
            if !Str.is_empty(cfg.magic_link_base_url) {
                cfg.magic_link_base_url
            } else {
                magic_link_verify_path(cfg)
            }
        url_sep = if Str.contains(base_verify_url, "?") { "&" } else { "?" }
        full_magic_url = "${base_verify_url}${url_sep}token=${OAuth.url_encode(token)}"

        if !Str.is_empty(cfg.magic_link_webhook_url) {
            payload = "{\"email\":${Json.to_str(email)},\"token\":${Json.to_str(token)},\"magic_url\":${Json.to_str(full_magic_url)},\"expires_at_ms\":${expires_at_ms.to_str()}}"
            resp = Ctx.http_request!(ctx, {
                method: "POST",
                url: cfg.magic_link_webhook_url,
                headers: [{ name: "Content-Type", value: "application/json" }],
                body: payload,
            })?
            if resp.status < 200 or resp.status >= 300 {
                return Err("Magic link delivery webhook failed with status ${resp.status.to_str()}")
            }
        }

        Ok({
            sent: True,
            expires_at_ms,
            dev_token: if cfg.expose_otp_for_dev { token } else { "" },
            magic_url: if cfg.expose_otp_for_dev { full_magic_url } else { "" },
        })
    }

    verify_magic_link_action! : Str, Config, Ctx.ActionCtx, VerifyMagicLinkArgs => Try(AuthTokenResult, Str)
    verify_magic_link_action! = |ns, cfg, ctx, args| {
        trimmed_token = Str.trim(args.token)
        if Str.is_empty(trimmed_token) {
            return Err("Invalid or expired magic link")
        }

        sha256! = ctx.crypto.sha256!
        code_hash = sha256!(trimmed_token)?

        rand_bytes! = ctx.crypto.random_bytes!
        uid_rand = rand_bytes!(16)?
        rt_rand = rand_bytes!(32)?
        new_user_id = "usr_${uid_rand}"
        raw_refresh_token = "rt_${rt_rand}"
        refresh_token_hash = sha256!(raw_refresh_token)?

        complete_args : CompleteMagicLinkArgs
        complete_args = {
            code_hash,
            name: args.name,
            new_user_id,
            refresh_token_hash,
            user_agent: args.user_agent,
        }
        created_raw = Ctx.run_mutation!(ctx, "${ns}._completeMagicLinkSignIn", complete_args)?
        created : CreatedSessionInfo
        created = match Json.parse(created_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode magic link session: ${msg}")
        }

        minted = mint_access_jwt!(cfg, ctx, {
            user_id: created.user_id,
            session_id: created.session_id,
            email: created.email,
            email_verified: created.email_verified,
            name: created.name,
            roles: created.roles,
        })?

        Ok({
            access_token: minted.access_token,
            refresh_token: raw_refresh_token,
            session_id: created.session_id,
            user_id: created.user_id,
            expires_at_ms: minted.expires_at_ms,
            email: created.email,
            name: created.name,
        })
    }

    enroll_totp_action! : Str, Config, Ctx.ActionCtx, {} => Try(EnrollTotpResult, Str)
    enroll_totp_action! = |ns, cfg, ctx, _| {
        id = require_active_session_action!(ns, ctx)?

        rand_bytes! = ctx.crypto.random_bytes!
        raw_b64 = rand_bytes!(20)?
        secret_bytes = Totp.base64url_decode(raw_b64)?
        secret_base32 = Totp.base32_encode(secret_bytes)

        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        aead_encrypt! = ctx.crypto.aead_encrypt!
        secret_ciphertext = aead_encrypt!(seed, secret_base32, "totp:${id.subject}")?

        upsert_args : UpsertPendingTotpArgs
        upsert_args = {
            user_id: id.subject,
            secret_ciphertext,
        }
        _ = Ctx.run_mutation!(ctx, "${ns}._upsertPendingTotpFactor", upsert_args)?

        account_label = if !Str.is_empty(id.email) { id.email } else { id.subject }
        otpauth_uri = Totp.build_otpauth_uri(cfg.issuer, account_label, secret_base32)
        Ok({
            secret_base32,
            otpauth_uri,
        })
    }

    confirm_totp_action! : Str, Config, Ctx.ActionCtx, TotpCodeArgs => Try(ConfirmTotpResult, Str)
    confirm_totp_action! = |ns, cfg, ctx, args| {
        id = require_active_session_action!(ns, ctx)?

        get_args : GetTotpFactorArgs
        get_args = { user_id: id.subject }
        factor_raw = Ctx.run_query!(ctx, "${ns}._getTotpFactor", get_args)?
        factor : GetTotpFactorResult
        factor = match Json.parse(factor_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode TOTP factor: ${msg}")
        }
        if !factor.found {
            return Err("TOTP enrollment not found")
        }
        if factor.enabled {
            return Err("TOTP is already enabled")
        }

        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        aead_decrypt! = ctx.crypto.aead_decrypt!
        secret_base32 = aead_decrypt!(seed, factor.secret_ciphertext, "totp:${id.subject}")?
        secret_bytes = Totp.base32_decode(secret_base32)?

        now_secs = Ctx.now_ms!(ctx) // 1000
        match Totp.verify_totp(secret_bytes, args.code, now_secs) {
            Invalid => Err("Invalid TOTP code")
            Valid(step) => {
                enable_args : UpdateTotpStepArgs
                enable_args = {
                    factor_id: factor.factor_id,
                    user_id: id.subject,
                    step,
                }
                _ = Ctx.run_mutation!(ctx, "${ns}._enableTotpFactor", enable_args)?
                Ok({ enabled: True })
            }
        }
    }

    verify_totp_action! : Str, Config, Ctx.ActionCtx, TotpCodeArgs => Try(VerifyTotpResult, Str)
    verify_totp_action! = |ns, cfg, ctx, args| {
        id = require_active_session_action!(ns, ctx)?

        rate_key = "totp:${id.subject}"
        rl_args : RateKeyArgs
        rl_args = { key: rate_key }
        rl_raw = Ctx.run_query!(ctx, "${ns}._checkRateLimit", rl_args)?
        rl : RateCheckResult
        rl = match Json.parse(rl_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode rate limit check: ${msg}")
        }
        if !rl.allowed {
            return Err("Too many failed attempts; account temporarily locked")
        }

        get_args : GetTotpFactorArgs
        get_args = { user_id: id.subject }
        factor_raw = Ctx.run_query!(ctx, "${ns}._getTotpFactor", get_args)?
        factor : GetTotpFactorResult
        factor = match Json.parse(factor_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode TOTP factor: ${msg}")
        }
        if !factor.found or !factor.enabled {
            return Err("TOTP is not enabled for this account")
        }

        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        aead_decrypt! = ctx.crypto.aead_decrypt!
        secret_base32 = aead_decrypt!(seed, factor.secret_ciphertext, "totp:${id.subject}")?
        secret_bytes = Totp.base32_decode(secret_base32)?

        now_secs = Ctx.now_ms!(ctx) // 1000
        match Totp.verify_totp(secret_bytes, args.code, now_secs) {
            Invalid => {
                rec_raw = Ctx.run_mutation!(ctx, "${ns}._recordFailedAttempt", rl_args)?
                rec : RateRecordResult
                rec = match Json.parse(rec_raw) {
                    Ok(v) => v
                    Err(_) => { locked: False, retry_after_ms: 0, attempts: 0 }
                }
                if rec.locked {
                    return Err("Too many failed attempts; account temporarily locked")
                }
                Err("Invalid TOTP code")
            }
            Valid(step) => {
                step_args : UpdateTotpStepArgs
                step_args = {
                    factor_id: factor.factor_id,
                    user_id: id.subject,
                    step,
                }
                _ = Ctx.run_mutation!(ctx, "${ns}._consumeTotpStep", step_args)?
                _ = Ctx.run_mutation!(ctx, "${ns}._resetRateLimit", rl_args)?
                Ok({ valid: True, step })
            }
        }
    }

    disable_totp_action! : Str, Config, Ctx.ActionCtx, TotpCodeArgs => Try(DisableTotpResult, Str)
    disable_totp_action! = |ns, cfg, ctx, args| {
        id = require_active_session_action!(ns, ctx)?

        get_args : GetTotpFactorArgs
        get_args = { user_id: id.subject }
        factor_raw = Ctx.run_query!(ctx, "${ns}._getTotpFactor", get_args)?
        factor : GetTotpFactorResult
        factor = match Json.parse(factor_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode TOTP factor: ${msg}")
        }
        if !factor.found or !factor.enabled {
            return Err("TOTP is not enabled for this account")
        }

        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        aead_decrypt! = ctx.crypto.aead_decrypt!
        secret_base32 = aead_decrypt!(seed, factor.secret_ciphertext, "totp:${id.subject}")?
        secret_bytes = Totp.base32_decode(secret_base32)?

        now_secs = Ctx.now_ms!(ctx) // 1000
        match Totp.verify_totp(secret_bytes, args.code, now_secs) {
            Invalid => Err("Invalid TOTP code")
            Valid(_) => {
                del_args : DeleteTotpFactorArgs
                del_args = {
                    factor_id: factor.factor_id,
                    user_id: id.subject,
                }
                _ = Ctx.run_mutation!(ctx, "${ns}._deleteTotpFactor", del_args)?
                Ok({ disabled: True })
            }
        }
    }

    # -------------------------------------------------------------------------
    # HTTP Routes: JWKS Endpoint + Magic Link + Modular OAuth2 PKCE
    # -------------------------------------------------------------------------

    jwks_route! : Config, Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponseEx, Str)
    jwks_route! = |cfg, ctx, _| {
        seed = Ctx.secret_get!(ctx, cfg.jwt_secret_name)?
        ed25519_jwk! = ctx.crypto.ed25519_jwk!
        jwk_json = ed25519_jwk!(seed, cfg.jwt_kid)?
        Ok({
            status: 200,
            content_type: "application/json",
            headers: [
                { name: "Cache-Control", value: "public, max-age=300" },
            ],
            body: "{\"keys\":[${jwk_json}]}",
        })
    }

    oauth_start_route! : Str, Config, OAuth.ProviderConfig, Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponseEx, Str)
    oauth_start_route! = |ns, cfg, provider, ctx, req| {
        rand_bytes! = ctx.crypto.random_bytes!
        state = rand_bytes!(24)?
        verifier = rand_bytes!(32)?

        sha256_b64url! = ctx.crypto.sha256_b64url!
        code_challenge = sha256_b64url!(verifier)?

        sha256! = ctx.crypto.sha256!
        state_hash = sha256!(state)?

        redirect_to = match OAuth.parse_query_param(req.query, "redirect_to") {
            Found(r) => if OAuth.is_safe_redirect(r) { r } else { cfg.oauth_success_redirect }
            NotFound => cfg.oauth_success_redirect
        }

        store_pkce_args : StoreCodeArgs
        store_pkce_args = {
            identifier: provider.id,
            code_hash: state_hash,
            kind: "oauth_pkce",
            provider: provider.id,
            verifier,
            redirect_to,
            ttl_ms: 600000,
        }
        _ = Ctx.run_mutation!(ctx, "${ns}._storeVerificationCode", store_pkce_args)?

        authorize_url = OAuth.build_authorize_url(provider, state, code_challenge)
        cookie_val = OAuth.build_state_cookie(cfg.oauth_route_prefix, state, cfg.secure_cookies)

        Ok({
            status: 302,
            content_type: "text/plain",
            headers: [
                { name: "Location", value: authorize_url },
                { name: "Set-Cookie", value: cookie_val },
                { name: "Cache-Control", value: "no-store" },
            ],
            body: "",
        })
    }

    json_error_response : U64, Str, List(App.HttpHeader) -> App.HttpRouteResponseEx
    json_error_response = |status, message, headers| {
        status,
        content_type: "application/json",
        headers,
        body: "{\"ok\":false,\"error\":${Json.to_str(message)}}",
    }

    oauth_callback_route! : Str, Config, OAuth.ProviderConfig, Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponseEx, Str)
    oauth_callback_route! = |ns, cfg, provider, ctx, req| {
        clear_cookie = OAuth.clear_state_cookie(cfg.oauth_route_prefix, cfg.secure_cookies)
        base_headers : List(App.HttpHeader)
        base_headers = [
            { name: "Set-Cookie", value: clear_cookie },
            { name: "Cache-Control", value: "no-store" },
        ]

        match OAuth.parse_query_param(req.query, "error") {
            Found(err_code) =>
                if !Str.is_empty(err_code) {
                    return Ok(json_error_response(400, "OAuth provider returned error: ${err_code}", base_headers))
                } else {}
            NotFound => {}
        }

        code = match OAuth.parse_query_param(req.query, "code") {
            Found(c) => if Str.is_empty(c) { return Ok(json_error_response(400, "Missing OAuth authorization code", base_headers)) } else { c }
            NotFound => return Ok(json_error_response(400, "Missing OAuth authorization code", base_headers))
        }

        query_state = match OAuth.parse_query_param(req.query, "state") {
            Found(s) => if Str.is_empty(s) { return Ok(json_error_response(400, "Missing OAuth state", base_headers)) } else { s }
            NotFound => return Ok(json_error_response(400, "Missing OAuth state", base_headers))
        }

        cookie_header = match App.header_value(req, "cookie") {
            Ok(h) => h
            Err(NotFound) => return Ok(json_error_response(400, "Missing OAuth state cookie", base_headers))
        }
        cookie_state = match OAuth.parse_cookie(cookie_header, "concave_oauth_state") {
            Found(s) => s
            NotFound => return Ok(json_error_response(400, "Missing OAuth state cookie", base_headers))
        }

        ct_eq! = ctx.crypto.ct_eq!
        state_match = ct_eq!(query_state, cookie_state)?
        if !state_match {
            return Ok(json_error_response(400, "OAuth CSRF state mismatch", base_headers))
        }

        sha256! = ctx.crypto.sha256!
        state_hash = sha256!(query_state)?

        pkce_raw = Ctx.run_mutation!(ctx, "${ns}._consumeOAuthPkce", {
            state_hash,
            provider: provider.id,
        })?
        pkce : ConsumeOAuthPkceResult
        pkce = match Json.parse(pkce_raw) {
            Ok(v) => v
            Err(InvalidJson(msg)) => return Err("failed to decode OAuth PKCE state: ${msg}")
        }
        if !pkce.valid {
            return Ok(json_error_response(400, pkce.error, base_headers))
        }

        client_secret = Ctx.secret_get!(ctx, provider.client_secret_name)?
        token_body = OAuth.build_token_exchange_body(provider, code, client_secret, pkce.verifier)
        token_http = Ctx.http_request!(ctx, {
            method: "POST",
            url: provider.token_url,
            headers: [
                { name: "Content-Type", value: "application/x-www-form-urlencoded" },
                { name: "Accept", value: "application/json" },
            ],
            body: token_body,
        })?
        if token_http.status < 200 or token_http.status >= 300 {
            return Ok(json_error_response(502, "OAuth token endpoint returned HTTP ${token_http.status.to_str()}", base_headers))
        }
        tok = match OAuth.parse_token_response(token_http.body) {
            Ok(t) => t
            Err(msg) => return Ok(json_error_response(502, msg, base_headers))
        }

        userinfo_http = Ctx.http_request!(ctx, {
            method: "GET",
            url: provider.userinfo_url,
            headers: [
                { name: "Authorization", value: "Bearer ${tok.access_token}" },
                { name: "Accept", value: "application/json" },
                { name: "User-Agent", value: "Concave-Auth/2.0" },
            ],
            body: "",
        })?
        if userinfo_http.status < 200 or userinfo_http.status >= 300 {
            return Ok(json_error_response(502, "OAuth userinfo endpoint returned HTTP ${userinfo_http.status.to_str()}", base_headers))
        }
        uinfo = match OAuth.parse_userinfo_response(userinfo_http.body) {
            Ok(u) => u
            Err(msg) => return Ok(json_error_response(502, msg, base_headers))
        }

        ua = match App.header_value(req, "user-agent") {
            Ok(v) => v
            Err(NotFound) => ""
        }

        accept_hdr = match App.header_value(req, "accept") {
            Ok(h) => h
            Err(NotFound) => ""
        }

        rand_bytes! = ctx.crypto.random_bytes!
        uid_rand = rand_bytes!(16)?
        new_user_id = "usr_${uid_rand}"

        if Str.contains(accept_hdr, "application/json") {
            rt_rand = rand_bytes!(32)?
            raw_refresh_token = "rt_${rt_rand}"
            refresh_token_hash = sha256!(raw_refresh_token)?

            upsert_sess_args : UpsertOAuthAccountArgs
            upsert_sess_args = {
                provider: provider.id,
                provider_account_id: uinfo.provider_account_id,
                email: uinfo.email,
                email_verified: uinfo.email_verified,
                name: uinfo.name,
                new_user_id,
                refresh_token_hash,
                user_agent: ua,
            }
            created_raw = Ctx.run_mutation!(ctx, "${ns}._upsertOAuthAccountAndSession", upsert_sess_args)?
            created : CreatedSessionInfo
            created = match Json.parse(created_raw) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("failed to decode OAuth session creation: ${msg}")
            }

            minted = mint_access_jwt!(cfg, ctx, {
                user_id: created.user_id,
                session_id: created.session_id,
                email: created.email,
                email_verified: created.email_verified,
                name: created.name,
                roles: created.roles,
            })?

            result_payload : AuthTokenResult
            result_payload = {
                access_token: minted.access_token,
                refresh_token: raw_refresh_token,
                session_id: created.session_id,
                user_id: created.user_id,
                expires_at_ms: minted.expires_at_ms,
                email: created.email,
                name: created.name,
            }
            body_json = match Json.to_str_try(result_payload) {
                Ok(s) => s
                Err(_) => return Err("failed to encode OAuth session JSON")
            }
            Ok({
                status: 200,
                content_type: "application/json",
                headers: base_headers,
                body: body_json,
            })
        } else {
            # Browser redirect: upsert/link OAuth account WITHOUT minting tokens or leaving
            # an unredeemed session, then hand off a 60-second single-use `oauth_code`.
            upsert_acc_args : UpsertOAuthAccountOnlyArgs
            upsert_acc_args = {
                provider: provider.id,
                provider_account_id: uinfo.provider_account_id,
                email: uinfo.email,
                email_verified: uinfo.email_verified,
                name: uinfo.name,
                new_user_id,
            }
            acc_raw = Ctx.run_mutation!(ctx, "${ns}._upsertOAuthAccount", upsert_acc_args)?
            acc_payload : PendingExchangePayload
            acc_payload = match Json.parse(acc_raw) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("failed to decode OAuth account upsert: ${msg}")
            }

            oauth_code = issue_oauth_exchange_code!(ns, cfg, ctx, provider.id, acc_payload)?
            dest = if OAuth.is_safe_redirect(pkce.redirect_to) { pkce.redirect_to } else { cfg.oauth_success_redirect }
            sep = if Str.contains(dest, "?") { "&" } else { "?" }
            location = "${dest}${sep}oauth_code=${OAuth.url_encode(oauth_code)}"
            Ok({
                status: 302,
                content_type: "text/plain",
                headers: [
                    { name: "Location", value: location },
                    { name: "Set-Cookie", value: clear_cookie },
                    { name: "Cache-Control", value: "no-store" },
                ],
                body: "",
            })
        }
    }

    magic_link_verify_route! : Str, Config, Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponseEx, Str)
    magic_link_verify_route! = |ns, cfg, ctx, req| {
        no_store_headers : List(App.HttpHeader)
        no_store_headers = [
            { name: "Cache-Control", value: "no-store" },
        ]

        token = match OAuth.parse_query_param(req.query, "token") {
            Found(t) =>
                if Str.is_empty(Str.trim(t)) {
                    return Ok(json_error_response(400, "Missing magic link token", no_store_headers))
                } else {
                    Str.trim(t)
                }
            NotFound => return Ok(json_error_response(400, "Missing magic link token", no_store_headers))
        }

        sha256! = ctx.crypto.sha256!
        code_hash = sha256!(token)?

        rand_bytes! = ctx.crypto.random_bytes!
        uid_rand = rand_bytes!(16)?
        new_user_id = "usr_${uid_rand}"

        accept_hdr = match App.header_value(req, "accept") {
            Ok(h) => h
            Err(NotFound) => ""
        }

        if Str.contains(accept_hdr, "application/json") {
            ua = match App.header_value(req, "user-agent") {
                Ok(v) => v
                Err(NotFound) => ""
            }
            rt_rand = rand_bytes!(32)?
            raw_refresh_token = "rt_${rt_rand}"
            refresh_token_hash = sha256!(raw_refresh_token)?

            complete_args : CompleteMagicLinkArgs
            complete_args = {
                code_hash,
                name: "",
                new_user_id,
                refresh_token_hash,
                user_agent: ua,
            }
            created_raw = match Ctx.run_mutation!(ctx, "${ns}._completeMagicLinkSignIn", complete_args) {
                Ok(r) => r
                Err(msg) => return Ok(json_error_response(400, msg, no_store_headers))
            }
            created : CreatedSessionInfo
            created = match Json.parse(created_raw) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("failed to decode magic link session: ${msg}")
            }

            minted = mint_access_jwt!(cfg, ctx, {
                user_id: created.user_id,
                session_id: created.session_id,
                email: created.email,
                email_verified: created.email_verified,
                name: created.name,
                roles: created.roles,
            })?

            result_payload : AuthTokenResult
            result_payload = {
                access_token: minted.access_token,
                refresh_token: raw_refresh_token,
                session_id: created.session_id,
                user_id: created.user_id,
                expires_at_ms: minted.expires_at_ms,
                email: created.email,
                name: created.name,
            }
            body_json = match Json.to_str_try(result_payload) {
                Ok(s) => s
                Err(_) => return Err("failed to encode magic link session JSON")
            }
            Ok({
                status: 200,
                content_type: "application/json",
                headers: no_store_headers,
                body: body_json,
            })
        } else {
            consume_args : ConsumeMagicLinkAccountArgs
            consume_args = {
                code_hash,
                name: "",
                new_user_id,
            }
            consumed_raw = Ctx.run_mutation!(ctx, "${ns}._consumeMagicLinkAccount", consume_args)?
            consumed : ConsumeMagicLinkAccountResult
            consumed = match Json.parse(consumed_raw) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("failed to decode magic link consumption: ${msg}")
            }
            if !consumed.valid {
                err_msg = if Str.is_empty(consumed.error) { "Invalid or expired magic link" } else { consumed.error }
                return Ok(json_error_response(400, err_msg, no_store_headers))
            }

            acc_payload : PendingExchangePayload
            acc_payload = {
                user_id: consumed.user_id,
                email: consumed.email,
                email_verified: consumed.email_verified,
                name: consumed.name,
                roles: consumed.roles,
            }
            oauth_code = issue_oauth_exchange_code!(ns, cfg, ctx, "magic_link", acc_payload)?
            dest = if OAuth.is_safe_redirect(consumed.redirect_to) { consumed.redirect_to } else { cfg.oauth_success_redirect }
            sep = if Str.contains(dest, "?") { "&" } else { "?" }
            location = "${dest}${sep}oauth_code=${OAuth.url_encode(oauth_code)}"
            Ok({
                status: 302,
                content_type: "text/plain",
                headers: [
                    { name: "Location", value: location },
                    { name: "Cache-Control", value: "no-store" },
                ],
                body: "",
            })
        }
    }

    # -------------------------------------------------------------------------
    # App Attachment
    # -------------------------------------------------------------------------

    ## Attach the Auth v2 component (6 isolated tables, internal DB transitions, public auth actions,
    ## session queries/mutations, `/.well-known/jwks.json`, magic-link verify, and all configured OAuth2 PKCE routes).
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        cfg = m.config

        base_app =
            spec
            |> App.component(m.spec)
            # Internal queries & mutations (blocked on public HTTP/WS)
            |> App.component_internal_query(
                ns,
                "${ns}._checkRateLimit",
                Schema.any,
                Schema.any,
                |ctx, args| check_rate_limit_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._recordFailedAttempt",
                Schema.any,
                Schema.any,
                |ctx, args| record_failed_attempt_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._resetRateLimit",
                Schema.any,
                Schema.bool,
                reset_rate_limit_inner!,
            )
            |> App.component_internal_query(
                ns,
                "${ns}._findPasswordAccount",
                Schema.any,
                Schema.any,
                find_password_account_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._createPasswordAccountAndSession",
                Schema.any,
                Schema.any,
                |ctx, args| create_password_account_and_session_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._createSession",
                Schema.any,
                Schema.any,
                |ctx, args| create_session_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._rotateRefreshToken",
                Schema.any,
                Schema.any,
                |ctx, args| rotate_refresh_token_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._storeVerificationCode",
                Schema.any,
                Schema.str,
                store_verification_code_inner!,
            )
            |> App.component_internal_query(
                ns,
                "${ns}._findLatestOtp",
                Schema.any,
                Schema.any,
                find_latest_otp_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._completeOtpSignIn",
                Schema.any,
                Schema.any,
                |ctx, args| complete_otp_sign_in_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._consumeOAuthPkce",
                Schema.any,
                Schema.any,
                consume_oauth_pkce_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._upsertOAuthAccount",
                Schema.any,
                Schema.any,
                |ctx, args| upsert_oauth_account_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._upsertOAuthAccountAndSession",
                Schema.any,
                Schema.any,
                |ctx, args| upsert_oauth_account_and_session_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._consumeOAuthExchangeCode",
                Schema.any,
                Schema.any,
                consume_oauth_exchange_code_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._completeMagicLinkSignIn",
                Schema.any,
                Schema.any,
                |ctx, args| complete_magic_link_sign_in_inner!(cfg, ctx, args),
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._consumeMagicLinkAccount",
                Schema.any,
                Schema.any,
                |ctx, args| consume_magic_link_account_inner!(cfg, ctx, args),
            )
            |> App.component_internal_query(
                ns,
                "${ns}._getTotpFactor",
                Schema.any,
                Schema.any,
                get_totp_factor_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._upsertPendingTotpFactor",
                Schema.any,
                Schema.str,
                upsert_pending_totp_factor_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._enableTotpFactor",
                Schema.any,
                Schema.bool,
                enable_totp_factor_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._consumeTotpStep",
                Schema.any,
                Schema.bool,
                consume_totp_step_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._deleteTotpFactor",
                Schema.any,
                Schema.bool,
                delete_totp_factor_inner!,
            )
            |> App.component_internal_mutation(
                ns,
                "${ns}._cronCleanupExpired",
                Schema.record([]),
                cleanup_result_schema,
                cron_cleanup_expired_inner!,
            )
            # Public Auth Actions (scoped to component namespace for secret allowlist enforcement)
            |> App.component_action(
                ns,
                "${ns}.signUpPassword",
                sign_up_password_args_schema,
                auth_token_result_schema,
                |ctx, args| sign_up_password_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.signInPassword",
                sign_in_password_args_schema,
                auth_token_result_schema,
                |ctx, args| sign_in_password_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.requestOtp",
                request_otp_args_schema,
                request_otp_result_schema,
                |ctx, args| request_otp_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.verifyOtp",
                verify_otp_args_schema,
                auth_token_result_schema,
                |ctx, args| verify_otp_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.refresh",
                refresh_args_schema,
                auth_token_result_schema,
                |ctx, args| refresh_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.exchangeOAuthCode",
                exchange_oauth_code_args_schema,
                auth_token_result_schema,
                |ctx, args| exchange_oauth_code_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.requestMagicLink",
                request_magic_link_args_schema,
                request_magic_link_result_schema,
                |ctx, args| request_magic_link_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.verifyMagicLink",
                verify_magic_link_args_schema,
                auth_token_result_schema,
                |ctx, args| verify_magic_link_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.enrollTotp",
                Schema.record([]),
                enroll_totp_result_schema,
                |ctx, args| enroll_totp_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.confirmTotp",
                totp_code_args_schema,
                confirm_totp_result_schema,
                |ctx, args| confirm_totp_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.verifyTotp",
                totp_code_args_schema,
                verify_totp_result_schema,
                |ctx, args| verify_totp_action!(ns, cfg, ctx, args),
            )
            |> App.component_action(
                ns,
                "${ns}.disableTotp",
                totp_code_args_schema,
                disable_totp_result_schema,
                |ctx, args| disable_totp_action!(ns, cfg, ctx, args),
            )
            # Public Session Management Mutations & Reactive Queries
            |> App.component_mutation(
                ns,
                "${ns}.signOut",
                Schema.record([]),
                Schema.bool,
                sign_out_inner!,
            )
            |> App.component_mutation(
                ns,
                "${ns}.signOutAll",
                Schema.record([]),
                Schema.int,
                sign_out_all_inner!,
            )
            |> App.component_query(
                ns,
                "${ns}.listSessions",
                Schema.record([]),
                Schema.list(public_session_schema),
                list_sessions_inner!,
            )
            |> App.component_query(
                ns,
                "${ns}.sessionStatus",
                Schema.record([]),
                public_session_status_schema,
                session_status_inner!,
            )
            # Public Ed25519 JWKS Discovery Route (scoped to component namespace for signing key secret)
            |> App.component_http_route_with_headers(
                ns,
                "GET",
                cfg.jwks_path,
                |ctx, req| jwks_route!(cfg, ctx, req),
            )
            # Public Magic Link Verification Route (supports JSON response or single-use `oauth_code` 302 redirect)
            |> App.component_http_route_with_headers(
                ns,
                "GET",
                magic_link_verify_path(cfg),
                |ctx, req| magic_link_verify_route!(ns, cfg, ctx, req),
            )

        var $out_app = base_app
        prefix =
            if Str.ends_with(cfg.oauth_route_prefix, "/") {
                Str.drop_suffix(cfg.oauth_route_prefix, "/")
            } else {
                cfg.oauth_route_prefix
            }
        for provider in m.oauth_providers {
            $out_app =
                $out_app
                |> App.component_http_route_with_headers(
                    ns,
                    "GET",
                    "${prefix}/${provider.id}/start",
                    |ctx, req| oauth_start_route!(ns, cfg, provider, ctx, req),
                )
                |> App.component_http_route_with_headers(
                    ns,
                    "GET",
                    "${prefix}/${provider.id}/callback",
                    |ctx, req| oauth_callback_route!(ns, cfg, provider, ctx, req),
                )
        }
        $out_app
    }

    ## Attach the Auth v2 component AND schedule recurring expired-record cleanup via `App.cron`.
    attach_with_cron : App, Mount, I64 -> App
    attach_with_cron = |spec, m, cleanup_interval_ms| {
        attached = attach(spec, m)
        if cleanup_interval_ms > 0 {
            attached |> App.cron("${m.namespace}_cleanup_expired", cleanup_interval_ms, "${m.namespace}._cronCleanupExpired", "{}")
        } else {
            attached
        }
    }
}

# -----------------------------------------------------------------------------
# Pure-Roc Component Wiring Tests (`roc test packages/auth/Auth.roc`)
# -----------------------------------------------------------------------------

expect {
    # Default mount declares 6 isolated tables and allowlists AUTH_JWT_PRIVATE_KEY.
    m = Auth.mount("auth")
    m.namespace == "auth"
    and m.spec.pkg_name == "concave-auth"
    and List.len(m.spec.tables) == 6
    and m.spec.allowed_secrets == ["AUTH_JWT_PRIVATE_KEY"]
}

expect {
    # Adding OAuth providers automatically allowlists their secrets and mounts start/callback + magic-link + JWKS routes.
    m =
        Auth.mount("auth")
        |> Auth.with_magic_link_base_url("https://example.com/auth/magic-link/verify")
        |> Auth.with_oauth_provider(
            OAuth.google({
                client_id: "g_cid",
                client_secret_name: "GOOGLE_CLIENT_SECRET",
                redirect_uri: "https://example.com/auth/oauth/google/callback",
            }),
        )
        |> Auth.with_oauth_provider(
            OAuth.github({
                client_id: "gh_cid",
                client_secret_name: "GITHUB_CLIENT_SECRET",
                redirect_uri: "https://example.com/auth/oauth/github/callback",
            }),
        )
    spec = App.new("test-auth") |> Auth.attach_with_cron(m, 3600000)

    List.len(m.spec.allowed_secrets) == 3
    and List.any(m.spec.allowed_secrets, |s| s == "AUTH_JWT_PRIVATE_KEY")
    and List.any(m.spec.allowed_secrets, |s| s == "GOOGLE_CLIENT_SECRET")
    and List.any(m.spec.allowed_secrets, |s| s == "GITHUB_CLIENT_SECRET")
    and List.len(spec.components) == 1
    and List.len(spec.actions) == 12
    and List.len(spec.http_routes) == 6 # 1 JWKS + 1 Magic Link verify + 2*2 OAuth routes
    and List.len(spec.crons) == 1
}
