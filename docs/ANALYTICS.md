# PostHog-Style Analytics Component (`packages/analytics`)

`packages/analytics` is a reusable, zero-dependency pure-Roc **Product Analytics & Feature Flags** component for Concave, modeled after PostHog.

All tables (`events`, `persons`, `aliases`, `feature_flags`) live inside the mounted component's host-enforced namespace, while executing inside your application's exact same ACID transactions and pushing real-time WebSocket updates to every insight and feature-flag subscriber.

## Mounting & Attaching in Roc

```roc
app [concave_app] {
    pf: platform "./platform/main.roc",
    sdk: "./packages/concave-sdk/main.roc",
    analytics: "./packages/analytics/main.roc",
}

import sdk.App
import sdk.Ctx
import analytics.Analytics
import analytics.Props

analytics : Analytics.Mount
analytics = Analytics.mount("analytics")

# Optional custom configuration:
# analytics = Analytics.mount_with("analytics", {
#     require_auth_for_admin: True,
#     max_batch_size: 100,
# })

concave_app : () -> App
concave_app = ||
    App.new("my-app")
    |> Analytics.attach(analytics)
```

## Transactional Server-Side Helpers

Call `Analytics.track_event!`, `Analytics.track!`, `Analytics.identify_in_tx!`, or `Analytics.is_flag_enabled!` inside your own mutations and queries:

```roc
place_order! : Ctx.MutationCtx, PlaceOrderArgs => Try(Str, Str)
place_order! = |ctx, args| {
    user = Ctx.require_auth!(ctx.auth!)?
    free_shipping = Analytics.is_flag_enabled!(
        analytics,
        Ctx.as_query_ctx(ctx),
        "free-shipping",
        user.subject,
    )?

    # Committed atomically with the order — rolls back automatically if this mutation returns `Err`!
    _ = Analytics.track_event!(analytics, ctx, user.subject, "order_placed", [
        Props.prop("amount", args.amount.to_str()),
        Props.prop("free_shipping", if free_shipping { "true" } else { "false" }),
    ])?

    Db.insert!(ctx.db, orders_table, { user_id: user.subject, amount: args.amount, free_shipping })
}
```

## Attached Endpoints (`<ns>.*`)

### Mutations
- `<ns>.capture` — Capture a single event (auto-resolves aliases and updates person activity counters).
- `<ns>.captureBatch` — Atomically capture a batch of events (bounded by `max_batch_size`).
- `<ns>.identify` — Link an optional `anon_id` to a canonical `distinct_id`, merge anonymous profile history, and apply PostHog `$set` / `$set_once` person properties.
- `<ns>.alias` — Explicitly alias `alias_id -> distinct_id` (cycle-protected).
- `<ns>.upsertFlag` — Create or update a feature flag or multivariate A/B experiment (kill switch, 0–100% deterministic rollout, property targeting filters, weighted variants).
- `<ns>.deleteFlag` — Delete a feature flag by `key`.
- `<ns>.evaluateFlagAndTrack` — Evaluate a flag and atomically record a `$feature_flag_called` exposure event.

### Reactive Queries (Live WebSocket Subscriptions)
- `<ns>.recentEvents` — Live event stream (optionally scoped to a single `event` name for surgical ReadSet reactivity).
- `<ns>.personEvents` — Unified chronological event timeline across a person's canonical ID and all linked aliases.
- `<ns>.sessionEvents` — Chronological event timeline for a `session_id`.
- `<ns>.groupEvents` — Event timeline for a B2B group (`group_type`, `group_key`).
- `<ns>.getPerson` / `<ns>.listPersons` — Person profiles with properties, aliases, and event counts.
- `<ns>.listFlags` — All configured feature flags.
- `<ns>.evaluateFlag` / `<ns>.evaluateAllFlags` — Reactive feature flag evaluation (toggling a flag pushes updates to connected browsers over WebSockets).
- `<ns>.summary` — Real-time overview KPIs (`total_events`, `unique_persons`, `active_sessions`, `top_events`).
- `<ns>.trends` — Time-bucketed event counts & unique persons with optional property breakdown and property filters.
- `<ns>.funnel` — Ordered multi-step conversion funnel with conversion window, step/overall conversion rates, and average time-to-convert.
- `<ns>.retention` — Cohort retention matrix (`cohort_event`, `return_event`, `period_ms`, `num_periods`; pass `from_ms < 0` to default to the trailing window).

## Optional Browser / Node Client Helper (`packages/analytics/client.js`)

```js
import { ConcaveClient } from "/_concave/index.js";
import { api } from "./_generated/api.js";
import { createAnalytics } from "./packages/analytics/client.js";

const client = new ConcaveClient(window.location.origin);
const posthog = createAnalytics(client, api.analytics);

await posthog.capturePageview();
await posthog.identify("alice", {
  set: { email: "alice@acme.io", plan: "pro" },
  setOnce: { initial_referrer: "hn" },
});
await posthog.capture("message_sent", { room_id: "general" });

// Reactive feature flags signal (updates live when flags change):
const flags = posthog.subscribeFlags();
```

## Property Filter Operators

Supported `op` values in `Props.Filter`:
`eq`, `neq`, `contains`, `not_contains`, `is_set`, `is_not_set`, `in` (comma-separated), `not_in` (comma-separated).
