app [concave_app] {
    pf: platform "../../../platform/main.roc",
    sdk: "../../../packages/concave-sdk/main.roc",
    migrations: "../../../packages/migrations/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Schema
import sdk.Table
import migrations.Migrations

UserDoc : {
    id : Str,
    created_at : I64,
    name : Str,
    role : Str,
    migrated : Bool,
}

users_schema : Schema
users_schema = Schema.record([
    Schema.field("name", Schema.str),
    Schema.field("role", Schema.str),
    Schema.field("migrated", Schema.bool),
])

users_table : Table(UserDoc)
users_table =
    Table.define("users", users_schema)
    |> Table.with_index("by_role", ["role"])

SeedUserArgs : {
    name : Str,
    role : Str,
    migrated : Bool,
}

seed_user_args_schema : Schema
seed_user_args_schema = Schema.record([
    Schema.field("name", Schema.str),
    Schema.field("role", Schema.str),
    Schema.field("migrated", Schema.bool),
])

users_seed! : Ctx.MutationCtx, SeedUserArgs => Try(Str, Str)
users_seed! = |ctx, args|
    Db.insert!(ctx.db, users_table, {
        name: args.name,
        role: args.role,
        migrated: args.migrated,
    })

users_list! : Ctx.QueryCtx, {} => Try(List(UserDoc), Str)
users_list! = |ctx, _|
    Db.query(users_table)
    |> Db.asc()
    |> Db.collect!(ctx.db)

backfill_user_role! : Ctx.MutationCtx, UserDoc => Try({}, Str)
backfill_user_role! = |ctx, user|
    if user.migrated {
        Ok({})
    } else {
        Db.patch!(ctx.db, users_table, user.id, {
            role: "member",
            migrated: Bool.True,
        })
    }

app_migrations : Migrations.Mount
app_migrations =
    Migrations.mount("migrations")
    |> Migrations.register(
        "backfill_user_roles",
        Migrations.table_migration(users_table, backfill_user_role!),
    )

concave_app : () -> App
concave_app = ||
    App.new("migrations-test")
    |> App.table(users_table)
    |> Migrations.attach(app_migrations)
    |> App.mutation("users.seed", seed_user_args_schema, Schema.id("users"), users_seed!)
    |> App.query("users.list", Schema.record([]), Schema.list(Table.doc_schema(users_table)), users_list!)
