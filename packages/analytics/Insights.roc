import Props

## Pure PostHog-style Product Analytics computation engine:
## - Identity alias resolution
## - Summary KPIs & top events
## - Time-series Trends (total + unique persons + optional property breakdown)
## - Multi-step Conversion Funnels (with conversion window & avg time-to-convert)
## - Cohort Retention matrix

Insights := [Insights].{
    EventRecord : {
        distinct_id : Str,
        event : Str,
        timestamp_ms : I64,
        session_id : Str,
        properties : List(Props.Prop),
    }

    AliasEntry : {
        alias_id : Str,
        distinct_id : Str,
    }

    TopEvent : {
        event : Str,
        count : I64,
        unique_persons : I64,
    }

    SummaryResult : {
        total_events : I64,
        unique_persons : I64,
        active_sessions : I64,
        top_events : List(TopEvent),
    }

    TrendBucket : {
        bucket_start_ms : I64,
        count : I64,
        unique_persons : I64,
    }

    BreakdownEntry : {
        value : Str,
        count : I64,
        unique_persons : I64,
    }

    TrendResult : {
        event : Str,
        total_events : I64,
        unique_persons : I64,
        buckets : List(TrendBucket),
        breakdown : List(BreakdownEntry),
    }

    FunnelStepResult : {
        step_index : I64,
        event : Str,
        count : I64,
        conversion_rate_from_prev : F64,
        conversion_rate_from_start : F64,
        avg_time_from_prev_ms : I64,
    }

    FunnelResult : {
        total_entered : I64,
        overall_conversion_rate : F64,
        steps : List(FunnelStepResult),
    }

    RetentionCohort : {
        cohort_start_ms : I64,
        cohort_size : I64,
        retained_counts : List(I64),
        retained_rates : List(F64),
    }

    RetentionResult : {
        cohorts : List(RetentionCohort),
    }

    max_i64 : I64
    max_i64 = 9223372036854775807

    ## Saturating signed addition for non-negative `delta >= 0` (never overflows `I64`).
    safe_add_i64 : I64, I64 -> I64
    safe_add_i64 = |a, b| {
        if b > 0 and a > max_i64 - b {
            max_i64
        } else {
            a + b
        }
    }

    ## Saturating multiplication for non-negative `a >= 0, b >= 0` (never overflows `I64`).
    safe_mul_nonneg_i64 : I64, I64 -> I64
    safe_mul_nonneg_i64 = |a, b| {
        if a <= 0 or b <= 0 {
            0
        } else if a > max_i64 // b {
            max_i64
        } else {
            a * b
        }
    }

    ## Saturating non-negative subtraction `max(0, a - b)` that never overflows `I64`
    ## even when `b` is near `I64.min` and `a` is positive.
    safe_sub_nonneg_i64 : I64, I64 -> I64
    safe_sub_nonneg_i64 = |a, b| {
        if a <= b {
            0
        } else if b < 0 and a > max_i64 + b {
            max_i64
        } else {
            a - b
        }
    }

    ## Count list length as `I64`.
    list_len_i64 : List(a) -> I64
    list_len_i64 = |items| {
        var $n = 0.I64
        for _ in items {
            $n = $n + 1
        }
        $n
    }

    ## Safe I64 -> F64 ratio in `[0.0, 1.0]` (or arbitrary ratio) with zero-denominator guard.
    ratio : I64, I64 -> F64
    ratio = |num, den| {
        if den <= 0 {
            0.0
        } else {
            num.to_f64() / den.to_f64()
        }
    }

    ## Resolve an anonymous or aliased `distinct_id` to its canonical `distinct_id` (bounded to 8 hops).
    resolve_id : List(AliasEntry), Str -> Str
    resolve_id = |aliases, raw_id| {
        var $cur = raw_id
        var $hops = 0.I64
        while $hops < 8 {
            var $next = $cur
            for a in aliases {
                if a.alias_id == $cur and a.distinct_id != $cur {
                    $next = a.distinct_id
                }
            }
            if $next == $cur {
                return $cur
            }
            $cur = $next
            $hops = $hops + 1
        }
        $cur
    }

    ## Check whether a string list contains `target`.
    list_contains_str : List(Str), Str -> Bool
    list_contains_str = |items, target| {
        for item in items {
            if item == target {
                return True
            }
        }
        False
    }

    ## Append `target` only if not already present.
    add_unique_str : List(Str), Str -> List(Str)
    add_unique_str = |items, target|
        if list_contains_str(items, target) {
            items
        } else {
            List.append(items, target)
        }

    ## Compute overview KPIs and top events (sorted by count descending, capped at `top_n`).
    compute_summary : List(EventRecord), List(AliasEntry), I64 -> SummaryResult
    compute_summary = |events, aliases, top_n| {
        var $total = 0.I64
        var $persons = []
        var $sessions = []
        var $event_names = []

        for ev in events {
            $total = $total + 1
            canon = resolve_id(aliases, ev.distinct_id)
            $persons = add_unique_str($persons, canon)
            if !Str.is_empty(ev.session_id) {
                $sessions = add_unique_str($sessions, ev.session_id)
            }
            $event_names = add_unique_str($event_names, ev.event)
        }

        var $top = []
        for ev_name in $event_names {
            var $ev_count = 0.I64
            var $ev_persons = []
            for ev in events {
                if ev.event == ev_name {
                    $ev_count = $ev_count + 1
                    canon = resolve_id(aliases, ev.distinct_id)
                    $ev_persons = add_unique_str($ev_persons, canon)
                }
            }
            $top = List.append($top, {
                event: ev_name,
                count: $ev_count,
                unique_persons: list_len_i64($ev_persons),
            })
        }

        sorted = sort_top_events_desc($top)
        limit = if top_n <= 0 { 10 } else { top_n }
        trimmed = take_i64(sorted, limit)

        {
            total_events: $total,
            unique_persons: list_len_i64($persons),
            active_sessions: list_len_i64($sessions),
            top_events: trimmed,
        }
    }

    sort_top_events_desc : List(TopEvent) -> List(TopEvent)
    sort_top_events_desc = |items| {
        # Simple insertion sort (distinct event names are small in number).
        var $sorted = []
        for item in items {
            var $next = []
            var $inserted = False
            for existing in $sorted {
                if !$inserted and item.count > existing.count {
                    $next = List.append($next, item)
                    $inserted = True
                }
                $next = List.append($next, existing)
            }
            if !$inserted {
                $next = List.append($next, item)
            }
            $sorted = $next
        }
        $sorted
    }

    sort_breakdown_desc : List(BreakdownEntry) -> List(BreakdownEntry)
    sort_breakdown_desc = |items| {
        var $sorted = []
        for item in items {
            var $next = []
            var $inserted = False
            for existing in $sorted {
                if !$inserted and item.count > existing.count {
                    $next = List.append($next, item)
                    $inserted = True
                }
                $next = List.append($next, existing)
            }
            if !$inserted {
                $next = List.append($next, item)
            }
            $sorted = $next
        }
        $sorted
    }

    take_i64 : List(a), I64 -> List(a)
    take_i64 = |items, n| {
        var $out = []
        var $i = 0.I64
        for item in items {
            if $i < n {
                $out = List.append($out, item)
                $i = $i + 1
            }
        }
        $out
    }

    ## Compute time-bucketed Trends + optional property breakdown for `event_name` over `[from_ms, to_ms]`.
    ## Automatically widens `bucket_ms` when `span / bucket_ms >= 500` so `<= 500` buckets
    ## ALWAYS partition the full `[from_ms, to_ms]` interval (`sum(buckets.count) == total_events`).
    compute_trends : Str, List(EventRecord), List(AliasEntry), I64, I64, I64, Str, List(Props.Filter) -> TrendResult
    compute_trends = |event_name, events, aliases, from_ms, to_ms, raw_bucket_ms, breakdown_property, filters| {
        req_bucket_ms = if raw_bucket_ms <= 0 { 3600000 } else { raw_bucket_ms }

        # Filter matching events first.
        var $matched = []
        var $all_persons = []
        for ev in events {
            if ev.event == event_name
                and ev.timestamp_ms >= from_ms
                and ev.timestamp_ms <= to_ms
                and Props.matches_all(ev.properties, filters)
            {
                canon = resolve_id(aliases, ev.distinct_id)
                $matched = List.append($matched, {
                    canon,
                    timestamp_ms: ev.timestamp_ms,
                    properties: ev.properties,
                })
                $all_persons = add_unique_str($all_persons, canon)
            }
        }

        # Build contiguous time buckets partitioning `[from_ms, to_ms]` in at most 500 buckets.
        var $buckets = []
        if to_ms >= from_ms {
            span = safe_sub_nonneg_i64(to_ms, from_ms)
            min_step = (span // 500) + 1
            bucket_ms = if req_bucket_ms < min_step { min_step } else { req_bucket_ms }

            var $cursor = from_ms
            var $done = False
            while !$done {
                b_end = safe_add_i64($cursor, bucket_ms)
                is_last = b_end > to_ms or b_end == $cursor
                var $b_count = 0.I64
                var $b_persons = []
                for m in $matched {
                    in_bucket =
                        if is_last {
                            m.timestamp_ms >= $cursor and m.timestamp_ms <= to_ms
                        } else {
                            m.timestamp_ms >= $cursor and m.timestamp_ms < b_end
                        }
                    if in_bucket {
                        $b_count = $b_count + 1
                        $b_persons = add_unique_str($b_persons, m.canon)
                    }
                }
                $buckets = List.append($buckets, {
                    bucket_start_ms: $cursor,
                    count: $b_count,
                    unique_persons: list_len_i64($b_persons),
                })
                if is_last {
                    $done = True
                } else {
                    $cursor = b_end
                }
            }
        }

        # Optional breakdown by event property.
        var $breakdown = []
        if !Str.is_empty(breakdown_property) {
            var $vals = []
            for m in $matched {
                v = Props.get_or(m.properties, breakdown_property, "$none")
                $vals = add_unique_str($vals, v)
            }
            for v in $vals {
                var $v_count = 0.I64
                var $v_persons = []
                for m in $matched {
                    mv = Props.get_or(m.properties, breakdown_property, "$none")
                    if mv == v {
                        $v_count = $v_count + 1
                        $v_persons = add_unique_str($v_persons, m.canon)
                    }
                }
                $breakdown = List.append($breakdown, {
                    value: v,
                    count: $v_count,
                    unique_persons: list_len_i64($v_persons),
                })
            }
            $breakdown = sort_breakdown_desc($breakdown)
        }

        {
            event: event_name,
            total_events: list_len_i64($matched),
            unique_persons: list_len_i64($all_persons),
            buckets: $buckets,
            breakdown: $breakdown,
        }
    }

    ## Sort simplified person events by `timestamp_ms` ascending.
    sort_by_ts_asc : List({ event : Str, timestamp_ms : I64 }) -> List({ event : Str, timestamp_ms : I64 })
    sort_by_ts_asc = |items| {
        var $sorted = []
        for item in items {
            var $next = []
            var $inserted = False
            for existing in $sorted {
                if !$inserted and item.timestamp_ms < existing.timestamp_ms {
                    $next = List.append($next, item)
                    $inserted = True
                }
                $next = List.append($next, existing)
            }
            if !$inserted {
                $next = List.append($next, item)
            }
            $sorted = $next
        }
        $sorted
    }

    ## Compute a multi-step ordered conversion funnel across canonical persons.
    ## Each person's best progression starting from step 0 within `[from_ms, to_ms]`
    ## and completing subsequent steps within `conversion_window_ms` is counted.
    compute_funnel : List(Str), List(EventRecord), List(AliasEntry), I64, I64, I64, List(Props.Filter) -> FunnelResult
    compute_funnel = |raw_steps, events, aliases, from_ms, to_ms, raw_window_ms, filters| {
        steps = take_i64(raw_steps, 20)
        num_steps = list_len_i64(steps)
        if num_steps == 0 {
            return {
                total_entered: 0,
                overall_conversion_rate: 0.0,
                steps: [],
            }
        }

        window_ms = if raw_window_ms <= 0 { 86400000 } else { raw_window_ms }
        first_step = match List.first(steps) {
            Ok(s) => s
            Err(_) => ""
        }

        # Collect relevant events (up to `to_ms + window_ms` so late entrants can finish converting).
        max_ts = safe_add_i64(to_ms, window_ms)
        var $relevant = []
        var $entrants = []
        for ev in events {
            if ev.timestamp_ms >= from_ms
                and ev.timestamp_ms <= max_ts
                and list_contains_str(steps, ev.event)
                and Props.matches_all(ev.properties, filters)
            {
                canon = resolve_id(aliases, ev.distinct_id)
                $relevant = List.append($relevant, {
                    canon,
                    event: ev.event,
                    timestamp_ms: ev.timestamp_ms,
                })
                if ev.event == first_step and ev.timestamp_ms <= to_ms {
                    $entrants = add_unique_str($entrants, canon)
                }
            }
        }

        # For each entrant, compute the best reached step index (0-based) and per-step transition deltas.
        var $person_outcomes = []
        for person_id in $entrants {
            var $p_events = []
            for r in $relevant {
                if r.canon == person_id {
                    $p_events = List.append($p_events, {
                        event: r.event,
                        timestamp_ms: r.timestamp_ms,
                    })
                }
            }
            ordered = sort_by_ts_asc($p_events)

            var $best_step = -1.I64
            var $best_times = []

            # Try every step-0 occurrence in `[from_ms, to_ms]` and keep the deepest progression.
            var $start_idx = 0.I64
            for start_ev in ordered {
                if start_ev.event == first_step and start_ev.timestamp_ms <= to_ms {
                    deadline = safe_add_i64(start_ev.timestamp_ms, window_ms)
                    var $reached = 0.I64
                    var $times = [start_ev.timestamp_ms]
                    var $last_ts = start_ev.timestamp_ms

                    var $want_step = 1.I64
                    var $scan_idx = 0.I64
                    for ev in ordered {
                        if $scan_idx > $start_idx and $want_step < num_steps and ev.timestamp_ms <= deadline {
                            target_ev = get_str_at(steps, $want_step)
                            if ev.event == target_ev and ev.timestamp_ms >= $last_ts {
                                $reached = $want_step
                                $times = List.append($times, ev.timestamp_ms)
                                $last_ts = ev.timestamp_ms
                                $want_step = $want_step + 1
                            }
                        }
                        $scan_idx = $scan_idx + 1
                    }

                    if $reached > $best_step {
                        $best_step = $reached
                        $best_times = $times
                    }
                }
                $start_idx = $start_idx + 1
            }

            if $best_step >= 0 {
                $person_outcomes = List.append($person_outcomes, {
                    max_step: $best_step,
                    times: $best_times,
                })
            }
        }

        total_entered = list_len_i64($person_outcomes)
        var $step_results = []
        var $prev_count = total_entered
        var $step_idx = 0.I64
        for step_name in steps {
            var $step_count = 0.I64
            var $delta_sum = 0.I64
            var $delta_n = 0.I64

            for po in $person_outcomes {
                if po.max_step >= $step_idx {
                    $step_count = $step_count + 1
                    if $step_idx > 0 {
                        t_curr = get_i64_at(po.times, $step_idx)
                        t_prev = get_i64_at(po.times, $step_idx - 1)
                        $delta_sum = $delta_sum + (t_curr - t_prev)
                        $delta_n = $delta_n + 1
                    }
                }
            }

            avg_delta = if $delta_n > 0 { $delta_sum // $delta_n } else { 0 }
            rate_prev = if $step_idx == 0 {
                if $step_count > 0 { 1.0 } else { 0.0 }
            } else {
                ratio($step_count, $prev_count)
            }
            rate_start = ratio($step_count, total_entered)

            $step_results = List.append($step_results, {
                step_index: $step_idx,
                event: step_name,
                count: $step_count,
                conversion_rate_from_prev: rate_prev,
                conversion_rate_from_start: rate_start,
                avg_time_from_prev_ms: avg_delta,
            })

            $prev_count = $step_count
            $step_idx = $step_idx + 1
        }

        overall_rate = if total_entered > 0 {
            last_count = $prev_count
            ratio(last_count, total_entered)
        } else {
            0.0
        }

        {
            total_entered,
            overall_conversion_rate: overall_rate,
            steps: $step_results,
        }
    }

    get_str_at : List(Str), I64 -> Str
    get_str_at = |items, target_idx| {
        var $i = 0.I64
        for item in items {
            if $i == target_idx {
                return item
            }
            $i = $i + 1
        }
        ""
    }

    get_i64_at : List(I64), I64 -> I64
    get_i64_at = |items, target_idx| {
        var $i = 0.I64
        for item in items {
            if $i == target_idx {
                return item
            }
            $i = $i + 1
        }
        0
    }

    ## Compute PostHog-style Cohort Retention table.
    ## Users are assigned to the cohort period of their FIRST `cohort_event` in
    ## `[from_ms, from_ms + num_periods * period_ms)`, then checked for `return_event` in each subsequent period.
    compute_retention : Str, Str, List(EventRecord), List(AliasEntry), I64, I64, I64 -> RetentionResult
    compute_retention = |cohort_event, return_event, events, aliases, from_ms, raw_period_ms, raw_num_periods| {
        period_ms = if raw_period_ms <= 0 { 86400000 } else { raw_period_ms }
        num_periods =
            if raw_num_periods <= 0 {
                7
            } else if raw_num_periods > 60 {
                60
            } else {
                raw_num_periods
            }
        end_ms = safe_add_i64(from_ms, safe_mul_nonneg_i64(num_periods, period_ms))

        # Find each canonical person's earliest cohort_event timestamp within the retention window.
        var $cohort_members = []
        var $return_hits = []

        for ev in events {
            if ev.timestamp_ms >= from_ms and ev.timestamp_ms < end_ms {
                canon = resolve_id(aliases, ev.distinct_id)
                period_idx = safe_sub_nonneg_i64(ev.timestamp_ms, from_ms) // period_ms
                if ev.event == cohort_event {
                    $cohort_members = upsert_earliest_period($cohort_members, canon, period_idx)
                }
                if ev.event == return_event {
                    $return_hits = List.append($return_hits, { canon, period_idx })
                }
            }
        }

        var $cohorts = []
        var $c = 0.I64
        while $c < num_periods {
            var $members = []
            for cm in $cohort_members {
                if cm.period_idx == $c {
                    $members = List.append($members, cm.canon)
                }
            }

            cohort_size = list_len_i64($members)
            var $counts = []
            var $rates = []
            var $offset = 0.I64
            while ($c + $offset) < num_periods {
                target_period = $c + $offset
                var $retained = []
                for h in $return_hits {
                    if h.period_idx == target_period and list_contains_str($members, h.canon) {
                        $retained = add_unique_str($retained, h.canon)
                    }
                }
                r_count = list_len_i64($retained)
                $counts = List.append($counts, r_count)
                $rates = List.append($rates, ratio(r_count, cohort_size))
                $offset = $offset + 1
            }

            $cohorts = List.append($cohorts, {
                cohort_start_ms: safe_add_i64(from_ms, safe_mul_nonneg_i64($c, period_ms)),
                cohort_size,
                retained_counts: $counts,
                retained_rates: $rates,
            })
            $c = $c + 1
        }

        { cohorts: $cohorts }
    }

    upsert_earliest_period : List({ canon : Str, period_idx : I64 }), Str, I64 -> List({ canon : Str, period_idx : I64 })
    upsert_earliest_period = |items, canon, period_idx| {
        var $out = []
        var $found = False
        for item in items {
            if item.canon == canon {
                best = if period_idx < item.period_idx { period_idx } else { item.period_idx }
                $out = List.append($out, { canon, period_idx: best })
                $found = True
            } else {
                $out = List.append($out, item)
            }
        }
        if $found {
            $out
        } else {
            List.append($out, { canon, period_idx })
        }
    }
}

expect {
    aliases = [
        { alias_id: "anon-1", distinct_id: "alice" },
        { alias_id: "anon-0", distinct_id: "anon-1" },
    ]
    Insights.resolve_id(aliases, "anon-0") == "alice"
    and Insights.resolve_id(aliases, "bob") == "bob"
}

expect {
    aliases = [{ alias_id: "anon-a", distinct_id: "alice" }]
    events = [
        { distinct_id: "anon-a", event: "$pageview", timestamp_ms: 1000, session_id: "s1", properties: [Props.prop("path", "/")] },
        { distinct_id: "alice", event: "signup", timestamp_ms: 2000, session_id: "s1", properties: [Props.prop("plan", "pro")] },
        { distinct_id: "bob", event: "$pageview", timestamp_ms: 1500, session_id: "s2", properties: [Props.prop("path", "/pricing")] },
    ]
    summary = Insights.compute_summary(events, aliases, 5)
    summary.total_events == 3
    and summary.unique_persons == 2
    and summary.active_sessions == 2
    and List.len(summary.top_events) == 2
}

expect {
    aliases = [{ alias_id: "anon-a", distinct_id: "alice" }]
    events = [
        { distinct_id: "anon-a", event: "click", timestamp_ms: 100, session_id: "s1", properties: [Props.prop("btn", "cta")] },
        { distinct_id: "alice", event: "click", timestamp_ms: 150, session_id: "s1", properties: [Props.prop("btn", "cta")] },
        { distinct_id: "bob", event: "click", timestamp_ms: 250, session_id: "s2", properties: [Props.prop("btn", "nav")] },
    ]
    trend = Insights.compute_trends("click", events, aliases, 100, 299, 100, "btn", [])
    trend.total_events == 3
    and trend.unique_persons == 2
    and List.len(trend.buckets) == 2
    and List.len(trend.breakdown) == 2
}

expect {
    # Funnel: alice converts across alias (visit->signup 500ms, signup->purchase 500ms),
    # bob drops off after signup (visit->signup 300ms), carol misses conversion window.
    aliases = [{ alias_id: "anon-a", distinct_id: "alice" }]
    events = [
        { distinct_id: "anon-a", event: "visit", timestamp_ms: 1000, session_id: "s1", properties: [] },
        { distinct_id: "alice", event: "signup", timestamp_ms: 1500, session_id: "s1", properties: [] },
        { distinct_id: "alice", event: "purchase", timestamp_ms: 2000, session_id: "s1", properties: [] },
        { distinct_id: "bob", event: "visit", timestamp_ms: 1100, session_id: "s2", properties: [] },
        { distinct_id: "bob", event: "signup", timestamp_ms: 1400, session_id: "s2", properties: [] },
        { distinct_id: "carol", event: "visit", timestamp_ms: 1000, session_id: "s3", properties: [] },
        { distinct_id: "carol", event: "signup", timestamp_ms: 9999, session_id: "s3", properties: [] },
    ]
    f = Insights.compute_funnel(["visit", "signup", "purchase"], events, aliases, 0, 5000, 3000, [])
    counts = f.steps |> List.map(|s| s.count)
    avg_times = f.steps |> List.map(|s| s.avg_time_from_prev_ms)
    f.total_entered == 3
    and counts == [3, 2, 1]
    and avg_times == [0, 400, 500]
}

expect {
    # Retention: alice joins day 0 & returns day 1; bob joins day 0 & does not return; carol joins day 1.
    events = [
        { distinct_id: "alice", event: "signup", timestamp_ms: 100, session_id: "s1", properties: [] },
        { distinct_id: "alice", event: "active", timestamp_ms: 1100, session_id: "s2", properties: [] },
        { distinct_id: "bob", event: "signup", timestamp_ms: 200, session_id: "s3", properties: [] },
        { distinct_id: "carol", event: "signup", timestamp_ms: 1200, session_id: "s4", properties: [] },
    ]
    r = Insights.compute_retention("signup", "active", events, [], 0, 1000, 2)
    sizes = r.cohorts |> List.map(|c| c.cohort_size)
    day0_retained = match List.first(r.cohorts) {
        Ok(c) => c.retained_counts
        Err(_) => []
    }
    sizes == [2, 1] and day0_retained == [0, 1]
}

expect {
    # Auto-widening guarantees bucket conservation even on a 24h range with 60s requested buckets!
    events = [
        { distinct_id: "alice", event: "msg", timestamp_ms: 86400000, session_id: "s1", properties: [] },
        { distinct_id: "bob", event: "msg", timestamp_ms: 0, session_id: "s2", properties: [] },
    ]
    trend = Insights.compute_trends("msg", events, [], 0, 86400000, 60000, "", [])
    var $sum = 0.I64
    for b in trend.buckets {
        $sum = $sum + b.count
    }
    trend.total_events == 2 and $sum == 2 and List.len(trend.buckets) <= 500
}
