# Browser Client & Signals SDK (`/_concave/index.js`)

Concave ships a bespoke, **zero-dependency** native browser ESM runtime embedded directly inside every compiled server binary at `/_concave/index.js` — no `npm`, no `node_modules`, no bundler, and no Virtual DOM.

Companion `.d.ts` declarations (`client/concave-client/src/*.d.ts`) work alongside `--introspect` generated `_generated/{api.js,api.d.ts,dataModel.d.ts}` so editors (VS Code, `tsc --noEmit` with `checkJs: true`) give full end-to-end autocomplete and type checking on plain `.js` files.

---

## Connecting with `ConcaveClient`

```js
import { ConcaveClient } from "/_concave/index.js";
import { api } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin, {
  authToken: "dev:alice:Alice", // optional; or call client.setAuth(...) later
});
```

`ConcaveClient` accepts either an `http(s)://` origin (automatically upgraded to `ws(s)://.../ws`) or an explicit `ws(s)://.../ws` URL.

### Reactive Client Signals
- `client.status()` — `"connecting" | "connected" | "reconnecting" | "closed"`
- `client.commitTs()` — latest authoritative `commit_ts` applied to the client
- `client.identity()` — current authenticated `AuthIdentity | null`

### Authentication
```js
client.setAuth("Bearer eyJhbGciOiJSUzI1NiIs..."); // JWT (HS256, RS256, EdDSA, ES256)
client.setAuth("dev:alice:Alice Smith");           // Dev mode only
client.setAuth(null);                              // Sign out & re-evaluate subscriptions
```

---

## Reactive Queries (`client.query`)

Pass either a static args object or a **reactive accessor function** `() => args`:

```js
import { signal } from "/_concave/index.js";

const activeRoom = signal("general");

// Automatically resubscribes whenever `activeRoom()` changes.
// Returning `null` or `undefined` pauses the subscription cleanly.
const messages = client.query(api.messages.list, () => ({
  room_id: activeRoom(),
}));

// Read reactive state anywhere inside `computed`, `effect`, or DOM bindings:
// messages() -> { status: "loading" | "ready" | "error", data, error }
```

- All subscriptions updated by the same backend commit advance **atomically** in a single `batch()` (`transition { to_ts, updates }`), preventing torn UI states.
- Call `messages.dispose()` when tearing down outside a `createRoot` scope (inside `createRoot` / `mount`, cleanup is automatic).

---

## Mutations & Optimistic Updates (`client.mutate`)

```js
await client.mutate(
  api.messages.send,
  { room_id: activeRoom(), body: "Hello!" },
  {
    optimisticUpdate(store) {
      const args = { room_id: activeRoom() };
      const prev = store.getQuery(api.messages.list, args) ?? [];
      store.setQuery(api.messages.list, args, [
        ...prev,
        { id: "optimistic", created_at: Date.now(), room_id: args.room_id, body: "Hello!" },
      ]);
    },
  },
);
```

Optimistic overlays are applied immediately, automatically reconciled once the server transition reaches `to_ts >= commit_ts`, and rolled back cleanly on mutation error or WebSocket disconnect.

## Actions (`client.action`)

```js
const preview = await client.action(api.links.preview, { url: "https://example.com" });
```

---

## Fine-Grained Signals (`signals.js`)

Glitch-free push-pull topological reactivity (formally verified in `specs/maude/signals.maude`):

| Primitive | Description |
| --- | --- |
| `signal(initial, equals?)` | Writable reactive cell: `s()`, `s.set(v)`, `s.update(fn)`, `s.peek()`. |
| `computed(fn, equals?)` | Lazily evaluated, diamond-glitch-free derived signal. |
| `effect(fn)` | Re-runs when tracked dependencies change; return a cleanup fn or call `onCleanup`. Returns `dispose`. |
| `batch(fn)` | Coalesces multiple signal writes into a single atomic downstream flush. |
| `untrack(fn)` | Reads signals inside `fn` without creating dependencies. |
| `createRoot(fn)` | Creates an ownership scope; calling `dispose()` cleans up all nested effects & queries. |
| `onCleanup(fn)` | Registers a teardown hook on the current `effect` or `createRoot`. |

---

## Surgical DOM Helpers (`dom.js`)

Zero Virtual DOM — updates only the exact text node, attribute, or keyed list item that changed:

```js
import { el, each, show, mount } from "/_concave/index.js";

const dispose = mount(document.getElementById("root"), () =>
  el("main", { class: "app" },
    el("h1", null, () => `Connected (${client.status()})`),
    show(
      () => messages().status === "ready",
      () =>
        el("ul", null,
          each(
            () => messages().data ?? [],
            (msg) => msg.id,
            (msg) => el("li", null, () => msg().body),
          ),
        ),
      () => el("p", null, "Loading messages…"),
    ),
  ),
);
```

- `el(tag, props, ...children)`: Any prop or child may be a reactive accessor `() => value`; event handlers use `onClick`, `onInput`, `onSubmit`, etc.
- `each(itemsAccessor, keyFn, renderItem)`: Keyed list reconciliation preserving DOM node identity across inserts, deletes, and reorders, and disposing removed item roots automatically.
- `show(whenAccessor, renderThen, renderElse?)`: Conditional reactive branch with automatic root cleanup.
- `mount(container, renderRoot)`: Mounts into `container` inside a `createRoot` and returns `dispose`.

---

## Embedded Component Clients

In addition to `/_concave/index.js`, the Zig host embeds optional component helpers:
- **`/_concave/analytics.js`** — PostHog-style `createAnalytics(client, api.analytics)` helper (see [ANALYTICS.md](ANALYTICS.md)).
- **`/_concave/monitor.js`** — Browser/Node error & metric capture helper (see [OBSERVABILITY.md](OBSERVABILITY.md)).
