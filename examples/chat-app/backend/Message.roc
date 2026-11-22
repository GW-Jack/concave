import sdk.Schema
import sdk.Table

Message := [Message].{
    Doc : {
        id : Str,
        created_at : I64,
        room_id : Str,
        author_id : Str,
        author_name : Str,
        body : Str,
        kind : Str,
    }

    ListArgs : {
        room_id : Str,
    }

    SendArgs : {
        room_id : Str,
        body : Str,
    }

    PostPreviewArgs : {
        room_id : Str,
        body : Str,
    }

    FetchPreviewArgs : {
        room_id : Str,
        url : Str,
    }

    PreviewResult : {
        status : U64,
        title : Str,
        message_id : Str,
    }

    body_schema : Schema
    body_schema = Schema.record([
        Schema.field("room_id", Schema.id("rooms")),
        Schema.field("author_id", Schema.str),
        Schema.field("author_name", Schema.str),
        Schema.field("body", Schema.str),
        Schema.field("kind", Schema.str),
    ])

    table : Table(Doc)
    table =
        Table.define("messages", body_schema)
        |> Table.with_index("by_room", ["room_id"])

    by_room : Table.Index(Doc)
    by_room = Table.index_ref(table, "by_room")

    doc_schema : Schema
    doc_schema = Table.doc_schema(table)

    list_args_schema : Schema
    list_args_schema = Schema.record([
        Schema.field("room_id", Schema.id("rooms")),
    ])

    send_args_schema : Schema
    send_args_schema = Schema.record([
        Schema.field("room_id", Schema.id("rooms")),
        Schema.field("body", Schema.str),
    ])

    post_preview_args_schema : Schema
    post_preview_args_schema = Schema.record([
        Schema.field("room_id", Schema.id("rooms")),
        Schema.field("body", Schema.str),
    ])

    fetch_preview_args_schema : Schema
    fetch_preview_args_schema = Schema.record([
        Schema.field("room_id", Schema.id("rooms")),
        Schema.field("url", Schema.str),
    ])

    preview_result_schema : Schema
    preview_result_schema = Schema.record([
        Schema.field("status", Schema.int),
        Schema.field("title", Schema.str),
        Schema.field("message_id", Schema.id("messages")),
    ])
}
