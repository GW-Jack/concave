import Hash
import Props

## PostHog-style Feature Flag & Multivariate A/B Experiment evaluation engine.

Flags := [Flags].{
    Variant : {
        key : Str,
        weight : I64,
    }

    FlagRule : {
        key : Str,
        active : Bool,
        rollout_pct : I64,
        filters : List(Props.Filter),
        variants : List(Variant),
    }

    Evaluation : {
        key : Str,
        enabled : Bool,
        variant : Str,
        reason : Str,
    }

    variant : Str, I64 -> Variant
    variant = |key, weight| { key, weight }

    ## Validate a flag definition before persisting.
    validate : FlagRule -> Try({}, Str)
    validate = |flag| {
        if Str.is_empty(Str.trim(flag.key)) {
            return Err("Feature flag key cannot be empty")
        }
        if flag.rollout_pct < 0 or flag.rollout_pct > 100 {
            return Err("rollout_pct must be between 0 and 100")
        }
        if !List.is_empty(flag.variants) {
            var $total = 0.I64
            for v in flag.variants {
                if Str.is_empty(Str.trim(v.key)) {
                    return Err("Variant key cannot be empty")
                }
                if v.weight <= 0 {
                    return Err("Variant weight must be positive")
                }
                $total = $total + v.weight
            }
            if $total <= 0 {
                return Err("Total variant weight must be positive")
            }
        }
        Ok({})
    }

    ## Deterministically evaluate a feature flag / multivariate experiment for `distinct_id`
    ## and their resolved `person_props`.
    evaluate : FlagRule, Str, List(Props.Prop) -> Evaluation
    evaluate = |flag, distinct_id, person_props| {
        if !flag.active {
            return {
                key: flag.key,
                enabled: False,
                variant: "",
                reason: "disabled",
            }
        }

        if !Props.matches_all(person_props, flag.filters) {
            return {
                key: flag.key,
                enabled: False,
                variant: "",
                reason: "filter_mismatch",
            }
        }

        if flag.rollout_pct <= 0 {
            return {
                key: flag.key,
                enabled: False,
                variant: "",
                reason: "rollout_zero",
            }
        }

        if flag.rollout_pct < 100 {
            bucket = Hash.bucket_pct(flag.key, distinct_id)
            if bucket >= flag.rollout_pct {
                return {
                    key: flag.key,
                    enabled: False,
                    variant: "",
                    reason: "rollout_excluded",
                }
            }
        }

        if List.is_empty(flag.variants) {
            return {
                key: flag.key,
                enabled: True,
                variant: "true",
                reason: "matched",
            }
        }

        var $total_weight = 0.I64
        for v in flag.variants {
            if v.weight > 0 {
                $total_weight = $total_weight + v.weight
            }
        }

        if $total_weight <= 0 {
            return {
                key: flag.key,
                enabled: True,
                variant: "true",
                reason: "matched",
            }
        }

        # Use an independent salt for variant selection so rollout % and variant split are orthogonal.
        pick = Hash.bucket_bps("${flag.key}#variant", distinct_id) % $total_weight
        var $cum = 0.I64
        for v in flag.variants {
            if v.weight > 0 {
                $cum = $cum + v.weight
                if pick < $cum {
                    return {
                        key: flag.key,
                        enabled: True,
                        variant: v.key,
                        reason: "variant_matched",
                    }
                }
            }
        }

        # Defensive fallback (unreachable when $total_weight > 0).
        {
            key: flag.key,
            enabled: True,
            variant: "true",
            reason: "matched",
        }
    }
}

expect {
    rule = {
        key: "beta-editor",
        active: False,
        rollout_pct: 100,
        filters: [],
        variants: [],
    }
    res = Flags.evaluate(rule, "alice", [])
    !res.enabled and res.reason == "disabled"
}

expect {
    rule = {
        key: "pro-feature",
        active: True,
        rollout_pct: 100,
        filters: [Props.eq("plan", "pro")],
        variants: [],
    }
    pro_res = Flags.evaluate(rule, "alice", [Props.prop("plan", "pro")])
    free_res = Flags.evaluate(rule, "bob", [Props.prop("plan", "free")])
    pro_res.enabled and pro_res.variant == "true" and !free_res.enabled and free_res.reason == "filter_mismatch"
}

expect {
    rule = {
        key: "pricing-ab",
        active: True,
        rollout_pct: 100,
        filters: [],
        variants: [Flags.variant("control", 50), Flags.variant("treatment", 50)],
    }
    r1 = Flags.evaluate(rule, "user-42", [])
    r2 = Flags.evaluate(rule, "user-42", [])
    r1.enabled
    and r1.variant == r2.variant
    and (r1.variant == "control" or r1.variant == "treatment")
}
