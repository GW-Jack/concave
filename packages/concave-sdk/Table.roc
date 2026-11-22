import Schema

## Typed handle for a Concave table.
## The phantom `doc` type parameter ties `Db.get!`, `Db.insert!`, and `Db.query` to the document record type.
Table(doc) := {
    name : Str,
    document_schema : Schema,
    indexes : List(IndexSpec),
}.{
    IndexSpec : {
        name : Str,
        fields : List(Str),
    }

    TableSpec : {
        name : Str,
        document_schema : Schema,
        indexes : List(IndexSpec),
    }

    ## Typed handle for a named secondary index on a table.
    Index(doc_t) := {
        table_name : Str,
        index_name : Str,
    }

    define : Str, Schema -> Table(doc)
    define = |tbl_name, schema| {
        name: tbl_name,
        document_schema: schema,
        indexes: [],
    }

    with_index : Table(doc), Str, List(Str) -> Table(doc)
    with_index = |t, idx_name, fields| {
        name: t.name,
        document_schema: t.document_schema,
        indexes: List.append(t.indexes, { name: idx_name, fields }),
    }

    table_name : Table(doc) -> Str
    table_name = |t| t.name

    spec : Table(doc) -> TableSpec
    spec = |t| {
        name: t.name,
        document_schema: t.document_schema,
        indexes: t.indexes,
    }

    doc_schema : Table(doc) -> Schema
    doc_schema = |t| Schema.doc(t.name, t.document_schema)

    doc_schema_scoped : Table(doc), Str -> Schema
    doc_schema_scoped = |t, namespace| Schema.doc_scoped(namespace, t.name, t.document_schema)

    index_ref : Table(doc), Str -> Index(doc)
    index_ref = |t, idx_name|
        Index.{ table_name: t.name, index_name: idx_name }

    index_table_name : Index(doc) -> Str
    index_table_name = |i| i.table_name

    index_name : Index(doc) -> Str
    index_name = |i| i.index_name

    spec_to_json : TableSpec -> Str
    spec_to_json = |s| {
        indexes_json =
            s.indexes
            |> List.map(|idx| {
                fields_json = idx.fields |> List.map(Json.to_str) |> Str.join_with(",")
                "{\"name\":${Json.to_str(idx.name)},\"fields\":[${fields_json}]}"
            })
            |> Str.join_with(",")
        "{\"name\":${Json.to_str(s.name)},\"document_schema\":${Schema.to_json(s.document_schema)},\"indexes\":[${indexes_json}]}"
    }
}

expect {
    t : Table({ name : Str })
    t = Table.define("rooms", Schema.record([Schema.field("name", Schema.str)]))
        |> Table.with_index("by_name", ["name"])
    Table.table_name(t) == "rooms"
}
