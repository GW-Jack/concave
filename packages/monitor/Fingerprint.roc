## Deterministic Sentry-style error fingerprinting.
## Normalizes volatile tokens (numbers, UUIDs, hex IDs, whitespace) so errors
## like "Order 12345 failed" and "Order 99812 failed" group into the same issue.

Fingerprint := [Fingerprint].{
    modulus : I64
    modulus = 2147483647

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

    is_digit : U8 -> Bool
    is_digit = |b| b >= 48 and b <= 57

    is_hex_lower : U8 -> Bool
    is_hex_lower = |b| (b >= 48 and b <= 57) or (b >= 97 and b <= 102) or (b >= 65 and b <= 70)

    is_space : U8 -> Bool
    is_space = |b| b == 32 or b == 9 or b == 10 or b == 13

    to_lower_ascii : U8 -> U8
    to_lower_ascii = |b|
        if b >= 65 and b <= 90 {
            b + 32
        } else {
            b
        }

    ## Normalize a UTF-8 byte sequence by collapsing numeric/hex-ID runs and whitespace.
    ## Capped at 160 normalized bytes for bounded hashing.
    normalize_bytes : List(U8) -> List(U8)
    normalize_bytes = |bytes| {
        var $out = []
        var $in_num = False
        var $in_space = False
        var $hex_run = 0.I64
        var $hex_has_digit = False
        var $hex_buf = []

        flush_hex = |acc, buf, run_len, has_digit| {
            if run_len >= 8 and has_digit {
                # Replace UUID / hex-like IDs with '#'
                List.append(acc, 35.U8)
            } else {
                List.concat(acc, buf)
            }
        }

        for b in bytes {
            if List.len($out) < 160 {
                lb = to_lower_ascii(b)
                if is_space(lb) {
                    if $hex_run > 0 {
                        $out = flush_hex($out, $hex_buf, $hex_run, $hex_has_digit)
                        $hex_run = 0
                        $hex_has_digit = False
                        $hex_buf = []
                    }
                    $in_num = False
                    if !$in_space and !List.is_empty($out) {
                        $out = List.append($out, 32.U8)
                        $in_space = True
                    }
                } else if is_hex_lower(lb) or (lb == 45 and $hex_run > 0) {
                    $in_space = False
                    if is_digit(lb) {
                        $hex_has_digit = True
                    }
                    $hex_run = $hex_run + 1
                    $hex_buf = List.append($hex_buf, if is_digit(lb) { 35.U8 } else { lb })
                } else {
                    if $hex_run > 0 {
                        $out = flush_hex($out, $hex_buf, $hex_run, $hex_has_digit)
                        $hex_run = 0
                        $hex_has_digit = False
                        $hex_buf = []
                    }
                    $in_space = False
                    if is_digit(lb) {
                        if !$in_num {
                            $out = List.append($out, 35.U8)
                            $in_num = True
                        }
                    } else {
                        $in_num = False
                        $out = List.append($out, lb)
                    }
                }
            }
        }

        if $hex_run > 0 {
            $out = flush_hex($out, $hex_buf, $hex_run, $hex_has_digit)
        }

        # Collapse adjacent '#' markers (from multi-digit numbers).
        var $collapsed = []
        var $prev_hash = False
        for b in $out {
            if b == 35 {
                if !$prev_hash {
                    $collapsed = List.append($collapsed, b)
                    $prev_hash = True
                }
            } else {
                $collapsed = List.append($collapsed, b)
                $prev_hash = False
            }
        }
        $collapsed
    }

    hash_bytes_seeded : List(U8), I64, I64 -> I64
    hash_bytes_seeded = |bytes, seed, mult| {
        var $h = seed % modulus
        for b in bytes {
            $h = (($h * mult) + byte_to_i64(b) + 131) % modulus
        }
        $h = (($h * 48271) + 1234567) % modulus
        $h = (($h * 16807) + 9876543) % modulus
        if $h < 0 { 0 - $h } else { $h }
    }

    nibble_hex : I64 -> Str
    nibble_hex = |n|
        if n == 0 { "0" }
        else if n == 1 { "1" }
        else if n == 2 { "2" }
        else if n == 3 { "3" }
        else if n == 4 { "4" }
        else if n == 5 { "5" }
        else if n == 6 { "6" }
        else if n == 7 { "7" }
        else if n == 8 { "8" }
        else if n == 9 { "9" }
        else if n == 10 { "a" }
        else if n == 11 { "b" }
        else if n == 12 { "c" }
        else if n == 13 { "d" }
        else if n == 14 { "e" }
        else { "f" }

    i64_to_hex8 : I64 -> Str
    i64_to_hex8 = |val| {
        var $v = if val < 0 { 0 - val } else { val }
        var $digits = []
        var $i = 0.I64
        while $i < 8 {
            $digits = List.append($digits, nibble_hex($v % 16))
            $v = $v // 16
            $i = $i + 1
        }
        # Reverse the 8 nibbles into MSB-first hex.
        var $out = ""
        var $idx = 7.I64
        while $idx >= 0 {
            var $cur = 0.I64
            for d in $digits {
                if $cur == $idx {
                    $out = "${$out}${d}"
                }
                $cur = $cur + 1
            }
            $idx = $idx - 1
        }
        $out
    }

    ## Compute a deterministic issue fingerprint from `(source, error_type, message)`.
    ## If `explicit_fp` is non-empty, returns it directly (trimmed).
    compute : Str, Str, Str, Str -> Str
    compute = |explicit_fp, source, error_type, message| {
        trimmed_fp = Str.trim(explicit_fp)
        if !Str.is_empty(trimmed_fp) {
            return trimmed_fp
        }
        norm_msg = normalize_bytes(Str.to_utf8(message))
        prefix = Str.to_utf8("${Str.trim(source)}|${Str.trim(error_type)}|")
        combined = List.concat(prefix, norm_msg)
        h1 = hash_bytes_seeded(combined, 5381, 48271)
        h2 = hash_bytes_seeded(combined, 216613626, 16807)
        "fp_${i64_to_hex8(h1)}${i64_to_hex8(h2)}"
    }
}

expect {
    # Volatile IDs and numbers normalize to the exact same fingerprint.
    a = Fingerprint.compute("", "orders.place", "PaymentError", "Order 12345 failed for user 550e8400-e29b-41d4-a716-446655440000")
    b = Fingerprint.compute("", "orders.place", "PaymentError", "Order 99812 failed for user 123e4567-e89b-12d3-a456-426614174000")
    a == b and Str.starts_with(a, "fp_")
}

expect {
    # Different sources or error types produce distinct fingerprints.
    a = Fingerprint.compute("", "orders.place", "PaymentError", "Card declined")
    b = Fingerprint.compute("", "billing.charge", "PaymentError", "Card declined")
    c = Fingerprint.compute("", "orders.place", "TimeoutError", "Card declined")
    a != b and a != c and b != c
}

expect {
    # Explicit fingerprint overrides auto-computation.
    Fingerprint.compute("stripe-webhook-500", "webhooks", "HttpError", "status 500") == "stripe-webhook-500"
}
