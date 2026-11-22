## Language-agnostic schema IR matching `concave_core::manifest::SchemaType`.
## Used by `--introspect` to drive storage index sync and typed TypeScript codegen.

Schema := [
    Null,
    Bool,
    Int,
    Float,
    Str,
    Id({ table : Str, namespace : Str }),
    List(Schema),
    Optional(Schema),
    Record(List(Field)),
    Union(List(Variant)),
    Any,
].{
    Field : {
        name : Str,
        schema : Schema,
        optional : Bool,
    }

    Variant : {
        tag : Str,
        payload : [Some(Schema), None],
    }

    null : Schema
    null = Null

    bool : Schema
    bool = Bool

    int : Schema
    int = Int

    float : Schema
    float = Float

    str : Schema
    str = Str

    id : Str -> Schema
    id = |table| Id({ table, namespace: "" })

    scoped_id : Str, Str -> Schema
    scoped_id = |namespace, table| Id({ table, namespace })

    list : Schema -> Schema
    list = |item| List(item)

    optional : Schema -> Schema
    optional = |inner| Optional(inner)

    field : Str, Schema -> Field
    field = |name, schema| { name, schema, optional: False }

    opt_field : Str, Schema -> Field
    opt_field = |name, schema| { name, schema, optional: True }

    record : List(Field) -> Schema
    record = |fields| Record(fields)

    variant : Str -> Variant
    variant = |tag| { tag, payload: None }

    variant_with : Str, Schema -> Variant
    variant_with = |tag, payload| { tag, payload: Some(payload) }

    union : List(Variant) -> Schema
    union = |variants| Union(variants)

    any : Schema
    any = Any

    ## Append Concave system fields (`id`, `created_at`) to a document record schema.
    doc : Str, Schema -> Schema
    doc = |table_name, body_schema|
        doc_scoped("", table_name, body_schema)

    doc_scoped : Str, Str, Schema -> Schema
    doc_scoped = |namespace, table_name, body_schema| {
        sys_fields = [
            field("id", scoped_id(namespace, table_name)),
            field("created_at", int),
        ]
        match body_schema {
            Record(fields) => Record(List.concat(sys_fields, fields))
            other => Record(List.concat(sys_fields, [field("value", other)]))
        }
    }

    ## Serialize a `Schema` into the exact JSON format expected by `concave_core::SchemaType`.
    to_json : Schema -> Str
    to_json = |schema|
        match schema {
            Null => "{\"kind\":\"null\"}"
            Bool => "{\"kind\":\"bool\"}"
            Int => "{\"kind\":\"int\"}"
            Float => "{\"kind\":\"float\"}"
            Str => "{\"kind\":\"str\"}"
            Id({ table, namespace }) =>
                "{\"kind\":\"id\",\"table\":${Json.to_str(table)},\"namespace\":${Json.to_str(namespace)}}"
            List(item) =>
                "{\"kind\":\"list\",\"item\":${to_json(item)}}"
            Optional(inner) =>
                "{\"kind\":\"optional\",\"inner\":${to_json(inner)}}"
            Record(fields) => {
                rendered =
                    fields
                    |> List.map(|f| {
                        opt_str = if f.optional { "true" } else { "false" }
                        "{\"name\":${Json.to_str(f.name)},\"schema\":${to_json(f.schema)},\"optional\":${opt_str}}"
                    })
                    |> Str.join_with(",")
                "{\"kind\":\"record\",\"fields\":[${rendered}]}"
            }
            Union(variants) => {
                rendered =
                    variants
                    |> List.map(|v|
                        match v.payload {
                            None => "{\"tag\":${Json.to_str(v.tag)}}"
                            Some(p) => "{\"tag\":${Json.to_str(v.tag)},\"payload\":${to_json(p)}}"
                        }
                    )
                    |> Str.join_with(",")
                "{\"kind\":\"union\",\"variants\":[${rendered}]}"
            }
            Any => "{\"kind\":\"any\"}"
        }
}

expect Schema.to_json(Schema.str) == "{\"kind\":\"str\"}"
expect Schema.to_json(Schema.id("rooms")) == "{\"kind\":\"id\",\"table\":\"rooms\",\"namespace\":\"\"}"
