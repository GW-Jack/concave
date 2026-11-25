## Pure metric time-series rollups (count, sum, min, max, avg, p50, p95, p99)
## and application health overview summaries.

Rollups := [Rollups].{
    MetricSample : {
        timestamp_ms : I64,
        value : F64,
    }

    MetricBucket : {
        bucket_start_ms : I64,
        count : I64,
        sum : F64,
        min : F64,
        max : F64,
        avg : F64,
        p50 : F64,
        p95 : F64,
        p99 : F64,
    }

    MetricSeriesResult : {
        name : Str,
        count : I64,
        sum : F64,
        min : F64,
        max : F64,
        avg : F64,
        p50 : F64,
        p95 : F64,
        p99 : F64,
        buckets : List(MetricBucket),
    }

    IssueSummary : {
        id : Str,
        fingerprint : Str,
        title : Str,
        source : Str,
        level : Str,
        status : Str,
        count : I64,
        last_seen_ms : I64,
    }

    OverviewResult : {
        open_issues : I64,
        total_issues : I64,
        error_events_in_window : I64,
        error_logs_in_window : I64,
        firing_alerts : I64,
        active_rules : I64,
        top_issues : List(IssueSummary),
        services : List(Str),
    }

    list_len_i64 : List(a) -> I64
    list_len_i64 = |items| {
        var $n = 0.I64
        for _ in items {
            $n = $n + 1
        }
        $n
    }

    list_contains_str : List(Str), Str -> Bool
    list_contains_str = |items, target| {
        for item in items {
            if item == target {
                return True
            }
        }
        False
    }

    add_unique_str : List(Str), Str -> List(Str)
    add_unique_str = |items, target|
        if Str.is_empty(target) or list_contains_str(items, target) {
            items
        } else {
            List.append(items, target)
        }

    ## Sort a list of `F64` values ascending (insertion sort; exact and allocation-light).
    sort_f64_asc : List(F64) -> List(F64)
    sort_f64_asc = |items| {
        var $sorted = []
        for item in items {
            var $next = []
            var $inserted = False
            for existing in $sorted {
                if !$inserted and item < existing {
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

    ## Nearest-rank percentile (`pct` in 0..100) over a pre-sorted ascending `List(F64)`.
    percentile_sorted : List(F64), I64 -> F64
    percentile_sorted = |sorted, pct| {
        n = list_len_i64(sorted)
        if n <= 0 {
            return 0.0
        }
        clamped =
            if pct <= 0 {
                0
            } else if pct >= 100 {
                100
            } else {
                pct
            }
        # Nearest-rank index: ceil(pct / 100 * n) - 1, clamped to [0, n - 1].
        raw_rank = ((clamped * n) + 99) // 100
        target_idx =
            if raw_rank <= 1 {
                0
            } else if raw_rank > n {
                n - 1
            } else {
                raw_rank - 1
            }
        var $idx = 0.I64
        var $res = 0.0
        for v in sorted {
            if $idx == target_idx {
                $res = v
            }
            $idx = $idx + 1
        }
        $res
    }

    Stats : {
        count : I64,
        sum : F64,
        min : F64,
        max : F64,
        avg : F64,
        p50 : F64,
        p95 : F64,
        p99 : F64,
    }

    compute_stats : List(F64) -> Stats
    compute_stats = |values| {
        n = list_len_i64(values)
        if n <= 0 {
            return {
                count: 0,
                sum: 0.0,
                min: 0.0,
                max: 0.0,
                avg: 0.0,
                p50: 0.0,
                p95: 0.0,
                p99: 0.0,
            }
        }
        sorted = sort_f64_asc(values)
        var $sum = 0.0
        var $min_v = 0.0
        var $max_v = 0.0
        var $first = True
        for v in sorted {
            $sum = $sum + v
            if $first {
                $min_v = v
                $max_v = v
                $first = False
            } else {
                if v < $min_v { $min_v = v }
                if v > $max_v { $max_v = v }
            }
        }
        {
            count: n,
            sum: $sum,
            min: $min_v,
            max: $max_v,
            avg: $sum / n.to_f64(),
            p50: percentile_sorted(sorted, 50),
            p95: percentile_sorted(sorted, 95),
            p99: percentile_sorted(sorted, 99),
        }
    }

    ## Compute overall stats and time-bucketed series over `samples`.
    ## Automatically widens `bucket_ms` so at most 500 buckets are ever produced (DoS defense).
    compute_series : Str, List(MetricSample), I64 -> MetricSeriesResult
    compute_series = |name, samples, raw_bucket_ms| {
        req_bucket_ms = if raw_bucket_ms <= 0 { 60000 } else { raw_bucket_ms }

        var $min_ts = 0.I64
        var $max_ts = 0.I64
        var $has_ts = False
        for s in samples {
            if !$has_ts {
                $min_ts = s.timestamp_ms
                $max_ts = s.timestamp_ms
                $has_ts = True
            } else {
                if s.timestamp_ms < $min_ts { $min_ts = s.timestamp_ms }
                if s.timestamp_ms > $max_ts { $max_ts = s.timestamp_ms }
            }
        }

        bucket_ms =
            if $has_ts and $max_ts > $min_ts {
                max_i64 = 9223372036854775807
                span =
                    if $min_ts < 0 and $max_ts > max_i64 + $min_ts {
                        max_i64
                    } else {
                        $max_ts - $min_ts
                    }
                min_step = (span // 500) + 1
                if req_bucket_ms < min_step { min_step } else { req_bucket_ms }
            } else {
                req_bucket_ms
            }

        var $all_vals = []
        var $bucket_starts = []
        for s in samples {
            $all_vals = List.append($all_vals, s.value)
            b_start = (s.timestamp_ms // bucket_ms) * bucket_ms
            var $seen = False
            for bs in $bucket_starts {
                if bs == b_start {
                    $seen = True
                }
            }
            if !$seen {
                $bucket_starts = List.append($bucket_starts, b_start)
            }
        }

        # Sort bucket starts ascending.
        var $sorted_starts = []
        for bs in $bucket_starts {
            var $next = []
            var $inserted = False
            for ex in $sorted_starts {
                if !$inserted and bs < ex {
                    $next = List.append($next, bs)
                    $inserted = True
                }
                $next = List.append($next, ex)
            }
            if !$inserted {
                $next = List.append($next, bs)
            }
            $sorted_starts = $next
        }

        var $buckets = []
        for b_start in $sorted_starts {
            var $b_vals = []
            for s in samples {
                if (s.timestamp_ms // bucket_ms) * bucket_ms == b_start {
                    $b_vals = List.append($b_vals, s.value)
                }
            }
            st = compute_stats($b_vals)
            $buckets = List.append($buckets, {
                bucket_start_ms: b_start,
                count: st.count,
                sum: st.sum,
                min: st.min,
                max: st.max,
                avg: st.avg,
                p50: st.p50,
                p95: st.p95,
                p99: st.p99,
            })
        }

        overall = compute_stats($all_vals)
        {
            name,
            count: overall.count,
            sum: overall.sum,
            min: overall.min,
            max: overall.max,
            avg: overall.avg,
            p50: overall.p50,
            p95: overall.p95,
            p99: overall.p99,
            buckets: $buckets,
        }
    }

    ## Select an aggregate scalar (`count`, `sum`, `avg`, `min`, `max`, `p50`, `p95`, `p99`) from `Stats`.
    select_aggregation : Stats, Str -> F64
    select_aggregation = |st, agg|
        if agg == "count" { st.count.to_f64() }
        else if agg == "sum" { st.sum }
        else if agg == "min" { st.min }
        else if agg == "max" { st.max }
        else if agg == "p50" { st.p50 }
        else if agg == "p95" { st.p95 }
        else if agg == "p99" { st.p99 }
        else { st.avg }
}

expect {
    samples = [
        { timestamp_ms: 1000, value: 10.0 },
        { timestamp_ms: 1500, value: 20.0 },
        { timestamp_ms: 2000, value: 30.0 },
        { timestamp_ms: 61000, value: 40.0 },
        { timestamp_ms: 62000, value: 100.0 },
    ]
    series = Rollups.compute_series("api.latency_ms", samples, 60000)
    series.count == 5
    and series.min == 10.0
    and series.max == 100.0
    and series.avg == 40.0
    and series.p50 == 30.0
    and series.p95 == 100.0
    and List.len(series.buckets) == 2
}

expect {
    empty = Rollups.compute_series("empty", [], 60000)
    empty.count == 0 and empty.avg == 0.0 and List.is_empty(empty.buckets)
}
