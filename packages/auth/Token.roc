## Pure-Roc Convex Auth v2 token rotation, replay detection, reuse grace window,
## brute-force rate limiting, JWT claims formatting, and email/OTP helpers.

Token := [Token].{
    default_access_ttl_ms : I64
    default_access_ttl_ms = 900000 # 15 minutes

    default_refresh_ttl_ms : I64
    default_refresh_ttl_ms = 2592000000 # 30 days

    default_reuse_window_ms : I64
    default_reuse_window_ms = 10000 # 10 seconds

    default_otp_ttl_ms : I64
    default_otp_ttl_ms = 600000 # 10 minutes

    default_magic_link_ttl_ms : I64
    default_magic_link_ttl_ms = 900000 # 15 minutes

    default_oauth_exchange_ttl_ms : I64
    default_oauth_exchange_ttl_ms = 60000 # 60 seconds

    default_max_failed_attempts : I64
    default_max_failed_attempts = 5

    default_rate_window_ms : I64
    default_rate_window_ms = 900000 # 15 minutes

    default_lockout_ms : I64
    default_lockout_ms = 900000 # 15 minutes

    SessionState : {
        id : Str,
        user_id : Str,
        expires_at_ms : I64,
        revoked_at_ms : I64,
    }

    RefreshTokenState : {
        id : Str,
        session_id : Str,
        parent_token_id : Str,
        expires_at_ms : I64,
        used_at_ms : I64,
        revoked : Bool,
    }

    RotationDecision : [
        RotateNewToken,
        GraceReuseAccessOnly,
        RevokeFamily(Str),
        Reject(Str),
    ]

    RateLimitState : {
        window_start_ms : I64,
        attempts : I64,
        locked_until_ms : I64,
    }

    RateLimitPolicy : {
        max_attempts : I64,
        window_ms : I64,
        lockout_ms : I64,
    }

    RateLimitCheck : [
        Allowed,
        LockedOut(I64),
    ]

    JwtClaimsInput : {
        subject : Str,
        session_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
        roles : List(Str),
        issuer : Str,
        audience : Str,
        issued_at_ms : I64,
        ttl_ms : I64,
    }

    default_rate_policy : RateLimitPolicy
    default_rate_policy = {
        max_attempts: default_max_failed_attempts,
        window_ms: default_rate_window_ms,
        lockout_ms: default_lockout_ms,
    }

    ## Check whether a session is currently active (not revoked and not expired).
    is_session_active : SessionState, I64 -> Bool
    is_session_active = |session, now_ms|
        session.revoked_at_ms == 0 and session.expires_at_ms > now_ms

    ## Evaluate a Convex Auth v2 refresh token exchange against the token & session state.
    ##
    ## - Unused, unrevoked, unexpired token on active session -> `RotateNewToken`.
    ## - Recently-used token within `reuse_window_ms` (default 10s) on active session ->
    ##   `GraceReuseAccessOnly` (concurrent tab / retry tolerance; do NOT revoke session).
    ## - Already-used token OUTSIDE `reuse_window_ms` OR already-revoked token ->
    ##   `RevokeFamily("Refresh token reuse detected; session revoked")`.
    ## - Already-revoked session -> `RevokeFamily("Session has been revoked")`.
    ## - Expired session or expired token -> `Reject(...)`.
    evaluate_refresh : SessionState, RefreshTokenState, I64, I64 -> RotationDecision
    evaluate_refresh = |session, token, now_ms, reuse_window_ms| {
        if token.session_id != session.id {
            return Reject("Refresh token does not match session")
        }
        if session.revoked_at_ms > 0 {
            return RevokeFamily("Session has been revoked")
        }
        if token.revoked {
            return RevokeFamily("Refresh token reuse detected; session revoked")
        }
        if session.expires_at_ms <= now_ms {
            return Reject("Session expired")
        }
        if token.expires_at_ms <= now_ms {
            return Reject("Refresh token expired")
        }
        if token.used_at_ms > 0 {
            age_ms = now_ms - token.used_at_ms
            eff_window = if reuse_window_ms < 0 { 0 } else { reuse_window_ms }
            if age_ms >= 0 and eff_window > 0 and age_ms <= eff_window {
                GraceReuseAccessOnly
            } else {
                RevokeFamily("Refresh token reuse detected; session revoked")
            }
        } else {
            RotateNewToken
        }
    }

    ## Check whether an account/key is currently locked out by brute-force protection.
    check_rate_limit : RateLimitState, RateLimitPolicy, I64 -> RateLimitCheck
    check_rate_limit = |state, _policy, now_ms|
        if state.locked_until_ms > now_ms {
            LockedOut(state.locked_until_ms - now_ms)
        } else {
            Allowed
        }

    ## Record a failed authentication attempt and compute the updated rate-limit state.
    record_failed_attempt : RateLimitState, RateLimitPolicy, I64 -> RateLimitState
    record_failed_attempt = |state, policy, now_ms| {
        max_att = if policy.max_attempts <= 0 { 1 } else { policy.max_attempts }
        win_ms = if policy.window_ms <= 0 { default_rate_window_ms } else { policy.window_ms }
        lock_ms = if policy.lockout_ms <= 0 { default_lockout_ms } else { policy.lockout_ms }

        window_expired =
            state.window_start_ms <= 0
            or (now_ms - state.window_start_ms) >= win_ms
            or (state.locked_until_ms > 0 and state.locked_until_ms <= now_ms)

        if window_expired {
            next_attempts = 1
            locked_until = if next_attempts >= max_att { now_ms + lock_ms } else { 0 }
            {
                window_start_ms: now_ms,
                attempts: next_attempts,
                locked_until_ms: locked_until,
            }
        } else {
            next_attempts = state.attempts + 1
            locked_until =
                if state.locked_until_ms > now_ms {
                    state.locked_until_ms
                } else if next_attempts >= max_att {
                    now_ms + lock_ms
                } else {
                    0
                }
            {
                window_start_ms: state.window_start_ms,
                attempts: next_attempts,
                locked_until_ms: locked_until,
            }
        }
    }

    ## Reset brute-force rate-limit counters after a successful sign-in.
    reset_rate_limit : I64 -> RateLimitState
    reset_rate_limit = |now_ms| {
        window_start_ms: now_ms,
        attempts: 0,
        locked_until_ms: 0,
    }

    ## Build the JWT claims JSON object expected by `ctx.crypto.jwt_sign_ed25519!` and verified by Concave's host.
    build_jwt_claims_json : JwtClaimsInput -> Str
    build_jwt_claims_json = |c| build_jwt_claims_json_with_jti(c, "")

    ## Build the JWT claims JSON object with an optional unique RFC 7519 `jti` token ID.
    build_jwt_claims_json_with_jti : JwtClaimsInput, Str -> Str
    build_jwt_claims_json_with_jti = |c, jti| {
        iat_secs = c.issued_at_ms // 1000
        eff_ttl = if c.ttl_ms < 1000 { 1000 } else { c.ttl_ms }
        raw_exp = (c.issued_at_ms + eff_ttl) // 1000
        exp_secs = if raw_exp <= iat_secs { iat_secs + 1 } else { raw_exp }
        verified_str = if c.email_verified { "true" } else { "false" }
        roles_json = c.roles |> List.map(Json.to_str) |> Str.join_with(",")
        jti_part = if Str.is_empty(jti) { "" } else { ",\"jti\":${Json.to_str(jti)}" }
        "{\"sub\":${Json.to_str(c.subject)},\"sid\":${Json.to_str(c.session_id)},\"email\":${Json.to_str(c.email)},\"email_verified\":${verified_str},\"name\":${Json.to_str(c.name)},\"roles\":[${roles_json}],\"iss\":${Json.to_str(c.issuer)},\"aud\":${Json.to_str(c.audience)},\"iat\":${iat_secs.to_str()},\"exp\":${exp_secs.to_str()}${jti_part}}"
    }

    ## Trim and ASCII-lowercase an email address.
    normalize_email : Str -> Str
    normalize_email = |raw| {
        trimmed = Str.trim(raw)
        bytes = Str.to_utf8(trimmed)
        lowered = List.map(bytes, |b| if b >= 65 and b <= 90 { b + 32 } else { b })
        match Str.from_utf8(lowered) {
            Ok(s) => s
            Err(_) => trimmed
        }
    }

    ## Basic structural validation for email addresses (no whitespace, single `@`, non-empty local & dotted domain).
    is_valid_email : Str -> Bool
    is_valid_email = |raw| {
        email = normalize_email(raw)
        bytes = Str.to_utf8(email)
        n = List.len(bytes)
        if n < 5 or n > 254 {
            return False
        }
        for b in bytes {
            if b <= 32 or b >= 127 {
                return False
            }
        }
        parts = Str.split_on(email, "@")
        if List.len(parts) != 2 {
            return False
        }
        var $idx = 0.I64
        var $local = ""
        var $domain = ""
        for p in parts {
            if $idx == 0 {
                $local = p
            } else {
                $domain = p
            }
            $idx = $idx + 1
        }
        if Str.is_empty($local) or Str.is_empty($domain) {
            return False
        }
        if !Str.contains($domain, ".") or Str.starts_with($domain, ".") or Str.ends_with($domain, ".") {
            return False
        }
        True
    }

    byte_to_i64 : U8 -> I64
    byte_to_i64 = |b| {
        var $acc = 0.I64
        var $rem = b
        while $rem >= 16 {
            $acc = $acc + 16
            $rem = $rem - 16
        }
        while $rem > 0 {
            $acc = $acc + 1
            $rem = $rem - 1
        }
        $acc
    }

    ## Deterministically derive a zero-padded 6-digit numeric OTP code (`"000000"`..`"999999"`)
    ## from a CSPRNG random string produced by `ctx.crypto.random_bytes!`.
    derive_otp_digits : Str -> Str
    derive_otp_digits = |random_str| {
        bytes = Str.to_utf8(random_str)
        var $acc = 0.I64
        for b in bytes {
            $acc = (($acc * 257) + byte_to_i64(b) + 17) % 1000000
        }
        code = if $acc < 0 { 0 - $acc } else { $acc }
        raw = code.to_str()
        len = List.len(Str.to_utf8(raw))
        if len == 1 {
            "00000${raw}"
        } else if len == 2 {
            "0000${raw}"
        } else if len == 3 {
            "000${raw}"
        } else if len == 4 {
            "00${raw}"
        } else if len == 5 {
            "0${raw}"
        } else {
            raw
        }
    }
}

# -----------------------------------------------------------------------------
# Pure-Roc Unit Tests (`roc test packages/auth/Token.roc`)
# -----------------------------------------------------------------------------

expect {
    # Active unused refresh token rotates to a new token.
    sess = { id: "s1", user_id: "u1", expires_at_ms: 100000, revoked_at_ms: 0 }
    tok = { id: "t1", session_id: "s1", parent_token_id: "", expires_at_ms: 100000, used_at_ms: 0, revoked: False }
    Token.evaluate_refresh(sess, tok, 50000, 10000) == RotateNewToken
}

expect {
    # Reusing a rotated token WITHIN the 10-second grace window succeeds gracefully without revoking!
    sess = { id: "s1", user_id: "u1", expires_at_ms: 100000, revoked_at_ms: 0 }
    tok = { id: "t1", session_id: "s1", parent_token_id: "", expires_at_ms: 100000, used_at_ms: 50000, revoked: False }
    d0 = Token.evaluate_refresh(sess, tok, 50000, 10000)
    d5 = Token.evaluate_refresh(sess, tok, 55000, 10000)
    d10 = Token.evaluate_refresh(sess, tok, 60000, 10000)
    d0 == GraceReuseAccessOnly and d5 == GraceReuseAccessOnly and d10 == GraceReuseAccessOnly
}

expect {
    # Replaying a rotated token OUTSIDE the 10-second grace window revokes the entire session family!
    sess = { id: "s1", user_id: "u1", expires_at_ms: 100000, revoked_at_ms: 0 }
    tok = { id: "t1", session_id: "s1", parent_token_id: "", expires_at_ms: 100000, used_at_ms: 50000, revoked: False }
    Token.evaluate_refresh(sess, tok, 60001, 10000) == RevokeFamily("Refresh token reuse detected; session revoked")
}

expect {
    # Presenting an already-revoked token triggers family revocation.
    sess = { id: "s1", user_id: "u1", expires_at_ms: 100000, revoked_at_ms: 0 }
    tok = { id: "t1", session_id: "s1", parent_token_id: "", expires_at_ms: 100000, used_at_ms: 0, revoked: True }
    Token.evaluate_refresh(sess, tok, 50000, 10000) == RevokeFamily("Refresh token reuse detected; session revoked")
}

expect {
    # Presenting a token for an already-revoked session triggers RevokeFamily.
    sess = { id: "s1", user_id: "u1", expires_at_ms: 100000, revoked_at_ms: 40000 }
    tok = { id: "t1", session_id: "s1", parent_token_id: "", expires_at_ms: 100000, used_at_ms: 0, revoked: False }
    Token.evaluate_refresh(sess, tok, 50000, 10000) == RevokeFamily("Session has been revoked")
}

expect {
    # Expired session, expired token, and mismatched session are cleanly rejected.
    sess = { id: "s1", user_id: "u1", expires_at_ms: 40000, revoked_at_ms: 0 }
    tok = { id: "t1", session_id: "s1", parent_token_id: "", expires_at_ms: 100000, used_at_ms: 0, revoked: False }
    d_exp_sess = Token.evaluate_refresh(sess, tok, 50000, 10000)

    sess_ok = { id: "s1", user_id: "u1", expires_at_ms: 100000, revoked_at_ms: 0 }
    tok_exp = { id: "t1", session_id: "s1", parent_token_id: "", expires_at_ms: 40000, used_at_ms: 0, revoked: False }
    d_exp_tok = Token.evaluate_refresh(sess_ok, tok_exp, 50000, 10000)

    tok_wrong = { id: "t1", session_id: "s2", parent_token_id: "", expires_at_ms: 100000, used_at_ms: 0, revoked: False }
    d_mismatch = Token.evaluate_refresh(sess_ok, tok_wrong, 50000, 10000)

    d_exp_sess == Reject("Session expired")
    and d_exp_tok == Reject("Refresh token expired")
    and d_mismatch == Reject("Refresh token does not match session")
}

expect {
    # Rate limiter locks after 5 failed attempts and unlocks once lockout expires.
    pol = Token.default_rate_policy
    s0 = { window_start_ms: 0, attempts: 0, locked_until_ms: 0 }
    s1 = Token.record_failed_attempt(s0, pol, 1000)
    s2 = Token.record_failed_attempt(s1, pol, 2000)
    s3 = Token.record_failed_attempt(s2, pol, 3000)
    s4 = Token.record_failed_attempt(s3, pol, 4000)
    s5 = Token.record_failed_attempt(s4, pol, 5000)

    Token.check_rate_limit(s4, pol, 4500) == Allowed
    and Token.check_rate_limit(s5, pol, 6000) == LockedOut(899000)
    and Token.check_rate_limit(s5, pol, 905001) == Allowed
    and s5.attempts == 5
}

expect {
    # Email normalization & validation.
    Token.normalize_email("  Alice.Smith@Example.COM ") == "alice.smith@example.com"
    and Token.is_valid_email("alice@example.com")
    and !Token.is_valid_email("not-an-email")
    and !Token.is_valid_email("a@b")
    and !Token.is_valid_email("alice @example.com")
}

expect {
    # JWT claims JSON builder produces valid RFC 7519 claims with integer iat/exp.
    claims = Token.build_jwt_claims_json({
        subject: "usr_123",
        session_id: "ses_456",
        email: "alice@example.com",
        email_verified: True,
        name: "Alice",
        roles: ["user", "admin"],
        issuer: "concave-auth",
        audience: "concave-app",
        issued_at_ms: 1700000000000,
        ttl_ms: 900000,
    })
    Str.contains(claims, "\"sub\":\"usr_123\"")
    and Str.contains(claims, "\"sid\":\"ses_456\"")
    and Str.contains(claims, "\"email_verified\":true")
    and Str.contains(claims, "\"roles\":[\"user\",\"admin\"]")
    and Str.contains(claims, "\"iat\":1700000000")
    and Str.contains(claims, "\"exp\":1700000900")
}

expect {
    # OTP derivation always returns a 6-digit numeric string.
    c1 = Token.derive_otp_digits("abc123XYZ_random_entropy")
    c2 = Token.derive_otp_digits("different_random_entropy_999")
    List.len(Str.to_utf8(c1)) == 6
    and List.len(Str.to_utf8(c2)) == 6
    and c1 != c2
}
