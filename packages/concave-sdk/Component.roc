import Table

## Metadata describing a mounted reusable Concave Component and its isolated tables.
Component := [Component].{
    ComponentSpec : {
        namespace : Str,
        pkg_name : Str,
        tables : List(Table.TableSpec),
        allowed_secrets : List(Str),
    }

    define : Str, Str, List(Table.TableSpec) -> ComponentSpec
    define = |namespace, pkg_name, tables| {
        namespace,
        pkg_name,
        tables,
        allowed_secrets: [],
    }

    with_secrets : ComponentSpec, List(Str) -> ComponentSpec
    with_secrets = |c, secrets| {
        namespace: c.namespace,
        pkg_name: c.pkg_name,
        tables: c.tables,
        allowed_secrets: List.concat(c.allowed_secrets, secrets),
    }

    spec_to_json : ComponentSpec -> Str
    spec_to_json = |c| {
        tables_json = c.tables |> List.map(Table.spec_to_json) |> Str.join_with(",")
        secrets_json = c.allowed_secrets |> List.map(Json.to_str) |> Str.join_with(",")
        "{\"namespace\":${Json.to_str(c.namespace)},\"package\":${Json.to_str(c.pkg_name)},\"tables\":[${tables_json}],\"allowed_secrets\":[${secrets_json}]}"
    }
}
