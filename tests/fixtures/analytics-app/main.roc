app [concave_app] {
    pf: platform "../../../platform/main.roc",
    sdk: "../../../packages/concave-sdk/main.roc",
    analytics: "../../../packages/analytics/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Schema
import sdk.Table
import analytics.Analytics
import analytics.Props

## Two independently mounted Analytics instances proving strict namespace isolation.
product_analytics : Analytics.Mount
product_analytics = Analytics.mount("analytics")

billing_analytics : Analytics.Mount
billing_analytics = Analytics.mount_with("billing_analytics", {
    require_auth_for_admin: True,
    max_batch_size: 2,
})

OrderDoc : {
    id : Str,
    created_at : I64,
    user_id : Str,
    amount : I64,
    free_shipping : Bool,
}

orders_schema : Schema
orders_schema = Schema.record([
    Schema.field("user_id", Schema.str),
    Schema.field("amount", Schema.int),
    Schema.field("free_shipping", Schema.bool),
])

orders_table : Table(OrderDoc)
orders_table = Table.define("orders", orders_schema)

PlaceOrderArgs : {
    amount : I64,
}

PlaceOrderResult : {
    order_id : Str,
    free_shipping : Bool,
}

place_order_args_schema : Schema
place_order_args_schema = Schema.record([
    Schema.field("amount", Schema.int),
])

place_order_result_schema : Schema
place_order_result_schema = Schema.record([
    Schema.field("order_id", Schema.id("orders")),
    Schema.field("free_shipping", Schema.bool),
])

list_orders! : Ctx.QueryCtx, {} => Try(List(OrderDoc), Str)
list_orders! = |ctx, _|
    Db.query(orders_table)
    |> Db.asc()
    |> Db.collect!(ctx.db)

## Demonstrates transactional `Analytics.is_flag_enabled!` + `Analytics.track_event!`
## inside a parent app mutation. If `amount <= 0`, returns `Err` AFTER tracking to prove
## ACID rollback leaves zero ghost analytics events.
place_order! : Ctx.MutationCtx, PlaceOrderArgs => Try(PlaceOrderResult, Str)
place_order! = |ctx, args| {
    user = Ctx.require_auth!(ctx.auth!)?
    free_shipping = Analytics.is_flag_enabled!(
        product_analytics,
        Ctx.as_query_ctx(ctx),
        "free-shipping",
        user.subject,
    )?

    _ = Analytics.track_event!(
        product_analytics,
        ctx,
        user.subject,
        "order_placed",
        [
            Props.prop("amount", args.amount.to_str()),
            Props.prop("free_shipping", if free_shipping { "true" } else { "false" }),
        ],
    )?

    if args.amount <= 0 {
        return Err("Order amount must be positive")
    }

    order_id = Db.insert!(ctx.db, orders_table, {
        user_id: user.subject,
        amount: args.amount,
        free_shipping,
    })?

    Ok({ order_id, free_shipping })
}

concave_app : () -> App
concave_app = ||
    App.new("concave-analytics-test")
    |> App.table(orders_table)
    |> Analytics.attach(product_analytics)
    |> Analytics.attach(billing_analytics)
    |> App.query("orders.list", Schema.record([]), Schema.list(Table.doc_schema(orders_table)), list_orders!)
    |> App.mutation("orders.place", place_order_args_schema, place_order_result_schema, place_order!)
