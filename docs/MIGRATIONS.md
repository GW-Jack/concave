# Resumable Batched Migrations (`packages/migrations`)

`packages/migrations` is a zero-dependency pure-Roc **Resumable Batched Data Migrations** component for Concave.

It stores migration run state (`migration_runs`) in an isolated component namespace (default `"migrations"`) and executes each cursor-paginated batch inside its own ACID OCC transaction via Concave's transactional scheduler (`Ctx.run_after!`), so large table backfills never time out, block live traffic, or lose progress across restarts or replica rollouts.

---

## Mounting & Registering Migrations in Roc

```roc
app [concave_app] {
    pf: platform "./platform/main.roc",
    sdk: "./packages/concave-sdk/main.roc",
    migrations: "./packages/migrations/main.roc",
}

import sdk.App
import sdk.Ctx
import sdk.Db
import sdk.Schema
import sdk.Table
import migrations.Migrations

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
    |> Migrations.with_admin_roles(["admin", "ops"])
    |> Migrations.with_default_batch_size(100)
    |> Migrations.register(
        "backfill_user_roles",
        Migrations.table_migration(users_table, backfill_user_role!),
    )

concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> App.table(users_table)
    |> Migrations.attach(app_migrations)
```

### Builder API

| Function | Default | Description |
| --- | --- | --- |
| `Migrations.mount(namespace)` | `"migrations"` | Mount an isolated instance owning the `migration_runs` table (`by_name`, `by_status` indexes). |
| `Migrations.with_admin_roles(m, roles)` | `["admin"]` | Roles permitted to call `status`, `get`, `start`, and `cancel` (checked via `Ctx.has_any_role`). Pass `[]` to allow any authenticated user. |
| `Migrations.with_require_auth(m, req)` | `True` | Toggle authentication requirement on admin migration endpoints. Keep `True` in production. |
| `Migrations.with_default_batch_size(m, size)` | `100` | Default batch size when `start` is called with `batch_size <= 0`. Clamped to `[1, 500]`. |
| `Migrations.register(m, name, batch_fn!)` | — | Register a named migration with a custom batch step `(Ctx.MutationCtx, Str, U64 => Try(Migrations.BatchStepResult, Str))`. |
| `Migrations.table_migration(table, transform_doc!)` | — | Ergonomic helper that paginates `table` in ascending `created_at` order and runs `transform_doc!(ctx, doc)` on each document in the batch. |
| `Migrations.attach(app, m)` | — | Attaches the component table, public admin endpoints (`status`, `get`, `start`, `cancel`), and internal root-scoped batch runner (`_runBatch`). |

---

## Custom Batch Steps

For multi-table transforms, custom index scans, or filtered backfills, pass a custom `batch_fn!` to `Migrations.register`:

```roc
custom_step! : Ctx.MutationCtx, Str, U64 => Try(Migrations.BatchStepResult, Str)
custom_step! = |ctx, cursor, batch_size| {
    page =
        Db.from_index(orders_by_status)
        |> Db.eq([Key.str("legacy")])
        |> Db.asc()
        |> Db.paginate!(Ctx.as_reader(ctx.db), cursor, batch_size)?

    var $processed = 0.I64
    for order in page.page {
        Db.patch!(ctx.db, orders_table, order.id, { status: "archived" })?
        $processed = $processed + 1
    }

    Ok({
        processed: $processed,
        next_cursor: page.next_cursor,
        is_done: page.is_done,
    })
}
```

- `batch_fn!` receives the **root app's** `Ctx.MutationCtx`, the opaque cursor (`""` on the first batch), and the clamped `batch_size` (`U64` in `1..=500`).
- Each batch commits its document mutations, cursor advance (`migration_runs.cursor`), progress counters (`processed_count`, `batches_run`), and the next scheduled `Ctx.run_after!(ctx, 0, "<ns>._runBatch", ...)` job in a **single ACID transaction**.
- If a batch returns `is_done: False` without advancing `next_cursor`, the runner marks the migration `"failed"` with `"cursor did not advance"` to prevent infinite loops.

---

## Attached Endpoints (`<ns>.*`)

All public endpoints enforce admin auth/role checks by default.

### Queries (Live-Subscribable over WebSockets)
- **`<ns>.status`** (`{}`) -> `List(MigrationRunDoc)` — Lists all registered migrations (synthesizing `"idle"` entries for migrations that haven't run yet) plus any historical run records. Subscribe from an admin UI or `/_dashboard` to watch `processed_count` and `batches_run` stream live.
- **`<ns>.get`** (`{ name }`) -> `MigrationStatusResult` — Detailed status for a single migration (`found`, `registered`, `id`, `name`, `status`, `cursor`, `processed_count`, `batch_size`, `batches_run`, `started_at_ms`, `completed_at_ms`, `last_error`).

### Mutations
- **`<ns>.start`** (`{ name, batch_size, dry_run, force }`) -> `{ run_id, name, status, batch_size, dry_run, job_id }`
  - `batch_size`: Pass `0` to use `default_batch_size` (clamped to `[1, 500]`).
  - `dry_run`: When `True`, wraps `ctx` in a side-effect-free context where reads hit live data while `Db.insert!`/`patch!`/`replace!`/`delete!`, `ctx.scheduler`, and `ctx.storage` writes become no-ops — letting you verify row counts and logic safely before mutating production data.
  - `force`: Idempotency guard (see below).
- **`<ns>.cancel`** (`{ name }`) -> `Bool`
  - Marks a `"running"` migration as `"canceled"`. The next scheduled `_runBatch` invocation observes `status != "running"` and stops cleanly without executing further batches.

### Internal Mutation (Blocked on Public HTTP/WS)
- **`<ns>._runBatch`** — Root-scoped `App.internal_mutation` invoked exclusively by Concave's transactional job scheduler.

---

## State Machine & Idempotency

| Current Status | `start(..., force: false)` | `start(..., force: true)` |
| --- | --- | --- |
| `"idle"` / `"failed"` / `"canceled"` | Allowed (starts from cursor `""`) | Allowed |
| `"completed"` | Rejected (`"migration already completed; pass force: true to re-run"`) | Allowed |
| `"running"` | Rejected (`"migration is already running; cancel it before restarting"`) | Rejected (cancel first) |

Always write per-document transform functions idempotently (e.g. checking a sentinel field before patching) so re-running after a partial failure or with `force: true` is completely safe.

---

## Schema Compatibility Checks & PostgreSQL Index Backfills

Alongside data migrations, Concave's Zig host provides built-in schema safety and index maintenance:

1. **Startup Schema Checks (`CONCAVE_STRICT_MIGRATIONS`)**:
   - On startup, Concave compares the compiled binary's `AppManifest` against previously persisted schema metadata.
   - Set `CONCAVE_STRICT_MIGRATIONS=true` in CI or production to fail fast on incompatible schema changes instead of merely warning.
2. **PostgreSQL Secondary Index Backfills (`--backfill-indexes`)**:
   - Embedded `WalStore` rebuilds secondary indexes automatically on startup.
   - When adding a new `Table.with_index(...)` to an existing PostgreSQL deployment (`DATABASE_URL`), run the compiled server binary once with `--backfill-indexes` before routing traffic to queries that depend on the new index:

```sh
DATABASE_URL="postgres://..." ./my-server --backfill-indexes
```

The command scans existing documents for all declared tables and component namespaces, populates missing secondary index rows in PostgreSQL, prints the backfilled count, and exits cleanly.
