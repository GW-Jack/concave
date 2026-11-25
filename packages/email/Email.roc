import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table

## Reusable pure-Roc Durable Transactional Email Component for Concave.
##
## Features:
## - Isolated component namespace (default `"email"`) storing messages in `email_messages`
## - Transactional `Email.enqueue!` writes to the scoped `email_messages` table and schedules
##   `${ns}._deliver` atomically inside the caller's ACID mutation (outbox pattern)
## - Idempotency guard via `by_idempotency_key` index prevents duplicate sends
## - Built-in Resend, Postmark, and generic JSON Webhook providers with allowlisted secrets
## - Exponential backoff retry on 5xx, 429, and network errors (capped at 60s); dead-letter on 4xx/exhaustion
## - Inspection and dead-letter replay endpoints (`get`, `listByStatus`, `retry`)

Email := [Email].{
    # -------------------------------------------------------------------------
    # Provider & Mount Configuration Types
    # -------------------------------------------------------------------------

    Provider : [
        Resend({ endpoint : Str, secret_name : Str }),
        Postmark({ endpoint : Str, secret_name : Str }),
        Webhook({ url : Str, secret_name : Str }),
    ]

    Mount : {
        namespace : Str,
        provider : Provider,
        default_from : Str,
        max_attempts : I64,
        base_backoff_ms : I64,
        spec : Component.ComponentSpec,
    }

    # -------------------------------------------------------------------------
    # Document & Wire Types
    # -------------------------------------------------------------------------

    EmailMessageDoc : {
        id : Str,
        created_at : I64,
        idempotency_key : Str,
        from_addr : Str,
        to_addr : Str,
        subject : Str,
        html : Str,
        text : Str,
        status : Str,
        attempts : I64,
        provider_id : Str,
        last_error : Str,
        next_retry_at_ms : I64,
        sent_at_ms : I64,
    }

    NewEmailMessage : {
        idempotency_key : Str,
        from_addr : Str,
        to_addr : Str,
        subject : Str,
        html : Str,
        text : Str,
        status : Str,
        attempts : I64,
        provider_id : Str,
        last_error : Str,
        next_retry_at_ms : I64,
        sent_at_ms : I64,
    }

    EnqueueInput : {
        to : Str,
        subject : Str,
        html : Str,
        text : Str,
        idempotency_key : Str,
    }

    ProviderPayloadInput : {
        from_addr : Str,
        to_addr : Str,
        subject : Str,
        html : Str,
        text : Str,
        idempotency_key : Str,
    }

    GetArgs : {
        email_id : Str,
    }

    EmailGetResult : {
        found : Bool,
        id : Str,
        idempotency_key : Str,
        from_addr : Str,
        to_addr : Str,
        subject : Str,
        html : Str,
        text : Str,
        status : Str,
        attempts : I64,
        provider_id : Str,
        last_error : Str,
        next_retry_at_ms : I64,
        sent_at_ms : I64,
    }

    ListByStatusArgs : {
        status : Str,
    }

    RetryArgs : {
        email_id : Str,
    }

    DeliverArgs : {
        email_id : Str,
    }

    DeliverResult : {
        email_id : Str,
        status : Str,
        attempts : I64,
        last_error : Str,
    }

    ClaimResult : {
        claimed : Bool,
        id : Str,
        idempotency_key : Str,
        from_addr : Str,
        to_addr : Str,
        subject : Str,
        html : Str,
        text : Str,
        attempts : I64,
    }

    CompleteArgs : {
        email_id : Str,
        provider_id : Str,
        sent_at_ms : I64,
    }

    FailArgs : {
        email_id : Str,
        error_msg : Str,
        retryable : Bool,
        delay_ms : I64,
        now_ms : I64,
    }

    # -------------------------------------------------------------------------
    # Isolated Component Table & Indexes
    # -------------------------------------------------------------------------

    email_messages_schema : Schema
    email_messages_schema = Schema.record([
        Schema.field("idempotency_key", Schema.str),
        Schema.field("from_addr", Schema.str),
        Schema.field("to_addr", Schema.str),
        Schema.field("subject", Schema.str),
        Schema.field("html", Schema.str),
        Schema.field("text", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("attempts", Schema.int),
        Schema.field("provider_id", Schema.str),
        Schema.field("last_error", Schema.str),
        Schema.field("next_retry_at_ms", Schema.int),
        Schema.field("sent_at_ms", Schema.int),
    ])

    email_messages_table : Table(EmailMessageDoc)
    email_messages_table =
        Table.define("email_messages", email_messages_schema)
        |> Table.with_index("by_idempotency_key", ["idempotency_key"])
        |> Table.with_index("by_status", ["status"])

    by_idempotency_key : Table.Index(EmailMessageDoc)
    by_idempotency_key = Table.index_ref(email_messages_table, "by_idempotency_key")

    by_status : Table.Index(EmailMessageDoc)
    by_status = Table.index_ref(email_messages_table, "by_status")

    # -------------------------------------------------------------------------
    # Endpoint Wire Schemas
    # -------------------------------------------------------------------------

    email_id_args_schema : Schema
    email_id_args_schema = Schema.record([
        Schema.field("email_id", Schema.str),
    ])

    email_get_result_schema : Schema
    email_get_result_schema = Schema.record([
        Schema.field("found", Schema.bool),
        Schema.field("id", Schema.str),
        Schema.field("idempotency_key", Schema.str),
        Schema.field("from_addr", Schema.str),
        Schema.field("to_addr", Schema.str),
        Schema.field("subject", Schema.str),
        Schema.field("html", Schema.str),
        Schema.field("text", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("attempts", Schema.int),
        Schema.field("provider_id", Schema.str),
        Schema.field("last_error", Schema.str),
        Schema.field("next_retry_at_ms", Schema.int),
        Schema.field("sent_at_ms", Schema.int),
    ])

    list_by_status_args_schema : Schema
    list_by_status_args_schema = Schema.record([
        Schema.field("status", Schema.str),
    ])

    deliver_result_schema : Schema
    deliver_result_schema = Schema.record([
        Schema.field("email_id", Schema.str),
        Schema.field("status", Schema.str),
        Schema.field("attempts", Schema.int),
        Schema.field("last_error", Schema.str),
    ])

    claim_result_schema : Schema
    claim_result_schema = Schema.record([
        Schema.field("claimed", Schema.bool),
        Schema.field("id", Schema.str),
        Schema.field("idempotency_key", Schema.str),
        Schema.field("from_addr", Schema.str),
        Schema.field("to_addr", Schema.str),
        Schema.field("subject", Schema.str),
        Schema.field("html", Schema.str),
        Schema.field("text", Schema.str),
        Schema.field("attempts", Schema.int),
    ])

    complete_args_schema : Schema
    complete_args_schema = Schema.record([
        Schema.field("email_id", Schema.str),
        Schema.field("provider_id", Schema.str),
        Schema.field("sent_at_ms", Schema.int),
    ])

    fail_args_schema : Schema
    fail_args_schema = Schema.record([
        Schema.field("email_id", Schema.str),
        Schema.field("error_msg", Schema.str),
        Schema.field("retryable", Schema.bool),
        Schema.field("delay_ms", Schema.int),
        Schema.field("now_ms", Schema.int),
    ])

    # -------------------------------------------------------------------------
    # Pure Helpers (Backoff, Retry Classification, Provider Formatting)
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

    provider_secret_name : Provider -> Str
    provider_secret_name = |provider|
        match provider {
            Resend(cfg) => Str.trim(cfg.secret_name)
            Postmark(cfg) => Str.trim(cfg.secret_name)
            Webhook(cfg) => Str.trim(cfg.secret_name)
        }

    build_spec : Str, Provider -> Component.ComponentSpec
    build_spec = |ns, provider| {
        base = Component.define(ns, "concave-email", [Table.spec(email_messages_table)])
        secret = provider_secret_name(provider)
        if Str.is_empty(secret) {
            base
        } else {
            Component.with_secrets(base, [secret])
        }
    }

    ## Format the provider-specific JSON request payload for an outbound email.
    format_provider_body : Provider, ProviderPayloadInput -> Str
    format_provider_body = |provider, msg|
        match provider {
            Resend(_) =>
                "{\"from\":${Json.to_str(msg.from_addr)},\"to\":[${Json.to_str(msg.to_addr)}],\"subject\":${Json.to_str(msg.subject)},\"html\":${Json.to_str(msg.html)},\"text\":${Json.to_str(msg.text)}}"
            Postmark(_) =>
                "{\"From\":${Json.to_str(msg.from_addr)},\"To\":${Json.to_str(msg.to_addr)},\"Subject\":${Json.to_str(msg.subject)},\"HtmlBody\":${Json.to_str(msg.html)},\"TextBody\":${Json.to_str(msg.text)}}"
            Webhook(_) =>
                "{\"from\":${Json.to_str(msg.from_addr)},\"to\":${Json.to_str(msg.to_addr)},\"subject\":${Json.to_str(msg.subject)},\"html\":${Json.to_str(msg.html)},\"text\":${Json.to_str(msg.text)},\"idempotency_key\":${Json.to_str(msg.idempotency_key)}}"
        }

    ## Build the complete `Ctx.HttpRequestEx` for the configured email provider.
    build_provider_request : Provider, ProviderPayloadInput, Str -> Ctx.HttpRequestEx
    build_provider_request = |provider, msg, api_key| {
        body = format_provider_body(provider, msg)
        match provider {
            Resend(cfg) => {
                var $headers = [
                    { name: "Content-Type", value: "application/json" },
                    { name: "Authorization", value: "Bearer ${api_key}" },
                ]
                if !Str.is_empty(msg.idempotency_key) {
                    $headers = List.append($headers, { name: "Idempotency-Key", value: msg.idempotency_key })
                }
                {
                    method: "POST",
                    url: cfg.endpoint,
                    headers: $headers,
                    body,
                }
            }
            Postmark(cfg) => {
                method: "POST",
                url: cfg.endpoint,
                headers: [
                    { name: "Content-Type", value: "application/json" },
                    { name: "Accept", value: "application/json" },
                    { name: "X-Postmark-Server-Token", value: api_key },
                ],
                body,
            }
            Webhook(cfg) => {
                var $headers = [
                    { name: "Content-Type", value: "application/json" },
                ]
                if !Str.is_empty(Str.trim(cfg.secret_name)) and !Str.is_empty(api_key) {
                    $headers = List.append($headers, { name: "Authorization", value: "Bearer ${api_key}" })
                }
                {
                    method: "POST",
                    url: cfg.url,
                    headers: $headers,
                    body,
                }
            }
        }
    }

    ## Best-effort extraction of a top-level string field (e.g. `"id"` or `"MessageID"`) from a JSON object response.
    extract_provider_id : Str -> Str
    extract_provider_id = |body| {
        by_id = extract_json_str_field(body, "id")
        if !Str.is_empty(by_id) {
            by_id
        } else {
            extract_json_str_field(body, "MessageID")
        }
    }

    extract_json_str_field : Str, Str -> Str
    extract_json_str_field = |raw, key| {
        needle = "\"${key}\""
        parts = Str.split_on(raw, needle)
        if List.len(parts) < 2 {
            return ""
        }
        rest = match List.get(parts, 1) {
            Ok(s) => Str.trim(s)
            Err(_) => ""
        }
        if !Str.starts_with(rest, ":") {
            return ""
        }
        after_colon = Str.trim(Str.drop_prefix(rest, ":"))
        if !Str.starts_with(after_colon, "\"") {
            return ""
        }
        inner = Str.drop_prefix(after_colon, "\"")
        var $bytes = []
        var $escaped = False
        for b in Str.to_utf8(inner) {
            if $escaped {
                $bytes = List.append($bytes, b)
                $escaped = False
            } else if b == 92 {
                $escaped = True
            } else if b == 34 {
                return match Str.from_utf8($bytes) {
                    Ok(s) => s
                    Err(_) => ""
                }
            } else {
                $bytes = List.append($bytes, b)
            }
        }
        ""
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
                Err(_) => "provider error"
            }
        }
    }

    # -------------------------------------------------------------------------
    # Component Mount & Builder API
    # -------------------------------------------------------------------------

    ## Mount an isolated Email component under `namespace` (defaults to `"email"`).
    mount : Str -> Mount
    mount = |raw_namespace| {
        trimmed = Str.trim(raw_namespace)
        ns = if Str.is_empty(trimmed) { "email" } else { trimmed }
        default_provider = Resend({
            endpoint: "https://api.resend.com/emails",
            secret_name: "RESEND_API_KEY",
        })
        {
            namespace: ns,
            provider: default_provider,
            default_from: "",
            max_attempts: 5,
            base_backoff_ms: 1000,
            spec: build_spec(ns, default_provider),
        }
    }

    ## Configure Resend as the delivery provider (defaults to `"RESEND_API_KEY"` when `secret_name` is empty).
    with_resend : Mount, Str -> Mount
    with_resend = |m, raw_secret| {
        trimmed = Str.trim(raw_secret)
        secret_name = if Str.is_empty(trimmed) { "RESEND_API_KEY" } else { trimmed }
        provider = Resend({
            endpoint: "https://api.resend.com/emails",
            secret_name,
        })
        {
            namespace: m.namespace,
            provider,
            default_from: m.default_from,
            max_attempts: m.max_attempts,
            base_backoff_ms: m.base_backoff_ms,
            spec: build_spec(m.namespace, provider),
        }
    }

    ## Configure Postmark as the delivery provider (defaults to `"POSTMARK_SERVER_TOKEN"` when `secret_name` is empty).
    with_postmark : Mount, Str -> Mount
    with_postmark = |m, raw_secret| {
        trimmed = Str.trim(raw_secret)
        secret_name = if Str.is_empty(trimmed) { "POSTMARK_SERVER_TOKEN" } else { trimmed }
        provider = Postmark({
            endpoint: "https://api.postmarkapp.com/email",
            secret_name,
        })
        {
            namespace: m.namespace,
            provider,
            default_from: m.default_from,
            max_attempts: m.max_attempts,
            base_backoff_ms: m.base_backoff_ms,
            spec: build_spec(m.namespace, provider),
        }
    }

    ## Configure a custom JSON webhook relay provider (POSTs `{ from, to, subject, html, text, idempotency_key }`).
    with_webhook_provider : Mount, Str, Str -> Mount
    with_webhook_provider = |m, url, secret_name| {
        provider = Webhook({
            url: Str.trim(url),
            secret_name: Str.trim(secret_name),
        })
        {
            namespace: m.namespace,
            provider,
            default_from: m.default_from,
            max_attempts: m.max_attempts,
            base_backoff_ms: m.base_backoff_ms,
            spec: build_spec(m.namespace, provider),
        }
    }

    ## Set the default `From` email address for enqueued messages.
    with_default_from : Mount, Str -> Mount
    with_default_from = |m, from_addr| {
        namespace: m.namespace,
        provider: m.provider,
        default_from: Str.trim(from_addr),
        max_attempts: m.max_attempts,
        base_backoff_ms: m.base_backoff_ms,
        spec: m.spec,
    }

    ## Configure maximum delivery attempts before dead-lettering (default `5`, minimum `1`).
    with_max_attempts : Mount, I64 -> Mount
    with_max_attempts = |m, max_attempts| {
        namespace: m.namespace,
        provider: m.provider,
        default_from: m.default_from,
        max_attempts: if max_attempts < 1 { 1 } else { max_attempts },
        base_backoff_ms: m.base_backoff_ms,
        spec: m.spec,
    }

    ## Configure the base exponential backoff delay in milliseconds (default `1000`, capped at 60s).
    with_base_backoff_ms : Mount, I64 -> Mount
    with_base_backoff_ms = |m, ms| {
        clamped = if ms < 10 { 10 } else if ms > max_backoff_ms { max_backoff_ms } else { ms }
        {
            namespace: m.namespace,
            provider: m.provider,
            default_from: m.default_from,
            max_attempts: m.max_attempts,
            base_backoff_ms: clamped,
            spec: m.spec,
        }
    }

    # -------------------------------------------------------------------------
    # Transactional Helper for App Mutations
    # -------------------------------------------------------------------------

    ## Transactionally enqueue a durable outbound email inside the caller's ACID mutation.
    ## Inserts into the component's isolated `email_messages` table and schedules `${ns}._deliver`
    ## in the same transaction. If `idempotency_key` is non-empty and already exists, returns
    ## the existing `email_id` without inserting or scheduling a duplicate.
    enqueue! : Mount, Ctx.MutationCtx, EnqueueInput => Try(Str, Str)
    enqueue! = |m, ctx, input| {
        to_addr = Str.trim(input.to)
        if Str.is_empty(to_addr) {
            return Err("email recipient `to` cannot be empty")
        }
        subject = Str.trim(input.subject)
        if Str.is_empty(subject) {
            return Err("email `subject` cannot be empty")
        }
        from_addr = Str.trim(m.default_from)
        if Str.is_empty(from_addr) {
            return Err("email `default_from` must be configured via Email.with_default_from")
        }

        scoped = Ctx.scope_mutation(ctx, m.namespace)
        idem = Str.trim(input.idempotency_key)

        if !Str.is_empty(idem) {
            existing =
                Db.from_index(by_idempotency_key)
                |> Db.eq([Key.str(idem)])
                |> Db.first!(Ctx.as_reader(scoped.db))?
            match existing {
                Found(doc) => return Ok(doc.id)
                NotFound => {}
            }
        }

        new_msg : NewEmailMessage
        new_msg = {
            idempotency_key: idem,
            from_addr,
            to_addr,
            subject,
            html: input.html,
            text: input.text,
            status: "queued",
            attempts: 0,
            provider_id: "",
            last_error: "",
            next_retry_at_ms: 0,
            sent_at_ms: 0,
        }
        email_id = Db.insert!(scoped.db, email_messages_table, new_msg)?

        deliver_args : DeliverArgs
        deliver_args = { email_id: email_id }
        _ = Ctx.run_after!(scoped, 0, "${m.namespace}._deliver", deliver_args)?

        Ok(email_id)
    }

    # -------------------------------------------------------------------------
    # Internal Delivery State-Machine Endpoints
    # -------------------------------------------------------------------------

    claim_inner! : Ctx.MutationCtx, DeliverArgs => Try(ClaimResult, Str)
    claim_inner! = |ctx, args| {
        existing = Db.get!(Ctx.as_reader(ctx.db), email_messages_table, args.email_id)?
        match existing {
            NotFound =>
                Ok({
                    claimed: False,
                    id: args.email_id,
                    idempotency_key: "",
                    from_addr: "",
                    to_addr: "",
                    subject: "",
                    html: "",
                    text: "",
                    attempts: 0,
                })
            Found(doc) =>
                if doc.status != "queued" {
                    Ok({
                        claimed: False,
                        id: doc.id,
                        idempotency_key: doc.idempotency_key,
                        from_addr: doc.from_addr,
                        to_addr: doc.to_addr,
                        subject: doc.subject,
                        html: doc.html,
                        text: doc.text,
                        attempts: doc.attempts,
                    })
                } else {
                    next_attempts : I64
                    next_attempts = doc.attempts + 1
                    patch_body : { status : Str, attempts : I64, next_retry_at_ms : I64 }
                    patch_body = {
                        status: "sending",
                        attempts: next_attempts,
                        next_retry_at_ms: 0,
                    }
                    Db.patch!(ctx.db, email_messages_table, doc.id, patch_body)?
                    Ok({
                        claimed: True,
                        id: doc.id,
                        idempotency_key: doc.idempotency_key,
                        from_addr: doc.from_addr,
                        to_addr: doc.to_addr,
                        subject: doc.subject,
                        html: doc.html,
                        text: doc.text,
                        attempts: next_attempts,
                    })
                }
        }
    }

    complete_inner! : Ctx.MutationCtx, CompleteArgs => Try(Bool, Str)
    complete_inner! = |ctx, args| {
        patch_body : { status : Str, provider_id : Str, last_error : Str, next_retry_at_ms : I64, sent_at_ms : I64 }
        patch_body = {
            status: "sent",
            provider_id: args.provider_id,
            last_error: "",
            next_retry_at_ms: 0,
            sent_at_ms: args.sent_at_ms,
        }
        Db.patch!(ctx.db, email_messages_table, args.email_id, patch_body)?
        Ok(True)
    }

    fail_inner! : Str, I64, Ctx.MutationCtx, FailArgs => Try(Str, Str)
    fail_inner! = |ns, max_attempts, ctx, args| {
        existing = Db.get!(Ctx.as_reader(ctx.db), email_messages_table, args.email_id)?
        doc = match existing {
            Found(d) => d
            NotFound => return Ok("dead")
        }
        if args.retryable and doc.attempts < max_attempts {
            next_retry_at : I64
            next_retry_at = args.now_ms + args.delay_ms
            patch_body : { status : Str, last_error : Str, next_retry_at_ms : I64 }
            patch_body = {
                status: "queued",
                last_error: args.error_msg,
                next_retry_at_ms: next_retry_at,
            }
            Db.patch!(ctx.db, email_messages_table, doc.id, patch_body)?
            deliver_args : DeliverArgs
            deliver_args = { email_id: doc.id }
            _ = Ctx.run_after!(ctx, args.delay_ms, "${ns}._deliver", deliver_args)?
            Ok("queued")
        } else {
            patch_body : { status : Str, last_error : Str, next_retry_at_ms : I64 }
            patch_body = {
                status: "dead",
                last_error: args.error_msg,
                next_retry_at_ms: 0,
            }
            Db.patch!(ctx.db, email_messages_table, doc.id, patch_body)?
            Ok("dead")
        }
    }

    record_failure! : Str, Ctx.ActionCtx, Str, Str, Bool, I64, I64 => Try(Str, Str)
    record_failure! = |ns, ctx, email_id, error_msg, retryable, delay_ms, now_ms| {
        fail_args : FailArgs
        fail_args = {
            email_id,
            error_msg,
            retryable,
            delay_ms,
            now_ms,
        }
        raw = Ctx.run_mutation!(ctx, "${ns}._fail", fail_args)?
        match Json.parse(raw) {
            Ok(status_str) => Ok(status_str)
            Err(_) => Ok("dead")
        }
    }

    deliver_inner! : Mount, Ctx.ActionCtx, DeliverArgs => Try(DeliverResult, Str)
    deliver_inner! = |m, ctx, args| {
        ns = m.namespace
        claim_args : DeliverArgs
        claim_args = { email_id: args.email_id }
        claim_raw = Ctx.run_mutation!(ctx, "${ns}._claim", claim_args)?
        claimed : ClaimResult
        claimed = match Json.parse(claim_raw) {
            Ok(c) => c
            Err(InvalidJson(msg)) => return Err("failed to decode claim result: ${msg}")
        }

        if !claimed.claimed {
            return Ok({
                email_id: args.email_id,
                status: "skipped",
                attempts: claimed.attempts,
                last_error: "",
            })
        }

        now = Ctx.now_ms!(ctx)
        secret_name = provider_secret_name(m.provider)
        api_key =
            if Str.is_empty(secret_name) {
                ""
            } else {
                match Ctx.secret_get!(ctx, secret_name) {
                    Ok(k) => k
                    Err(sec_err) => {
                        err_msg = "secret `${secret_name}` unavailable: ${sec_err}"
                        next_status = record_failure!(ns, ctx, claimed.id, err_msg, Bool.False, 0, now)?
                        return Ok({
                            email_id: claimed.id,
                            status: next_status,
                            attempts: claimed.attempts,
                            last_error: err_msg,
                        })
                    }
                }
            }

        req = build_provider_request(
            m.provider,
            {
                from_addr: claimed.from_addr,
                to_addr: claimed.to_addr,
                subject: claimed.subject,
                html: claimed.html,
                text: claimed.text,
                idempotency_key: claimed.idempotency_key,
            },
            api_key,
        )

        match Ctx.http_request!(ctx, req) {
            Ok(resp) =>
                if resp.status >= 200 and resp.status < 300 {
                    provider_id = extract_provider_id(resp.body)
                    sent_at = Ctx.now_ms!(ctx)
                    complete_args : CompleteArgs
                    complete_args = {
                        email_id: claimed.id,
                        provider_id,
                        sent_at_ms: sent_at,
                    }
                    _ = Ctx.run_mutation!(ctx, "${ns}._complete", complete_args)?
                    Ok({
                        email_id: claimed.id,
                        status: "sent",
                        attempts: claimed.attempts,
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
                    next_status = record_failure!(ns, ctx, claimed.id, err_msg, retryable, delay_ms, Ctx.now_ms!(ctx))?
                    Ok({
                        email_id: claimed.id,
                        status: next_status,
                        attempts: claimed.attempts,
                        last_error: err_msg,
                    })
                }
            Err(net_err) => {
                delay_ms = compute_backoff_ms(m.base_backoff_ms, claimed.attempts)
                err_msg = "network error: ${truncate_error(net_err)}"
                next_status = record_failure!(ns, ctx, claimed.id, err_msg, Bool.True, delay_ms, Ctx.now_ms!(ctx))?
                Ok({
                    email_id: claimed.id,
                    status: next_status,
                    attempts: claimed.attempts,
                    last_error: err_msg,
                })
            }
        }
    }

    # -------------------------------------------------------------------------
    # Public Inspection & Ops Endpoints
    # -------------------------------------------------------------------------

    get_inner! : Ctx.QueryCtx, GetArgs => Try(EmailGetResult, Str)
    get_inner! = |ctx, args| {
        existing = Db.get!(ctx.db, email_messages_table, args.email_id)?
        match existing {
            Found(doc) =>
                Ok({
                    found: True,
                    id: doc.id,
                    idempotency_key: doc.idempotency_key,
                    from_addr: doc.from_addr,
                    to_addr: doc.to_addr,
                    subject: doc.subject,
                    html: doc.html,
                    text: doc.text,
                    status: doc.status,
                    attempts: doc.attempts,
                    provider_id: doc.provider_id,
                    last_error: doc.last_error,
                    next_retry_at_ms: doc.next_retry_at_ms,
                    sent_at_ms: doc.sent_at_ms,
                })
            NotFound =>
                Ok({
                    found: False,
                    id: args.email_id,
                    idempotency_key: "",
                    from_addr: "",
                    to_addr: "",
                    subject: "",
                    html: "",
                    text: "",
                    status: "",
                    attempts: 0,
                    provider_id: "",
                    last_error: "",
                    next_retry_at_ms: 0,
                    sent_at_ms: 0,
                })
        }
    }

    list_by_status_inner! : Ctx.QueryCtx, ListByStatusArgs => Try(List(EmailMessageDoc), Str)
    list_by_status_inner! = |ctx, args| {
        status = Str.trim(args.status)
        if Str.is_empty(status) {
            Db.query(email_messages_table)
            |> Db.asc()
            |> Db.collect!(ctx.db)
        } else {
            Db.from_index(by_status)
            |> Db.eq([Key.str(status)])
            |> Db.asc()
            |> Db.collect!(ctx.db)
        }
    }

    retry_inner! : Str, Ctx.MutationCtx, RetryArgs => Try(Bool, Str)
    retry_inner! = |ns, ctx, args| {
        existing = Db.get!(Ctx.as_reader(ctx.db), email_messages_table, args.email_id)?
        doc = match existing {
            Found(d) => d
            NotFound => return Err("email `${args.email_id}` not found")
        }
        if doc.status != "dead" {
            return Err("only dead emails can be retried (current status: `${doc.status}`)")
        }
        patch_body : { status : Str, attempts : I64, last_error : Str, next_retry_at_ms : I64 }
        patch_body = {
            status: "queued",
            attempts: 0,
            last_error: "",
            next_retry_at_ms: 0,
        }
        Db.patch!(ctx.db, email_messages_table, doc.id, patch_body)?
        deliver_args : DeliverArgs
        deliver_args = { email_id: doc.id }
        _ = Ctx.run_after!(ctx, 0, "${ns}._deliver", deliver_args)?
        Ok(True)
    }

    # -------------------------------------------------------------------------
    # App Attachment
    # -------------------------------------------------------------------------

    ## Attach the mounted Email component's isolated `email_messages` table,
    ## public inspection/retry endpoints (`get`, `listByStatus`, `retry`),
    ## and internal delivery action/mutations (`_deliver`, `_claim`, `_complete`, `_fail`).
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        max_attempts = m.max_attempts
        msg_doc_schema = Table.doc_schema_scoped(email_messages_table, ns)

        spec
        |> App.component(m.spec)
        |> App.component_query(
            ns,
            "${ns}.get",
            email_id_args_schema,
            email_get_result_schema,
            get_inner!,
        )
        |> App.component_query(
            ns,
            "${ns}.listByStatus",
            list_by_status_args_schema,
            Schema.list(msg_doc_schema),
            list_by_status_inner!,
        )
        |> App.component_mutation(
            ns,
            "${ns}.retry",
            email_id_args_schema,
            Schema.bool,
            |ctx, args| retry_inner!(ns, ctx, args),
        )
        |> App.component_internal_mutation(
            ns,
            "${ns}._claim",
            email_id_args_schema,
            claim_result_schema,
            claim_inner!,
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
            email_id_args_schema,
            deliver_result_schema,
            |ctx, args| deliver_inner!(m, ctx, args),
        )
    }
}

# -------------------------------------------------------------------------
# Pure-Roc Unit Tests
# -------------------------------------------------------------------------

expect {
    # Exponential backoff math with 60s cap
    Email.compute_backoff_ms(1000, 1) == 1000
    and Email.compute_backoff_ms(1000, 2) == 2000
    and Email.compute_backoff_ms(1000, 3) == 4000
    and Email.compute_backoff_ms(1000, 4) == 8000
    and Email.compute_backoff_ms(1000, 7) == 60000
    and Email.compute_backoff_ms(1000, 12) == 60000
    and Email.compute_backoff_ms(50, 1) == 50
    and Email.compute_backoff_ms(50, 2) == 100
}

expect {
    # Retryable status classification: 429 & 5xx retryable; 2xx & other 4xx non-retryable
    !Email.is_retryable_status(200)
    and !Email.is_retryable_status(202)
    and !Email.is_retryable_status(400)
    and !Email.is_retryable_status(401)
    and !Email.is_retryable_status(404)
    and !Email.is_retryable_status(422)
    and Email.is_retryable_status(429)
    and Email.is_retryable_status(500)
    and Email.is_retryable_status(502)
    and Email.is_retryable_status(503)
}

expect {
    # Provider request formatting (Resend, Postmark, Webhook) + provider ID extraction
    sample = {
        from_addr: "orders@example.com",
        to_addr: "alice@example.com",
        subject: "Receipt",
        html: "<p>Thanks</p>",
        text: "Thanks",
        idempotency_key: "order-123",
    }

    resend_m = Email.mount("email") |> Email.with_resend("")
    resend_req = Email.build_provider_request(resend_m.provider, sample, "re_secret")
    resend_has_auth = List.any(resend_req.headers, |h| h.name == "Authorization" and h.value == "Bearer re_secret")
    resend_has_idem = List.any(resend_req.headers, |h| h.name == "Idempotency-Key" and h.value == "order-123")

    postmark_m = Email.mount("email") |> Email.with_postmark("")
    postmark_req = Email.build_provider_request(postmark_m.provider, sample, "pm_secret")
    postmark_has_tok = List.any(postmark_req.headers, |h| h.name == "X-Postmark-Server-Token" and h.value == "pm_secret")

    webhook_m = Email.mount("email") |> Email.with_webhook_provider("http://127.0.0.1:13298/email", "EMAIL_API_KEY")
    webhook_req = Email.build_provider_request(webhook_m.provider, sample, "wh_secret")
    webhook_has_auth = List.any(webhook_req.headers, |h| h.name == "Authorization" and h.value == "Bearer wh_secret")

    resend_req.url == "https://api.resend.com/emails"
    and resend_has_auth
    and resend_has_idem
    and Str.contains(resend_req.body, "\"to\":[\"alice@example.com\"]")
    and postmark_req.url == "https://api.postmarkapp.com/email"
    and postmark_has_tok
    and Str.contains(postmark_req.body, "\"HtmlBody\":\"<p>Thanks</p>\"")
    and webhook_req.url == "http://127.0.0.1:13298/email"
    and webhook_has_auth
    and Str.contains(webhook_req.body, "\"idempotency_key\":\"order-123\"")
    and Email.extract_provider_id("{\"id\":\"re_999\"}") == "re_999"
    and Email.extract_provider_id("{\"MessageID\":\"pm_777\"}") == "pm_777"
}

expect {
    # Mount builders, secret allowlists, and component attachment
    m =
        Email.mount("email")
        |> Email.with_webhook_provider("http://127.0.0.1:13298/email", "EMAIL_API_KEY")
        |> Email.with_default_from("no-reply@example.com")
        |> Email.with_max_attempts(4)
        |> Email.with_base_backoff_ms(50)

    spec = App.new("email-unit-test") |> Email.attach(m)
    has_secret = List.any(m.spec.allowed_secrets, |s| s == "EMAIL_API_KEY")
    has_deliver = List.any(
        spec.actions,
        |a|
            a.meta.name == "email._deliver"
            and a.meta.namespace == "email"
            and match a.meta.visibility {
                Internal => True
                Public => False
            },
    )

    m.namespace == "email"
    and m.max_attempts == 4
    and m.base_backoff_ms == 50
    and has_secret
    and List.len(spec.components) == 1
    and List.len(spec.queries) == 2
    and List.len(spec.mutations) == 4
    and List.len(spec.actions) == 1
    and has_deliver
}
