## Structured key-value properties, `$set`/`$set_once` merging,
## and PostHog-style property filter evaluation.

Props := [Props].{
    Prop : {
        key : Str,
        value : Str,
    }

    ## Property filter operator (`op`):
    ## - `"eq"`           : property equals `value`
    ## - `"neq"`          : property is present and != `value` (or missing)
    ## - `"contains"`     : property contains substring `value`
    ## - `"not_contains"` : property does not contain substring `value`
    ## - `"is_set"`       : property exists and is non-empty
    ## - `"is_not_set"`   : property is missing or empty
    ## - `"in"`           : property equals one of comma-separated values in `value`
    ## - `"not_in"`       : property is not one of comma-separated values in `value`
    Filter : {
        key : Str,
        op : Str,
        value : Str,
    }

    prop : Str, Str -> Prop
    prop = |key, value| { key, value }

    filter : Str, Str, Str -> Filter
    filter = |key, op, value| { key, op, value }

    eq : Str, Str -> Filter
    eq = |key, value| { key, op: "eq", value }

    neq : Str, Str -> Filter
    neq = |key, value| { key, op: "neq", value }

    contains : Str, Str -> Filter
    contains = |key, value| { key, op: "contains", value }

    not_contains : Str, Str -> Filter
    not_contains = |key, value| { key, op: "not_contains", value }

    is_set : Str -> Filter
    is_set = |key| { key, op: "is_set", value: "" }

    is_not_set : Str -> Filter
    is_not_set = |key| { key, op: "is_not_set", value: "" }

    in_list : Str, List(Str) -> Filter
    in_list = |key, values| { key, op: "in", value: Str.join_with(values, ",") }

    ## Look up the last matching value for `key` in a property list.
    get : List(Prop), Str -> [Found(Str), NotFound]
    get = |props, key| {
        var $found = NotFound
        for p in props {
            if p.key == key {
                $found = Found(p.value)
            }
        }
        $found
    }

    ## Look up a property value or return `default_val`.
    get_or : List(Prop), Str, Str -> Str
    get_or = |props, key, default_val|
        match get(props, key) {
            Found(v) => v
            NotFound => default_val
        }

    ## Upsert a single key/value pair (replacing existing key if present).
    upsert : List(Prop), Str, Str -> List(Prop)
    upsert = |props, key, value| {
        var $out = []
        var $replaced = False
        for p in props {
            if p.key == key {
                $out = List.append($out, { key, value })
                $replaced = True
            } else {
                $out = List.append($out, p)
            }
        }
        if $replaced {
            $out
        } else {
            List.append($out, { key, value })
        }
    }

    ## PostHog `$set`: overwrite or add all properties in `updates` onto `base`.
    merge_set : List(Prop), List(Prop) -> List(Prop)
    merge_set = |base, updates| {
        var $acc = base
        for u in updates {
            if !Str.is_empty(u.key) {
                $acc = upsert($acc, u.key, u.value)
            }
        }
        $acc
    }

    ## PostHog `$set_once`: only set keys that are not already present in `base`.
    merge_set_once : List(Prop), List(Prop) -> List(Prop)
    merge_set_once = |base, updates| {
        var $acc = base
        for u in updates {
            if !Str.is_empty(u.key) {
                match get($acc, u.key) {
                    NotFound => {
                        $acc = List.append($acc, u)
                    }
                    Found(_) => {}
                }
            }
        }
        $acc
    }

    ## Check whether `needle` appears in a comma-separated list of values (trimmed).
    in_csv : Str, Str -> Bool
    in_csv = |needle, csv| {
        parts = Str.split_on(csv, ",")
        var $matched = False
        for part in parts {
            if Str.trim(part) == needle {
                $matched = True
            }
        }
        $matched
    }

    ## Evaluate a single PostHog property filter against `props`.
    matches_filter : List(Prop), Filter -> Bool
    matches_filter = |props, f| {
        lookup = get(props, f.key)
        if f.op == "eq" {
            match lookup {
                Found(v) => v == f.value
                NotFound => False
            }
        } else if f.op == "neq" {
            match lookup {
                Found(v) => v != f.value
                NotFound => True
            }
        } else if f.op == "contains" {
            match lookup {
                Found(v) => Str.contains(v, f.value)
                NotFound => False
            }
        } else if f.op == "not_contains" {
            match lookup {
                Found(v) => !Str.contains(v, f.value)
                NotFound => True
            }
        } else if f.op == "is_set" {
            match lookup {
                Found(v) => !Str.is_empty(v)
                NotFound => False
            }
        } else if f.op == "is_not_set" {
            match lookup {
                Found(v) => Str.is_empty(v)
                NotFound => True
            }
        } else if f.op == "in" {
            match lookup {
                Found(v) => in_csv(v, f.value)
                NotFound => False
            }
        } else if f.op == "not_in" {
            match lookup {
                Found(v) => !in_csv(v, f.value)
                NotFound => True
            }
        } else {
            False
        }
    }

    ## Evaluate a list of filters (logical AND — empty list always matches).
    matches_all : List(Prop), List(Filter) -> Bool
    matches_all = |props, filters| {
        for f in filters {
            if !matches_filter(props, f) {
                return False
            }
        }
        True
    }
}

expect {
    base = [Props.prop("plan", "free"), Props.prop("country", "US")]
    after_set = Props.merge_set(base, [Props.prop("plan", "pro"), Props.prop("role", "admin")])
    after_once = Props.merge_set_once(after_set, [Props.prop("plan", "enterprise"), Props.prop("utm_source", "hn")])
    Props.get_or(after_once, "plan", "") == "pro"
    and Props.get_or(after_once, "role", "") == "admin"
    and Props.get_or(after_once, "utm_source", "") == "hn"
}

expect {
    props = [
        Props.prop("plan", "pro"),
        Props.prop("email", "alice@acme.io"),
        Props.prop("country", "US"),
    ]
    Props.matches_all(
        props,
        [
            Props.eq("plan", "pro"),
            Props.contains("email", "@acme.io"),
            Props.in_list("country", ["US", "CA", "GB"]),
            Props.is_set("email"),
            Props.is_not_set("deleted_at"),
        ],
    )
}

expect {
    props = [Props.prop("plan", "free")]
    !Props.matches_all(props, [Props.eq("plan", "pro")])
}
