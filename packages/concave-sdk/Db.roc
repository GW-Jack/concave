import Ctx
import Key
import Table

Db := [Db].{
    ## Typed query builder supporting index-range bounds, sort order, and limits.
    QueryBuilder(doc) := {
        table_name : Str,
        index_name : Str,
        start : Key.Bound,
        end : Key.Bound,
        order : Key.Order,
        limit : [None, Some(U64)],
    }

    ## Fetch a single document by ID, decoded into `doc` using Roc's built-in `Json.parse`.
    get! : Ctx.DbReader, Table(doc), Str => Try([Found(doc), NotFound], Str)
        where [doc.Json.Parseable([InvalidJson(Str)])]
    get! = |db, table, doc_id| {
        get_raw! = db.get_raw!
        raw = get_raw!(db.namespace, Table.table_name(table), doc_id)?
        if raw == "null" {
            Ok(NotFound)
        } else {
            match Json.parse(raw) {
                Ok(doc) => Ok(Found(doc))
                Err(InvalidJson(msg)) => Err("failed to decode document: ${msg}")
            }
        }
    }

    ## Insert a new document into `table`, returning its generated `_id`.
    insert! : Ctx.DbWriter, Table(doc), body => Try(Str, Str)
        where [body.Json.Encodable(enc_err)]
    insert! = |db, table, body| {
        encoded = match Json.to_str_try(body) {
            Ok(s) => s
            Err(_) => return Err("failed to encode document body as JSON")
        }
        insert_raw! = db.insert_raw!
        insert_raw!(db.namespace, Table.table_name(table), encoded)
    }

    ## Shallow-merge `patch_fields` onto an existing document.
    patch! : Ctx.DbWriter, Table(doc), Str, patch_fields => Try({}, Str)
        where [patch_fields.Json.Encodable(enc_err)]
    patch! = |db, table, doc_id, patch_fields| {
        encoded = match Json.to_str_try(patch_fields) {
            Ok(s) => s
            Err(_) => return Err("failed to encode patch fields as JSON")
        }
        patch_raw! = db.patch_raw!
        patch_raw!(db.namespace, Table.table_name(table), doc_id, encoded)
    }

    ## Replace an existing document's body completely.
    replace! : Ctx.DbWriter, Table(doc), Str, body => Try({}, Str)
        where [body.Json.Encodable(enc_err)]
    replace! = |db, table, doc_id, body| {
        encoded = match Json.to_str_try(body) {
            Ok(s) => s
            Err(_) => return Err("failed to encode replacement body as JSON")
        }
        replace_raw! = db.replace_raw!
        replace_raw!(db.namespace, Table.table_name(table), doc_id, encoded)
    }

    ## Delete a document by ID.
    delete! : Ctx.DbWriter, Table(doc), Str => Try({}, Str)
    delete! = |db, table, doc_id| {
        delete_raw! = db.delete_raw!
        delete_raw!(db.namespace, Table.table_name(table), doc_id)
    }

    ## Start a full-table scan ordered by `_creationTime`.
    query : Table(doc) -> QueryBuilder(doc)
    query = |table|
        QueryBuilder.{
            table_name: Table.table_name(table),
            index_name: "by_creation_time",
            start: Unbounded,
            end: Unbounded,
            order: Asc,
            limit: None,
        }

    ## Start an indexed range query on a declared secondary index.
    from_index : Table.Index(doc) -> QueryBuilder(doc)
    from_index = |idx|
        QueryBuilder.{
            table_name: Table.index_table_name(idx),
            index_name: Table.index_name(idx),
            start: Unbounded,
            end: Unbounded,
            order: Asc,
            limit: None,
        }

    ## Constrain an indexed query to all entries matching the given key prefix (e.g., `eq([Key.str(room_id)])`).
    eq : QueryBuilder(doc), List(Key.KeyVal) -> QueryBuilder(doc)
    eq = |q, prefix|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: Included(prefix),
            end: Prefix(prefix),
            order: q.order,
            limit: q.limit,
        }

    gte : QueryBuilder(doc), List(Key.KeyVal) -> QueryBuilder(doc)
    gte = |q, lower|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: Included(lower),
            end: q.end,
            order: q.order,
            limit: q.limit,
        }

    gt : QueryBuilder(doc), List(Key.KeyVal) -> QueryBuilder(doc)
    gt = |q, lower|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: Excluded(lower),
            end: q.end,
            order: q.order,
            limit: q.limit,
        }

    lte : QueryBuilder(doc), List(Key.KeyVal) -> QueryBuilder(doc)
    lte = |q, upper|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: q.start,
            end: Included(upper),
            order: q.order,
            limit: q.limit,
        }

    lt : QueryBuilder(doc), List(Key.KeyVal) -> QueryBuilder(doc)
    lt = |q, upper|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: q.start,
            end: Excluded(upper),
            order: q.order,
            limit: q.limit,
        }

    asc : QueryBuilder(doc) -> QueryBuilder(doc)
    asc = |q|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: q.start,
            end: q.end,
            order: Asc,
            limit: q.limit,
        }

    desc : QueryBuilder(doc) -> QueryBuilder(doc)
    desc = |q|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: q.start,
            end: q.end,
            order: Desc,
            limit: q.limit,
        }

    take : QueryBuilder(doc), U64 -> QueryBuilder(doc)
    take = |q, n|
        QueryBuilder.{
            table_name: q.table_name,
            index_name: q.index_name,
            start: q.start,
            end: q.end,
            order: q.order,
            limit: Some(n),
        }

    encode_query_wire : Str, QueryBuilder(doc) -> Str
    encode_query_wire = |ns, q| {
        limit_wire = match q.limit {
            None => "N"
            Some(n) => "L${n.to_str()}:"
        }
        "!1:${Key.len_str(ns)}${Key.len_str(q.table_name)}${Key.len_str(q.index_name)}${Key.bound_to_wire(q.start)}${Key.bound_to_wire(q.end)}${Key.order_to_wire(q.order)}${limit_wire}"
    }

    ## Execute the query against `db` and return the host-serialized JSON array directly
    ## (zero Roc JSON parse/re-encode overhead for pass-through queries).
    collect_raw! : QueryBuilder(doc), Ctx.DbReader => Try(Str, Str)
    collect_raw! = |q, db| {
        req_wire = encode_query_wire(db.namespace, q)
        query_raw! = db.query_raw!
        query_raw!(req_wire)
    }

    ## Execute the query against `db` and decode the matching documents into `List(doc)`.
    collect! : QueryBuilder(doc), Ctx.DbReader => Try(List(doc), Str)
        where [doc.Json.Parseable([InvalidJson(Str)])]
    collect! = |q, db| {
        raw = collect_raw!(q, db)?
        match Json.parse(raw) {
            Ok(docs) => Ok(docs)
            Err(InvalidJson(msg)) => Err("failed to decode query results: ${msg}")
        }
    }

    ## Result of a reactive cursor-paginated query.
    Page(doc) : {
        page : List(doc),
        next_cursor : Str,
        is_done : Bool,
    }

    ## Execute the query with `limit = 1` and return `Found(doc)` or `NotFound`.
    first! : QueryBuilder(doc), Ctx.DbReader => Try([Found(doc), NotFound], Str)
        where [doc.Json.Parseable([InvalidJson(Str)])]
    first! = |qb, db| {
        docs = qb |> take(1) |> collect!(db)?
        match List.first(docs) {
            Ok(d) => Ok(Found(d))
            Err(_) => Ok(NotFound)
        }
    }

    ## Reactive cursor pagination over any indexed query (`cursor == ""` starts from the beginning).
    paginate! : QueryBuilder(doc), Ctx.DbReader, Str, U64 => Try(Page(doc), Str)
        where [doc.Json.Parseable([InvalidJson(Str)])]
    paginate! = |q, db, cursor, page_size| {
        req_wire =
            "!1:${Key.len_str(db.namespace)}${Key.len_str(q.table_name)}${Key.len_str(q.index_name)}${Key.bound_to_wire(q.start)}${Key.bound_to_wire(q.end)}${Key.order_to_wire(q.order)}${Key.len_str(cursor)}${page_size.to_str()}:"
        paginate_raw! = db.paginate_raw!
        raw = paginate_raw!(req_wire)?
        match Json.parse(raw) {
            Ok(res) => Ok(res)
            Err(InvalidJson(msg)) => Err("failed to decode page result: ${msg}")
        }
    }

    ## Reactive case-insensitive multi-token full-text search on a string field of `table`.
    search! : Ctx.DbReader, Table(doc), Str, Str, U64 => Try(List(doc), Str)
        where [doc.Json.Parseable([InvalidJson(Str)])]
    search! = |db, table, field, query_text, limit| {
        req_wire =
            "!1:${Key.len_str(db.namespace)}${Key.len_str(Table.table_name(table))}${Key.len_str(field)}${Key.len_str(query_text)}${limit.to_str()}:"
        search_raw! = db.search_raw!
        raw = search_raw!(req_wire)?
        match Json.parse(raw) {
            Ok(docs) => Ok(docs)
            Err(InvalidJson(msg)) => Err("failed to decode search results: ${msg}")
        }
    }
}
