import Token

## Pure-Roc modular OAuth2 + PKCE helpers for Concave's Auth v2 component.
## Provides built-in provider constructors (`google`, `github`, `discord`, `custom`),
## RFC 3986 URL encoding/decoding, Cookie/Query parsing, PKCE authorize/token builders,
## and a tolerant zero-dependency JSON field extractor for external OAuth provider responses.

OAuth := [OAuth].{
    ProviderConfig : {
        id : Str,
        authorize_url : Str,
        token_url : Str,
        userinfo_url : Str,
        scopes : List(Str),
        client_id : Str,
        client_secret_name : Str,
        redirect_uri : Str,
    }

    TokenResponse : {
        access_token : Str,
        token_type : Str,
        scope : Str,
        error : Str,
        error_description : Str,
    }

    UserInfo : {
        provider_account_id : Str,
        email : Str,
        email_verified : Bool,
        name : Str,
    }

    JsonVal : [
        StrVal(Str),
        BoolVal(Bool),
        NumVal(Str),
        OtherVal,
    ]

    JsonEntry : {
        key : Str,
        val : JsonVal,
    }

    ScanPhase : [
        BeforeObj,
        ExpectKey,
        ExpectColon,
        ExpectVal,
        ReadPrim,
        SkipNested,
        Done,
    ]

    StrTarget : [
        KeyTarget,
        ValTarget,
    ]

    PctState : [
        PctNormal,
        PctHi,
        PctLo(U8),
    ]

    # -------------------------------------------------------------------------
    # Provider Constructors
    # -------------------------------------------------------------------------

    google : { client_id : Str, client_secret_name : Str, redirect_uri : Str } -> ProviderConfig
    google = |cfg| {
        id: "google",
        authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
        token_url: "https://oauth2.googleapis.com/token",
        userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
        scopes: ["openid", "email", "profile"],
        client_id: cfg.client_id,
        client_secret_name: cfg.client_secret_name,
        redirect_uri: cfg.redirect_uri,
    }

    github : { client_id : Str, client_secret_name : Str, redirect_uri : Str } -> ProviderConfig
    github = |cfg| {
        id: "github",
        authorize_url: "https://github.com/login/oauth/authorize",
        token_url: "https://github.com/login/oauth/access_token",
        userinfo_url: "https://api.github.com/user",
        scopes: ["read:user", "user:email"],
        client_id: cfg.client_id,
        client_secret_name: cfg.client_secret_name,
        redirect_uri: cfg.redirect_uri,
    }

    discord : { client_id : Str, client_secret_name : Str, redirect_uri : Str } -> ProviderConfig
    discord = |cfg| {
        id: "discord",
        authorize_url: "https://discord.com/api/oauth2/authorize",
        token_url: "https://discord.com/api/oauth2/token",
        userinfo_url: "https://discord.com/api/users/@me",
        scopes: ["identify", "email"],
        client_id: cfg.client_id,
        client_secret_name: cfg.client_secret_name,
        redirect_uri: cfg.redirect_uri,
    }

    custom : ProviderConfig -> ProviderConfig
    custom = |cfg| cfg

    # -------------------------------------------------------------------------
    # URL / Query / Cookie / Redirect Helpers
    # -------------------------------------------------------------------------

    is_unreserved : U8 -> Bool
    is_unreserved = |b|
        (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or (b >= 48 and b <= 57)
        or b == 45 # '-'
        or b == 46 # '.'
        or b == 95 # '_'
        or b == 126 # '~'

    hex_digit_upper : U8 -> U8
    hex_digit_upper = |n|
        if n < 10 { 48 + n } else { 55 + n }

    hex_val : U8 -> [Hex(U8), NotHex]
    hex_val = |b|
        if b >= 48 and b <= 57 {
            Hex(b - 48)
        } else if b >= 65 and b <= 70 {
            Hex(b - 55)
        } else if b >= 97 and b <= 102 {
            Hex(b - 87)
        } else {
            NotHex
        }

    ## RFC 3986 percent-encoding for OAuth query parameters and form bodies.
    url_encode : Str -> Str
    url_encode = |raw| {
        var $out = []
        for b in Str.to_utf8(raw) {
            if is_unreserved(b) {
                $out = List.append($out, b)
            } else {
                $out = List.append($out, 37.U8) # '%'
                $out = List.append($out, hex_digit_upper(b // 16))
                $out = List.append($out, hex_digit_upper(b % 16))
            }
        }
        match Str.from_utf8($out) {
            Ok(s) => s
            Err(_) => raw
        }
    }

    ## Decode `application/x-www-form-urlencoded` / URL query parameter value.
    url_decode : Str -> Str
    url_decode = |raw| {
        var $out = []
        var $state = PctNormal
        for b in Str.to_utf8(raw) {
            match $state {
                PctNormal =>
                    if b == 43 {
                        $out = List.append($out, 32.U8)
                    } else if b == 37 {
                        $state = PctHi
                    } else {
                        $out = List.append($out, b)
                    }
                PctHi =>
                    match hex_val(b) {
                        Hex(h) => {
                            $state = PctLo(h)
                        }
                        NotHex => {
                            $out = List.append($out, 37.U8)
                            $out = List.append($out, b)
                            $state = PctNormal
                        }
                    }
                PctLo(h) =>
                    match hex_val(b) {
                        Hex(l) => {
                            $out = List.append($out, (h * 16) + l)
                            $state = PctNormal
                        }
                        NotHex => {
                            $out = List.append($out, b)
                            $state = PctNormal
                        }
                    }
            }
        }
        match Str.from_utf8($out) {
            Ok(s) => s
            Err(_) => raw
        }
    }

    ## Parse a named query parameter from a URL query string (with or without leading `?`).
    parse_query_param : Str, Str -> [Found(Str), NotFound]
    parse_query_param = |raw_query, target_key| {
        cleaned = if Str.starts_with(raw_query, "?") { Str.drop_prefix(raw_query, "?") } else { raw_query }
        if Str.is_empty(cleaned) {
            return NotFound
        }
        pairs = Str.split_on(cleaned, "&")
        for pair in pairs {
            if !Str.is_empty(pair) {
                parts = Str.split_on(pair, "=")
                var $idx = 0.I64
                var $k = ""
                var $v = ""
                for p in parts {
                    if $idx == 0 {
                        $k = p
                    } else if $idx == 1 {
                        $v = p
                    } else {
                        $v = "${$v}=${p}"
                    }
                    $idx = $idx + 1
                }
                if url_decode($k) == target_key {
                    return Found(url_decode($v))
                }
            }
        }
        NotFound
    }

    ## Parse a named cookie from an HTTP `Cookie` request header.
    parse_cookie : Str, Str -> [Found(Str), NotFound]
    parse_cookie = |cookie_header, target_name| {
        if Str.is_empty(Str.trim(cookie_header)) {
            return NotFound
        }
        pairs = Str.split_on(cookie_header, ";")
        for pair in pairs {
            trimmed = Str.trim(pair)
            if !Str.is_empty(trimmed) {
                parts = Str.split_on(trimmed, "=")
                var $idx = 0.I64
                var $k = ""
                var $v = ""
                for p in parts {
                    if $idx == 0 {
                        $k = Str.trim(p)
                    } else if $idx == 1 {
                        $v = Str.trim(p)
                    } else {
                        $v = "${$v}=${p}"
                    }
                    $idx = $idx + 1
                }
                if $k == target_name {
                    return Found($v)
                }
            }
        }
        NotFound
    }

    ## Validate a post-OAuth redirect path to prevent open-redirect vulnerabilities.
    ## Only relative same-origin paths starting with `/` (and not `//`) are permitted.
    is_safe_redirect : Str -> Bool
    is_safe_redirect = |path| {
        if Str.is_empty(path) {
            return False
        }
        if !Str.starts_with(path, "/") or Str.starts_with(path, "//") or Str.contains(path, "\\") {
            return False
        }
        for b in Str.to_utf8(path) {
            if b < 32 or b == 127 {
                return False
            }
        }
        True
    }

    ## Build the OAuth2 + PKCE S256 authorization URL.
    build_authorize_url : ProviderConfig, Str, Str -> Str
    build_authorize_url = |provider, state, code_challenge| {
        sep = if Str.contains(provider.authorize_url, "?") { "&" } else { "?" }
        scope_str = Str.join_with(provider.scopes, " ")
        "${provider.authorize_url}${sep}response_type=code&client_id=${url_encode(provider.client_id)}&redirect_uri=${url_encode(provider.redirect_uri)}&scope=${url_encode(scope_str)}&state=${url_encode(state)}&code_challenge=${url_encode(code_challenge)}&code_challenge_method=S256"
    }

    ## Build the `application/x-www-form-urlencoded` body for the OAuth2 token exchange request.
    build_token_exchange_body : ProviderConfig, Str, Str, Str -> Str
    build_token_exchange_body = |provider, code, client_secret, code_verifier|
        "grant_type=authorization_code&code=${url_encode(code)}&redirect_uri=${url_encode(provider.redirect_uri)}&client_id=${url_encode(provider.client_id)}&client_secret=${url_encode(client_secret)}&code_verifier=${url_encode(code_verifier)}"

    ## Build the CSRF state cookie set during `/auth/oauth/<provider>/start`.
    build_state_cookie : Str, Str, Bool -> Str
    build_state_cookie = |route_prefix, state, secure| {
        cookie_path = if Str.is_empty(route_prefix) { "/auth/oauth" } else { route_prefix }
        sec = if secure { "; Secure" } else { "" }
        "concave_oauth_state=${state}; HttpOnly; SameSite=Lax; Path=${cookie_path}; Max-Age=600${sec}"
    }

    ## Build the expired Set-Cookie header to clear the CSRF state cookie after callback.
    clear_state_cookie : Str, Bool -> Str
    clear_state_cookie = |route_prefix, secure| {
        cookie_path = if Str.is_empty(route_prefix) { "/auth/oauth" } else { route_prefix }
        sec = if secure { "; Secure" } else { "" }
        "concave_oauth_state=; HttpOnly; SameSite=Lax; Path=${cookie_path}; Max-Age=0${sec}"
    }

    # -------------------------------------------------------------------------
    # Tolerant Zero-Dep Top-Level JSON Extractor (for External OAuth Providers)
    # -------------------------------------------------------------------------

    is_ws : U8 -> Bool
    is_ws = |b| b == 32 or b == 9 or b == 10 or b == 13

    decode_prim : List(U8) -> JsonVal
    decode_prim = |buf|
        match Str.from_utf8(buf) {
            Ok(s) => {
                t = Str.trim(s)
                if t == "true" {
                    BoolVal(True)
                } else if t == "false" {
                    BoolVal(False)
                } else if t == "null" or Str.is_empty(t) {
                    OtherVal
                } else {
                    NumVal(t)
                }
            }
            Err(_) => OtherVal
        }

    scan_json_object : Str -> List(JsonEntry)
    scan_json_object = |raw| {
        var $entries = []
        var $phase = BeforeObj
        var $depth = 0.I64
        var $in_str = False
        var $escape = False
        var $str_target = KeyTarget
        var $str_buf = []
        var $cur_key = ""
        var $prim_buf = []
        var $nested_in_str = False
        var $nested_escape = False

        for b in Str.to_utf8(raw) {
            if $phase == Done {
                # Ignore trailing bytes after root object closes.
                $depth = 0
            } else if $in_str {
                if $escape {
                    mapped =
                        if b == 34 { 34.U8 }
                        else if b == 92 { 92.U8 }
                        else if b == 47 { 47.U8 }
                        else if b == 110 { 10.U8 }
                        else if b == 114 { 13.U8 }
                        else if b == 116 { 9.U8 }
                        else if b == 98 { 8.U8 }
                        else if b == 102 { 12.U8 }
                        else { b }
                    $str_buf = List.append($str_buf, mapped)
                    $escape = False
                } else if b == 92 {
                    $escape = True
                } else if b == 34 {
                    decoded = match Str.from_utf8($str_buf) {
                        Ok(s) => s
                        Err(_) => ""
                    }
                    $str_buf = []
                    $in_str = False
                    match $str_target {
                        KeyTarget => {
                            $cur_key = decoded
                            $phase = ExpectColon
                        }
                        ValTarget => {
                            $entries = List.append($entries, { key: $cur_key, val: StrVal(decoded) })
                            $phase = ExpectKey
                        }
                    }
                } else {
                    $str_buf = List.append($str_buf, b)
                }
            } else {
                match $phase {
                    BeforeObj =>
                        if b == 123 {
                            $depth = 1
                            $phase = ExpectKey
                        } else {}
                    ExpectKey =>
                        if b == 34 {
                            $in_str = True
                            $escape = False
                            $str_target = KeyTarget
                            $str_buf = []
                        } else if b == 125 {
                            $depth = 0
                            $phase = Done
                        } else {}
                    ExpectColon =>
                        if b == 58 {
                            $phase = ExpectVal
                        } else {}
                    ExpectVal =>
                        if is_ws(b) {
                            $phase = ExpectVal
                        } else if b == 34 {
                            $in_str = True
                            $escape = False
                            $str_target = ValTarget
                            $str_buf = []
                        } else if b == 123 or b == 91 {
                            $depth = 2
                            $nested_in_str = False
                            $nested_escape = False
                            $phase = SkipNested
                        } else {
                            $prim_buf = [b]
                            $phase = ReadPrim
                        }
                    ReadPrim =>
                        if b == 44 or b == 125 or is_ws(b) {
                            $entries = List.append($entries, { key: $cur_key, val: decode_prim($prim_buf) })
                            $prim_buf = []
                            if b == 125 {
                                $depth = 0
                                $phase = Done
                            } else {
                                $phase = ExpectKey
                            }
                        } else {
                            $prim_buf = List.append($prim_buf, b)
                        }
                    SkipNested =>
                        if $nested_in_str {
                            if $nested_escape {
                                $nested_escape = False
                            } else if b == 92 {
                                $nested_escape = True
                            } else if b == 34 {
                                $nested_in_str = False
                            } else {}
                        } else if b == 34 {
                            $nested_in_str = True
                        } else if b == 123 or b == 91 {
                            $depth = $depth + 1
                        } else if b == 125 or b == 93 {
                            $depth = $depth - 1
                            if $depth <= 1 {
                                $entries = List.append($entries, { key: $cur_key, val: OtherVal })
                                $phase = ExpectKey
                            } else {}
                        } else {}
                    Done => {}
                }
            }
        }
        $entries
    }

    ## Extract a top-level string field from a JSON object.
    extract_json_str : Str, Str -> [Found(Str), NotFound]
    extract_json_str = |raw, key| {
        for entry in scan_json_object(raw) {
            if entry.key == key {
                match entry.val {
                    StrVal(s) => return Found(s)
                    _ => {}
                }
            }
        }
        NotFound
    }

    ## Extract a top-level boolean field from a JSON object.
    extract_json_bool : Str, Str -> [Found(Bool), NotFound]
    extract_json_bool = |raw, key| {
        for entry in scan_json_object(raw) {
            if entry.key == key {
                match entry.val {
                    BoolVal(v) => return Found(v)
                    _ => {}
                }
            }
        }
        NotFound
    }

    ## Extract a top-level ID field as `Str`, accepting either a JSON string or integer (e.g. GitHub `id`).
    extract_json_id_str : Str, Str -> [Found(Str), NotFound]
    extract_json_id_str = |raw, key| {
        for entry in scan_json_object(raw) {
            if entry.key == key {
                match entry.val {
                    StrVal(s) => if !Str.is_empty(s) { return Found(s) } else {}
                    NumVal(n) => if !Str.is_empty(n) { return Found(n) } else {}
                    _ => {}
                }
            }
        }
        NotFound
    }

    ## Parse an OAuth2 token endpoint JSON response (tolerating extra provider-specific fields).
    parse_token_response : Str -> Try(TokenResponse, Str)
    parse_token_response = |raw| {
        err_code = match extract_json_str(raw, "error") {
            Found(e) => e
            NotFound => ""
        }
        err_desc = match extract_json_str(raw, "error_description") {
            Found(d) => d
            NotFound => ""
        }
        if !Str.is_empty(err_code) {
            msg = if Str.is_empty(err_desc) { err_code } else { "${err_code}: ${err_desc}" }
            return Err("OAuth token exchange failed: ${msg}")
        }
        access_token = match extract_json_str(raw, "access_token") {
            Found(t) => t
            NotFound => return Err("OAuth token response missing access_token")
        }
        if Str.is_empty(access_token) {
            return Err("OAuth token response contained empty access_token")
        }
        token_type = match extract_json_str(raw, "token_type") {
            Found(tt) => tt
            NotFound => "Bearer"
        }
        scope = match extract_json_str(raw, "scope") {
            Found(sc) => sc
            NotFound => ""
        }
        Ok({
            access_token,
            token_type,
            scope,
            error: "",
            error_description: "",
        })
    }

    ## Parse an OAuth2/OIDC userinfo JSON response (Google `sub`, GitHub numeric `id`/`login`, Discord `verified`).
    parse_userinfo_response : Str -> Try(UserInfo, Str)
    parse_userinfo_response = |raw| {
        provider_account_id = match extract_json_id_str(raw, "sub") {
            Found(s) => s
            NotFound =>
                match extract_json_id_str(raw, "id") {
                    Found(s) => s
                    NotFound => return Err("OAuth userinfo response missing sub/id")
                }
        }
        email_raw = match extract_json_str(raw, "email") {
            Found(e) => e
            NotFound => ""
        }
        email = Token.normalize_email(email_raw)
        email_verified = match extract_json_bool(raw, "email_verified") {
            Found(v) => v
            NotFound =>
                match extract_json_bool(raw, "verified") {
                    Found(v) => v
                    NotFound => False
                }
        }
        name = match extract_json_str(raw, "name") {
            Found(n) => if !Str.is_empty(Str.trim(n)) { Str.trim(n) } else { "" }
            NotFound =>
                match extract_json_str(raw, "login") {
                    Found(l) => Str.trim(l)
                    NotFound =>
                        match extract_json_str(raw, "username") {
                            Found(u) => Str.trim(u)
                            NotFound => email
                        }
                }
        }
        Ok({
            provider_account_id,
            email,
            email_verified,
            name: if Str.is_empty(name) { provider_account_id } else { name },
        })
    }
}

# -----------------------------------------------------------------------------
# Pure-Roc Unit Tests (`roc test packages/auth/OAuth.roc`)
# -----------------------------------------------------------------------------

expect {
    # RFC 3986 URL encode + decode roundtrip.
    raw = "https://app.example.com/auth/oauth/google/callback?next=/dash board&x=1+2"
    enc = OAuth.url_encode(raw)
    !Str.contains(enc, " ")
    and Str.contains(enc, "%20")
    and OAuth.url_decode(enc) == raw
}

expect {
    # Query param parsing handles leading ?, multiple params, and percent decoding.
    q = "?code=abc%2F123&state=xyz_99&redirect_to=%2Fapp%2Fhome"
    OAuth.parse_query_param(q, "code") == Found("abc/123")
    and OAuth.parse_query_param(q, "state") == Found("xyz_99")
    and OAuth.parse_query_param(q, "redirect_to") == Found("/app/home")
    and OAuth.parse_query_param(q, "missing") == NotFound
}

expect {
    # Cookie header parsing extracts CSRF state cookie accurately.
    hdr = "theme=dark; concave_oauth_state=st_abc123; other=val=with=eq"
    OAuth.parse_cookie(hdr, "concave_oauth_state") == Found("st_abc123")
    and OAuth.parse_cookie(hdr, "other") == Found("val=with=eq")
    and OAuth.parse_cookie(hdr, "nope") == NotFound
}

expect {
    # Safe redirect validation blocks protocol-relative and external URLs.
    OAuth.is_safe_redirect("/dashboard?tab=1")
    and !OAuth.is_safe_redirect("//evil.com/phish")
    and !OAuth.is_safe_redirect("https://evil.com")
    and !OAuth.is_safe_redirect("")
}

expect {
    # Provider constructors and PKCE S256 authorize URL generation.
    g = OAuth.google({
        client_id: "cid_123",
        client_secret_name: "GOOGLE_CLIENT_SECRET",
        redirect_uri: "http://127.0.0.1:3210/auth/oauth/google/callback",
    })
    url = OAuth.build_authorize_url(g, "state_xyz", "chal_abc")
    Str.starts_with(url, "https://accounts.google.com/o/oauth2/v2/auth?")
    and Str.contains(url, "code_challenge=chal_abc")
    and Str.contains(url, "code_challenge_method=S256")
    and Str.contains(url, "state=state_xyz")
}

expect {
    # Tolerant token response parser handles extra fields & nested objects.
    body = "{\"token_type\":\"Bearer\",\"expires_in\":3600,\"meta\":{\"a\":1,\"b\":\"}\"},\"access_token\":\"tok_live_999\",\"scope\":\"openid email\"}"
    match OAuth.parse_token_response(body) {
        Ok(tok) => tok.access_token == "tok_live_999" and tok.token_type == "Bearer"
        Err(_) => False
    }
}

expect {
    # Tolerant userinfo parser handles Google (`sub`), GitHub (numeric `id` + `login`), and Discord (`verified`).
    google_json = "{\"sub\":\"g_1001\",\"email\":\"Alice@Example.COM\",\"email_verified\":true,\"name\":\"Alice \\\"A\\\"\"}"
    gh_json = "{\"id\":424242,\"login\":\"octocat\",\"email\":\"octo@github.com\"}"
    discord_json = "{\"id\":\"d_99\",\"username\":\"wumpus\",\"email\":\"w@discord.gg\",\"verified\":true}"

    ok_g = match OAuth.parse_userinfo_response(google_json) {
        Ok(u) => u.provider_account_id == "g_1001" and u.email == "alice@example.com" and u.email_verified and u.name == "Alice \"A\""
        Err(_) => False
    }
    ok_gh = match OAuth.parse_userinfo_response(gh_json) {
        Ok(u) => u.provider_account_id == "424242" and u.email == "octo@github.com" and !u.email_verified and u.name == "octocat"
        Err(_) => False
    }
    ok_d = match OAuth.parse_userinfo_response(discord_json) {
        Ok(u) => u.provider_account_id == "d_99" and u.email_verified and u.name == "wumpus"
        Err(_) => False
    }
    ok_g and ok_gh and ok_d
}
