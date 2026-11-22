import Component
import Ctx
import Schema
import Table

## Complete declarative Concave application descriptor returned by a user's `main.roc`.
App := {
    app_name : Str,
    tables : List(Table.TableSpec),
    components : List(Component.ComponentSpec),
    queries : List(QueryEntry),
    mutations : List(MutationEntry),
    actions : List(ActionEntry),
}.{
    FunctionMeta : {
        name : Str,
        kind : [Query, Mutation, Action],
        namespace : Str,
        args_schema : Schema,
        returns_schema : Schema,
    }

    QueryEntry : {
        meta : FunctionMeta,
        run! : Box((Ctx.QueryCtx, Str => Try(Str, Str))),
    }

    MutationEntry : {
        meta : FunctionMeta,
        run! : Box((Ctx.MutationCtx, Str => Try(Str, Str))),
    }

    ActionEntry : {
        meta : FunctionMeta,
        run! : Box((Ctx.ActionCtx, Str => Try(Str, Str))),
    }

    new : Str -> App
    new = |app_name| {
        app_name,
        tables: [],
        components: [],
        queries: [],
        mutations: [],
        actions: [],
    }

    table : App, Table(doc) -> App
    table = |a, tbl| {
        app_name: a.app_name,
        tables: List.append(a.tables, Table.spec(tbl)),
        components: a.components,
        queries: a.queries,
        mutations: a.mutations,
        actions: a.actions,
    }

    component : App, Component.ComponentSpec -> App
    component = |a, comp| {
        app_name: a.app_name,
        tables: a.tables,
        components: List.append(a.components, comp),
        queries: a.queries,
        mutations: a.mutations,
        actions: a.actions,
    }

    ## Register a typed reactive Query endpoint.
    query :
        App,
        Str,
        Schema,
        Schema,
        (Ctx.QueryCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    query = |a, name, args_schema, returns_schema, handler!| {
        wrapped! : Ctx.QueryCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid query args for `${name}`: ${msg}")
            }
            out = handler!(ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode query result for `${name}`")
            }
        }
        entry : QueryEntry
        entry = {
            meta: {
                name,
                kind: Query,
                namespace: "",
                args_schema,
                returns_schema,
            },
            run!: Box.box(wrapped!),
        }
        {
            app_name: a.app_name,
            tables: a.tables,
            components: a.components,
            queries: List.append(a.queries, entry),
            mutations: a.mutations,
            actions: a.actions,
        }
    }

    ## Register a typed reactive Query endpoint scoped to a mounted Component's namespace.
    component_query :
        App,
        Str,
        Str,
        Schema,
        Schema,
        (Ctx.QueryCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    component_query = |a, namespace, name, args_schema, returns_schema, handler!| {
        wrapped! : Ctx.QueryCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            scoped_ctx = Ctx.scope_query(ctx, namespace)
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid query args for `${name}`: ${msg}")
            }
            out = handler!(scoped_ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode query result for `${name}`")
            }
        }
        entry : QueryEntry
        entry = {
            meta: {
                name,
                kind: Query,
                namespace,
                args_schema,
                returns_schema,
            },
            run!: Box.box(wrapped!),
        }
        {
            app_name: a.app_name,
            tables: a.tables,
            components: a.components,
            queries: List.append(a.queries, entry),
            mutations: a.mutations,
            actions: a.actions,
        }
    }

    ## Register a typed ACID transactional Mutation endpoint.
    mutation :
        App,
        Str,
        Schema,
        Schema,
        (Ctx.MutationCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    mutation = |a, name, args_schema, returns_schema, handler!| {
        wrapped! : Ctx.MutationCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid mutation args for `${name}`: ${msg}")
            }
            out = handler!(ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode mutation result for `${name}`")
            }
        }
        entry : MutationEntry
        entry = {
            meta: {
                name,
                kind: Mutation,
                namespace: "",
                args_schema,
                returns_schema,
            },
            run!: Box.box(wrapped!),
        }
        {
            app_name: a.app_name,
            tables: a.tables,
            components: a.components,
            queries: a.queries,
            mutations: List.append(a.mutations, entry),
            actions: a.actions,
        }
    }

    ## Register a typed ACID transactional Mutation endpoint scoped to a mounted Component's namespace.
    component_mutation :
        App,
        Str,
        Str,
        Schema,
        Schema,
        (Ctx.MutationCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    component_mutation = |a, namespace, name, args_schema, returns_schema, handler!| {
        wrapped! : Ctx.MutationCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            scoped_ctx = Ctx.scope_mutation(ctx, namespace)
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid mutation args for `${name}`: ${msg}")
            }
            out = handler!(scoped_ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode mutation result for `${name}`")
            }
        }
        entry : MutationEntry
        entry = {
            meta: {
                name,
                kind: Mutation,
                namespace,
                args_schema,
                returns_schema,
            },
            run!: Box.box(wrapped!),
        }
        {
            app_name: a.app_name,
            tables: a.tables,
            components: a.components,
            queries: a.queries,
            mutations: List.append(a.mutations, entry),
            actions: a.actions,
        }
    }

    ## Register an external Action endpoint (HTTP + calling queries/mutations).
    action :
        App,
        Str,
        Schema,
        Schema,
        (Ctx.ActionCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    action = |a, name, args_schema, returns_schema, handler!| {
        wrapped! : Ctx.ActionCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid action args for `${name}`: ${msg}")
            }
            out = handler!(ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode action result for `${name}`")
            }
        }
        entry : ActionEntry
        entry = {
            meta: {
                name,
                kind: Action,
                namespace: "",
                args_schema,
                returns_schema,
            },
            run!: Box.box(wrapped!),
        }
        {
            app_name: a.app_name,
            tables: a.tables,
            components: a.components,
            queries: a.queries,
            mutations: a.mutations,
            actions: List.append(a.actions, entry),
        }
    }

    ## Serialize the full `AppManifest` JSON IR for `--introspect`.
    manifest_json : App -> Str
    manifest_json = |a| {
        tables_json = a.tables |> List.map(Table.spec_to_json) |> Str.join_with(",")
        comps_json = a.components |> List.map(Component.spec_to_json) |> Str.join_with(",")

        all_metas =
            a.queries
            |> List.map(|e| e.meta)
            |> List.concat(a.mutations |> List.map(|e| e.meta))
            |> List.concat(a.actions |> List.map(|e| e.meta))

        funcs_json =
            all_metas
            |> List.map(function_meta_to_json)
            |> Str.join_with(",")

        "{\"app_name\":${Json.to_str(a.app_name)},\"tables\":[${tables_json}],\"components\":[${comps_json}],\"functions\":[${funcs_json}]}"
    }

    function_meta_to_json : FunctionMeta -> Str
    function_meta_to_json = |m| {
        kind_str = match m.kind {
            Query => "\"query\""
            Mutation => "\"mutation\""
            Action => "\"action\""
        }
        "{\"name\":${Json.to_str(m.name)},\"kind\":${kind_str},\"namespace\":${Json.to_str(m.namespace)},\"args_schema\":${Schema.to_json(m.args_schema)},\"returns_schema\":${Schema.to_json(m.returns_schema)}}"
    }

    ## Dispatch a Query by name (invoked by the Concave platform host).
    dispatch_query! : App, Ctx.QueryCtx, Str, Str => Try(Str, Str)
    dispatch_query! = |a, ctx, name, raw_args| {
        for entry in a.queries {
            if entry.meta.name == name {
                run! = Box.unbox(entry.run!)
                return run!(ctx, raw_args)
            }
        }
        Err("unknown query `${name}`")
    }

    ## Dispatch a Mutation by name (invoked by the Concave platform host).
    dispatch_mutation! : App, Ctx.MutationCtx, Str, Str => Try(Str, Str)
    dispatch_mutation! = |a, ctx, name, raw_args| {
        for entry in a.mutations {
            if entry.meta.name == name {
                run! = Box.unbox(entry.run!)
                return run!(ctx, raw_args)
            }
        }
        Err("unknown mutation `${name}`")
    }

    ## Dispatch an Action by name (invoked by the Concave platform host).
    dispatch_action! : App, Ctx.ActionCtx, Str, Str => Try(Str, Str)
    dispatch_action! = |a, ctx, name, raw_args| {
        for entry in a.actions {
            if entry.meta.name == name {
                run! = Box.unbox(entry.run!)
                return run!(ctx, raw_args)
            }
        }
        Err("unknown action `${name}`")
    }
}
