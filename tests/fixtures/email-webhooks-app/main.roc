app [concave_app] {
    pf: platform "../../../platform/main.roc",
    sdk: "../../../packages/concave-sdk/main.roc",
    email: "../../../packages/email/main.roc",
    webhooks: "../../../packages/webhooks/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Schema
import sdk.Table
import email.Email
import webhooks.Webhooks

app_email : Email.Mount
app_email =
    Email.mount("email")
    |> Email.with_webhook_provider("http://127.0.0.1:13298/email", "EMAIL_API_KEY")
    |> Email.with_default_from("orders@concave.test")
    |> Email.with_max_attempts(4)
    |> Email.with_base_backoff_ms(50)

app_webhooks : Webhooks.Mount
app_webhooks =
    Webhooks.mount("webhooks")
    |> Webhooks.with_signing_secret("WEBHOOK_SIGNING_SECRET")
    |> Webhooks.with_max_attempts(4)
    |> Webhooks.with_base_backoff_ms(50)

OrderDoc : {
    id : Str,
    created_at : I64,
    customer_email : Str,
    amount_cents : I64,
    idempotency_key : Str,
}

orders_schema : Schema
orders_schema = Schema.record([
    Schema.field("customer_email", Schema.str),
    Schema.field("amount_cents", Schema.int),
    Schema.field("idempotency_key", Schema.str),
])

orders_table : Table(OrderDoc)
orders_table = Table.define("orders", orders_schema)

CreateOrderArgs : {
    customer_email : Str,
    amount_cents : I64,
    idempotency_key : Str,
}

create_order_args_schema : Schema
create_order_args_schema = Schema.record([
    Schema.field("customer_email", Schema.str),
    Schema.field("amount_cents", Schema.int),
    Schema.field("idempotency_key", Schema.str),
])

CreateOrderResult : {
    order_id : Str,
    email_id : Str,
    delivery_ids : List(Str),
}

create_order_result_schema : Schema
create_order_result_schema = Schema.record([
    Schema.field("order_id", Schema.id("orders")),
    Schema.field("email_id", Schema.scoped_id("email", "email_messages")),
    Schema.field("delivery_ids", Schema.list(Schema.scoped_id("webhooks", "webhooks_deliveries"))),
])

orders_create! : Ctx.MutationCtx, CreateOrderArgs => Try(CreateOrderResult, Str)
orders_create! = |ctx, args| {
    new_order : { customer_email : Str, amount_cents : I64, idempotency_key : Str }
    new_order = {
        customer_email: args.customer_email,
        amount_cents: args.amount_cents,
        idempotency_key: args.idempotency_key,
    }
    order_id = Db.insert!(ctx.db, orders_table, new_order)?

    email_id = Email.enqueue!(app_email, ctx, {
        to: args.customer_email,
        subject: "Order ${order_id} confirmed",
        html: "<p>Order ${order_id} for ${args.amount_cents.to_str()} cents</p>",
        text: "Order ${order_id} for ${args.amount_cents.to_str()} cents",
        idempotency_key: args.idempotency_key,
    })?

    payload_json =
        "{\"order_id\":${Json.to_str(order_id)},\"customer_email\":${Json.to_str(args.customer_email)},\"amount_cents\":${args.amount_cents.to_str()}}"

    delivery_ids = Webhooks.dispatch!(app_webhooks, ctx, "order.created", payload_json)?

    Ok({
        order_id,
        email_id,
        delivery_ids,
    })
}

orders_list! : Ctx.QueryCtx, {} => Try(List(OrderDoc), Str)
orders_list! = |ctx, _|
    Db.query(orders_table)
    |> Db.asc()
    |> Db.collect!(ctx.db)

inbound_webhook! : Ctx.ActionCtx, App.HttpRouteRequest => Try(App.HttpRouteResponse, Str)
inbound_webhook! = |ctx, req| {
    sig_header = match App.header_value(req, "x-concave-signature") {
        Ok(v) => v
        Err(NotFound) =>
            return Ok({
                status: 401,
                content_type: "application/json",
                body: "{\"verified\":false,\"error\":\"missing X-Concave-Signature header\"}",
            })
    }

    secret = Ctx.secret_get!(ctx, "WEBHOOK_SIGNING_SECRET")?

    match Webhooks.verify_signature!(ctx, secret, sig_header, req.body, 300) {
        Ok({}) =>
            Ok({
                status: 200,
                content_type: "application/json",
                body: "{\"verified\":true,\"bytes\":${Str.count_utf8_bytes(req.body).to_str()}}",
            })
        Err(err_msg) =>
            Ok({
                status: 401,
                content_type: "application/json",
                body: "{\"verified\":false,\"error\":${Json.to_str(err_msg)}}",
            })
    }
}

concave_app : () -> App
concave_app = ||
    App.new("email-webhooks-test")
    |> App.with_secret("WEBHOOK_SIGNING_SECRET")
    |> App.table(orders_table)
    |> Email.attach(app_email)
    |> Webhooks.attach(app_webhooks)
    |> App.mutation("orders.create", create_order_args_schema, create_order_result_schema, orders_create!)
    |> App.query("orders.list", Schema.record([]), Schema.list(Table.doc_schema(orders_table)), orders_list!)
    |> App.http_route("POST", "/webhooks/inbound", inbound_webhook!)
