## Typed index keys, range bounds, and sort orders for structured `Db` queries.

Key := [Key].{
    KeyVal : [
        Null,
        Bool(Bool),
        Int(I64),
        Float(F64),
        Str(Str),
        Id(Str),
    ]

    Bound : [
        Unbounded,
        Included(List(KeyVal)),
        Excluded(List(KeyVal)),
        Prefix(List(KeyVal)),
    ]

    Order : [Asc, Desc]

    null : KeyVal
    null = Null

    bool : Bool -> KeyVal
    bool = |b| Bool(b)

    int : I64 -> KeyVal
    int = |i| Int(i)

    float : F64 -> KeyVal
    float = |f| Float(f)

    str : Str -> KeyVal
    str = |s| Str(s)

    id : Str -> KeyVal
    id = |s| Id(s)

    val_to_json : KeyVal -> Str
    val_to_json = |v|
        match v {
            Null => "{\"type\":\"null\"}"
            Bool(b) => {
                bs = if b { "true" } else { "false" }
                "{\"type\":\"bool\",\"value\":${bs}}"
            }
            Int(i) => "{\"type\":\"int\",\"value\":${i.to_str()}}"
            Float(f) => "{\"type\":\"float\",\"value\":${f.to_str()}}"
            Str(s) => "{\"type\":\"str\",\"value\":${Json.to_str(s)}}"
            Id(s) => "{\"type\":\"id\",\"value\":${Json.to_str(s)}}"
        }

    tuple_to_json : List(KeyVal) -> Str
    tuple_to_json = |vals| {
        inner = vals |> List.map(val_to_json) |> Str.join_with(",")
        "[${inner}]"
    }

    bound_to_json : Bound -> Str
    bound_to_json = |b|
        match b {
            Unbounded => "{\"kind\":\"unbounded\"}"
            Included(vals) => "{\"kind\":\"included\",\"values\":${tuple_to_json(vals)}}"
            Excluded(vals) => "{\"kind\":\"excluded\",\"values\":${tuple_to_json(vals)}}"
            Prefix(vals) => "{\"kind\":\"prefix\",\"values\":${tuple_to_json(vals)}}"
        }

    order_to_json : Order -> Str
    order_to_json = |ord|
        match ord {
            Asc => "\"asc\""
            Desc => "\"desc\""
        }

    ## Zero-JSON length-prefixed wire encoder (`<byte_len>:<raw_utf8>`) for fast Roc <-> Zig FFI.
    len_str : Str -> Str
    len_str = |s| {
        n = List.len(Str.to_utf8(s))
        "${n.to_str()}:${s}"
    }

    val_to_wire : KeyVal -> Str
    val_to_wire = |v|
        match v {
            Null => "n"
            Bool(b) => if b { "T" } else { "F" }
            Int(i) => "i${i.to_str()}:"
            Float(f) => "f${f.to_str()}:"
            Str(s) => "s${len_str(s)}"
            Id(s) => "d${len_str(s)}"
        }

    tuple_to_wire : List(KeyVal) -> Str
    tuple_to_wire = |vals| {
        n = List.len(vals)
        inner = vals |> List.map(val_to_wire) |> Str.join_with("")
        "${n.to_str()}:${inner}"
    }

    bound_to_wire : Bound -> Str
    bound_to_wire = |b|
        match b {
            Unbounded => "U"
            Included(vals) => "I${tuple_to_wire(vals)}"
            Excluded(vals) => "E${tuple_to_wire(vals)}"
            Prefix(vals) => "P${tuple_to_wire(vals)}"
        }

    order_to_wire : Order -> Str
    order_to_wire = |ord|
        match ord {
            Asc => "A"
            Desc => "D"
        }
}

expect Key.val_to_json(Key.str("general")) == "{\"type\":\"str\",\"value\":\"general\"}"
expect Key.val_to_json(Key.int(42)) == "{\"type\":\"int\",\"value\":42}"
expect Key.bound_to_wire(Included([Key.str("general"), Key.int(42)])) == "I2:s7:generali42:"
expect Key.bound_to_wire(Unbounded) == "U"
