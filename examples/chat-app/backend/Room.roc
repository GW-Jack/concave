import sdk.Schema
import sdk.Table

Room := [Room].{
    Doc : {
        id : Str,
        created_at : I64,
        name : Str,
        topic : Str,
        created_by : Str,
    }

    CreateArgs : {
        name : Str,
        topic : Str,
    }

    body_schema : Schema
    body_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("topic", Schema.str),
        Schema.field("created_by", Schema.str),
    ])

    table : Table(Doc)
    table =
        Table.define("rooms", body_schema)
        |> Table.with_index("by_name", ["name"])

    by_name : Table.Index(Doc)
    by_name = Table.index_ref(table, "by_name")

    doc_schema : Schema
    doc_schema = Table.doc_schema(table)

    create_args_schema : Schema
    create_args_schema = Schema.record([
        Schema.field("name", Schema.str),
        Schema.field("topic", Schema.str),
    ])
}
