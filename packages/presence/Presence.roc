import sdk.App
import sdk.Component
import sdk.Ctx
import sdk.Db
import sdk.Key
import sdk.Schema
import sdk.Table

## Reusable pure-Roc Presence Component.
## Tracks online users & typing status per room inside an isolated component namespace.

Presence := [Presence].{
    SessionDoc : {
        id : Str,
        created_at : I64,
        room_id : Str,
        user_id : Str,
        user_name : Str,
        typing : Bool,
        last_seen_ms : I64,
    }

    HeartbeatArgs : {
        room_id : Str,
        typing : Bool,
    }

    LeaveArgs : {
        room_id : Str,
    }

    ListArgs : {
        room_id : Str,
    }

    OnlineUser : {
        user_id : Str,
        user_name : Str,
        typing : Bool,
        last_seen_ms : I64,
    }

    Mount : {
        namespace : Str,
        ttl_ms : I64,
        spec : Component.ComponentSpec,
    }

    sessions_schema : Schema
    sessions_schema = Schema.record([
        Schema.field("room_id", Schema.str),
        Schema.field("user_id", Schema.str),
        Schema.field("user_name", Schema.str),
        Schema.field("typing", Schema.bool),
        Schema.field("last_seen_ms", Schema.int),
    ])

    sessions_table : Table(SessionDoc)
    sessions_table =
        Table.define("sessions", sessions_schema)
        |> Table.with_index("by_room", ["room_id"])
        |> Table.with_index("by_room_last_seen", ["room_id", "last_seen_ms"])
        |> Table.with_index("by_room_user", ["room_id", "user_id"])

    by_room : Table.Index(SessionDoc)
    by_room = Table.index_ref(sessions_table, "by_room")

    by_room_last_seen : Table.Index(SessionDoc)
    by_room_last_seen = Table.index_ref(sessions_table, "by_room_last_seen")

    by_room_user : Table.Index(SessionDoc)
    by_room_user = Table.index_ref(sessions_table, "by_room_user")

    heartbeat_args_schema : Schema
    heartbeat_args_schema = Schema.record([
        Schema.field("room_id", Schema.str),
        Schema.field("typing", Schema.bool),
    ])

    leave_args_schema : Schema
    leave_args_schema = Schema.record([
        Schema.field("room_id", Schema.str),
    ])

    list_args_schema : Schema
    list_args_schema = Schema.record([
        Schema.field("room_id", Schema.str),
    ])

    online_user_schema : Schema
    online_user_schema = Schema.record([
        Schema.field("user_id", Schema.str),
        Schema.field("user_name", Schema.str),
        Schema.field("typing", Schema.bool),
        Schema.field("last_seen_ms", Schema.int),
    ])

    validate_room_id : Str -> Try(Str, Str)
    validate_room_id = |raw| {
        trimmed = Str.trim(raw)
        if Str.is_empty(trimmed) {
            Err("room_id cannot be empty")
        } else if Str.count_utf8_bytes(trimmed) > 128 {
            Err("room_id exceeds maximum length of 128 bytes")
        } else {
            Ok(trimmed)
        }
    }

    ## Mount an isolated instance of the Presence component under `namespace`.
    mount : Str, I64 -> Mount
    mount = |namespace, ttl_ms| {
        namespace,
        ttl_ms: if ttl_ms < 1000 { 1000 } else { ttl_ms },
        spec: Component.define(
            namespace,
            "concave-presence",
            [Table.spec(sessions_table)],
        ),
    }

    ## Record or refresh the authenticated user's presence & typing state in a room.
    heartbeat! : Ctx.MutationCtx, HeartbeatArgs => Try(Bool, Str)
    heartbeat! = |ctx, args| {
        user = Ctx.require_auth!(ctx.auth!)?
        room_id = validate_room_id(args.room_id)?
        now_ms! = ctx.now_ms!
        now = now_ms!()

        existing =
            Db.from_index(by_room_user)
            |> Db.eq([Key.str(room_id), Key.str(user.subject)])
            |> Db.first!(Ctx.as_reader(ctx.db))?

        match existing {
            Found(doc) => {
                Db.patch!(ctx.db, sessions_table, doc.id, {
                    user_name: user.name,
                    typing: args.typing,
                    last_seen_ms: now,
                })?
                Ok(True)
            }
            NotFound => {
                _ = Db.insert!(ctx.db, sessions_table, {
                    room_id,
                    user_id: user.subject,
                    user_name: user.name,
                    typing: args.typing,
                    last_seen_ms: now,
                })?
                Ok(True)
            }
        }
    }

    ## Explicitly remove the authenticated user from a room's presence list.
    leave! : Ctx.MutationCtx, LeaveArgs => Try(Bool, Str)
    leave! = |ctx, args| {
        user = Ctx.require_auth!(ctx.auth!)?
        room_id = validate_room_id(args.room_id)?
        existing =
            Db.from_index(by_room_user)
            |> Db.eq([Key.str(room_id), Key.str(user.subject)])
            |> Db.first!(Ctx.as_reader(ctx.db))?

        match existing {
            Found(doc) => {
                Db.delete!(ctx.db, sessions_table, doc.id)?
                Ok(True)
            }
            NotFound => Ok(False)
        }
    }

    ## List active (non-stale) users in a room (requires authentication, bounded to 200 users).
    list_online! : I64, Ctx.QueryCtx, ListArgs => Try(List(OnlineUser), Str)
    list_online! = |ttl_ms, ctx, args| {
        _ = Ctx.require_auth!(ctx.auth!)?
        room_id = validate_room_id(args.room_id)?
        now_ms! = ctx.now_ms!
        cutoff = now_ms!() - ttl_ms
        docs =
            Db.from_index(by_room_last_seen)
            |> Db.eq([Key.str(room_id)])
            |> Db.gte([Key.str(room_id), Key.int(cutoff)])
            |> Db.desc()
            |> Db.take(200)
            |> Db.collect!(ctx.db)?

        active =
            docs
            |> List.keep_if(|d| d.last_seen_ms >= cutoff)
            |> List.map(|d| {
                user_id: d.user_id,
                user_name: d.user_name,
                typing: d.typing,
                last_seen_ms: d.last_seen_ms,
            })
        Ok(active)
    }

    ## Attach the mounted Presence component's isolated tables and public endpoints to an `App`.
    attach : App, Mount -> App
    attach = |spec, m| {
        ns = m.namespace
        ttl = m.ttl_ms
        spec
        |> App.component(m.spec)
        |> App.component_query(
            ns,
            "${ns}.listOnline",
            list_args_schema,
            Schema.list(online_user_schema),
            |ctx, args| list_online!(ttl, ctx, args),
        )
        |> App.component_mutation(
            ns,
            "${ns}.heartbeat",
            heartbeat_args_schema,
            Schema.bool,
            heartbeat!,
        )
        |> App.component_mutation(
            ns,
            "${ns}.leave",
            leave_args_schema,
            Schema.bool,
            leave!,
        )
    }
}

expect {
    m = Presence.mount("presence", 30000)
    m.namespace == "presence" and m.spec.pkg_name == "concave-presence"
}
