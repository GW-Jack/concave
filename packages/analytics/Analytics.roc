import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table
import Flags
import Insights
import Props

## Reusable pure-Roc PostHog-style Product Analytics Component for Concave.
##
## Features:
## - Transactional event capture (`capture`, `captureBatch`, and in-tx `Analytics.track!`)
## - Person profiles & anonymous-to-identified identity resolution (`identify`, `alias`, `$set` / `$set_once`)
## - Feature flags & multivariate A/B experiments (`upsertFlag`, `deleteFlag`, `evaluateFlag`, `evaluateAllFlags`, `evaluateFlagAndTrack`)
## - Live reactive WebSocket insights (`summary`, `trends`, `funnel`, `retention`, `recentEvents`, `personEvents`, `sessionEvents`, `groupEvents`)
## - Strict host-enforced namespace isolation across 4 tables (`events`, `persons`, `aliases`, `feature_flags`)

Analytics := [Analytics].{
    # -------------------------------------------------------------------------
    # Document Types
    # -------------------------------------------------------------------------

    EventDoc : {
        id : Str,
        created_at : I64,
        distinct_id : Str,
        event : Str,
        timestamp_ms : I64,
        session_id : Str,
        group_type : Str,
        group_key : Str,
        properties : List(Props.Prop),
    }

    PersonDoc : {
        id : Str,
        created_at : I64,
        distinct_id : Str,
        properties : List(Props.Prop),
        first_seen_ms : I64,
        last_seen_ms : I64,
        event_count : I64,
    }

    AliasDoc : {
        id : Str,
        created_at : I64,
        alias_id : Str,
        distinct_id : Str,
    }

    FeatureFlagDoc : {
        id : Str,
        created_at : I64,
        key : Str,
        name : Str,
        active : Bool,
        rollout_pct : I64,
        filters : List(Props.Filter),
        variants : List(Flags.Variant),
        updated_at_ms : I64,
    }

    # -------------------------------------------------------------------------
    # Wire Argument & Result Types
    # -------------------------------------------------------------------------

    CaptureArgs : {
        distinct_id : Str,
        event : Str,
        properties : List(Props.Prop),
        session_id : Str,
        group_type : Str,
        group_key : Str,
        timestamp_ms : I64,
    }

    CaptureBatchArgs : {
        events : List(CaptureArgs),
    }

    CaptureBatchResult : {
        accepted : I64,
        event_ids : List(Str),
    }

    IdentifyArgs : {
        distinct_id : Str,
        anon_id : Str,
        set : List(Props.Prop),
        set_once : List(Props.Prop),
    }

    AliasArgs : {
        alias_id : Str,
        distinct_id : Str,
    }

    PersonProfile : {
        found : Bool,
        distinct_id : Str,
        properties : List(Props.Prop),
        aliases : List(Str),
        first_seen_ms : I64,
        last_seen_ms : I64,
        event_count : I64,
    }

    GetPersonArgs : {
        distinct_id : Str,
    }

    ListPersonsArgs : {
        limit : I64,
    }

    RecentEventsArgs : {
        event : Str,
        limit : I64,
    }

    PersonEventsArgs : {
        distinct_id : Str,
        limit : I64,
    }

    SessionEventsArgs : {
        session_id : Str,
        limit : I64,
    }

    GroupEventsArgs : {
        group_type : Str,
        group_key : Str,
        limit : I64,
    }

    UpsertFlagArgs : {
        key : Str,
        name : Str,
        active : Bool,
        rollout_pct : I64,
        filters : List(Props.Filter),
        variants : List(Flags.Variant),
    }

    DeleteFlagArgs : {
        key : Str,
    }

    EvaluateFlagArgs : {
        key : Str,
        distinct_id : Str,
        override_properties : List(Props.Prop),
    }

    EvaluateAllFlagsArgs : {
        distinct_id : Str,
        override_properties : List(Props.Prop),
    }

    EvaluateFlagAndTrackArgs : {
        key : Str,
        distinct_id : Str,
        override_properties : List(Props.Prop),
        session_id : Str,
    }

    SummaryArgs : {
        from_ms : I64,
        to_ms : I64,
        top_n : I64,
    }

    TrendsArgs : {
        event : Str,
        from_ms : I64,
        to_ms : I64,
        bucket_ms : I64,
        breakdown_property : Str,
        filters : List(Props.Filter),
    }

    FunnelArgs : {
        steps : List(Str),
        from_ms : I64,
        to_ms : I64,
        conversion_window_ms : I64,
        filters : List(Props.Filter),
    }

    RetentionArgs : {
        cohort_event : Str,
        return_event : Str,
        from_ms : I64,
        period_ms : I64,
        num_periods : I64,
    }

    Config : {
        require_auth_for_admin : Bool,
        max_batch_size : I64,
    }

    Mount : {
        namespace : Str,
        require_auth_for_admin : Bool,
        admin_roles : List(Str),
        max_batch_size : I64,
        spec : Component.ComponentSpec,
    }

    # -------------------------------------------------------------------------
    # Schemas & Tables
    # -------------------------------------------------------------------------

    prop_schema : Schema
    prop_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("value", Schema.str),
    ])

    filter_schema : Schema
    filter_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("op", Schema.str),
        Schema.field("value", Schema.str),
    ])

    variant_schema : Schema
    variant_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("weight", Schema.int),
    ])

    flag_eval_schema : Schema
    flag_eval_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("enabled", Schema.bool),
        Schema.field("variant", Schema.str),
        Schema.field("reason", Schema.str),
    ])

    events_schema : Schema
    events_schema = Schema.record([
        Schema.field("distinct_id", Schema.str),
        Schema.field("event", Schema.str),
        Schema.field("timestamp_ms", Schema.int),
        Schema.field("session_id", Schema.str),
        Schema.field("group_type", Schema.str),
        Schema.field("group_key", Schema.str),
        Schema.field("properties", Schema.list(prop_schema)),
    ])

    events_table : Table(EventDoc)
    events_table =
        Table.define("events", events_schema)
        |> Table.with_index("by_timestamp", ["timestamp_ms"])
        |> Table.with_index("by_event_time", ["event", "timestamp_ms"])
        |> Table.with_index("by_distinct_time", ["distinct_id", "timestamp_ms"])
        |> Table.with_index("by_session_time", ["session_id", "timestamp_ms"])
        |> Table.with_index("by_group_time", ["group_type", "group_key", "timestamp_ms"])

    events_by_timestamp : Table.Index(EventDoc)
    events_by_timestamp = Table.index_ref(events_table, "by_timestamp")

    events_by_event_time : Table.Index(EventDoc)
    events_by_event_time = Table.index_ref(events_table, "by_event_time")

    events_by_distinct_time : Table.Index(EventDoc)
    events_by_distinct_time = Table.index_ref(events_table, "by_distinct_time")

    events_by_session_time : Table.Index(EventDoc)
    events_by_session_time = Table.index_ref(events_table, "by_session_time")

    events_by_group_time : Table.Index(EventDoc)
    events_by_group_time = Table.index_ref(events_table, "by_group_time")

    persons_schema : Schema
    persons_schema = Schema.record([
        Schema.field("distinct_id", Schema.str),
        Schema.field("properties", Schema.list(prop_schema)),
        Schema.field("first_seen_ms", Schema.int),
        Schema.field("last_seen_ms", Schema.int),
        Schema.field("event_count", Schema.int),
    ])

    persons_table : Table(PersonDoc)
    persons_table =
        Table.define("persons", persons_schema)
        |> Table.with_index("by_distinct_id", ["distinct_id"])
        |> Table.with_index("by_last_seen", ["last_seen_ms"])

    persons_by_distinct_id : Table.Index(PersonDoc)
    persons_by_distinct_id = Table.index_ref(persons_table, "by_distinct_id")

    persons_by_last_seen : Table.Index(PersonDoc)
    persons_by_last_seen = Table.index_ref(persons_table, "by_last_seen")

    aliases_schema : Schema
    aliases_schema = Schema.record([
        Schema.field("alias_id", Schema.str),
        Schema.field("distinct_id", Schema.str),
    ])

    aliases_table : Table(AliasDoc)
    aliases_table =
        Table.define("aliases", aliases_schema)
        |> Table.with_index("by_alias_id", ["alias_id"])
        |> Table.with_index("by_distinct_id", ["distinct_id"])

    aliases_by_alias_id : Table.Index(AliasDoc)
    aliases_by_alias_id = Table.index_ref(aliases_table, "by_alias_id")

    aliases_by_distinct_id : Table.Index(AliasDoc)
    aliases_by_distinct_id = Table.index_ref(aliases_table, "by_distinct_id")

    flags_schema : Schema
    flags_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("active", Schema.bool),
        Schema.field("rollout_pct", Schema.int),
        Schema.field("filters", Schema.list(filter_schema)),
        Schema.field("variants", Schema.list(variant_schema)),
        Schema.field("updated_at_ms", Schema.int),
    ])

    flags_table : Table(FeatureFlagDoc)
    flags_table =
        Table.define("feature_flags", flags_schema)
        |> Table.with_index("by_key", ["key"])

    flags_by_key : Table.Index(FeatureFlagDoc)
    flags_by_key = Table.index_ref(flags_table, "by_key")

    # -------------------------------------------------------------------------
    # Endpoint Wire Schemas
    # -------------------------------------------------------------------------

    capture_args_schema : Schema
    capture_args_schema = Schema.record([
        Schema.field("distinct_id", Schema.str),
        Schema.field("event", Schema.str),
        Schema.field("properties", Schema.list(prop_schema)),
        Schema.field("session_id", Schema.str),
        Schema.field("group_type", Schema.str),
        Schema.field("group_key", Schema.str),
        Schema.field("timestamp_ms", Schema.int),
    ])

    capture_batch_args_schema : Schema
    capture_batch_args_schema = Schema.record([
        Schema.field("events", Schema.list(capture_args_schema)),
    ])

    capture_batch_result_schema : Schema
    capture_batch_result_schema = Schema.record([
        Schema.field("accepted", Schema.int),
        Schema.field("event_ids", Schema.list(Schema.str)),
    ])

    identify_args_schema : Schema
    identify_args_schema = Schema.record([
        Schema.field("distinct_id", Schema.str),
        Schema.field("anon_id", Schema.str),
        Schema.field("set", Schema.list(prop_schema)),
        Schema.field("set_once", Schema.list(prop_schema)),
    ])

    alias_args_schema : Schema
    alias_args_schema = Schema.record([
        Schema.field("alias_id", Schema.str),
        Schema.field("distinct_id", Schema.str),
    ])

    person_profile_schema : Schema
    person_profile_schema = Schema.record([
        Schema.field("found", Schema.bool),
        Schema.field("distinct_id", Schema.str),
        Schema.field("properties", Schema.list(prop_schema)),
        Schema.field("aliases", Schema.list(Schema.str)),
        Schema.field("first_seen_ms", Schema.int),
        Schema.field("last_seen_ms", Schema.int),
        Schema.field("event_count", Schema.int),
    ])

    get_person_args_schema : Schema
    get_person_args_schema = Schema.record([
        Schema.field("distinct_id", Schema.str),
    ])

    list_persons_args_schema : Schema
    list_persons_args_schema = Schema.record([
        Schema.field("limit", Schema.int),
    ])

    recent_events_args_schema : Schema
    recent_events_args_schema = Schema.record([
        Schema.field("event", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    person_events_args_schema : Schema
    person_events_args_schema = Schema.record([
        Schema.field("distinct_id", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    session_events_args_schema : Schema
    session_events_args_schema = Schema.record([
        Schema.field("session_id", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    group_events_args_schema : Schema
    group_events_args_schema = Schema.record([
        Schema.field("group_type", Schema.str),
        Schema.field("group_key", Schema.str),
        Schema.field("limit", Schema.int),
    ])

    upsert_flag_args_schema : Schema
    upsert_flag_args_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("name", Schema.str),
        Schema.field("active", Schema.bool),
        Schema.field("rollout_pct", Schema.int),
        Schema.field("filters", Schema.list(filter_schema)),
        Schema.field("variants", Schema.list(variant_schema)),
    ])

    delete_flag_args_schema : Schema
    delete_flag_args_schema = Schema.record([
        Schema.field("key", Schema.str),
    ])

    evaluate_flag_args_schema : Schema
    evaluate_flag_args_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("distinct_id", Schema.str),
        Schema.field("override_properties", Schema.list(prop_schema)),
    ])

    evaluate_all_flags_args_schema : Schema
    evaluate_all_flags_args_schema = Schema.record([
        Schema.field("distinct_id", Schema.str),
        Schema.field("override_properties", Schema.list(prop_schema)),
    ])

    evaluate_flag_and_track_args_schema : Schema
    evaluate_flag_and_track_args_schema = Schema.record([
        Schema.field("key", Schema.str),
        Schema.field("distinct_id", Schema.str),
        Schema.field("override_properties", Schema.list(prop_schema)),
        Schema.field("session_id", Schema.str),
    ])

    summary_args_schema : Schema
    summary_args_schema = Schema.record([
        Schema.field("from_ms", Schema.int),
        Schema.field("to_ms", Schema.int),
        Schema.field("top_n", Schema.int),
    ])

    summary_result_schema : Schema
    summary_result_schema = Schema.record([
        Schema.field("total_events", Schema.int),
        Schema.field("unique_persons", Schema.int),
        Schema.field("active_sessions", Schema.int),
        Schema.field(
            "top_events",
            Schema.list(
                Schema.record([
                    Schema.field("event", Schema.str),
                    Schema.field("count", Schema.int),
                    Schema.field("unique_persons", Schema.int),
                ]),
            ),
        ),
    ])

    trends_args_schema : Schema
    trends_args_schema = Schema.record([
        Schema.field("event", Schema.str),
        Schema.field("from_ms", Schema.int),
        Schema.field("to_ms", Schema.int),
        Schema.field("bucket_ms", Schema.int),
        Schema.field("breakdown_property", Schema.str),
        Schema.field("filters", Schema.list(filter_schema)),
    ])

    trends_result_schema : Schema
    trends_result_schema = Schema.record([
        Schema.field("event", Schema.str),
        Schema.field("total_events", Schema.int),
        Schema.field("unique_persons", Schema.int),
        Schema.field(
            "buckets",
            Schema.list(
                Schema.record([
                    Schema.field("bucket_start_ms", Schema.int),
                    Schema.field("count", Schema.int),
                    Schema.field("unique_persons", Schema.int),
                ]),
            ),
        ),
        Schema.field(
            "breakdown",
            Schema.list(
                Schema.record([
                    Schema.field("value", Schema.str),
                    Schema.field("count", Schema.int),
                    Schema.field("unique_persons", Schema.int),
                ]),
            ),
        ),
    ])

    funnel_args_schema : Schema
    funnel_args_schema = Schema.record([
        Schema.field("steps", Schema.list(Schema.str)),
        Schema.field("from_ms", Schema.int),
        Schema.field("to_ms", Schema.int),
        Schema.field("conversion_window_ms", Schema.int),
        Schema.field("filters", Schema.list(filter_schema)),
    ])

    funnel_result_schema : Schema
    funnel_result_schema = Schema.record([
        Schema.field("total_entered", Schema.int),
        Schema.field("overall_conversion_rate", Schema.float),
        Schema.field(
            "steps",
            Schema.list(
                Schema.record([
                    Schema.field("step_index", Schema.int),
                    Schema.field("event", Schema.str),
                    Schema.field("count", Schema.int),
                    Schema.field("conversion_rate_from_prev", Schema.float),
                    Schema.field("conversion_rate_from_start", Schema.float),
                    Schema.field("avg_time_from_prev_ms", Schema.int),
                ]),
            ),
        ),
    ])

    retention_args_schema : Schema
    retention_args_schema = Schema.record([
        Schema.field("cohort_event", Schema.str),
        Schema.field("return_event", Schema.str),
        Schema.field("from_ms", Schema.int),
        Schema.field("period_ms", Schema.int),
        Schema.field("num_periods", Schema.int),
    ])

    retention_result_schema : Schema
    retention_result_schema = Schema.record([
        Schema.field(
            "cohorts",
            Schema.list(
                Schema.record([
                    Schema.field("cohort_start_ms", Schema.int),
                    Schema.field("cohort_size", Schema.int),
                    Schema.field("retained_counts", Schema.list(Schema.int)),
                    Schema.field("retained_rates", Schema.list(Schema.float)),
                ]),
            ),
        ),
    ])

    # -------------------------------------------------------------------------
    # Ergonomic Constructors & Mounting
    # -------------------------------------------------------------------------

    prop : Str, Str -> Props.Prop
    prop = Props.prop

    default_config : Config
    default_config = {
        require_auth_for_admin: True,
        max_batch_size: 100,
    }

    ## Mount an isolated PostHog-style Analytics component under `namespace` with secure defaults.
    mount : Str -> Mount
    mount = |namespace| mount_with(namespace, default_config)

    ## Mount an isolated Analytics component with explicit `Config`.
    mount_with : Str, Config -> Mount
    mount_with = |namespace, cfg| {
        namespace,
        require_auth_for_admin: cfg.require_auth_for_admin,
        admin_roles: ["admin"],
        max_batch_size: if cfg.max_batch_size <= 0 { 100 } else if cfg.max_batch_size > 500 { 500 } else { cfg.max_batch_size },
        spec: Component.define(
            namespace,
            "concave-analytics",
            [
                Table.spec(events_table),
                Table.spec(persons_table),
                Table.spec(aliases_table),
                Table.spec(flags_table),
            ],
        ),
    }

    ## Override the roles permitted to access Analytics admin/BI endpoints (default: `["admin"]`; empty allows any authenticated user).
    with_admin_roles : Mount, List(Str) -> Mount
    with_admin_roles = |m, roles| {
        namespace: m.namespace,
        require_auth_for_admin: m.require_auth_for_admin,
        admin_roles: roles,
        max_batch_size: m.max_batch_size,
        spec: m.spec,
    }

    # -------------------------------------------------------------------------
    # Internal Helpers
    # -------------------------------------------------------------------------

    is_admin_identity : Ctx.AuthIdentity, List(Str) -> Bool
    is_admin_identity = |id, admin_roles|
        if List.is_empty(admin_roles) {
            True
        } else {
            Ctx.has_any_role(id, admin_roles)
        }

    require_admin_if_needed! : Bool, List(Str), (() => Try(Ctx.AuthIdentity, [Unauthenticated])) => Try({}, Str)
    require_admin_if_needed! = |req_auth, admin_roles, auth!|
        if req_auth {
            id = Ctx.require_auth!(auth!)?
            if is_admin_identity(id, admin_roles) {
                Ok({})
            } else {
                Err("Forbidden: admin role required")
            }
        } else {
            Ok({})
        }

    clamp_props : List(Props.Prop) -> List(Props.Prop)
    clamp_props = |items| Insights.take_i64(items, 64)

    clamp_event_ts : I64, I64, Bool -> I64
    clamp_event_ts = |raw_ts, now, allow_historical| {
        if raw_ts <= 0 {
            return now
        }
        max_future = now + 300000 # 5 minutes
        if raw_ts > max_future {
            return now
        }
        if allow_historical {
            return raw_ts
        }
        max_past = now - 31536000000 # 365 days
        if raw_ts < max_past {
            now
        } else {
            raw_ts
        }
    }

    clamp_limit_u64 : I64, I64, I64 -> U64
    clamp_limit_u64 = |raw, default_val, max_val| {
        clamped =
            if raw <= 0 {
                default_val
            } else if raw > max_val {
                max_val
            } else {
                raw
            }
        var $out = 0.U64
        var $rem = clamped
        while $rem >= 100 {
            $out = $out + 100
            $rem = $rem - 100
        }
        while $rem >= 10 {
            $out = $out + 10
            $rem = $rem - 10
        }
        while $rem > 0 {
            $out = $out + 1
            $rem = $rem - 1
        }
        $out
    }

    resolve_distinct_id_db! : Ctx.DbReader, Str => Try(Str, Str)
    resolve_distinct_id_db! = |db, raw_id| {
        var $cur = raw_id
        var $hops = 0.I64
        while $hops < 8 {
            lookup =
                Db.from_index(aliases_by_alias_id)
                |> Db.eq([Key.str($cur)])
                |> Db.first!(db)?
            match lookup {
                NotFound => return Ok($cur)
                Found(doc) => {
                    if doc.distinct_id == $cur {
                        return Ok($cur)
                    }
                    $cur = doc.distinct_id
                }
            }
            $hops = $hops + 1
        }
        Ok($cur)
    }

    ## Resolve the caller's distinct_id safely:
    ## - When authenticated and NOT an admin, bind strictly to `id.subject` (prevents cross-user spoofing).
    ## - When authenticated as an admin (or when `require_auth_for_admin` is False and unauthenticated),
    ##   allow explicit `provided` distinct_id.
    resolve_caller_distinct_id! : List(Str), (() => Try(Ctx.AuthIdentity, [Unauthenticated])), Str => Try(Str, Str)
    resolve_caller_distinct_id! = |admin_roles, auth!, provided| {
        trimmed = Str.trim(provided)
        match auth!() {
            Ok(id) =>
                if is_admin_identity(id, admin_roles) and !Str.is_empty(trimmed) {
                    Ok(trimmed)
                } else {
                    Ok(id.subject)
                }
            Err(Unauthenticated) =>
                if !Str.is_empty(trimmed) {
                    Ok(trimmed)
                } else {
                    Err("distinct_id is required when unauthenticated")
                }
        }
    }

    collect_linked_aliases! : Ctx.DbReader, Str => Try(List(Str), Str)
    collect_linked_aliases! = |db, canonical_id| {
        var $frontier = [canonical_id]
        var $aliases = []
        var $depth = 0.I64
        while $depth < 8 and !List.is_empty($frontier) {
            var $next_frontier = []
            for target_id in $frontier {
                docs =
                    Db.from_index(aliases_by_distinct_id)
                    |> Db.eq([Key.str(target_id)])
                    |> Db.collect!(db)?
                for d in docs {
                    if d.alias_id != canonical_id and !Insights.list_contains_str($aliases, d.alias_id) {
                        $aliases = List.append($aliases, d.alias_id)
                        $next_frontier = List.append($next_frontier, d.alias_id)
                    }
                }
            }
            $frontier = $next_frontier
            $depth = $depth + 1
        }
        Ok($aliases)
    }

    load_aliases! : Ctx.DbReader => Try(List(Insights.AliasEntry), Str)
    load_aliases! = |db| {
        docs = Db.query(aliases_table) |> Db.asc() |> Db.take(2000) |> Db.collect!(db)?
        Ok(docs |> List.map(|d| { alias_id: d.alias_id, distinct_id: d.distinct_id }))
    }

    event_doc_to_record : EventDoc -> Insights.EventRecord
    event_doc_to_record = |d| {
        distinct_id: d.distinct_id,
        event: d.event,
        timestamp_ms: d.timestamp_ms,
        session_id: d.session_id,
        properties: d.properties,
    }

    flag_doc_to_rule : FeatureFlagDoc -> Flags.FlagRule
    flag_doc_to_rule = |d| {
        key: d.key,
        active: d.active,
        rollout_pct: d.rollout_pct,
        filters: d.filters,
        variants: d.variants,
    }

    sort_events_desc : List(EventDoc) -> List(EventDoc)
    sort_events_desc = |items| {
        var $sorted = []
        for item in items {
            var $next = []
            var $inserted = False
            for existing in $sorted {
                if !$inserted and item.timestamp_ms > existing.timestamp_ms {
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

    take_events : List(EventDoc), I64 -> List(EventDoc)
    take_events = |items, limit| {
        var $out = []
        var $n = 0.I64
        for item in items {
            if $n < limit {
                $out = List.append($out, item)
                $n = $n + 1
            }
        }
        $out
    }

    # -------------------------------------------------------------------------
    # Core Mutations (Scoped to Component Namespace)
    # -------------------------------------------------------------------------

    ## Capture a single product event and update the canonical person's activity counters.
    capture! : List(Str), Ctx.MutationCtx, CaptureArgs => Try(Str, Str)
    capture! = |admin_roles, ctx, args| {
        event_name = Str.trim(args.event)
        if Str.is_empty(event_name) {
            return Err("Event name cannot be empty")
        }
        if Str.count_utf8_bytes(event_name) > 256 {
            return Err("Event name exceeds maximum length")
        }

        auth! = ctx.auth!
        caller_is_admin = match auth!() {
            Ok(id) => is_admin_identity(id, admin_roles)
            Err(Unauthenticated) => False
        }
        raw_id = resolve_caller_distinct_id!(admin_roles, ctx.auth!, args.distinct_id)?
        reader = Ctx.as_reader(ctx.db)
        canonical_id = resolve_distinct_id_db!(reader, raw_id)?

        now_ms! = ctx.now_ms!
        now = now_ms!()
        ts = clamp_event_ts(args.timestamp_ms, now, caller_is_admin)

        event_id = Db.insert!(ctx.db, events_table, {
            distinct_id: canonical_id,
            event: event_name,
            timestamp_ms: ts,
            session_id: Str.trim(args.session_id),
            group_type: Str.trim(args.group_type),
            group_key: Str.trim(args.group_key),
            properties: clamp_props(args.properties),
        })?

        # Keep canonical person profile up to date in the same ACID transaction.
        existing_person =
            Db.from_index(persons_by_distinct_id)
            |> Db.eq([Key.str(canonical_id)])
            |> Db.first!(reader)?

        match existing_person {
            NotFound => {
                empty_props : List(Props.Prop)
                empty_props = []
                _ = Db.insert!(ctx.db, persons_table, {
                    distinct_id: canonical_id,
                    properties: empty_props,
                    first_seen_ms: ts,
                    last_seen_ms: ts,
                    event_count: 1.I64,
                })?
            }
            Found(person) => {
                first_ms = if ts < person.first_seen_ms { ts } else { person.first_seen_ms }
                last_ms = if ts > person.last_seen_ms { ts } else { person.last_seen_ms }
                Db.patch!(ctx.db, persons_table, person.id, {
                    first_seen_ms: first_ms,
                    last_seen_ms: last_ms,
                    event_count: person.event_count + 1,
                })?
            }
        }

        Ok(event_id)
    }

    ## Atomically capture a batch of events (PostHog `/batch/` equivalent).
    capture_batch! : List(Str), I64, Ctx.MutationCtx, CaptureBatchArgs => Try(CaptureBatchResult, Str)
    capture_batch! = |admin_roles, max_batch, ctx, args| {
        count = Insights.list_len_i64(args.events)
        if count > max_batch {
            return Err("Batch size ${count.to_str()} exceeds max_batch_size (${max_batch.to_str()})")
        }
        var $ids = []
        for ev in args.events {
            ev_id = capture!(admin_roles, ctx, ev)?
            $ids = List.append($ids, ev_id)
        }
        Ok({
            accepted: count,
            event_ids: $ids,
        })
    }

    ## PostHog `identify`: link optional `anon_id` -> `distinct_id`, merge anonymous person profile,
    ## and apply `$set` (overwrite) and `$set_once` (initial-only) person properties.
    ## Enforces authentication (when `req_auth` is True), caller-identity binding, forest acyclicity,
    ## root-only person rows, and event-count conservation.
    identify! : Bool, List(Str), Ctx.MutationCtx, IdentifyArgs => Try(PersonProfile, Str)
    identify! = |req_auth, admin_roles, ctx, args| {
        raw_distinct_id =
            if req_auth {
                user = Ctx.require_auth!(ctx.auth!)?
                trimmed = Str.trim(args.distinct_id)
                if is_admin_identity(user, admin_roles) and !Str.is_empty(trimmed) {
                    trimmed
                } else {
                    user.subject
                }
            } else {
                trimmed = Str.trim(args.distinct_id)
                if Str.is_empty(trimmed) {
                    return Err("distinct_id cannot be empty")
                }
                trimmed
            }
        anon_id = Str.trim(args.anon_id)
        reader = Ctx.as_reader(ctx.db)
        now_ms! = ctx.now_ms!
        now = now_ms!()

        # Always resolve `distinct_id` to its canonical root so we never create non-root person rows.
        canonical_id = resolve_distinct_id_db!(reader, raw_distinct_id)?

        # Merge anonymous person profile & create alias ONLY when `anon_id` is an unaliased root
        # distinct from `canonical_id` (prevents cycles and cross-person alias hijacking).
        var $anon_props = []
        var $anon_first = now
        var $anon_last = now
        var $anon_has_seen = False
        var $anon_events = 0.I64

        if !Str.is_empty(anon_id) and anon_id != canonical_id {
            anon_resolved = resolve_distinct_id_db!(reader, anon_id)?
            if anon_resolved == anon_id {
                _ = Db.insert!(ctx.db, aliases_table, {
                    alias_id: anon_id,
                    distinct_id: canonical_id,
                })?

                anon_person =
                    Db.from_index(persons_by_distinct_id)
                    |> Db.eq([Key.str(anon_id)])
                    |> Db.first!(reader)?

                match anon_person {
                    NotFound => {}
                    Found(ap) => {
                        $anon_props = ap.properties
                        $anon_first = ap.first_seen_ms
                        $anon_last = ap.last_seen_ms
                        $anon_has_seen = True
                        $anon_events = ap.event_count
                        Db.delete!(ctx.db, persons_table, ap.id)?
                    }
                }
            }
        }

        existing_canon =
            Db.from_index(persons_by_distinct_id)
            |> Db.eq([Key.str(canonical_id)])
            |> Db.first!(reader)?

        set_once_clamped = clamp_props(args.set_once)
        set_clamped = clamp_props(args.set)

        final_person = match existing_canon {
            NotFound => {
                merged =
                    $anon_props
                    |> Props.merge_set_once(set_once_clamped)
                    |> Props.merge_set(set_clamped)
                    |> clamp_props
                first_ms = if $anon_has_seen { $anon_first } else { now }
                last_ms = if $anon_has_seen and $anon_last > now { $anon_last } else { now }
                _ = Db.insert!(ctx.db, persons_table, {
                    distinct_id: canonical_id,
                    properties: merged,
                    first_seen_ms: first_ms,
                    last_seen_ms: last_ms,
                    event_count: $anon_events,
                })?
                {
                    properties: merged,
                    first_seen_ms: first_ms,
                    last_seen_ms: last_ms,
                    event_count: $anon_events,
                }
            }
            Found(cp) => {
                # Precedence: anon_props < existing canonical props < set_once < set
                base_props = Props.merge_set($anon_props, cp.properties)
                merged =
                    base_props
                    |> Props.merge_set_once(set_once_clamped)
                    |> Props.merge_set(set_clamped)
                    |> clamp_props
                first_ms =
                    if $anon_has_seen and $anon_first < cp.first_seen_ms {
                        $anon_first
                    } else {
                        cp.first_seen_ms
                    }
                last_ms_0 =
                    if $anon_has_seen and $anon_last > cp.last_seen_ms {
                        $anon_last
                    } else {
                        cp.last_seen_ms
                    }
                last_ms = if now > last_ms_0 { now } else { last_ms_0 }
                total_events = cp.event_count + $anon_events
                Db.patch!(ctx.db, persons_table, cp.id, {
                    properties: merged,
                    first_seen_ms: first_ms,
                    last_seen_ms: last_ms,
                    event_count: total_events,
                })?
                {
                    properties: merged,
                    first_seen_ms: first_ms,
                    last_seen_ms: last_ms,
                    event_count: total_events,
                }
            }
        }

        alias_ids = collect_linked_aliases!(reader, canonical_id)?

        Ok({
            found: True,
            distinct_id: canonical_id,
            properties: final_person.properties,
            aliases: alias_ids,
            first_seen_ms: final_person.first_seen_ms,
            last_seen_ms: final_person.last_seen_ms,
            event_count: final_person.event_count,
        })
    }

    ## Explicitly alias `alias_id` -> `distinct_id`.
    ## Requires admin auth (when `req_auth` is True) to prevent cross-account identity hijacking.
    alias! : Bool, List(Str), Ctx.MutationCtx, AliasArgs => Try(Bool, Str)
    alias! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        alias_id = Str.trim(args.alias_id)
        distinct_id = Str.trim(args.distinct_id)
        if Str.is_empty(alias_id) or Str.is_empty(distinct_id) {
            return Err("alias_id and distinct_id cannot be empty")
        }
        if alias_id == distinct_id {
            return Ok(False)
        }
        reader = Ctx.as_reader(ctx.db)
        canonical_target = resolve_distinct_id_db!(reader, distinct_id)?
        if canonical_target == alias_id {
            return Err("Cannot create cyclic alias")
        }
        alias_resolved = resolve_distinct_id_db!(reader, alias_id)?
        if alias_resolved == canonical_target {
            return Ok(False)
        }
        if alias_resolved != alias_id {
            return Err("alias_id is already linked to a different distinct_id")
        }

        _ = Db.insert!(ctx.db, aliases_table, {
            alias_id,
            distinct_id: canonical_target,
        })?

        # Merge any existing `persons` row for `alias_id` into `canonical_target` so only roots hold person rows.
        src_person =
            Db.from_index(persons_by_distinct_id)
            |> Db.eq([Key.str(alias_id)])
            |> Db.first!(reader)?

        match src_person {
            NotFound => {}
            Found(sp) => {
                Db.delete!(ctx.db, persons_table, sp.id)?
                dst_person =
                    Db.from_index(persons_by_distinct_id)
                    |> Db.eq([Key.str(canonical_target)])
                    |> Db.first!(reader)?
                match dst_person {
                    NotFound => {
                        _ = Db.insert!(ctx.db, persons_table, {
                            distinct_id: canonical_target,
                            properties: sp.properties,
                            first_seen_ms: sp.first_seen_ms,
                            last_seen_ms: sp.last_seen_ms,
                            event_count: sp.event_count,
                        })?
                    }
                    Found(dp) => {
                        merged_props = Props.merge_set(sp.properties, dp.properties) |> clamp_props
                        first_ms = if sp.first_seen_ms < dp.first_seen_ms { sp.first_seen_ms } else { dp.first_seen_ms }
                        last_ms = if sp.last_seen_ms > dp.last_seen_ms { sp.last_seen_ms } else { dp.last_seen_ms }
                        Db.patch!(ctx.db, persons_table, dp.id, {
                            properties: merged_props,
                            first_seen_ms: first_ms,
                            last_seen_ms: last_ms,
                            event_count: dp.event_count + sp.event_count,
                        })?
                    }
                }
            }
        }

        Ok(True)
    }

    ## Create or update a Feature Flag / A/B Experiment definition.
    upsert_flag! : Bool, List(Str), Ctx.MutationCtx, UpsertFlagArgs => Try(Str, Str)
    upsert_flag! = |require_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(require_auth, admin_roles, ctx.auth!)?
        key = Str.trim(args.key)
        rule : Flags.FlagRule
        rule = {
            key,
            active: args.active,
            rollout_pct: args.rollout_pct,
            filters: args.filters,
            variants: args.variants,
        }
        Flags.validate(rule)?

        now_ms! = ctx.now_ms!
        now = now_ms!()
        reader = Ctx.as_reader(ctx.db)

        existing =
            Db.from_index(flags_by_key)
            |> Db.eq([Key.str(key)])
            |> Db.first!(reader)?

        match existing {
            NotFound =>
                Db.insert!(ctx.db, flags_table, {
                    key,
                    name: args.name,
                    active: args.active,
                    rollout_pct: args.rollout_pct,
                    filters: args.filters,
                    variants: args.variants,
                    updated_at_ms: now,
                })
            Found(doc) => {
                Db.patch!(ctx.db, flags_table, doc.id, {
                    name: args.name,
                    active: args.active,
                    rollout_pct: args.rollout_pct,
                    filters: args.filters,
                    variants: args.variants,
                    updated_at_ms: now,
                })?
                Ok(doc.id)
            }
        }
    }

    ## Delete a Feature Flag by `key`.
    delete_flag! : Bool, List(Str), Ctx.MutationCtx, DeleteFlagArgs => Try(Bool, Str)
    delete_flag! = |require_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(require_auth, admin_roles, ctx.auth!)?
        key = Str.trim(args.key)
        existing =
            Db.from_index(flags_by_key)
            |> Db.eq([Key.str(key)])
            |> Db.first!(Ctx.as_reader(ctx.db))?

        match existing {
            NotFound => Ok(False)
            Found(doc) => {
                Db.delete!(ctx.db, flags_table, doc.id)?
                Ok(True)
            }
        }
    }

    ## Evaluate a flag AND atomically record a `$feature_flag_called` exposure event for experiment analysis.
    evaluate_flag_and_track! : List(Str), Ctx.MutationCtx, EvaluateFlagAndTrackArgs => Try(Flags.Evaluation, Str)
    evaluate_flag_and_track! = |admin_roles, ctx, args| {
        eval = evaluate_flag!(admin_roles, Ctx.as_query_ctx(ctx), {
            key: args.key,
            distinct_id: args.distinct_id,
            override_properties: args.override_properties,
        })?

        enabled_str = if eval.enabled { "true" } else { "false" }
        _ = capture!(admin_roles, ctx, {
            distinct_id: args.distinct_id,
            event: "$feature_flag_called",
            properties: [
                Props.prop("$feature_flag", eval.key),
                Props.prop("$feature_flag_response", if eval.enabled { eval.variant } else { "false" }),
                Props.prop("$feature_flag_enabled", enabled_str),
                Props.prop("$feature_flag_reason", eval.reason),
            ],
            session_id: args.session_id,
            group_type: "",
            group_key: "",
            timestamp_ms: 0,
        })?

        Ok(eval)
    }

    # -------------------------------------------------------------------------
    # Core Reactive Queries (Scoped to Component Namespace)
    # -------------------------------------------------------------------------

    ## Stream the most recent captured events (admin-gated when `req_auth` is True).
    recent_events! : Bool, List(Str), Ctx.QueryCtx, RecentEventsArgs => Try(List(EventDoc), Str)
    recent_events! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        lim = clamp_limit_u64(args.limit, 50, 500)
        ev_filter = Str.trim(args.event)
        if Str.is_empty(ev_filter) {
            Db.from_index(events_by_timestamp)
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        } else {
            Db.from_index(events_by_event_time)
            |> Db.eq([Key.str(ev_filter)])
            |> Db.desc()
            |> Db.take(lim)
            |> Db.collect!(ctx.db)
        }
    }

    ## Fetch a person's unified event timeline across their canonical ID and all linked aliases.
    ## When `req_auth` is True, requires caller to be an admin or querying their own canonical ID.
    person_events! : Bool, List(Str), Ctx.QueryCtx, PersonEventsArgs => Try(List(EventDoc), Str)
    person_events! = |req_auth, admin_roles, ctx, args| {
        lim_i64 = if args.limit <= 0 { 50 } else if args.limit > 500 { 500 } else { args.limit }
        lim_u64 = clamp_limit_u64(lim_i64, 50, 500)
        canonical_id = resolve_distinct_id_db!(ctx.db, Str.trim(args.distinct_id))?
        if req_auth {
            user = Ctx.require_auth!(ctx.auth!)?
            user_canon = resolve_distinct_id_db!(ctx.db, user.subject)?
            if !is_admin_identity(user, admin_roles) and canonical_id != user_canon {
                return Err("Forbidden: cannot access another person's events")
            }
        }

        alias_ids = collect_linked_aliases!(ctx.db, canonical_id)?

        var $ids = [canonical_id]
        for aid in alias_ids {
            $ids = Insights.add_unique_str($ids, aid)
        }

        var $all_events = []
        for id in $ids {
            chunk =
                Db.from_index(events_by_distinct_time)
                |> Db.eq([Key.str(id)])
                |> Db.desc()
                |> Db.take(lim_u64)
                |> Db.collect!(ctx.db)?
            $all_events = List.concat($all_events, chunk)
        }

        Ok($all_events |> sort_events_desc |> take_events(lim_i64))
    }

    ## Fetch all events for a session in chronological order (admin-gated when `req_auth` is True).
    session_events! : Bool, List(Str), Ctx.QueryCtx, SessionEventsArgs => Try(List(EventDoc), Str)
    session_events! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        lim = clamp_limit_u64(args.limit, 100, 500)
        Db.from_index(events_by_session_time)
        |> Db.eq([Key.str(Str.trim(args.session_id))])
        |> Db.asc()
        |> Db.take(lim)
        |> Db.collect!(ctx.db)
    }

    ## Fetch recent events for a B2B group (`group_type`, `group_key`) (admin-gated when `req_auth` is True).
    group_events! : Bool, List(Str), Ctx.QueryCtx, GroupEventsArgs => Try(List(EventDoc), Str)
    group_events! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        lim = clamp_limit_u64(args.limit, 100, 500)
        Db.from_index(events_by_group_time)
        |> Db.eq([Key.str(Str.trim(args.group_type)), Key.str(Str.trim(args.group_key))])
        |> Db.desc()
        |> Db.take(lim)
        |> Db.collect!(ctx.db)
    }

    ## Look up a person's profile (admin or self-only when `req_auth` is True).
    get_person! : Bool, List(Str), Ctx.QueryCtx, GetPersonArgs => Try(PersonProfile, Str)
    get_person! = |req_auth, admin_roles, ctx, args| {
        canonical_id = resolve_distinct_id_db!(ctx.db, Str.trim(args.distinct_id))?
        if req_auth {
            user = Ctx.require_auth!(ctx.auth!)?
            user_canon = resolve_distinct_id_db!(ctx.db, user.subject)?
            if !is_admin_identity(user, admin_roles) and canonical_id != user_canon {
                return Err("Forbidden: cannot access another person's profile")
            }
        }
        person_lookup =
            Db.from_index(persons_by_distinct_id)
            |> Db.eq([Key.str(canonical_id)])
            |> Db.first!(ctx.db)?

        alias_ids = collect_linked_aliases!(ctx.db, canonical_id)?

        match person_lookup {
            NotFound =>
                Ok({
                    found: False,
                    distinct_id: canonical_id,
                    properties: [],
                    aliases: alias_ids,
                    first_seen_ms: 0,
                    last_seen_ms: 0,
                    event_count: 0,
                })
            Found(p) =>
                Ok({
                    found: True,
                    distinct_id: p.distinct_id,
                    properties: p.properties,
                    aliases: alias_ids,
                    first_seen_ms: p.first_seen_ms,
                    last_seen_ms: p.last_seen_ms,
                    event_count: p.event_count,
                })
        }
    }

    ## List most recently active persons (admin-gated when `req_auth` is True).
    list_persons! : Bool, List(Str), Ctx.QueryCtx, ListPersonsArgs => Try(List(PersonDoc), Str)
    list_persons! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        lim = clamp_limit_u64(args.limit, 50, 500)
        Db.from_index(persons_by_last_seen)
        |> Db.desc()
        |> Db.take(lim)
        |> Db.collect!(ctx.db)
    }

    ## List all configured feature flags and experiments (admin-gated when `req_auth` is True).
    list_flags! : Bool, List(Str), Ctx.QueryCtx, {} => Try(List(FeatureFlagDoc), Str)
    list_flags! = |req_auth, admin_roles, ctx, _| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        Db.from_index(flags_by_key)
        |> Db.asc()
        |> Db.take(500)
        |> Db.collect!(ctx.db)
    }

    ## Evaluate a single feature flag for `distinct_id`.
    ## Server-stored person properties take precedence over caller-supplied `override_properties`
    ## so untrusted clients cannot spoof premium/plan targeting rules.
    evaluate_flag! : List(Str), Ctx.QueryCtx, EvaluateFlagArgs => Try(Flags.Evaluation, Str)
    evaluate_flag! = |admin_roles, ctx, args| {
        key = Str.trim(args.key)
        raw_id = resolve_caller_distinct_id!(admin_roles, ctx.auth!, args.distinct_id)?
        canonical_id = resolve_distinct_id_db!(ctx.db, raw_id)?

        flag_lookup =
            Db.from_index(flags_by_key)
            |> Db.eq([Key.str(key)])
            |> Db.first!(ctx.db)?

        match flag_lookup {
            NotFound =>
                Ok({
                    key,
                    enabled: False,
                    variant: "",
                    reason: "not_found",
                })
            Found(flag_doc) => {
                person_lookup =
                    Db.from_index(persons_by_distinct_id)
                    |> Db.eq([Key.str(canonical_id)])
                    |> Db.first!(ctx.db)?

                stored_props = match person_lookup {
                    NotFound => []
                    Found(p) => p.properties
                }
                effective_props = Props.merge_set(clamp_props(args.override_properties), stored_props)
                Ok(Flags.evaluate(flag_doc_to_rule(flag_doc), canonical_id, effective_props))
            }
        }
    }

    ## Evaluate all feature flags for `distinct_id` (reactive PostHog `/decide` equivalent).
    evaluate_all_flags! : List(Str), Ctx.QueryCtx, EvaluateAllFlagsArgs => Try(List(Flags.Evaluation), Str)
    evaluate_all_flags! = |admin_roles, ctx, args| {
        raw_id = resolve_caller_distinct_id!(admin_roles, ctx.auth!, args.distinct_id)?
        canonical_id = resolve_distinct_id_db!(ctx.db, raw_id)?

        person_lookup =
            Db.from_index(persons_by_distinct_id)
            |> Db.eq([Key.str(canonical_id)])
            |> Db.first!(ctx.db)?

        stored_props = match person_lookup {
            NotFound => []
            Found(p) => p.properties
        }
        effective_props = Props.merge_set(clamp_props(args.override_properties), stored_props)

        all_flags = Db.from_index(flags_by_key) |> Db.asc() |> Db.take(500) |> Db.collect!(ctx.db)?
        evals =
            all_flags
            |> List.map(|f| Flags.evaluate(flag_doc_to_rule(f), canonical_id, effective_props))
        Ok(evals)
    }

    ## Real-time overview KPIs (admin-gated when `req_auth` is True, bounded scan).
    summary! : Bool, List(Str), Ctx.QueryCtx, SummaryArgs => Try(Insights.SummaryResult, Str)
    summary! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        now_ms! = ctx.now_ms!
        is_live = args.to_ms <= 0
        to_ms = if is_live { now_ms!() } else { args.to_ms }
        from_ms = if is_live and args.from_ms <= 0 { to_ms - 86400000 } else { args.from_ms }
        top_n = if args.top_n <= 0 { 10 } else if args.top_n > 100 { 100 } else { args.top_n }

        docs =
            if is_live or to_ms == Insights.max_i64 {
                Db.from_index(events_by_timestamp)
                |> Db.gte([Key.int(from_ms)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            } else {
                Db.from_index(events_by_timestamp)
                |> Db.gte([Key.int(from_ms)])
                |> Db.lt([Key.int(to_ms + 1)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            }

        aliases = load_aliases!(ctx.db)?
        records = docs |> List.map(event_doc_to_record)
        Ok(Insights.compute_summary(records, aliases, top_n))
    }

    ## Real-time time-bucketed event Trends (admin-gated when `req_auth` is True, bounded scan).
    trends! : Bool, List(Str), Ctx.QueryCtx, TrendsArgs => Try(Insights.TrendResult, Str)
    trends! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        event_name = Str.trim(args.event)
        if Str.is_empty(event_name) {
            return Err("Trend event name cannot be empty")
        }
        now_ms! = ctx.now_ms!
        is_live = args.to_ms <= 0
        to_ms = if is_live { now_ms!() } else { args.to_ms }
        from_ms = if is_live and args.from_ms <= 0 { to_ms - 86400000 } else { args.from_ms }

        docs =
            if is_live or to_ms == Insights.max_i64 {
                Db.from_index(events_by_event_time)
                |> Db.eq([Key.str(event_name)])
                |> Db.gte([Key.str(event_name), Key.int(from_ms)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            } else {
                Db.from_index(events_by_event_time)
                |> Db.gte([Key.str(event_name), Key.int(from_ms)])
                |> Db.lt([Key.str(event_name), Key.int(to_ms + 1)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            }

        aliases = load_aliases!(ctx.db)?
        records = docs |> List.map(event_doc_to_record)
        Ok(
            Insights.compute_trends(
                event_name,
                records,
                aliases,
                from_ms,
                to_ms,
                args.bucket_ms,
                Str.trim(args.breakdown_property),
                args.filters,
            ),
        )
    }

    ## Real-time multi-step Conversion Funnel (admin-gated when `req_auth` is True, bounded scan).
    funnel! : Bool, List(Str), Ctx.QueryCtx, FunnelArgs => Try(Insights.FunnelResult, Str)
    funnel! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        now_ms! = ctx.now_ms!
        is_live = args.to_ms <= 0
        to_ms = if is_live { now_ms!() } else { args.to_ms }
        from_ms = if is_live and args.from_ms <= 0 { to_ms - 86400000 } else { args.from_ms }
        window_ms = if args.conversion_window_ms <= 0 { 86400000 } else { args.conversion_window_ms }
        scan_end = Insights.safe_add_i64(to_ms, window_ms)

        docs =
            if is_live or scan_end == Insights.max_i64 {
                Db.from_index(events_by_timestamp)
                |> Db.gte([Key.int(from_ms)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            } else {
                Db.from_index(events_by_timestamp)
                |> Db.gte([Key.int(from_ms)])
                |> Db.lt([Key.int(scan_end + 1)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            }

        aliases = load_aliases!(ctx.db)?
        records = docs |> List.map(event_doc_to_record)
        Ok(Insights.compute_funnel(args.steps, records, aliases, from_ms, to_ms, window_ms, args.filters))
    }

    ## Real-time Cohort Retention table (admin-gated when `req_auth` is True, bounded scan).
    retention! : Bool, List(Str), Ctx.QueryCtx, RetentionArgs => Try(Insights.RetentionResult, Str)
    retention! = |req_auth, admin_roles, ctx, args| {
        _ = require_admin_if_needed!(req_auth, admin_roles, ctx.auth!)?
        cohort_ev = Str.trim(args.cohort_event)
        return_ev = if Str.is_empty(Str.trim(args.return_event)) { cohort_ev } else { Str.trim(args.return_event) }
        if Str.is_empty(cohort_ev) {
            return Err("cohort_event cannot be empty")
        }

        period_ms = if args.period_ms <= 0 { 86400000 } else { args.period_ms }
        num_periods =
            if args.num_periods <= 0 {
                7
            } else if args.num_periods > 60 {
                60
            } else {
                args.num_periods
            }

        now_ms! = ctx.now_ms!
        is_live = args.from_ms < 0
        span_ms = Insights.safe_mul_nonneg_i64(num_periods, period_ms)
        from_ms = if is_live { now_ms!() - span_ms } else { args.from_ms }
        end_ms = Insights.safe_add_i64(from_ms, span_ms)

        docs =
            if is_live or end_ms == Insights.max_i64 {
                Db.from_index(events_by_timestamp)
                |> Db.gte([Key.int(from_ms)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            } else {
                Db.from_index(events_by_timestamp)
                |> Db.gte([Key.int(from_ms)])
                |> Db.lt([Key.int(end_ms)])
                |> Db.asc()
                |> Db.take(2000)
                |> Db.collect!(ctx.db)?
            }

        aliases = load_aliases!(ctx.db)?
        records = docs |> List.map(event_doc_to_record)
        Ok(Insights.compute_retention(cohort_ev, return_ev, records, aliases, from_ms, period_ms, num_periods))
    }

    # -------------------------------------------------------------------------
    # Server-Side In-Transaction / Direct Component Helpers
    # -------------------------------------------------------------------------

    ## Record an analytics event inside a parent app mutation's EXACT SAME ACID transaction.
    track! : Mount, Ctx.MutationCtx, CaptureArgs => Try(Str, Str)
    track! = |m, parent_ctx, args| {
        scoped = Ctx.scope_mutation(parent_ctx, m.namespace)
        capture!([], scoped, args)
    }

    ## Ergonomic one-liner to track an event inside a parent mutation's ACID transaction
    ## using server timestamp and no session/group fields.
    track_event! : Mount, Ctx.MutationCtx, Str, Str, List(Props.Prop) => Try(Str, Str)
    track_event! = |m, parent_ctx, distinct_id, event, properties|
        track!(m, parent_ctx, {
            distinct_id,
            event,
            properties,
            session_id: "",
            group_type: "",
            group_key: "",
            timestamp_ms: 0,
        })

    ## Identify a user inside a parent app mutation's ACID transaction (trusted server-side caller).
    identify_in_tx! : Mount, Ctx.MutationCtx, IdentifyArgs => Try(PersonProfile, Str)
    identify_in_tx! = |m, parent_ctx, args| {
        scoped = Ctx.scope_mutation(parent_ctx, m.namespace)
        identify!(False, [], scoped, args)
    }

    ## Evaluate a feature flag from inside a parent app query (trusted server-side caller).
    evaluate_flag_in_query! : Mount, Ctx.QueryCtx, EvaluateFlagArgs => Try(Flags.Evaluation, Str)
    evaluate_flag_in_query! = |m, parent_ctx, args| {
        scoped = Ctx.scope_query(parent_ctx, m.namespace)
        evaluate_flag!([], scoped, args)
    }

    ## Convenience boolean check for a feature flag from inside backend queries/mutations.
    is_flag_enabled! : Mount, Ctx.QueryCtx, Str, Str => Try(Bool, Str)
    is_flag_enabled! = |m, parent_ctx, flag_key, distinct_id| {
        eval = evaluate_flag_in_query!(m, parent_ctx, {
            key: flag_key,
            distinct_id,
            override_properties: [],
        })?
        Ok(eval.enabled)
    }

    ## Create or update a feature flag from inside a parent app mutation (e.g., seeding defaults).
    upsert_flag_in_tx! : Mount, Ctx.MutationCtx, UpsertFlagArgs => Try(Str, Str)
    upsert_flag_in_tx! = |m, parent_ctx, args| {
        scoped = Ctx.scope_mutation(parent_ctx, m.namespace)
        upsert_flag!(False, [], scoped, args)
    }

    ## List all feature flags from inside a parent app query or mutation (trusted server-side caller).
    list_flags_in_query! : Mount, Ctx.QueryCtx => Try(List(FeatureFlagDoc), Str)
    list_flags_in_query! = |m, parent_ctx| {
        scoped = Ctx.scope_query(parent_ctx, m.namespace)
        list_flags!(False, [], scoped, {})
    }

    # -------------------------------------------------------------------------
    # App Attachment
    # -------------------------------------------------------------------------

    ## Attach the mounted Analytics component's isolated tables, mutations, and reactive queries to `App`.
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        req_auth = m.require_auth_for_admin
        admin_roles = m.admin_roles
        max_batch = m.max_batch_size

        event_doc_schema = Table.doc_schema_scoped(events_table, ns)
        person_doc_schema = Table.doc_schema_scoped(persons_table, ns)
        flag_doc_schema = Table.doc_schema_scoped(flags_table, ns)

        spec
        |> App.component(m.spec)
        # Mutations
        |> App.component_mutation(
            ns,
            "${ns}.capture",
            capture_args_schema,
            Schema.scoped_id(ns, "events"),
            |ctx, args| capture!(admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.captureBatch",
            capture_batch_args_schema,
            capture_batch_result_schema,
            |ctx, args| capture_batch!(admin_roles, max_batch, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.identify",
            identify_args_schema,
            person_profile_schema,
            |ctx, args| identify!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.alias",
            alias_args_schema,
            Schema.bool,
            |ctx, args| alias!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.upsertFlag",
            upsert_flag_args_schema,
            Schema.scoped_id(ns, "feature_flags"),
            |ctx, args| upsert_flag!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.deleteFlag",
            delete_flag_args_schema,
            Schema.bool,
            |ctx, args| delete_flag!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.evaluateFlagAndTrack",
            evaluate_flag_and_track_args_schema,
            flag_eval_schema,
            |ctx, args| evaluate_flag_and_track!(admin_roles, ctx, args),
        )
        # Reactive Queries
        |> App.component_query(
            ns,
            "${ns}.recentEvents",
            recent_events_args_schema,
            Schema.list(event_doc_schema),
            |ctx, args| recent_events!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.personEvents",
            person_events_args_schema,
            Schema.list(event_doc_schema),
            |ctx, args| person_events!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.sessionEvents",
            session_events_args_schema,
            Schema.list(event_doc_schema),
            |ctx, args| session_events!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.groupEvents",
            group_events_args_schema,
            Schema.list(event_doc_schema),
            |ctx, args| group_events!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.getPerson",
            get_person_args_schema,
            person_profile_schema,
            |ctx, args| get_person!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.listPersons",
            list_persons_args_schema,
            Schema.list(person_doc_schema),
            |ctx, args| list_persons!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.listFlags",
            Schema.record([]),
            Schema.list(flag_doc_schema),
            |ctx, args| list_flags!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.evaluateFlag",
            evaluate_flag_args_schema,
            flag_eval_schema,
            |ctx, args| evaluate_flag!(admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.evaluateAllFlags",
            evaluate_all_flags_args_schema,
            Schema.list(flag_eval_schema),
            |ctx, args| evaluate_all_flags!(admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.summary",
            summary_args_schema,
            summary_result_schema,
            |ctx, args| summary!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.trends",
            trends_args_schema,
            trends_result_schema,
            |ctx, args| trends!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.funnel",
            funnel_args_schema,
            funnel_result_schema,
            |ctx, args| funnel!(req_auth, admin_roles, ctx, args),
        )
        |> App.component_query(
            ns,
            "${ns}.retention",
            retention_args_schema,
            retention_result_schema,
            |ctx, args| retention!(req_auth, admin_roles, ctx, args),
        )
    }
}

expect {
    m = Analytics.mount("analytics")
    m.namespace == "analytics"
    and m.spec.pkg_name == "concave-analytics"
    and List.len(m.spec.tables) == 4
}

expect {
    m = Analytics.mount_with("product_analytics", { require_auth_for_admin: True, max_batch_size: 25 })
    spec = App.new("test") |> Analytics.attach(m)
    m.namespace == "product_analytics"
    and m.require_auth_for_admin
    and m.max_batch_size == 25
    and List.len(spec.components) == 1
    and List.len(spec.mutations) == 7
    and List.len(spec.queries) == 13
}
