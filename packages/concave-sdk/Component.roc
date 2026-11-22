import Table

## Metadata describing a mounted reusable Concave Component and its isolated tables.
Component := [Component].{
    ComponentSpec : {
        namespace : Str,
        pkg_name : Str,
        tables : List(Table.TableSpec),
    }

    define : Str, Str, List(Table.TableSpec) -> ComponentSpec
    define = |namespace, pkg_name, tables| {
        namespace,
        pkg_name,
        tables,
    }

    spec_to_json : ComponentSpec -> Str
    spec_to_json = |c| {
        tables_json = c.tables |> List.map(Table.spec_to_json) |> Str.join_with(",")
        "{\"namespace\":${Json.to_str(c.namespace)},\"package\":${Json.to_str(c.pkg_name)},\"tables\":[${tables_json}]}"
    }
}
