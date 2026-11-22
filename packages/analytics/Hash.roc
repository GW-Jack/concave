## Deterministic hashing and bucketing for Feature Flag rollouts & A/B experiments.
## Uses overflow-free modular polynomial hashing over UTF-8 bytes in `I64` (mod 2^31 - 1),
## so flag assignment is 100% deterministic across nodes, platforms, and restarts.

Hash := [Hash].{
    ## Mersenne prime 2^31 - 1; any product with multiplier < 10^8 stays safely inside I64.
    modulus : I64
    modulus = 2147483647

    ## Convert a `U8` byte into an `I64` without relying on platform-specific casts.
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

    ## Deterministic 31-bit hash over UTF-8 bytes returning a value in `[0, 2147483647)`.
    hash_str : Str -> I64
    hash_str = |input| {
        bytes = Str.to_utf8(input)
        var $h = 5381.I64
        for b in bytes {
            $h = (($h * 48271) + byte_to_i64(b) + 131) % modulus
        }
        # Two avalanche rounds with distinct Park-Miller multipliers so similar inputs spread uniformly.
        $h = (($h * 48271) + 1234567) % modulus
        $h = (($h * 16807) + 9876543) % modulus
        $h
    }

    ## Map `(salt, distinct_id)` into a deterministic bucket in `[0, 10000)` (basis points, 0.01% precision).
    bucket_bps : Str, Str -> I64
    bucket_bps = |salt, distinct_id|
        hash_str("${salt}:${distinct_id}") % 10000

    ## Map `(flag_key, distinct_id)` into a deterministic percentage bucket in `[0, 100)`.
    bucket_pct : Str, Str -> I64
    bucket_pct = |flag_key, distinct_id|
        bucket_bps(flag_key, distinct_id) // 100
}

expect {
    a = Hash.bucket_bps("new-ui", "user-alice")
    b = Hash.bucket_bps("new-ui", "user-alice")
    a == b and a >= 0 and a < 10000
}

expect {
    p = Hash.bucket_pct("checkout-v2", "user-bob")
    p >= 0 and p < 100
}

expect {
    h1 = Hash.hash_str("flag-a:user-1")
    h2 = Hash.hash_str("flag-b:user-1")
    h3 = Hash.hash_str("flag-a:user-2")
    h1 != h2 and h1 != h3 and h2 != h3
}

expect {
    # Verify uniform-ish spread across 100 synthetic users at 50% rollout (between 30 and 70 hits).
    var $hits = 0.I64
    var $i = 0.I64
    while $i < 100 {
        if Hash.bucket_pct("experiment-x", "user-${$i.to_str()}") < 50 {
            $hits = $hits + 1
        }
        $i = $i + 1
    }
    $hits >= 30 and $hits <= 70
}
