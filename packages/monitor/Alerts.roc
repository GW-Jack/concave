## Pure threshold alert rule evaluation and state-machine transitions
## (`ok` <-> `firing`, respecting `acked` and cooldown deduplication).

Alerts := [Alerts].{
    RuleInput : {
        key : Str,
        name : Str,
        status : Str,
        op : Str,
        threshold : F64,
        cooldown_ms : I64,
        last_triggered_ms : I64,
        webhook_url : Str,
    }

    Transition : {
        next_status : Str,
        breached : Bool,
        should_open_incident : Bool,
        should_resolve_incidents : Bool,
        should_notify : Bool,
        notify_event : Str,
    }

    ## Evaluate a scalar comparison operator (`gt`, `gte`, `lt`, `lte`, `eq`).
    compare : F64, Str, F64 -> Bool
    compare = |actual, op, threshold|
        if op == "gt" { actual > threshold }
        else if op == "gte" { actual >= threshold }
        else if op == "lt" { actual < threshold }
        else if op == "lte" { actual <= threshold }
        else if op == "eq" { actual == threshold }
        else { actual > threshold }

    ## Compute the next state & side-effects for a single alert rule evaluation.
    evaluate_transition : RuleInput, F64, I64 -> Transition
    evaluate_transition = |rule, actual_value, now_ms| {
        breached = compare(actual_value, rule.op, rule.threshold)
        has_webhook = !Str.is_empty(Str.trim(rule.webhook_url))
        cooldown_ok =
            rule.cooldown_ms <= 0
            or rule.last_triggered_ms <= 0
            or (now_ms - rule.last_triggered_ms) >= rule.cooldown_ms

        if breached {
            if rule.status == "ok" {
                {
                    next_status: "firing",
                    breached: True,
                    should_open_incident: True,
                    should_resolve_incidents: False,
                    should_notify: has_webhook and cooldown_ok,
                    notify_event: "alert.firing",
                }
            } else if rule.status == "acked" {
                # Stay acknowledged while still breaching; do not re-page.
                {
                    next_status: "acked",
                    breached: True,
                    should_open_incident: False,
                    should_resolve_incidents: False,
                    should_notify: False,
                    notify_event: "",
                }
            } else {
                # Already firing; suppress duplicate incident, respect cooldown.
                {
                    next_status: "firing",
                    breached: True,
                    should_open_incident: False,
                    should_resolve_incidents: False,
                    should_notify: False,
                    notify_event: "",
                }
            }
        } else {
            if rule.status == "firing" or rule.status == "acked" {
                {
                    next_status: "ok",
                    breached: False,
                    should_open_incident: False,
                    should_resolve_incidents: True,
                    should_notify: has_webhook,
                    notify_event: "alert.resolved",
                }
            } else {
                {
                    next_status: "ok",
                    breached: False,
                    should_open_incident: False,
                    should_resolve_incidents: False,
                    should_notify: False,
                    notify_event: "",
                }
            }
        }
    }
}

expect {
    rule = {
        key: "high-errors",
        name: "High Errors",
        status: "ok",
        op: "gte",
        threshold: 5.0,
        cooldown_ms: 60000,
        last_triggered_ms: 0,
        webhook_url: "https://hooks.example.test/alert",
    }
    t1 = Alerts.evaluate_transition(rule, 7.0, 100000)
    t1.next_status == "firing" and t1.should_open_incident and t1.should_notify and t1.notify_event == "alert.firing"
}

expect {
    # Already firing stays firing without opening duplicate incidents.
    rule = {
        key: "high-errors",
        name: "High Errors",
        status: "firing",
        op: "gte",
        threshold: 5.0,
        cooldown_ms: 60000,
        last_triggered_ms: 100000,
        webhook_url: "https://hooks.example.test/alert",
    }
    t2 = Alerts.evaluate_transition(rule, 8.0, 110000)
    t3 = Alerts.evaluate_transition(rule, 2.0, 120000)
    t2.next_status == "firing" and !t2.should_open_incident and !t2.should_notify
    and t3.next_status == "ok" and t3.should_resolve_incidents and t3.should_notify and t3.notify_event == "alert.resolved"
}

expect {
    # Acknowledged rule stays acked while breaching and resolves cleanly once clear.
    rule = {
        key: "slow-api",
        name: "Slow API",
        status: "acked",
        op: "gt",
        threshold: 250.0,
        cooldown_ms: 0,
        last_triggered_ms: 1000,
        webhook_url: "",
    }
    t_still = Alerts.evaluate_transition(rule, 300.0, 2000)
    t_clear = Alerts.evaluate_transition(rule, 100.0, 3000)
    t_still.next_status == "acked" and !t_still.should_open_incident
    and t_clear.next_status == "ok" and t_clear.should_resolve_incidents and !t_clear.should_notify
}
