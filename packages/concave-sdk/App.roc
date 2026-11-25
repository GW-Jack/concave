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
    crons : List(CronEntry),
    http_routes : List(HttpRouteEntry),
    allowed_secrets : List(Str),
}.{
    Visibility : [Public, Internal]

    FunctionMeta : {
        name : Str,
        kind : [Query, Mutation, Action],
        visibility : Visibility,
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

    CronEntry : {
        name : Str,
        interval_ms : I64,
        fn_name : Str,
        args_json : Str,
    }

    HttpHeader : {
        name : Str,
        value : Str,
    }

    HttpRouteRequest : {
        method : Str,
        path : Str,
        query : Str,
        body : Str,
        content_type : Str,
        headers : List(HttpHeader),
    }

    ## Look up an HTTP request header value case-insensitively (e.g. for webhook HMAC signatures).
    header_value : HttpRouteRequest, Str -> Try(Str, [NotFound])
    header_value = |req, target_name| {
        needle = ascii_lower(target_name)
        for h in req.headers {
            if ascii_lower(h.name) == needle {
                return Ok(h.value)
            }
        }
        Err(NotFound)
    }

    ascii_lower : Str -> Str
    ascii_lower = |s| {
        bytes = Str.to_utf8(s)
        lowered = List.map(bytes, |b| if b >= 65 and b <= 90 { b + 32 } else { b })
        match Str.from_utf8(lowered) {
            Ok(out) => out
            Err(_) => s
        }
    }

    HttpRouteResponse : {
        status : U64,
        content_type : Str,
        body : Str,
    }

    HttpRouteResponseEx : {
        status : U64,
        content_type : Str,
        headers : List(HttpHeader),
        body : Str,
    }

    HttpRouteEntry : {
        method : Str,
        path : Str,
        namespace : Str,
        run! : Box((Ctx.ActionCtx, HttpRouteRequest => Try(HttpRouteResponseEx, Str))),
    }

    new : Str -> App
    new = |app_name| {
        app_name,
        tables: [],
        components: [],
        queries: [],
        mutations: [],
        actions: [],
        crons: [],
        http_routes: [],
        allowed_secrets: [],
    }

    ## Allowlist a single named secret for root app Actions and HTTP routes.
    with_secret : App, Str -> App
    with_secret = |a, name| {
        app_name: a.app_name,
        tables: a.tables,
        components: a.components,
        queries: a.queries,
        mutations: a.mutations,
        actions: a.actions,
        crons: a.crons,
        http_routes: a.http_routes,
        allowed_secrets: List.append(a.allowed_secrets, name),
    }

    ## Allowlist multiple named secrets for root app Actions and HTTP routes.
    with_secrets : App, List(Str) -> App
    with_secrets = |a, names| {
        app_name: a.app_name,
        tables: a.tables,
        components: a.components,
        queries: a.queries,
        mutations: a.mutations,
        actions: a.actions,
        crons: a.crons,
        http_routes: a.http_routes,
        allowed_secrets: List.concat(a.allowed_secrets, names),
    }

    table : App, Table(doc) -> App
    table = |a, tbl| {
        app_name: a.app_name,
        tables: List.append(a.tables, Table.spec(tbl)),
        components: a.components,
        queries: a.queries,
        mutations: a.mutations,
        actions: a.actions,
        crons: a.crons,
        http_routes: a.http_routes,
        allowed_secrets: a.allowed_secrets,
    }

    component : App, Component.ComponentSpec -> App
    component = |a, comp| {
        app_name: a.app_name,
        tables: a.tables,
        components: List.append(a.components, comp),
        queries: a.queries,
        mutations: a.mutations,
        actions: a.actions,
        crons: a.crons,
        http_routes: a.http_routes,
        allowed_secrets: a.allowed_secrets,
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
    query = |a, name, args_schema, returns_schema, handler!|
        register_query(a, Public, "", name, args_schema, returns_schema, handler!)

    ## Register an internal-only Query (callable via `Ctx.run_query!`, rejected on public HTTP/WS).
    internal_query :
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
    internal_query = |a, name, args_schema, returns_schema, handler!|
        register_query(a, Internal, "", name, args_schema, returns_schema, handler!)

    register_query :
        App,
        Visibility,
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
    register_query = |a, visibility, namespace, name, args_schema, returns_schema, handler!| {
        full_name =
            if !Str.is_empty(namespace) and !Str.starts_with(name, "${namespace}.") {
                "${namespace}.${name}"
            } else {
                name
            }
        wrapped! : Ctx.QueryCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            eff_ctx = if Str.is_empty(namespace) { ctx } else { Ctx.scope_query(ctx, namespace) }
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid query args for `${full_name}`: ${msg}")
            }
            out = handler!(eff_ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode query result for `${full_name}`")
            }
        }
        entry : QueryEntry
        entry = {
            meta: {
                name: full_name,
                kind: Query,
                visibility,
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
            crons: a.crons,
            http_routes: a.http_routes,
            allowed_secrets: a.allowed_secrets,
        }
    }

    ## Register a typed reactive Query returning `Try([Found(out), NotFound], Str)` (e.g. `Db.get!` or `Db.first!`).
    ## Automatically wraps `inner_returns_schema` in `Schema.optional(...)` and encodes `NotFound` as JSON `null`
    ## and `Found(out)` as unwrapped `out` JSON so runtime output matches generated TypeScript `T | null`.
    query_optional :
        App,
        Str,
        Schema,
        Schema,
        (Ctx.QueryCtx, args => Try([Found(out), NotFound], Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    query_optional = |a, name, args_schema, inner_returns_schema, handler!| {
        wrapped! : Ctx.QueryCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid query args for `${name}`: ${msg}")
            }
            match handler!(ctx, parsed)? {
                NotFound => Ok("null")
                Found(out) =>
                    match Json.to_str_try(out) {
                        Ok(s) => Ok(s)
                        Err(_) => Err("failed to encode query result for `${name}`")
                    }
            }
        }
        entry : QueryEntry
        entry = {
            meta: {
                name,
                kind: Query,
                visibility: Public,
                namespace: "",
                args_schema,
                returns_schema: Schema.optional(inner_returns_schema),
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
            crons: a.crons,
            http_routes: a.http_routes,
            allowed_secrets: a.allowed_secrets,
        }
    }

    ## Register a zero-parse pass-through reactive Query whose handler returns pre-encoded JSON
    ## (e.g. from `Db.collect_raw!`), skipping redundant JSON decode/encode while keeping full schema & codegen.
    query_raw :
        App,
        Str,
        Schema,
        Schema,
        (Ctx.QueryCtx, args => Try(Str, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
        ]
    query_raw = |a, name, args_schema, returns_schema, handler!| {
        wrapped! : Ctx.QueryCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid query args for `${name}`: ${msg}")
            }
            handler!(ctx, parsed)
        }
        entry : QueryEntry
        entry = {
            meta: {
                name,
                kind: Query,
                visibility: Public,
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
            crons: a.crons,
            http_routes: a.http_routes,
            allowed_secrets: a.allowed_secrets,
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
    component_query = |a, namespace, name, args_schema, returns_schema, handler!|
        register_query(a, Public, namespace, name, args_schema, returns_schema, handler!)

    ## Register an internal-only Query scoped to a mounted Component's namespace.
    component_internal_query :
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
    component_internal_query = |a, namespace, name, args_schema, returns_schema, handler!|
        register_query(a, Internal, namespace, name, args_schema, returns_schema, handler!)

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
    mutation = |a, name, args_schema, returns_schema, handler!|
        register_mutation(a, Public, "", name, args_schema, returns_schema, handler!)

    ## Register an internal-only Mutation (callable by crons, scheduler, and actions; blocked on public HTTP/WS).
    internal_mutation :
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
    internal_mutation = |a, name, args_schema, returns_schema, handler!|
        register_mutation(a, Internal, "", name, args_schema, returns_schema, handler!)

    register_mutation :
        App,
        Visibility,
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
    register_mutation = |a, visibility, namespace, name, args_schema, returns_schema, handler!| {
        full_name =
            if !Str.is_empty(namespace) and !Str.starts_with(name, "${namespace}.") {
                "${namespace}.${name}"
            } else {
                name
            }
        wrapped! : Ctx.MutationCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            eff_ctx = if Str.is_empty(namespace) { ctx } else { Ctx.scope_mutation(ctx, namespace) }
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid mutation args for `${full_name}`: ${msg}")
            }
            out = handler!(eff_ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode mutation result for `${full_name}`")
            }
        }
        entry : MutationEntry
        entry = {
            meta: {
                name: full_name,
                kind: Mutation,
                visibility,
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
            crons: a.crons,
            http_routes: a.http_routes,
            allowed_secrets: a.allowed_secrets,
        }
    }

    ## Register a typed ACID transactional Mutation returning `Try([Found(out), NotFound], Str)`,
    ## encoded as JSON `null` or unwrapped `out` JSON matching `Schema.optional(inner_returns_schema)`.
    mutation_optional :
        App,
        Str,
        Schema,
        Schema,
        (Ctx.MutationCtx, args => Try([Found(out), NotFound], Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    mutation_optional = |a, name, args_schema, inner_returns_schema, handler!| {
        wrapped! : Ctx.MutationCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid mutation args for `${name}`: ${msg}")
            }
            match handler!(ctx, parsed)? {
                NotFound => Ok("null")
                Found(out) =>
                    match Json.to_str_try(out) {
                        Ok(s) => Ok(s)
                        Err(_) => Err("failed to encode mutation result for `${name}`")
                    }
            }
        }
        entry : MutationEntry
        entry = {
            meta: {
                name,
                kind: Mutation,
                visibility: Public,
                namespace: "",
                args_schema,
                returns_schema: Schema.optional(inner_returns_schema),
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
            crons: a.crons,
            http_routes: a.http_routes,
            allowed_secrets: a.allowed_secrets,
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
    component_mutation = |a, namespace, name, args_schema, returns_schema, handler!|
        register_mutation(a, Public, namespace, name, args_schema, returns_schema, handler!)

    ## Register an internal-only Mutation scoped to a mounted Component's namespace.
    component_internal_mutation :
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
    component_internal_mutation = |a, namespace, name, args_schema, returns_schema, handler!|
        register_mutation(a, Internal, namespace, name, args_schema, returns_schema, handler!)

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
    action = |a, name, args_schema, returns_schema, handler!|
        register_action(a, Public, "", name, args_schema, returns_schema, handler!)

    ## Register an internal-only Action (callable by crons and scheduler; blocked on public HTTP/WS).
    internal_action :
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
    internal_action = |a, name, args_schema, returns_schema, handler!|
        register_action(a, Internal, "", name, args_schema, returns_schema, handler!)

    ## Register a public Action scoped to a mounted Component's namespace.
    component_action :
        App,
        Str,
        Str,
        Schema,
        Schema,
        (Ctx.ActionCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    component_action = |a, namespace, name, args_schema, returns_schema, handler!|
        register_action(a, Public, namespace, name, args_schema, returns_schema, handler!)

    ## Register an internal-only Action scoped to a mounted Component's namespace.
    component_internal_action :
        App,
        Str,
        Str,
        Schema,
        Schema,
        (Ctx.ActionCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    component_internal_action = |a, namespace, name, args_schema, returns_schema, handler!|
        register_action(a, Internal, namespace, name, args_schema, returns_schema, handler!)

    register_action :
        App,
        Visibility,
        Str,
        Str,
        Schema,
        Schema,
        (Ctx.ActionCtx, args => Try(out, Str))
        -> App
        where [
            args.Json.Parseable([InvalidJson(Str)]),
            out.Json.Encodable(enc_err),
        ]
    register_action = |a, visibility, namespace, name, args_schema, returns_schema, handler!| {
        full_name =
            if !Str.is_empty(namespace) and !Str.starts_with(name, "${namespace}.") {
                "${namespace}.${name}"
            } else {
                name
            }
        wrapped! : Ctx.ActionCtx, Str => Try(Str, Str)
        wrapped! = |ctx, raw_args| {
            parsed : args
            parsed = match Json.parse(raw_args) {
                Ok(v) => v
                Err(InvalidJson(msg)) => return Err("invalid action args for `${full_name}`: ${msg}")
            }
            out = handler!(ctx, parsed)?
            match Json.to_str_try(out) {
                Ok(s) => Ok(s)
                Err(_) => Err("failed to encode action result for `${full_name}`")
            }
        }
        entry : ActionEntry
        entry = {
            meta: {
                name: full_name,
                kind: Action,
                visibility,
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
            mutations: a.mutations,
            actions: List.append(a.actions, entry),
            crons: a.crons,
            http_routes: a.http_routes,
            allowed_secrets: a.allowed_secrets,
        }
    }

    ## Register a recurring scheduled Cron job that calls a registered mutation or action every `interval_ms` ms.
    cron : App, Str, I64, Str, Str -> App
    cron = |a, name, interval_ms, fn_name, args_json| {
        entry : CronEntry
        entry = { name, interval_ms, fn_name, args_json }
        {
            app_name: a.app_name,
            tables: a.tables,
            components: a.components,
            queries: a.queries,
            mutations: a.mutations,
            actions: a.actions,
            crons: List.append(a.crons, entry),
            http_routes: a.http_routes,
            allowed_secrets: a.allowed_secrets,
        }
    }

    ## Register a custom HTTP route / webhook handler (e.g. `App.http_route("POST", "/webhooks/stripe", handler!)`).
    ## Paths ending in `*` match by prefix; method `"*"` matches any HTTP method.
    http_route : App, Str, Str, (Ctx.ActionCtx, HttpRouteRequest => Try(HttpRouteResponse, Str)) -> App
    http_route = |a, method, path, handler!|
        component_http_route(a, "", method, path, handler!)

    ## Register a custom HTTP route returning explicit response headers (e.g. `Location`, `Set-Cookie`, `Cache-Control`).
    http_route_with_headers : App, Str, Str, (Ctx.ActionCtx, HttpRouteRequest => Try(HttpRouteResponseEx, Str)) -> App
    http_route_with_headers = |a, method, path, handler!|
        component_http_route_with_headers(a, "", method, path, handler!)

    ## Register a custom HTTP route scoped to a mounted Component's namespace (for secret allowlists).
    component_http_route : App, Str, Str, Str, (Ctx.ActionCtx, HttpRouteRequest => Try(HttpRouteResponse, Str)) -> App
    component_http_route = |a, namespace, method, path, handler!| {
        wrapped! : Ctx.ActionCtx, HttpRouteRequest => Try(HttpRouteResponseEx, Str)
        wrapped! = |ctx, req| {
            r = handler!(ctx, req)?
            Ok({
                status: r.status,
                content_type: r.content_type,
                headers: [],
                body: r.body,
            })
        }
        component_http_route_with_headers(a, namespace, method, path, wrapped!)
    }

    ## Register a custom HTTP route with response headers scoped to a mounted Component's namespace.
    component_http_route_with_headers : App, Str, Str, Str, (Ctx.ActionCtx, HttpRouteRequest => Try(HttpRouteResponseEx, Str)) -> App
    component_http_route_with_headers = |a, namespace, method, path, handler!| {
        entry : HttpRouteEntry
        entry = {
            method,
            path,
            namespace,
            run!: Box.box(handler!),
        }
        {
            app_name: a.app_name,
            tables: a.tables,
            components: a.components,
            queries: a.queries,
            mutations: a.mutations,
            actions: a.actions,
            crons: a.crons,
            http_routes: List.append(a.http_routes, entry),
            allowed_secrets: a.allowed_secrets,
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

        crons_json =
            a.crons
            |> List.map(cron_to_json)
            |> Str.join_with(",")

        routes_json =
            a.http_routes
            |> List.map(http_route_to_json)
            |> Str.join_with(",")

        secrets_json =
            a.allowed_secrets
            |> List.map(Json.to_str)
            |> Str.join_with(",")

        "{\"app_name\":${Json.to_str(a.app_name)},\"tables\":[${tables_json}],\"components\":[${comps_json}],\"functions\":[${funcs_json}],\"crons\":[${crons_json}],\"http_routes\":[${routes_json}],\"allowed_secrets\":[${secrets_json}]}"
    }

    cron_to_json : CronEntry -> Str
    cron_to_json = |c|
        "{\"name\":${Json.to_str(c.name)},\"interval_ms\":${c.interval_ms.to_str()},\"fn_name\":${Json.to_str(c.fn_name)},\"args_json\":${Json.to_str(c.args_json)}}"

    http_route_to_json : HttpRouteEntry -> Str
    http_route_to_json = |r|
        "{\"method\":${Json.to_str(r.method)},\"path\":${Json.to_str(r.path)},\"namespace\":${Json.to_str(r.namespace)}}"

    function_meta_to_json : FunctionMeta -> Str
    function_meta_to_json = |m| {
        kind_str = match m.kind {
            Query => "\"query\""
            Mutation => "\"mutation\""
            Action => "\"action\""
        }
        vis_str = match m.visibility {
            Public => "\"public\""
            Internal => "\"internal\""
        }
        "{\"name\":${Json.to_str(m.name)},\"kind\":${kind_str},\"visibility\":${vis_str},\"namespace\":${Json.to_str(m.namespace)},\"args_schema\":${Schema.to_json(m.args_schema)},\"returns_schema\":${Schema.to_json(m.returns_schema)}}"
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

    has_unsafe_path_segment : Str -> Bool
    has_unsafe_path_segment = |path| {
        if Str.contains(path, "\\") {
            return Bool.True
        }
        bytes = Str.to_utf8(path)
        if List.any(bytes, |b| b == 0) {
            return Bool.True
        }
        segs = Str.split_on(path, "/")
        List.any(segs, |seg| seg == ".." or seg == ".")
    }

    http_path_matches : Str, Str -> Bool
    http_path_matches = |pattern, path| {
        if has_unsafe_path_segment(path) {
            return Bool.False
        }
        if Str.ends_with(pattern, "*") {
            prefix = Str.drop_suffix(pattern, "*")
            if !Str.starts_with(path, prefix) {
                return Bool.False
            }
            if Str.is_empty(prefix) or Str.ends_with(prefix, "/") {
                return Bool.True
            }
            rest = Str.drop_prefix(path, prefix)
            Str.is_empty(rest) or Str.starts_with(rest, "/")
        } else {
            pattern == path
        }
    }

    ## Dispatch a custom HTTP route by method + path (invoked by the Concave platform host).
    dispatch_http! : App, Ctx.ActionCtx, Str, Str, Str => Try(Str, Str)
    dispatch_http! = |a, ctx, method, path, req_json| {
        if has_unsafe_path_segment(path) {
            return Err("invalid http route path `${path}`")
        }
        for entry in a.http_routes {
            method_ok = entry.method == "*" or entry.method == method
            path_ok = http_path_matches(entry.path, path)
            if method_ok and path_ok {
                parsed : HttpRouteRequest
                parsed = match Json.parse(req_json) {
                    Ok(v) => v
                    Err(InvalidJson(msg)) => return Err("invalid http route request: ${msg}")
                }
                run! = Box.unbox(entry.run!)
                resp = run!(ctx, parsed)?
                if List.len(resp.headers) == 0 {
                    basic : HttpRouteResponse
                    basic = {
                        status: resp.status,
                        content_type: resp.content_type,
                        body: resp.body,
                    }
                    return match Json.to_str_try(basic) {
                        Ok(s) => Ok(s)
                        Err(_) => Err("failed to encode http route response")
                    }
                }
                return match Json.to_str_try(resp) {
                    Ok(s) => Ok(s)
                    Err(_) => Err("failed to encode http route response")
                }
            }
        }
        Err("no matching http route for `${method} ${path}`")
    }
}
