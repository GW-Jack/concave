## Structured key-value attributes and log severity level normalization
## for Concave's pure-Roc Monitor component.

Attrs := [Attrs].{
    Attr : {
        key : Str,
        value : Str,
    }

    attr : Str, Str -> Attr
    attr = |key, value| { key, value }

    ## Look up the last matching value for `key` in an attribute list.
    get : List(Attr), Str -> [Found(Str), NotFound]
    get = |attrs, key| {
        var $found = NotFound
        for a in attrs {
            if a.key == key {
                $found = Found(a.value)
            }
        }
        $found
    }

    ## Look up an attribute value or return `default_val`.
    get_or : List(Attr), Str, Str -> Str
    get_or = |attrs, key, default_val|
        match get(attrs, key) {
            Found(v) => v
            NotFound => default_val
        }

    ## Upsert a single key/value pair (replacing existing key and deduplicating any repeats).
    upsert : List(Attr), Str, Str -> List(Attr)
    upsert = |attrs, key, value| {
        var $out = []
        var $replaced = False
        for a in attrs {
            if a.key == key {
                if !$replaced {
                    $out = List.append($out, { key, value })
                    $replaced = True
                }
            } else {
                $out = List.append($out, a)
            }
        }
        if $replaced {
            $out
        } else {
            List.append($out, { key, value })
        }
    }

    ## Merge `updates` onto `base` (skipping empty keys).
    merge : List(Attr), List(Attr) -> List(Attr)
    merge = |base, updates| {
        var $acc = base
        for u in updates {
            if !Str.is_empty(u.key) {
                $acc = upsert($acc, u.key, u.value)
            }
        }
        $acc
    }

    ## Normalize a log/issue severity string into canonical lowercase form.
    normalize_level : Str -> Str
    normalize_level = |raw| {
        trimmed = Str.trim(raw)
        if trimmed == "debug" or trimmed == "DEBUG" {
            "debug"
        } else if trimmed == "info" or trimmed == "INFO" {
            "info"
        } else if trimmed == "warn" or trimmed == "WARN" or trimmed == "warning" or trimmed == "WARNING" {
            "warn"
        } else if trimmed == "error" or trimmed == "ERROR" {
            "error"
        } else if trimmed == "fatal" or trimmed == "FATAL" or trimmed == "critical" or trimmed == "CRITICAL" {
            "fatal"
        } else {
            "info"
        }
    }

    ## Numeric severity rank: debug=10, info=20, warn=30, error=40, fatal=50.
    level_rank : Str -> I64
    level_rank = |raw| {
        norm = normalize_level(raw)
        if norm == "debug" {
            10
        } else if norm == "info" {
            20
        } else if norm == "warn" {
            30
        } else if norm == "error" {
            40
        } else if norm == "fatal" {
            50
        } else {
            20
        }
    }
}

expect {
    a = Attrs.merge([Attrs.attr("env", "dev")], [Attrs.attr("env", "prod"), Attrs.attr("region", "us-east")])
    Attrs.get_or(a, "env", "") == "prod" and Attrs.get_or(a, "region", "") == "us-east"
}

expect {
    Attrs.normalize_level("WARNING") == "warn"
    and Attrs.level_rank("fatal") > Attrs.level_rank("error")
    and Attrs.level_rank("error") > Attrs.level_rank("warn")
    and Attrs.level_rank("warn") > Attrs.level_rank("info")
    and Attrs.level_rank("info") > Attrs.level_rank("debug")
}
