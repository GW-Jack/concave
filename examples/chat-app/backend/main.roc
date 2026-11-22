app [concave_app] {
    pf: platform "../../../platform/main.roc",
    sdk: "../../../packages/concave-sdk/main.roc",
    presence: "../../../packages/presence/main.roc",
    ratelimit: "../../../packages/rate-limiter/main.roc",
    analytics: "../../../packages/analytics/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import presence.Presence
import ratelimit.RateLimiter
import analytics.Analytics
import analytics.Flags
import analytics.Props
import Room
import Message

## Mounted reusable Components (each gets strict host-enforced table namespace isolation
## while executing inside the app's exact same ACID transactions).
chat_presence : Presence.Mount
chat_presence = Presence.mount("presence", 30000)

send_limiter : RateLimiter.Mount
send_limiter = RateLimiter.mount("rate_limit", 12, 60000)

chat_analytics : Analytics.Mount
chat_analytics = Analytics.mount("analytics")

## Queries

list_rooms! : Ctx.QueryCtx, {} => Try(List(Room.Doc), Str)
list_rooms! = |ctx, _|
    Db.query(Room.table)
    |> Db.asc()
    |> Db.collect!(ctx.db)

list_messages! : Ctx.QueryCtx, Message.ListArgs => Try(List(Message.Doc), Str)
list_messages! = |ctx, args|
    Db.from_index(Message.by_room)
    |> Db.eq([Key.str(args.room_id)])
    |> Db.asc()
    |> Db.take(100)
    |> Db.collect!(ctx.db)

## Mutations

ensure_defaults! : Ctx.MutationCtx, {} => Try(List(Room.Doc), Str)
ensure_defaults! = |ctx, _| {
    # Seed default feature flags & A/B experiments if none exist yet.
    existing_flags = Analytics.list_flags_in_query!(chat_analytics, Ctx.as_query_ctx(ctx))?
    if List.is_empty(existing_flags) {
        _ = Analytics.upsert_flag_in_tx!(chat_analytics, ctx, {
            key: "link-previews",
            name: "Allow /preview URL Actions",
            active: True,
            rollout_pct: 100,
            filters: [],
            variants: [],
        })?
        _ = Analytics.upsert_flag_in_tx!(chat_analytics, ctx, {
            key: "composer-cta",
            name: "Send button A/B test",
            active: True,
            rollout_pct: 100,
            filters: [],
            variants: [
                Flags.variant("control", 50),
                Flags.variant("rocket", 50),
            ],
        })?
    }

    existing = Db.query(Room.table) |> Db.asc() |> Db.collect!(Ctx.as_reader(ctx.db))?
    if List.is_empty(existing) {
        general_id = Db.insert!(ctx.db, Room.table, {
            name: "general",
            topic: "Welcome to Concave — real-time reactive chat powered by zero-dep Roc + Zig",
            created_by: "system",
        })?
        _ = Db.insert!(ctx.db, Message.table, {
            room_id: general_id,
            author_id: "system",
            author_name: "Concave",
            body: "Welcome! Open a second browser tab to see surgical ReadSet reactivity, live presence, and transactional rate limiting.",
            kind: "system",
        })?
        roc_id = Db.insert!(ctx.db, Room.table, {
            name: "roc-lang",
            topic: "Functional programming, native platforms, and Roc 0.1.0",
            created_by: "system",
        })?
        _ = Db.insert!(ctx.db, Message.table, {
            room_id: roc_id,
            author_id: "system",
            author_name: "Concave",
            body: "Messages posted in #general never invalidate subscribers in #roc-lang!",
            kind: "system",
        })?
        Db.query(Room.table) |> Db.asc() |> Db.collect!(Ctx.as_reader(ctx.db))
    } else {
        Ok(existing)
    }
}

create_room! : Ctx.MutationCtx, Room.CreateArgs => Try(Str, Str)
create_room! = |ctx, args| {
    user = Ctx.require_auth!(ctx.auth!)?
    trimmed = Str.trim(args.name)
    if Str.is_empty(trimmed) {
        return Err("Room name cannot be empty")
    }
    dup =
        Db.from_index(Room.by_name)
        |> Db.eq([Key.str(trimmed)])
        |> Db.first!(Ctx.as_reader(ctx.db))?
    match dup {
        Found(_) => Err("Room `#${trimmed}` already exists")
        NotFound => {
            room_id = Db.insert!(ctx.db, Room.table, {
                name: trimmed,
                topic: Str.trim(args.topic),
                created_by: user.name,
            })?
            _ = Analytics.track_event!(chat_analytics, ctx, user.subject, "room_created", [
                Props.prop("room_id", room_id),
                Props.prop("room_name", trimmed),
            ])?
            Ok(room_id)
        }
    }
}

send_message! : Ctx.MutationCtx, Message.SendArgs => Try(Str, Str)
send_message! = |ctx, args| {
    user = Ctx.require_auth!(ctx.auth!)?
    trimmed = Str.trim(args.body)
    if Str.is_empty(trimmed) {
        return Err("Message body cannot be empty")
    }

    # Verify the room exists in root namespace.
    room_lookup = Db.get!(Ctx.as_reader(ctx.db), Room.table, args.room_id)?
    match room_lookup {
        NotFound => return Err("Room not found")
        Found(_) => {}
    }

    # Enforce per-user rate limit inside the EXACT SAME ACID transaction
    # (tables live in isolated `rate_limit` component namespace!).
    _ = RateLimiter.enforce!(send_limiter, ctx, user.subject)?

    msg_id = Db.insert!(ctx.db, Message.table, {
        room_id: args.room_id,
        author_id: user.subject,
        author_name: user.name,
        body: trimmed,
        kind: "text",
    })?

    # Record analytics atomically in the exact same ACID transaction.
    _ = Analytics.track_event!(chat_analytics, ctx, user.subject, "message_sent", [
        Props.prop("room_id", args.room_id),
        Props.prop("author", user.name),
    ])?

    Ok(msg_id)
}

post_preview! : Ctx.MutationCtx, Message.PostPreviewArgs => Try(Str, Str)
post_preview! = |ctx, args| {
    user = Ctx.require_auth!(ctx.auth!)?
    previews_enabled = Analytics.is_flag_enabled!(
        chat_analytics,
        Ctx.as_query_ctx(ctx),
        "link-previews",
        user.subject,
    )?
    if !previews_enabled {
        return Err("Link previews are disabled by feature flag `link-previews`")
    }
    msg_id = Db.insert!(ctx.db, Message.table, {
        room_id: args.room_id,
        author_id: user.subject,
        author_name: "${user.name} (link preview)",
        body: args.body,
        kind: "preview",
    })?
    _ = Analytics.track_event!(chat_analytics, ctx, user.subject, "link_preview_posted", [
        Props.prop("room_id", args.room_id),
    ])?
    Ok(msg_id)
}

## External Action: fetch a URL over HTTP and commit a preview message via `run_mutation!`.

extract_title : Str -> Str
extract_title = |html| {
    match Str.split_first(html, "<title>") {
        Ok({ before: _, after }) =>
            match Str.split_first(after, "</title>") {
                Ok({ before, after: _ }) => Str.trim(before)
                Err(_) => ""
            }
        Err(_) => ""
    }
}

fetch_preview! : Ctx.ActionCtx, Message.FetchPreviewArgs => Try(Message.PreviewResult, Str)
fetch_preview! = |ctx, args| {
    _ = Ctx.require_auth!(ctx.auth!)?
    http_fetch! = ctx.http_fetch!
    resp = http_fetch!({
        method: "GET",
        url: args.url,
        body: "",
    })?

    raw_title = extract_title(resp.body)
    title = if Str.is_empty(raw_title) { args.url } else { raw_title }
    summary = "🔗 ${title} (HTTP ${resp.status.to_str()}) — ${args.url}"

    run_mutation! = ctx.run_mutation!
    mut_args = Json.to_str({ room_id: args.room_id, body: summary })
    msg_id_json = run_mutation!("messages.postPreview", mut_args)?
    msg_id = Json.parse(msg_id_json) ?? msg_id_json

    Ok({
        status: resp.status,
        title,
        message_id: msg_id,
    })
}

## Application Descriptor

concave_app : () -> App
concave_app = ||
    App.new("concave-chat")
    |> App.table(Room.table)
    |> App.table(Message.table)
    |> Presence.attach(chat_presence)
    |> RateLimiter.attach(send_limiter)
    |> Analytics.attach(chat_analytics)
    |> App.query("rooms.list", Schema.record([]), Schema.list(Room.doc_schema), list_rooms!)
    |> App.query("messages.list", Message.list_args_schema, Schema.list(Message.doc_schema), list_messages!)
    |> App.mutation("rooms.ensureDefaults", Schema.record([]), Schema.list(Room.doc_schema), ensure_defaults!)
    |> App.mutation("rooms.create", Room.create_args_schema, Schema.id("rooms"), create_room!)
    |> App.mutation("messages.send", Message.send_args_schema, Schema.id("messages"), send_message!)
    |> App.mutation("messages.postPreview", Message.post_preview_args_schema, Schema.id("messages"), post_preview!)
    |> App.action("messages.fetchPreview", Message.fetch_preview_args_schema, Message.preview_result_schema, fetch_preview!)
