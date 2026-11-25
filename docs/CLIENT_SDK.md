# Browser Client & Signals SDK (`/_concave/index.js`)

Concave ships a bespoke, **zero-dependency** native browser ESM runtime — bundled, minified, and pre-gzipped at build time into **1 single ~10 KB gzipped request** at `/_concave/index.js` (including binary WebSocket framing, proactive JWT refresh, glitch-free signals, surgical DOM helpers, and a reactive SPA router, with strong `ETag` / `304` caching) — no `npm`, no `node_modules`, no bundler, and no Virtual DOM.

Companion `.d.ts` declarations (`client/concave-client/src/*.d.ts`) work alongside `--introspect` generated `_generated/{api.js,api.d.ts,dataModel.d.ts}` so editors (VS Code, `tsc --noEmit` with `checkJs: true`) give full end-to-end autocomplete and type checking on plain `.js` files.

---

## Connecting with `ConcaveClient` & `createApi`

```js
import { ConcaveClient } from "/_concave/index.js";
import { createApi } from "./_generated/api.js";

const client = new ConcaveClient(window.location.origin, {
  authToken: "dev:alice:Alice", // optional; or call client.setAuth(...) later
});
const db = createApi(client);
```

`ConcaveClient` accepts either an `http(s)://` origin (automatically upgraded to `ws(s)://.../ws`) or an explicit `ws(s)://.../ws` URL.

`createApi(client)` wraps your generated `api` tree so every query, mutation, and action is directly callable with full end-to-end TypeScript inference (`db.rooms.list()`, `db.messages.send(...)`, `db.rooms.list.once()`), while still exposing `.ref` and keeping the raw `api` export available.

### Dev Live Reload
When running `concave dev --static-dir ...`, the server automatically enables `--live-reload`, watches `--static-dir`, sets `Cache-Control: no-cache` on static files, and pushes WebSocket `{ type: "reload", reason }` frames on edit:
- **CSS-only edits** hot-swap `<link rel="stylesheet">` tags in place without losing DOM/form state.
- **JS/HTML edits** reload the page automatically.
- Configure or disable per client via `new ConcaveClient(url, { liveReload: false })` or `{ onReload(ev) { ... } }`.

### Reactive Client Signals
- `client.status()` — `"connecting" | "connected" | "reconnecting" | "closed"`
- `client.commitTs()` — latest authoritative `commit_ts` applied to the client
- `client.identity()` — current authenticated `AuthIdentity | null`
- `client.isAuthenticated()` — reactive `boolean` (`true` while `client.identity() !== null`)

### Authentication & Proactive JWT Refresh
```js
client.setAuth("Bearer eyJhbGciOiJSUzI1NiIs..."); // JWT (HS256, RS256, EdDSA, ES256)
client.setAuth("dev:alice:Alice Smith");           // Dev mode only
client.setAuth(null);                              // Sign out & re-evaluate subscriptions
client.getToken();                                 // Current raw token string or null
```

For short-lived JWTs (such as `packages/auth`, Clerk, Auth0, or Supabase), configure a `fetchToken` callback either in the constructor or via `client.setTokenFetcher(...)`:

```js
const client = new ConcaveClient(window.location.origin, {
  fetchToken: async ({ forceRefresh }) => {
    // Return a fresh JWT string (or null when signed out).
    return await getJwt({ forceRefresh });
  },
  refreshMarginMs: 30_000, // default: refresh 30s before JWT `exp`
});

// Or attach/clear dynamically at runtime:
client.setTokenFetcher(async ({ forceRefresh }) => ...);
client.setTokenFetcher(null);
```

- **Proactive refresh**: `ConcaveClient` decodes the JWT `exp` claim locally and schedules a background refresh `refreshMarginMs` (default `30_000` ms, minimum `1_000` ms) before expiration, plus retries once with `{ forceRefresh: true }` if the server rejects an expired token.
- **Zero-flicker same-user rotation**: When a refreshed JWT has the same `(sub, iss)` pair as the previous token, `ConcaveClient` re-authenticates the WebSocket in place while **preserving live query caches and optimistic overlays** (switching users or signing out still resets cached subscription state cleanly).

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
// messages() -> { status: "paused" | "loading" | "ready" | "error", data, error }
// When the args accessor returns `null` or `undefined`, status becomes `"paused"`.
```

- All subscriptions updated by the same backend commit advance **atomically** in a single `batch()` (`transition { to_ts, updates }`), preventing torn UI states.
- Call `messages.dispose()` when tearing down outside a `createRoot` scope (inside `createRoot` / `mount`, cleanup is automatic).

---

## Mutations & Optimistic Updates (`client.mutate` / `optimisticAppend`)

```js
// Shorthand for appending to a live list query:
await db.messages.send(
  { room_id: activeRoom(), body: "Hello!" },
  client.optimisticAppend(db.messages.list, { room_id: activeRoom() }, {
    id: "optimistic",
    created_at: Date.now(),
    room_id: activeRoom(),
    body: "Hello!",
  }),
);

// Or write a custom optimistic reducer:
await db.messages.send(
  { room_id: activeRoom(), body: "Hello!" },
  {
    optimisticUpdate(store) {
      const args = { room_id: activeRoom() };
      const prev = store.getQuery(db.messages.list, args) ?? [];
      store.setQuery(db.messages.list, args, [...prev, nextItem]);
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
import { bindValue, each, mount, show, tags } from "/_concave/index.js";

const { button, form, h1, input, li, main, p, ul } = tags;

const dispose = mount(document.getElementById("root"), () =>
  main({ class: "app" },
    h1(() => `Connected (${client.status()})`),
    show(
      () => messages().status === "ready",
      () =>
        ul(
          each(
            () => messages().data ?? [],
            (msg) => msg.id,
            (msg) => li(() => msg().body),
          ),
        ),
      () => p("Loading messages…"),
    ),
    form({ onSubmit },
      input({ placeholder: "Say hi…", ...bindValue(draft) }),
      button({ type: "submit" }, "Send"),
    ),
  ),
);
```

- `el(tag, props, ...children)`: Core element constructor. Any prop or child may be a reactive accessor `() => value`; event handlers use `onClick`, `onInput`, `onSubmit`, etc.
- `tags`: Proxy providing shorthand element builders (`const { div, button, input } = tags`) where the `props` object is optional (`div("hi")` or `div({ class: "card" }, "hi")`).
- `bindValue(sig, onInput?)` / `bindChecked(sig, onChange?)`: Two-way binding prop helpers for inputs/checkboxes (`input({ ...bindValue(draft) })`).
- `each(itemsAccessor, keyFn, renderItem)`: Keyed list reconciliation preserving DOM node identity across inserts, deletes, and reorders, and disposing removed item roots automatically.
- `show(whenAccessor, renderThen, renderElse?)`: Conditional reactive branch with automatic root cleanup.
- `mount(container, renderRoot)`: Mounts into `container` inside a `createRoot` and returns `dispose`.

---

## Reactive SPA Router (`/_concave/router.js` & `/_concave/index.js`)

Concave includes a zero-dependency reactive History API router re-exported from `/_concave/index.js` (and also available standalone at `/_concave/router.js`):

```js
import { createRouter, matchRoute, mount, show, tags } from "/_concave/index.js";

const { div, h1, nav, p } = tags;

const router = createRouter([
  { path: "/", name: "home" },
  { path: "/rooms/:id", name: "room" },
  { path: "/files/*", name: "files" },
]);

mount(document.getElementById("app"), () =>
  div(
    nav(
      router.link("/", "Home"),
      " · ",
      router.link("/rooms/general", { class: "nav-link" }, "General"),
    ),
    () => {
      const m = router.current();
      if (!m.route) return p("Not Found");
      if (m.route.name === "room") return h1(`Room: ${m.params.id}`);
      return h1("Home");
    },
  ),
);
```

- `createRouter(routes, { initialPath? })` returns `{ path, query, current, navigate, link, dispose }`:
  - `path`: reactive `Signal<string>` of the current pathname.
  - `query`: reactive `Signal<Record<string, string>>` of decoded URL query parameters (prototype-pollution safe).
  - `current`: reactive `Accessor<{ route, params, path, query }>` matching the first route whose pattern matches `path()`.
  - `navigate(to, { replace? })`: pushes/replaces browser history and updates `path`/`query` atomically in a `batch()`. Rejects non-relative or protocol-relative paths (`//...`).
  - `link(to, props?, ...children)`: creates an `<a>` element that intercepts plain left-clicks for SPA navigation while preserving Cmd/Ctrl-click, middle-click, and `target="_blank"`.
  - `dispose()`: detaches the `window` `popstate` listener.
- `matchRoute(pattern, pathname)`: pure helper supporting static segments, `:param` captures, and trailing `*` wildcards; returns `Record<string, string> | null`.

---

## Embedded Component Clients

In addition to `/_concave/index.js` and `/_concave/router.js`, the Zig host embeds optional component helpers:
- **`/_concave/auth.js`** — Auth v2 `createAuth(client, api.auth, options?)` controller with automatic `fetchToken` refresh wiring, live `sessionStatus` auto sign-out across tabs, password/OTP helpers, and `oauthUrl` / `consumeOAuthFragment` (see [AUTH.md](AUTH.md)).
- **`/_concave/analytics.js`** — PostHog-style `createAnalytics(client, api.analytics)` helper (see [ANALYTICS.md](ANALYTICS.md)).
- **`/_concave/monitor.js`** — Browser/Node error & metric capture helper (see [OBSERVABILITY.md](OBSERVABILITY.md)).
