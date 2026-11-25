import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table

## Reusable pure-Roc Durable Signed Outbound Webhooks Component for Concave.
##
## Features:
## - Isolated component namespace (default `"webhooks"`) with `webhooks_endpoints` & `webhooks_deliveries`
## - Transactional `Webhooks.dispatch!` queries active subscribed endpoints, inserts delivery rows,
##   and schedules `${ns}._deliver` atomically inside the caller's ACID mutation
## - HMAC-SHA256 payload signing (`X-Concave-Signature: t=<ts>,v1=<hex_sig>`) over `"<ts>.<payload_json>"`
## - Exponential backoff retry on 5xx, 429, and network errors (capped at 60s); dead-letter on 4xx/exhaustion
## - Endpoint `consecutive_failures` tracking (incremented on failure, reset to 0 on delivery)
## - Constant-time inbound webhook verification (`Webhooks.verify_signature!`) with replay tolerance
## - Endpoint & delivery management API (`registerEndpoint`, `listEndpoints`, `listDeliveries`, `retryDelivery`)

Webhooks := [Webhooks].{
    # -------------------------------------------------------------------------
    # Configuration, Document & Wire Types
    # -------------------------------------------------------------------------

    Mount : {
        namespace : Str,
        signing_secret_name : Str,
        extra_secrets : List(Str),
        max_attempts : I64,
        base_backoff_ms : I64,
        spec : Component.ComponentSpec,
    }

    WebhookEndpointDoc : {
        id : Str,
        created_at : I64,
        name : Str,
        url : Str,
        events : List(Str),
        active : Bool,
        secret_name : Str,
        consecutive_failures : I64,
    }

    NewWebhookEndpoint : {
        name : Str,
        url : Str,
        events : List(Str),
        active : Bool,
        secret_name : Str,
        consecutive_failures : I64,
    }

    WebhookDeliveryDoc : {
        id : Str,
        created_at : I64,
        endpoint_id : Str,
        event_type : Str,
        payload_json : Str,
        status : Str,
        attempts : I64,
        last_status : I64,
        last_error : Str,
        delivered_at_ms : I64,
    }

    NewWebhookDelivery : {
        endpoint_id : Str,
        event_type : Str,
        payload_json : Str,
        status : Str,
        attempts : I64,
        last_status : I64,
        last_error : Str,
        delivered_at_ms : I64,
    }

    ParsedSignatureHeader : {
        timestamp : I64,
        v1_sigs : List(Str),
    }

    EmptyArgs : {}

    RegisterEndpointArgs : {
        name : Str,
        url : Str,
        events : List(Str),
        secret_name : Str,
    }

    ListDeliveriesArgs : {
        status : Str,
        endpoint_id : Str,
    }

    DeliveryIdArgs : {
        delivery_id : Str,
    }

    DeliverResult : {
        delivery_id : Str,
        status : Str,
        attempts : I64,
        last_status : I64,
        last_error : Str,
    }

    ClaimResult : {
        claimed : Bool,
        delivery_id : Str,
        endpoint_id : Str,
        endpoint_url : Str,
        secret_name : Str,
        event_type : Str,
        payload_json : Str,
        attempts : I64,
    }

    CompleteArgs : {
        delivery_id : Str,
        endpoint_id : Str,
        http_status : I64,
        delivered_at_ms : I64,
    }

    FailArgs : {
        delivery_id : Str,
        endpoint_id : Str,
        http_status : I64,
        error_msg : Str,
        retryable : Bool,
        delay_ms : I64,
    }

    # -------------------------------------------------------------------------
    # Isolated Component Tables & Indexes
    # -------------------------------------------------------------------------

    endpoints_schema : Schema
    endpoints_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("url", Schema.str),
        Schema.field("events", Schema.list(Schema.str)),
        Schema.field("active", Schema.bool),
        Schema.field("secret_name", Schema.str),
        Schema.field("consecutive_failures", Schema.int),
    ])

    endpoints_table : Table(WebhookEndpointDoc)
    endpoints_table =
        Table.define("webhooks_endpoints", endpoints_schema)
        |> Table.with_index("by_name", ["name"])

    deliveries_schema : Schema
    deliveries_schema = Schema.record([
        Schema.field("endpoint_id", Schema.str),
        Schema.field("event_type", Schema.str),
        Schema.field("payload_json", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("attempts", Schema.int),
        Schema.field("last_status", Schema.int),
        Schema.field("last_error", Schema.str),
        Schema.field("delivered_at_ms", Schema.int),
    ])

    deliveries_table : Table(WebhookDeliveryDoc)
    deliveries_table =
        Table.define("webhooks_deliveries", deliveries_schema)
        |> Table.with_index("by_status", ["status"])
        |> Table.with_index("by_endpoint", ["endpoint_id"])

    deliveries_by_status : Table.Index(WebhookDeliveryDoc)
    deliveries_by_status = Table.index_ref(deliveries_table, "by_status")

    deliveries_by_endpoint : Table.Index(WebhookDeliveryDoc)
    deliveries_by_endpoint = Table.index_ref(deliveries_table, "by_endpoint")

    # -------------------------------------------------------------------------
    # Endpoint Wire Schemas
    # -------------------------------------------------------------------------

    register_endpoint_args_schema : Schema
    register_endpoint_args_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("url", Schema.str),
        Schema.field("events", Schema.list(Schema.str)),
        Schema.field("secret_name", Schema.str),
    ])

    list_deliveries_args_schema : Schema
    list_deliveries_args_schema = Schema.record([
        Schema.field("status", Schema.str),
        Schema.field("endpoint_id", Schema.str),
    ])

    delivery_id_args_schema : Schema
    delivery_id_args_schema = Schema.record([
        Schema.field("delivery_id", Schema.str),
    ])

    deliver_result_schema : Schema
    deliver_result_schema = Schema.record([
        Schema.field("delivery_id", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("attempts", Schema.int),
        Schema.field("last_status", Schema.int),
        Schema.field("last_error", Schema.str),
    ])

    claim_result_schema : Schema
    claim_result_schema = Schema.record([
        Schema.field("claimed", Schema.bool),
        Schema.field("delivery_id", Schema.str),
        Schema.field("endpoint_id", Schema.str),
        Schema.field("endpoint_url", Schema.str),
        Schema.field("secret_name", Schema.str),
        Schema.field("event_type", Schema.str),
        Schema.field("payload_json", Schema.str),
        Schema.field("attempts", Schema.int),
    ])

    complete_args_schema : Schema
    complete_args_schema = Schema.record([
        Schema.field("delivery_id", Schema.str),
        Schema.field("endpoint_id", Schema.str),
        Schema.field("http_status", Schema.int),
        Schema.field("delivered_at_ms", Schema.int),
    ])

    fail_args_schema : Schema
    fail_args_schema = Schema.record([
        Schema.field("delivery_id", Schema.str),
        Schema.field("endpoint_id", Schema.str),
        Schema.field("http_status", Schema.int),
        Schema.field("error_msg", Schema.str),
        Schema.field("retryable", Schema.bool),
        Schema.field("delay_ms", Schema.int),
    ])

    # -------------------------------------------------------------------------
    # Pure Helpers (Signing Format/Parse, Event Matching, Backoff, Status)
    # -------------------------------------------------------------------------

    max_backoff_ms : I64
    max_backoff_ms = 60000

    ## Compute exponential backoff in milliseconds (`base_ms * 2^(attempt - 1)`), capped at 60s.
    compute_backoff_ms : I64, I64 -> I64
    compute_backoff_ms = |base_ms, attempt| {
        eff_base = if base_ms < 10 { 10 } else if base_ms > max_backoff_ms { max_backoff_ms } else { base_ms }
        shifts = if attempt <= 1 { 0 } else if attempt > 16 { 15 } else { attempt - 1 }
        var $delay = eff_base
        var $i = 0.I64
        while $i < shifts {
            if $delay >= max_backoff_ms // 2 {
                $delay = max_backoff_ms
                $i = shifts
            } else {
                $delay = $delay * 2
                $i = $i + 1
            }
        }
        if $delay > max_backoff_ms { max_backoff_ms } else { $delay }
    }

    ## Classify an HTTP status code as retryable (`429` or `5xx`) vs permanent (`4xx` other than `429`).
    is_retryable_status : U64 -> Bool
    is_retryable_status = |status|
        if status >= 200 and status < 300 {
            False
        } else if status == 429 or status >= 500 {
            True
        } else if status >= 400 and status < 500 {
            False
        } else {
            True
        }

    u64_status_to_i64 : U64 -> I64
    u64_status_to_i64 = |status| {
        clamped = if status > 999 { 999 } else { status }
        var $out = 0.I64
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

    ## Build the canonical HMAC-SHA256 signing input `"<ts>.<payload_json>"`.
    build_signing_payload : I64, Str -> Str
    build_signing_payload = |ts_secs, payload_json|
        "${ts_secs.to_str()}.${payload_json}"

    ## Format the `X-Concave-Signature` header (`"t=<ts>,v1=<hex_sig>"`).
    format_signature_header : I64, Str -> Str
    format_signature_header = |ts_secs, hex_sig|
        "t=${ts_secs.to_str()},v1=${hex_sig}"

    ## Parse a non-negative base-10 ASCII integer strictly into `I64`.
    parse_nonneg_i64 : Str -> Try(I64, Str)
    parse_nonneg_i64 = |raw| {
        trimmed = Str.trim(raw)
        bytes = Str.to_utf8(trimmed)
        if List.is_empty(bytes) {
            return Err("empty integer")
        }
        if List.len(bytes) > 18 {
            return Err("integer out of range")
        }
        var $acc = 0.I64
        for b in bytes {
            if b < 48 or b > 57 {
                return Err("invalid digit in timestamp")
            }
            digit : I64
            digit = match b {
                48 => 0
                49 => 1
                50 => 2
                51 => 3
                52 => 4
                53 => 5
                54 => 6
                55 => 7
                56 => 8
                _ => 9
            }
            $acc = ($acc * 10) + digit
        }
        Ok($acc)
    }

    ## Parse `X-Concave-Signature` header of the form `t=<unix_secs>,v1=<hex_sig>[,v1=<hex_sig2>]`.
    parse_signature_header : Str -> Try(ParsedSignatureHeader, Str)
    parse_signature_header = |raw| {
        trimmed = Str.trim(raw)
        if Str.is_empty(trimmed) {
            return Err("missing signature header")
        }
        parts = Str.split_on(trimmed, ",")
        var $has_ts = False
        var $ts = 0.I64
        var $v1s = []
        for part in parts {
            item = Str.trim(part)
            if Str.starts_with(item, "t=") {
                ts_raw = Str.drop_prefix(item, "t=")
                parsed_ts = parse_nonneg_i64(ts_raw)?
                $ts = parsed_ts
                $has_ts = True
            } else if Str.starts_with(item, "v1=") {
                sig_val = Str.trim(Str.drop_prefix(item, "v1="))
                if !Str.is_empty(sig_val) {
                    $v1s = List.append($v1s, sig_val)
                }
            }
        }
        if !$has_ts {
            return Err("signature header missing timestamp `t=`")
        }
        if List.is_empty($v1s) {
            return Err("signature header missing `v1=` signature")
        }
        Ok({
            timestamp: $ts,
            v1_sigs: $v1s,
        })
    }

    ## Check whether an endpoint's subscribed event list matches `event_type`.
    ## Empty list or `"*"` matches all events; prefix wildcards like `"order.*"` match `"order.created"`.
    matches_event : List(Str), Str -> Bool
    matches_event = |subscribed, event_type| {
        if List.is_empty(subscribed) {
            return True
        }
        target = Str.trim(event_type)
        List.any(
            subscribed,
            |pattern| {
                p = Str.trim(pattern)
                if p == "*" or p == target {
                    True
                } else if Str.ends_with(p, ".*") {
                    prefix = Str.drop_suffix(p, "*")
                    Str.starts_with(target, prefix)
                } else {
                    False
                }
            },
        )
    }

    truncate_error : Str -> Str
    truncate_error = |raw| {
        trimmed = Str.trim(raw)
        bytes = Str.to_utf8(trimmed)
        if List.len(bytes) <= 256 {
            trimmed
        } else {
            match Str.from_utf8(List.take_first(bytes, 256)) {
                Ok(s) => s
                Err(_) => "webhook delivery error"
            }
        }
    }

    build_spec : Str, Str, List(Str) -> Component.ComponentSpec
    build_spec = |ns, signing_secret_name, extra_secrets| {
        base = Component.define(
            ns,
            "concave-webhooks",
            [
                Table.spec(endpoints_table),
                Table.spec(deliveries_table),
            ],
        )
        var $secrets = []
        trimmed_sig = Str.trim(signing_secret_name)
        if !Str.is_empty(trimmed_sig) {
            $secrets = List.append($secrets, trimmed_sig)
        }
        for s in extra_secrets {
            ts = Str.trim(s)
            if !Str.is_empty(ts) and !List.any($secrets, |existing| existing == ts) {
                $secrets = List.append($secrets, ts)
            }
        }
        if List.is_empty($secrets) {
            base
        } else {
            Component.with_secrets(base, $secrets)
        }
    }

    # -------------------------------------------------------------------------
    # Component Mount & Builder API
    # -------------------------------------------------------------------------

    ## Mount an isolated Webhooks component under `namespace` (defaults to `"webhooks"`).
    mount : Str -> Mount
    mount = |raw_namespace| {
        trimmed = Str.trim(raw_namespace)
        ns = if Str.is_empty(trimmed) { "webhooks" } else { trimmed }
        default_secret = "WEBHOOK_SIGNING_SECRET"
        {
            namespace: ns,
            signing_secret_name: default_secret,
            extra_secrets: [],
            max_attempts: 5,
            base_backoff_ms: 1000,
            spec: build_spec(ns, default_secret, []),
        }
    }

    ## Configure maximum delivery attempts before dead-lettering (default `5`, minimum `1`).
    with_max_attempts : Mount, I64 -> Mount
    with_max_attempts = |m, n| {
        namespace: m.namespace,
        signing_secret_name: m.signing_secret_name,
        extra_secrets: m.extra_secrets,
        max_attempts: if n < 1 { 1 } else { n },
        base_backoff_ms: m.base_backoff_ms,
        spec: m.spec,
    }

    ## Configure the base exponential backoff delay in milliseconds (default `1000`, capped at 60s).
    with_base_backoff_ms : Mount, I64 -> Mount
    with_base_backoff_ms = |m, ms| {
        clamped = if ms < 10 { 10 } else if ms > max_backoff_ms { max_backoff_ms } else { ms }
        {
            namespace: m.namespace,
            signing_secret_name: m.signing_secret_name,
            extra_secrets: m.extra_secrets,
            max_attempts: m.max_attempts,
            base_backoff_ms: clamped,
            spec: m.spec,
        }
    }

    ## Configure the component's default signing secret name (added to `Component.with_secrets`).
    with_signing_secret : Mount, Str -> Mount
    with_signing_secret = |m, raw_secret| {
        trimmed = Str.trim(raw_secret)
        secret_name = if Str.is_empty(trimmed) { "WEBHOOK_SIGNING_SECRET" } else { trimmed }
        {
            namespace: m.namespace,
            signing_secret_name: secret_name,
            extra_secrets: m.extra_secrets,
            max_attempts: m.max_attempts,
            base_backoff_ms: m.base_backoff_ms,
            spec: build_spec(m.namespace, secret_name, m.extra_secrets),
        }
    }

    ## Allowlist additional per-endpoint signing secret names on the component manifest.
    with_extra_secrets : Mount, List(Str) -> Mount
    with_extra_secrets = |m, secrets| {
        next_extra = List.concat(m.extra_secrets, secrets)
        {
            namespace: m.namespace,
            signing_secret_name: m.signing_secret_name,
            extra_secrets: next_extra,
            max_attempts: m.max_attempts,
            base_backoff_ms: m.base_backoff_ms,
            spec: build_spec(m.namespace, m.signing_secret_name, next_extra),
        }
    }

    # -------------------------------------------------------------------------
    # Transactional Outbound Dispatch Helper (App Mutations)
    # -------------------------------------------------------------------------

    ## Transactionally dispatch a webhook event to all matching active endpoints inside the caller's
    ## ACID mutation. Inserts one `webhooks_deliveries` row per matching endpoint and schedules
    ## `${ns}._deliver` atomically in the same transaction. Returns the list of created delivery IDs.
    dispatch! : Mount, Ctx.MutationCtx, Str, Str => Try(List(Str), Str)
    dispatch! = |m, ctx, raw_event_type, payload_json| {
        event_type = Str.trim(raw_event_type)
        if Str.is_empty(event_type) {
            return Err("webhook `event_type` cannot be empty")
        }

        scoped = Ctx.scope_mutation(ctx, m.namespace)
        endpoints =
            Db.query(endpoints_table)
            |> Db.asc()
            |> Db.collect!(Ctx.as_reader(scoped.db))?

        var $delivery_ids = []
        for ep in endpoints {
            if ep.active and matches_event(ep.events, event_type) {
                new_del : NewWebhookDelivery
                new_del = {
                    endpoint_id: ep.id,
                    event_type,
                    payload_json,
                    status: "queued",
                    attempts: 0,
                    last_status: 0,
                    last_error: "",
                    delivered_at_ms: 0,
                }
                delivery_id = Db.insert!(scoped.db, deliveries_table, new_del)?
                deliver_args : DeliveryIdArgs
                deliver_args = { delivery_id: delivery_id }
                _ = Ctx.run_after!(scoped, 0, "${m.namespace}._deliver", deliver_args)?
                $delivery_ids = List.append($delivery_ids, delivery_id)
            }
        }
        Ok($delivery_ids)
    }

    # -------------------------------------------------------------------------
    # Inbound Webhook Signature Verification Helper (Actions & HTTP Routes)
    # -------------------------------------------------------------------------

    ## Verify an inbound `X-Concave-Signature` header (`t=<ts>,v1=<hex>`) against `payload`
    ## using host HMAC-SHA256, constant-time equality (`ct_eq!`), and a replay tolerance window in seconds.
    verify_signature! : Ctx.ActionCtx, Str, Str, Str, I64 => Try({}, Str)
    verify_signature! = |ctx, secret, sig_header, payload, tolerance_secs| {
        if Str.is_empty(secret) {
            return Err("webhook verification secret cannot be empty")
        }
        parsed = parse_signature_header(sig_header)?

        if tolerance_secs > 0 {
            now_secs = Ctx.now_ms!(ctx) // 1000
            age =
                if now_secs >= parsed.timestamp {
                    now_secs - parsed.timestamp
                } else {
                    parsed.timestamp - now_secs
                }
            if age > tolerance_secs {
                return Err("webhook signature timestamp outside tolerance window")
            }
        }

        signing_payload = build_signing_payload(parsed.timestamp, payload)
        hmac_sha256! = ctx.crypto.hmac_sha256!
        expected_sig = hmac_sha256!(secret, signing_payload)?

        ct_eq! = ctx.crypto.ct_eq!
        for candidate in parsed.v1_sigs {
            matched = ct_eq!(expected_sig, candidate)?
            if matched {
                return Ok({})
            }
        }

        Err("invalid webhook signature")
    }

    # -------------------------------------------------------------------------
    # Internal Delivery State-Machine Endpoints
    # -------------------------------------------------------------------------

    claim_inner! : Str, Ctx.MutationCtx, DeliveryIdArgs => Try(ClaimResult, Str)
    claim_inner! = |default_secret_name, ctx, args| {
        existing_del = Db.get!(Ctx.as_reader(ctx.db), deliveries_table, args.delivery_id)?
        del = match existing_del {
            Found(d) => d
            NotFound =>
                return Ok({
                    claimed: False,
                    delivery_id: args.delivery_id,
                    endpoint_id: "",
                    endpoint_url: "",
                    secret_name: "",
                    event_type: "",
                    payload_json: "",
                    attempts: 0,
                })
        }

        if del.status != "queued" {
            return Ok({
                claimed: False,
                delivery_id: del.id,
                endpoint_id: del.endpoint_id,
                endpoint_url: "",
                secret_name: "",
                event_type: del.event_type,
                payload_json: del.payload_json,
                attempts: del.attempts,
            })
        }

        existing_ep = Db.get!(Ctx.as_reader(ctx.db), endpoints_table, del.endpoint_id)?
        ep = match existing_ep {
            Found(e) => e
            NotFound => {
                dead_patch : { status : Str, last_error : Str }
                dead_patch = {
                    status: "dead",
                    last_error: "webhook endpoint not found",
                }
                Db.patch!(ctx.db, deliveries_table, del.id, dead_patch)?
                return Ok({
                    claimed: False,
                    delivery_id: del.id,
                    endpoint_id: del.endpoint_id,
                    endpoint_url: "",
                    secret_name: "",
                    event_type: del.event_type,
                    payload_json: del.payload_json,
                    attempts: del.attempts,
                })
            }
        }

        if !ep.active {
            return Ok({
                claimed: False,
                delivery_id: del.id,
                endpoint_id: ep.id,
                endpoint_url: ep.url,
                secret_name: "",
                event_type: del.event_type,
                payload_json: del.payload_json,
                attempts: del.attempts,
            })
        }

        next_attempts : I64
        next_attempts = del.attempts + 1
        claim_patch : { status : Str, attempts : I64 }
        claim_patch = {
            status: "delivering",
            attempts: next_attempts,
        }
        Db.patch!(ctx.db, deliveries_table, del.id, claim_patch)?

        ep_secret = Str.trim(ep.secret_name)
        eff_secret = if Str.is_empty(ep_secret) { default_secret_name } else { ep_secret }

        Ok({
            claimed: True,
            delivery_id: del.id,
            endpoint_id: ep.id,
            endpoint_url: ep.url,
            secret_name: eff_secret,
            event_type: del.event_type,
            payload_json: del.payload_json,
            attempts: next_attempts,
        })
    }

    complete_inner! : Ctx.MutationCtx, CompleteArgs => Try(Bool, Str)
    complete_inner! = |ctx, args| {
        del_patch : { status : Str, last_status : I64, last_error : Str, delivered_at_ms : I64 }
        del_patch = {
            status: "delivered",
            last_status: args.http_status,
            last_error: "",
            delivered_at_ms: args.delivered_at_ms,
        }
        Db.patch!(ctx.db, deliveries_table, args.delivery_id, del_patch)?

        existing_ep = Db.get!(Ctx.as_reader(ctx.db), endpoints_table, args.endpoint_id)?
        match existing_ep {
            Found(ep) =>
                if ep.consecutive_failures != 0 {
                    ep_patch : { consecutive_failures : I64 }
                    ep_patch = { consecutive_failures: 0 }
                    Db.patch!(ctx.db, endpoints_table, ep.id, ep_patch)?
                }
            NotFound => {}
        }

        Ok(True)
    }

    fail_inner! : Str, I64, Ctx.MutationCtx, FailArgs => Try(Str, Str)
    fail_inner! = |ns, max_attempts, ctx, args| {
        existing_del = Db.get!(Ctx.as_reader(ctx.db), deliveries_table, args.delivery_id)?
        del = match existing_del {
            Found(d) => d
            NotFound => return Ok("dead")
        }

        existing_ep = Db.get!(Ctx.as_reader(ctx.db), endpoints_table, args.endpoint_id)?
        match existing_ep {
            Found(ep) => {
                next_failures : I64
                next_failures = ep.consecutive_failures + 1
                ep_patch : { consecutive_failures : I64 }
                ep_patch = { consecutive_failures: next_failures }
                Db.patch!(ctx.db, endpoints_table, ep.id, ep_patch)?
            }
            NotFound => {}
        }

        if args.retryable and del.attempts < max_attempts {
            retry_patch : { status : Str, last_status : I64, last_error : Str }
            retry_patch = {
                status: "queued",
                last_status: args.http_status,
                last_error: args.error_msg,
            }
            Db.patch!(ctx.db, deliveries_table, del.id, retry_patch)?
            deliver_args : DeliveryIdArgs
            deliver_args = { delivery_id: del.id }
            _ = Ctx.run_after!(ctx, args.delay_ms, "${ns}._deliver", deliver_args)?
            Ok("queued")
        } else {
            dead_patch : { status : Str, last_status : I64, last_error : Str }
            dead_patch = {
                status: "dead",
                last_status: args.http_status,
                last_error: args.error_msg,
            }
            Db.patch!(ctx.db, deliveries_table, del.id, dead_patch)?
            Ok("dead")
        }
    }

    record_failure! : Str, Ctx.ActionCtx, Str, Str, I64, Str, Bool, I64 => Try(Str, Str)
    record_failure! = |ns, ctx, delivery_id, endpoint_id, http_status, error_msg, retryable, delay_ms| {
        fail_args : FailArgs
        fail_args = {
            delivery_id,
            endpoint_id,
            http_status,
            error_msg,
            retryable,
            delay_ms,
        }
        raw = Ctx.run_mutation!(ctx, "${ns}._fail", fail_args)?
        match Json.parse(raw) {
            Ok(status_str) => Ok(status_str)
            Err(_) => Ok("dead")
        }
    }

    deliver_inner! : Mount, Ctx.ActionCtx, DeliveryIdArgs => Try(DeliverResult, Str)
    deliver_inner! = |m, ctx, args| {
        ns = m.namespace
        claim_args : DeliveryIdArgs
        claim_args = { delivery_id: args.delivery_id }
        claim_raw = Ctx.run_mutation!(ctx, "${ns}._claim", claim_args)?
        claimed : ClaimResult
        claimed = match Json.parse(claim_raw) {
            Ok(c) => c
            Err(InvalidJson(msg)) => return Err("failed to decode claim result: ${msg}")
        }

        if !claimed.claimed {
            return Ok({
                delivery_id: args.delivery_id,
                status: "skipped",
                attempts: claimed.attempts,
                last_status: 0,
                last_error: "",
            })
        }

        secret = match Ctx.secret_get!(ctx, claimed.secret_name) {
            Ok(s) => s
            Err(sec_err) => {
                err_msg = "signing secret `${claimed.secret_name}` unavailable: ${sec_err}"
                next_status = record_failure!(ns, ctx, claimed.delivery_id, claimed.endpoint_id, 0, err_msg, Bool.False, 0)?
                return Ok({
                    delivery_id: claimed.delivery_id,
                    status: next_status,
                    attempts: claimed.attempts,
                    last_status: 0,
                    last_error: err_msg,
                })
            }
        }

        now = Ctx.now_ms!(ctx)
        ts_secs = now // 1000
        signing_payload = build_signing_payload(ts_secs, claimed.payload_json)
        hmac_sha256! = ctx.crypto.hmac_sha256!
        hex_sig = hmac_sha256!(secret, signing_payload)?
        sig_header = format_signature_header(ts_secs, hex_sig)

        req : Ctx.HttpRequestEx
        req = {
            method: "POST",
            url: claimed.endpoint_url,
            headers: [
                { name: "Content-Type", value: "application/json" },
                { name: "X-Concave-Delivery-Id", value: claimed.delivery_id },
                { name: "X-Concave-Event", value: claimed.event_type },
                { name: "X-Concave-Signature", value: sig_header },
            ],
            body: claimed.payload_json,
        }

        match Ctx.http_request!(ctx, req) {
            Ok(resp) => {
                status_i64 = u64_status_to_i64(resp.status)
                if resp.status >= 200 and resp.status < 300 {
                    complete_args : CompleteArgs
                    complete_args = {
                        delivery_id: claimed.delivery_id,
                        endpoint_id: claimed.endpoint_id,
                        http_status: status_i64,
                        delivered_at_ms: Ctx.now_ms!(ctx),
                    }
                    _ = Ctx.run_mutation!(ctx, "${ns}._complete", complete_args)?
                    Ok({
                        delivery_id: claimed.delivery_id,
                        status: "delivered",
                        attempts: claimed.attempts,
                        last_status: status_i64,
                        last_error: "",
                    })
                } else {
                    retryable = is_retryable_status(resp.status)
                    delay_ms = compute_backoff_ms(m.base_backoff_ms, claimed.attempts)
                    snippet = truncate_error(resp.body)
                    err_msg =
                        if Str.is_empty(snippet) {
                            "HTTP ${resp.status.to_str()}"
                        } else {
                            "HTTP ${resp.status.to_str()}: ${snippet}"
                        }
                    next_status = record_failure!(ns, ctx, claimed.delivery_id, claimed.endpoint_id, status_i64, err_msg, retryable, delay_ms)?
                    Ok({
                        delivery_id: claimed.delivery_id,
                        status: next_status,
                        attempts: claimed.attempts,
                        last_status: status_i64,
                        last_error: err_msg,
                    })
                }
            }
            Err(net_err) => {
                delay_ms = compute_backoff_ms(m.base_backoff_ms, claimed.attempts)
                err_msg = "network error: ${truncate_error(net_err)}"
                next_status = record_failure!(ns, ctx, claimed.delivery_id, claimed.endpoint_id, 0, err_msg, Bool.True, delay_ms)?
                Ok({
                    delivery_id: claimed.delivery_id,
                    status: next_status,
                    attempts: claimed.attempts,
                    last_status: 0,
                    last_error: err_msg,
                })
            }
        }
    }

    # -------------------------------------------------------------------------
    # Public Management Endpoints
    # -------------------------------------------------------------------------

    register_endpoint_inner! : Ctx.MutationCtx, RegisterEndpointArgs => Try(Str, Str)
    register_endpoint_inner! = |ctx, args| {
        name = Str.trim(args.name)
        if Str.is_empty(name) {
            return Err("webhook endpoint `name` cannot be empty")
        }
        url = Str.trim(args.url)
        if !(Str.starts_with(url, "https://") or Str.starts_with(url, "http://")) {
            return Err("webhook endpoint `url` must start with http:// or https://")
        }
        new_ep : NewWebhookEndpoint
        new_ep = {
            name,
            url,
            events: args.events,
            active: Bool.True,
            secret_name: Str.trim(args.secret_name),
            consecutive_failures: 0,
        }
        Db.insert!(ctx.db, endpoints_table, new_ep)
    }

    list_endpoints_inner! : Ctx.QueryCtx, EmptyArgs => Try(List(WebhookEndpointDoc), Str)
    list_endpoints_inner! = |ctx, _|
        Db.query(endpoints_table)
        |> Db.asc()
        |> Db.collect!(ctx.db)

    list_deliveries_inner! : Ctx.QueryCtx, ListDeliveriesArgs => Try(List(WebhookDeliveryDoc), Str)
    list_deliveries_inner! = |ctx, args| {
        status = Str.trim(args.status)
        endpoint_id = Str.trim(args.endpoint_id)
        if !Str.is_empty(endpoint_id) {
            rows =
                Db.from_index(deliveries_by_endpoint)
                |> Db.eq([Key.str(endpoint_id)])
                |> Db.asc()
                |> Db.collect!(ctx.db)?
            if Str.is_empty(status) {
                Ok(rows)
            } else {
                Ok(List.keep_if(rows, |d| d.status == status))
            }
        } else if !Str.is_empty(status) {
            Db.from_index(deliveries_by_status)
            |> Db.eq([Key.str(status)])
            |> Db.asc()
            |> Db.collect!(ctx.db)
        } else {
            Db.query(deliveries_table)
            |> Db.asc()
            |> Db.collect!(ctx.db)
        }
    }

    retry_delivery_inner! : Str, Ctx.MutationCtx, DeliveryIdArgs => Try(Bool, Str)
    retry_delivery_inner! = |ns, ctx, args| {
        existing = Db.get!(Ctx.as_reader(ctx.db), deliveries_table, args.delivery_id)?
        del = match existing {
            Found(d) => d
            NotFound => return Err("webhook delivery `${args.delivery_id}` not found")
        }
        if del.status != "dead" {
            return Err("only dead deliveries can be retried (current status: `${del.status}`)")
        }
        reset_patch : { status : Str, attempts : I64, last_status : I64, last_error : Str }
        reset_patch = {
            status: "queued",
            attempts: 0,
            last_status: 0,
            last_error: "",
        }
        Db.patch!(ctx.db, deliveries_table, del.id, reset_patch)?
        deliver_args : DeliveryIdArgs
        deliver_args = { delivery_id: del.id }
        _ = Ctx.run_after!(ctx, 0, "${ns}._deliver", deliver_args)?
        Ok(True)
    }

    # -------------------------------------------------------------------------
    # App Attachment
    # -------------------------------------------------------------------------

    ## Attach the mounted Webhooks component's isolated tables (`webhooks_endpoints`,
    ## `webhooks_deliveries`), public management endpoints (`registerEndpoint`, `listEndpoints`,
    ## `listDeliveries`, `retryDelivery`), and internal delivery workers (`_deliver`, `_claim`,
    ## `_complete`, `_fail`).
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        max_attempts = m.max_attempts
        default_secret = m.signing_secret_name
        ep_doc_schema = Table.doc_schema_scoped(endpoints_table, ns)
        del_doc_schema = Table.doc_schema_scoped(deliveries_table, ns)

        spec
        |> App.component(m.spec)
        |> App.component_mutation(
            ns,
            "${ns}.registerEndpoint",
            register_endpoint_args_schema,
            Schema.scoped_id(ns, "webhooks_endpoints"),
            register_endpoint_inner!,
        )
        |> App.component_query(
            ns,
            "${ns}.listEndpoints",
            Schema.record([]),
            Schema.list(ep_doc_schema),
            list_endpoints_inner!,
        )
        |> App.component_query(
            ns,
            "${ns}.listDeliveries",
            list_deliveries_args_schema,
            Schema.list(del_doc_schema),
            list_deliveries_inner!,
        )
        |> App.component_mutation(
            ns,
            "${ns}.retryDelivery",
            delivery_id_args_schema,
            Schema.bool,
            |ctx, args| retry_delivery_inner!(ns, ctx, args),
        )
        |> App.component_internal_mutation(
            ns,
            "${ns}._claim",
            delivery_id_args_schema,
            claim_result_schema,
            |ctx, args| claim_inner!(default_secret, ctx, args),
        )
        |> App.component_internal_mutation(
            ns,
            "${ns}._complete",
            complete_args_schema,
            Schema.bool,
            complete_inner!,
        )
        |> App.component_internal_mutation(
            ns,
            "${ns}._fail",
            fail_args_schema,
            Schema.str,
            |ctx, args| fail_inner!(ns, max_attempts, ctx, args),
        )
        |> App.component_internal_action(
            ns,
            "${ns}._deliver",
            delivery_id_args_schema,
            deliver_result_schema,
            |ctx, args| deliver_inner!(m, ctx, args),
        )
    }
}

# -------------------------------------------------------------------------
# Pure-Roc Unit Tests
# -------------------------------------------------------------------------

expect {
    # Signature header formatting and parsing (including multiple v1 signatures and error cases)
    hdr = Webhooks.format_signature_header(1700000123, "deadbeef0123")
    parsed_ok = match Webhooks.parse_signature_header(hdr) {
        Ok(p) => p.timestamp == 1700000123 and p.v1_sigs == ["deadbeef0123"]
        Err(_) => False
    }
    parsed_multi = match Webhooks.parse_signature_header("t=1700000999, v1=aaa, v1=bbb") {
        Ok(p) => p.timestamp == 1700000999 and List.len(p.v1_sigs) == 2
        Err(_) => False
    }
    missing_ts = match Webhooks.parse_signature_header("v1=abc") {
        Ok(_) => False
        Err(_) => True
    }
    missing_sig = match Webhooks.parse_signature_header("t=1700000123") {
        Ok(_) => False
        Err(_) => True
    }
    bad_ts = match Webhooks.parse_signature_header("t=notanumber,v1=abc") {
        Ok(_) => False
        Err(_) => True
    }

    hdr == "t=1700000123,v1=deadbeef0123"
    and Webhooks.build_signing_payload(1700000123, "{\"ok\":true}") == "1700000123.{\"ok\":true}"
    and parsed_ok
    and parsed_multi
    and missing_ts
    and missing_sig
    and bad_ts
}

expect {
    # Event matching: empty list, "*", exact match, prefix wildcard, and non-match
    Webhooks.matches_event([], "order.created")
    and Webhooks.matches_event(["*"], "order.created")
    and Webhooks.matches_event(["order.created", "order.paid"], "order.paid")
    and !Webhooks.matches_event(["order.created"], "order.canceled")
    and Webhooks.matches_event(["order.*"], "order.created")
    and !Webhooks.matches_event(["order.*"], "invoice.created")
}

expect {
    # Exponential backoff math + retryable HTTP status classification + status conversion
    Webhooks.compute_backoff_ms(1000, 1) == 1000
    and Webhooks.compute_backoff_ms(1000, 2) == 2000
    and Webhooks.compute_backoff_ms(1000, 3) == 4000
    and Webhooks.compute_backoff_ms(1000, 10) == 60000
    and !Webhooks.is_retryable_status(200)
    and !Webhooks.is_retryable_status(400)
    and !Webhooks.is_retryable_status(404)
    and Webhooks.is_retryable_status(429)
    and Webhooks.is_retryable_status(500)
    and Webhooks.is_retryable_status(503)
    and Webhooks.u64_status_to_i64(200) == 200
    and Webhooks.u64_status_to_i64(503) == 503
}

expect {
    # Mount builders, secret allowlists, and component attachment
    m =
        Webhooks.mount("webhooks")
        |> Webhooks.with_signing_secret("WEBHOOK_SIGNING_SECRET")
        |> Webhooks.with_max_attempts(4)
        |> Webhooks.with_base_backoff_ms(50)

    spec = App.new("webhooks-unit-test") |> Webhooks.attach(m)
    has_secret = List.any(m.spec.allowed_secrets, |s| s == "WEBHOOK_SIGNING_SECRET")
    has_deliver = List.any(
        spec.actions,
        |a|
            a.meta.name == "webhooks._deliver"
            and a.meta.namespace == "webhooks"
            and match a.meta.visibility {
                Internal => True
                Public => False
            },
    )

    m.namespace == "webhooks"
    and m.max_attempts == 4
    and m.base_backoff_ms == 50
    and has_secret
    and List.len(m.spec.tables) == 2
    and List.len(spec.components) == 1
    and List.len(spec.queries) == 2
    and List.len(spec.mutations) == 5
    and List.len(spec.actions) == 1
    and has_deliver
}
