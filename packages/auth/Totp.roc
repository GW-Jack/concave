import OAuth

## Pure-Roc RFC 6238 TOTP / RFC 4226 HOTP MFA implementation (HMAC-SHA1, RFC 4648 Base32,
## Base64url decoder for CSPRNG secrets, and `otpauth://` Key URI builder).
## Zero external dependencies and zero host changes required.

Totp := [Totp].{
    default_period_secs : I64
    default_period_secs = 30

    default_digits : I64
    default_digits = 6

    default_window_steps : I64
    default_window_steps = 1

    VerifyResult : [
        Valid(I64),
        Invalid,
    ]

    # -------------------------------------------------------------------------
    # Unsigned 32-bit Word Helpers (Represented Safely in I64: 0..4294967295)
    # -------------------------------------------------------------------------

    mod32 : I64
    mod32 = 4294967296

    mask32_max : I64
    mask32_max = 4294967295

    u8_to_i64 : U8 -> I64
    u8_to_i64 = |b| {
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

    i64_to_u8 : I64 -> U8
    i64_to_u8 = |n| {
        var $rem = n % 256
        if $rem < 0 {
            $rem = $rem + 256
        }
        var $out = 0.U8
        while $rem >= 16 {
            $out = $out + 16
            $rem = $rem - 16
        }
        while $rem > 0 {
            $out = $out + 1
            $rem = $rem - 1
        }
        $out
    }

    u64_to_i64 : U64 -> I64
    u64_to_i64 = |n| {
        var $rem = n
        var $acc = 0.I64
        while $rem >= 65536 {
            $acc = $acc + 65536
            $rem = $rem - 65536
        }
        while $rem >= 256 {
            $acc = $acc + 256
            $rem = $rem - 256
        }
        while $rem > 0 {
            $acc = $acc + 1
            $rem = $rem - 1
        }
        $acc
    }

    i64_to_u64 : I64 -> U64
    i64_to_u64 = |n| {
        if n <= 0 {
            return 0.U64
        }
        var $rem = n
        var $acc = 0.U64
        while $rem >= 65536 {
            $acc = $acc + 65536
            $rem = $rem - 65536
        }
        while $rem >= 256 {
            $acc = $acc + 256
            $rem = $rem - 256
        }
        while $rem > 0 {
            $acc = $acc + 1
            $rem = $rem - 1
        }
        $acc
    }

    add32 : I64, I64 -> I64
    add32 = |a, b| (a + b) % mod32

    bit_not32 : I64 -> I64
    bit_not32 = |a| mask32_max - (a % mod32)

    bit_and32 : I64, I64 -> I64
    bit_and32 = |a, b| {
        var $x = a % mod32
        var $y = b % mod32
        var $res = 0.I64
        var $bit = 1.I64
        while $x > 0 and $y > 0 {
            if ($x % 2) == 1 and ($y % 2) == 1 {
                $res = $res + $bit
            }
            $x = $x // 2
            $y = $y // 2
            $bit = $bit * 2
        }
        $res
    }

    bit_or32 : I64, I64 -> I64
    bit_or32 = |a, b| {
        x = a % mod32
        y = b % mod32
        x + y - bit_and32(x, y)
    }

    bit_xor32 : I64, I64 -> I64
    bit_xor32 = |a, b| {
        x = a % mod32
        y = b % mod32
        x + y - (2 * bit_and32(x, y))
    }

    rotl1 : I64 -> I64
    rotl1 = |x| {
        v = x % mod32
        ((v % 2147483648) * 2) + (v // 2147483648)
    }

    rotl5 : I64 -> I64
    rotl5 = |x| {
        v = x % mod32
        ((v % 134217728) * 32) + (v // 134217728)
    }

    rotl30 : I64 -> I64
    rotl30 = |x| {
        v = x % mod32
        ((v % 4) * 1073741824) + (v // 4)
    }

    get_byte : List(U8), I64 -> I64
    get_byte = |bytes, idx|
        match List.get(bytes, i64_to_u64(idx)) {
            Ok(b) => u8_to_i64(b)
            Err(_) => 0
        }

    get_word : List(I64), I64 -> I64
    get_word = |words, idx|
        match List.get(words, i64_to_u64(idx)) {
            Ok(w) => w
            Err(_) => 0
        }

    append_be32 : List(U8), I64 -> List(U8)
    append_be32 = |buf, w| {
        v = w % mod32
        b0 = i64_to_u8(v // 16777216)
        b1 = i64_to_u8((v // 65536) % 256)
        b2 = i64_to_u8((v // 256) % 256)
        b3 = i64_to_u8(v % 256)
        buf
        |> List.append(b0)
        |> List.append(b1)
        |> List.append(b2)
        |> List.append(b3)
    }

    # -------------------------------------------------------------------------
    # FIPS 180-4 SHA-1 & RFC 2104 HMAC-SHA1
    # -------------------------------------------------------------------------

    ## Compute the 20-byte SHA-1 digest of `msg`.
    sha1 : List(U8) -> List(U8)
    sha1 = |msg| {
        orig_len = u64_to_i64(List.len(msg))
        bit_len = orig_len * 8

        var $padded = List.append(msg, 128.U8)
        while (u64_to_i64(List.len($padded)) % 64) != 56 {
            $padded = List.append($padded, 0.U8)
        }

        # Append 64-bit big-endian bit length.
        hi_len = bit_len // mod32
        lo_len = bit_len % mod32
        $padded = append_be32($padded, hi_len)
        $padded = append_be32($padded, lo_len)

        var $h0 = 1732584193.I64 # 0x67452301
        var $h1 = 4023233417.I64 # 0xEFCDAB89
        var $h2 = 2562383102.I64 # 0x98BADCFE
        var $h3 = 271733878.I64 # 0x10325476
        var $h4 = 3285377520.I64 # 0xC3D2E1F0

        total_len = u64_to_i64(List.len($padded))
        var $offset = 0.I64
        while $offset < total_len {
            var $w = []
            var $j = 0.I64
            while $j < 16 {
                base = $offset + ($j * 4)
                word =
                    (get_byte($padded, base) * 16777216)
                    + (get_byte($padded, base + 1) * 65536)
                    + (get_byte($padded, base + 2) * 256)
                    + get_byte($padded, base + 3)
                $w = List.append($w, word)
                $j = $j + 1
            }

            var $i = 16.I64
            while $i < 80 {
                x1 = bit_xor32(get_word($w, $i - 3), get_word($w, $i - 8))
                x2 = bit_xor32(x1, get_word($w, $i - 14))
                x3 = bit_xor32(x2, get_word($w, $i - 16))
                $w = List.append($w, rotl1(x3))
                $i = $i + 1
            }

            var $a = $h0
            var $b = $h1
            var $c = $h2
            var $d = $h3
            var $e = $h4

            var $r = 0.I64
            while $r < 80 {
                f =
                    if $r < 20 {
                        bit_or32(bit_and32($b, $c), bit_and32(bit_not32($b), $d))
                    } else if $r < 40 {
                        bit_xor32(bit_xor32($b, $c), $d)
                    } else if $r < 60 {
                        bit_or32(bit_or32(bit_and32($b, $c), bit_and32($b, $d)), bit_and32($c, $d))
                    } else {
                        bit_xor32(bit_xor32($b, $c), $d)
                    }
                k =
                    if $r < 20 {
                        1518500249.I64
                    } else if $r < 40 {
                        1859775393.I64
                    } else if $r < 60 {
                        2400959708.I64
                    } else {
                        3395469782.I64
                    }

                temp = add32(add32(add32(add32(rotl5($a), f), $e), k), get_word($w, $r))
                $e = $d
                $d = $c
                $c = rotl30($b)
                $b = $a
                $a = temp
                $r = $r + 1
            }

            $h0 = add32($h0, $a)
            $h1 = add32($h1, $b)
            $h2 = add32($h2, $c)
            $h3 = add32($h3, $d)
            $h4 = add32($h4, $e)

            $offset = $offset + 64
        }

        []
        |> append_be32($h0)
        |> append_be32($h1)
        |> append_be32($h2)
        |> append_be32($h3)
        |> append_be32($h4)
    }

    ## Compute the 20-byte RFC 2104 HMAC-SHA1 MAC of `message` under `key`.
    hmac_sha1 : List(U8), List(U8) -> List(U8)
    hmac_sha1 = |key, message| {
        norm_key = if List.len(key) > 64 { sha1(key) } else { key }
        var $k_block = norm_key
        while List.len($k_block) < 64 {
            $k_block = List.append($k_block, 0.U8)
        }

        var $ipad = []
        var $opad = []
        for kb in $k_block {
            kv = u8_to_i64(kb)
            $ipad = List.append($ipad, i64_to_u8(bit_xor32(kv, 54))) # 0x36
            $opad = List.append($opad, i64_to_u8(bit_xor32(kv, 92))) # 0x5c
        }

        inner = sha1(List.concat($ipad, message))
        sha1(List.concat($opad, inner))
    }

    # -------------------------------------------------------------------------
    # RFC 4648 Base32 & Base64url Encoding / Decoding
    # -------------------------------------------------------------------------

    base32_char : I64 -> U8
    base32_char = |v|
        if v >= 0 and v < 26 {
            i64_to_u8(65 + v) # 'A'..'Z'
        } else {
            i64_to_u8(50 + (v - 26)) # '2'..'7'
        }

    base32_val : U8 -> [Val(I64), Skip, Bad]
    base32_val = |b|
        if b >= 65 and b <= 90 {
            Val(u8_to_i64(b) - 65) # A-Z
        } else if b >= 97 and b <= 122 {
            Val(u8_to_i64(b) - 97) # a-z
        } else if b >= 50 and b <= 55 {
            Val(u8_to_i64(b) - 50 + 26) # 2-7
        } else if b == 61 or b == 32 or b == 45 or b == 9 or b == 10 or b == 13 {
            Skip # '=', space, '-', whitespace
        } else {
            Bad
        }

    ## Encode raw bytes into unpadded RFC 4648 uppercase Base32 (standard for `otpauth://` secrets).
    base32_encode : List(U8) -> Str
    base32_encode = |bytes| {
        var $out = []
        var $buf = 0.I64
        var $bits = 0.I64

        for b in bytes {
            $buf = ($buf * 256) + u8_to_i64(b)
            $bits = $bits + 8
            while $bits >= 5 {
                $bits = $bits - 5
                div = pow2_small($bits)
                idx = ($buf // div) % 32
                $buf = $buf % div
                $out = List.append($out, base32_char(idx))
            }
        }
        if $bits > 0 {
            idx = ($buf * pow2_small(5 - $bits)) % 32
            $out = List.append($out, base32_char(idx))
        }

        match Str.from_utf8($out) {
            Ok(s) => s
            Err(_) => ""
        }
    }

    ## Decode RFC 4648 Base32 (tolerant of lowercase, spaces, hyphens, and optional `=` padding).
    base32_decode : Str -> Try(List(U8), Str)
    base32_decode = |raw| {
        var $out = []
        var $buf = 0.I64
        var $bits = 0.I64

        for b in Str.to_utf8(raw) {
            match base32_val(b) {
                Val(v) => {
                    $buf = ($buf * 32) + v
                    $bits = $bits + 5
                    if $bits >= 8 {
                        $bits = $bits - 8
                        div = pow2_small($bits)
                        byte_val = ($buf // div) % 256
                        $buf = $buf % div
                        $out = List.append($out, i64_to_u8(byte_val))
                    }
                }
                Skip => {}
                Bad => return Err("Invalid Base32 character")
            }
        }
        Ok($out)
    }

    base64url_val : U8 -> [Val(I64), Skip, Bad]
    base64url_val = |b|
        if b >= 65 and b <= 90 {
            Val(u8_to_i64(b) - 65) # A-Z -> 0..25
        } else if b >= 97 and b <= 122 {
            Val(u8_to_i64(b) - 97 + 26) # a-z -> 26..51
        } else if b >= 48 and b <= 57 {
            Val(u8_to_i64(b) - 48 + 52) # 0-9 -> 52..61
        } else if b == 45 or b == 43 {
            Val(62) # '-' or '+'
        } else if b == 95 or b == 47 {
            Val(63) # '_' or '/'
        } else if b == 61 or b == 32 or b == 10 or b == 13 {
            Skip
        } else {
            Bad
        }

    ## Decode an unpadded or padded Base64url string (e.g. from `ctx.crypto.random_bytes!`) into raw bytes.
    base64url_decode : Str -> Try(List(U8), Str)
    base64url_decode = |raw| {
        var $out = []
        var $buf = 0.I64
        var $bits = 0.I64

        for b in Str.to_utf8(raw) {
            match base64url_val(b) {
                Val(v) => {
                    $buf = ($buf * 64) + v
                    $bits = $bits + 6
                    if $bits >= 8 {
                        $bits = $bits - 8
                        div = pow2_small($bits)
                        byte_val = ($buf // div) % 256
                        $buf = $buf % div
                        $out = List.append($out, i64_to_u8(byte_val))
                    }
                }
                Skip => {}
                Bad => return Err("Invalid Base64url character")
            }
        }
        Ok($out)
    }

    pow2_small : I64 -> I64
    pow2_small = |exp| {
        var $res = 1.I64
        var $i = 0.I64
        while $i < exp {
            $res = $res * 2
            $i = $i + 1
        }
        $res
    }

    pow10 : I64 -> I64
    pow10 = |digits| {
        var $res = 1.I64
        var $i = 0.I64
        while $i < digits {
            $res = $res * 10
            $i = $i + 1
        }
        $res
    }

    # -------------------------------------------------------------------------
    # RFC 4226 HOTP & RFC 6238 TOTP
    # -------------------------------------------------------------------------

    counter_to_be64 : I64 -> List(U8)
    counter_to_be64 = |counter| {
        c = if counter < 0 { 0 } else { counter }
        hi = c // mod32
        lo = c % mod32
        []
        |> append_be32(hi)
        |> append_be32(lo)
    }

    zero_pad_code : I64, I64 -> Str
    zero_pad_code = |num, digits| {
        raw = num.to_str()
        raw_len = u64_to_i64(List.len(Str.to_utf8(raw)))
        var $out = raw
        var $pad = digits - raw_len
        while $pad > 0 {
            $out = "0${$out}"
            $pad = $pad - 1
        }
        $out
    }

    ## RFC 4226 HOTP with HMAC-SHA1 and dynamic truncation.
    hotp : List(U8), I64, I64 -> Str
    hotp = |secret_bytes, counter, digits| {
        d = if digits < 6 { 6 } else if digits > 9 { 9 } else { digits }
        mac = hmac_sha1(secret_bytes, counter_to_be64(counter))
        offset = get_byte(mac, 19) % 16
        bin_code =
            ((get_byte(mac, offset) % 128) * 16777216)
            + (get_byte(mac, offset + 1) * 65536)
            + (get_byte(mac, offset + 2) * 256)
            + get_byte(mac, offset + 3)
        otp = bin_code % pow10(d)
        zero_pad_code(otp, d)
    }

    ## RFC 6238 TOTP at `unix_secs` with `period_secs` (default 30) and `digits` (default 6).
    totp_at : List(U8), I64, I64, I64 -> Str
    totp_at = |secret_bytes, unix_secs, period_secs, digits| {
        p = if period_secs <= 0 { default_period_secs } else { period_secs }
        step = if unix_secs <= 0 { 0 } else { unix_secs // p }
        hotp(secret_bytes, step, digits)
    }

    normalize_code : Str -> Str
    normalize_code = |raw| {
        var $out = []
        for b in Str.to_utf8(raw) {
            if b != 32 and b != 45 and b != 9 and b != 10 and b != 13 {
                $out = List.append($out, b)
            }
        }
        match Str.from_utf8($out) {
            Ok(s) => s
            Err(_) => ""
        }
    }

    is_all_ascii_digits : Str -> Bool
    is_all_ascii_digits = |s| {
        bytes = Str.to_utf8(s)
        if List.is_empty(bytes) {
            return False
        }
        for b in bytes {
            if b < 48 or b > 57 {
                return False
            }
        }
        True
    }

    ct_str_eq : Str, Str -> Bool
    ct_str_eq = |a, b| {
        ba = Str.to_utf8(a)
        bb = Str.to_utf8(b)
        na = u64_to_i64(List.len(ba))
        nb = u64_to_i64(List.len(bb))
        if na != nb {
            return False
        }
        var $diff = 0.I64
        var $i = 0.I64
        while $i < na {
            va = get_byte(ba, $i)
            vb = get_byte(bb, $i)
            if va != vb {
                $diff = $diff + 1
            }
            $i = $i + 1
        }
        $diff == 0
    }

    ## Verify a TOTP `code` against `secret_bytes` at `unix_secs` within `±window_steps`
    ## (default `period_secs = 30`, `digits = 6`, `window_steps = 1`).
    ## Returns `Valid(matched_step)` so callers can persist `last_used_step` for replay prevention.
    verify_totp_window : List(U8), Str, I64, I64, I64, I64 -> VerifyResult
    verify_totp_window = |secret_bytes, raw_code, unix_secs, period_secs, digits, window_steps| {
        d = if digits < 6 { 6 } else if digits > 9 { 9 } else { digits }
        p = if period_secs <= 0 { default_period_secs } else { period_secs }
        w = if window_steps < 0 { 0 } else if window_steps > 5 { 5 } else { window_steps }

        cleaned = normalize_code(raw_code)
        if u64_to_i64(List.len(Str.to_utf8(cleaned))) != d or !is_all_ascii_digits(cleaned) {
            return Invalid
        }
        if List.is_empty(secret_bytes) {
            return Invalid
        }

        cur_step = if unix_secs <= 0 { 0 } else { unix_secs // p }
        var $offset = 0 - w
        var $matched_step = -1.I64
        while $offset <= w {
            candidate_step = cur_step + $offset
            if candidate_step >= 0 {
                expected = hotp(secret_bytes, candidate_step, d)
                if ct_str_eq(cleaned, expected) and $matched_step < 0 {
                    $matched_step = candidate_step
                }
            }
            $offset = $offset + 1
        }

        if $matched_step >= 0 {
            Valid($matched_step)
        } else {
            Invalid
        }
    }

    ## Convenience wrapper with RFC 6238 defaults (30s period, 6 digits, ±1 step window).
    verify_totp : List(U8), Str, I64 -> VerifyResult
    verify_totp = |secret_bytes, code, unix_secs|
        verify_totp_window(secret_bytes, code, unix_secs, default_period_secs, default_digits, default_window_steps)

    ## Build an `otpauth://totp/...` Key URI compatible with Google Authenticator, 1Password, Authy, etc.
    build_otpauth_uri : Str, Str, Str -> Str
    build_otpauth_uri = |issuer, account_name, base32_secret| {
        clean_issuer = if Str.is_empty(Str.trim(issuer)) { "Concave" } else { Str.trim(issuer) }
        clean_account = Str.trim(account_name)
        enc_issuer = OAuth.url_encode(clean_issuer)
        enc_account = OAuth.url_encode(clean_account)
        label = if Str.is_empty(clean_account) { enc_issuer } else { "${enc_issuer}:${enc_account}" }
        "otpauth://totp/${label}?secret=${OAuth.url_encode(base32_secret)}&issuer=${enc_issuer}&algorithm=SHA1&digits=6&period=30"
    }

    bytes_to_hex : List(U8) -> Str
    bytes_to_hex = |bytes| {
        nibble = |n| if n < 10 { i64_to_u8(48 + n) } else { i64_to_u8(87 + n) }
        var $out = []
        for b in bytes {
            v = u8_to_i64(b)
            $out = List.append($out, nibble(v // 16))
            $out = List.append($out, nibble(v % 16))
        }
        match Str.from_utf8($out) {
            Ok(s) => s
            Err(_) => ""
        }
    }
}

# -----------------------------------------------------------------------------
# Pure-Roc Unit Tests (`roc test packages/auth/Totp.roc`)
# -----------------------------------------------------------------------------

expect {
    # FIPS 180-4 SHA-1 standard test vectors.
    h_empty = Totp.bytes_to_hex(Totp.sha1(Str.to_utf8("")))
    h_abc = Totp.bytes_to_hex(Totp.sha1(Str.to_utf8("abc")))
    h_empty == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
    and h_abc == "a9993e364706816aba3e25717850c26c9cd0d89d"
}

expect {
    # RFC 4226 Appendix D HOTP standard test vectors (secret = "12345678901234567890").
    secret = Str.to_utf8("12345678901234567890")
    Totp.hotp(secret, 0, 6) == "755224"
    and Totp.hotp(secret, 1, 6) == "287082"
    and Totp.hotp(secret, 2, 6) == "359152"
    and Totp.hotp(secret, 9, 6) == "520489"
}

expect {
    # RFC 6238 Appendix B TOTP SHA-1 8-digit test vectors (secret = "12345678901234567890").
    secret = Str.to_utf8("12345678901234567890")
    Totp.totp_at(secret, 59, 30, 8) == "94287082"
    and Totp.totp_at(secret, 1111111109, 30, 8) == "07081804"
    and Totp.totp_at(secret, 1234567890, 30, 8) == "89005924"
    and Totp.totp_at(secret, 2000000000, 30, 8) == "69279037"
}

expect {
    # RFC 4648 Base32 encode & decode round-trip (including padded & lowercase inputs).
    raw = Str.to_utf8("foobar")
    enc = Totp.base32_encode(raw)
    ok_round = match Totp.base32_decode("mzxw6ytboi======") {
        Ok(dec) => dec == raw
        Err(_) => False
    }
    secret = Str.to_utf8("12345678901234567890")
    secret_b32 = Totp.base32_encode(secret)
    ok_secret = match Totp.base32_decode(secret_b32) {
        Ok(dec) => dec == secret
        Err(_) => False
    }
    enc == "MZXW6YTBOI"
    and secret_b32 == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    and ok_round
    and ok_secret
}

expect {
    # Base64url decode handles unpadded CSPRNG output cleanly.
    # "12345678901234567890" in base64url is "MTIzNDU2Nzg5MDEyMzQ1Njc4OTA"
    match Totp.base64url_decode("MTIzNDU2Nzg5MDEyMzQ1Njc4OTA") {
        Ok(bytes) => bytes == Str.to_utf8("12345678901234567890")
        Err(_) => False
    }
}

expect {
    # TOTP window verification accepts exact, -1, and +1 steps and rejects ±2 steps.
    secret = Str.to_utf8("12345678901234567890")
    # step 100 is t = 3000..3029
    c98 = Totp.hotp(secret, 98, 6)
    c99 = Totp.hotp(secret, 99, 6)
    c100 = Totp.hotp(secret, 100, 6)
    c101 = Totp.hotp(secret, 101, 6)
    c102 = Totp.hotp(secret, 102, 6)

    Totp.verify_totp_window(secret, c100, 3015, 30, 6, 1) == Valid(100)
    and Totp.verify_totp_window(secret, c99, 3015, 30, 6, 1) == Valid(99)
    and Totp.verify_totp_window(secret, c101, 3015, 30, 6, 1) == Valid(101)
    and Totp.verify_totp_window(secret, c98, 3015, 30, 6, 1) == Invalid
    and Totp.verify_totp_window(secret, c102, 3015, 30, 6, 1) == Invalid
    and Totp.verify_totp_window(secret, "abcdef", 3015, 30, 6, 1) == Invalid
}

expect {
    # otpauth:// URI properly percent-encodes issuer & account name.
    uri = Totp.build_otpauth_uri("My App", "alice+1@example.com", "JBSWY3DPEHPK3PXP")
    uri == "otpauth://totp/My%20App:alice%2B1%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=My%20App&algorithm=SHA1&digits=6&period=30"
}
