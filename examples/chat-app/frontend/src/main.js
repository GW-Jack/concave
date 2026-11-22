// Native browser ESM served directly by Concave's zero-dependency Zig host.
// Zero npm, zero node_modules, zero transpiler, zero bundler!
// Full IDE type-checking via JSDoc + generated `.d.ts` files.
// @ts-check

import {
  ConcaveClient,
  computed,
  each,
  effect,
  el,
  mount,
  onCleanup,
  show,
  signal,
} from "/_concave/index.js";
import { createAnalytics, fromProps } from "/_concave/analytics.js";
import { api } from "./_generated/api.js";

/** @typedef {import("./_generated/dataModel.d.ts").Id<"rooms">} RoomId */
/** @typedef {import("./_generated/dataModel.d.ts").Id<"messages">} MessageId */

const SERVER_URL = window.location.origin;

const storedHandle =
  localStorage.getItem("concave_handle") ??
  `user-${Math.floor(100 + Math.random() * 900)}`;

const handleSignal = signal(storedHandle);
/** @type {import("/_concave/index.d.ts").Signal<RoomId | null>} */
const activeRoomId = signal(null);
const draft = signal("");
const newRoomName = signal("");
const newRoomTopic = signal("");
/** @type {import("/_concave/index.d.ts").Signal<string | null>} */
const errorMessage = signal(null);
const previewBusy = signal(false);
const showAnalytics = signal(false);

/** @param {string} handle */
function makeDevToken(handle) {
  const clean = handle.trim() || "guest";
  const slug = clean.toLowerCase().replace(/[^a-z0-9_-]/g, "-") || "guest";
  return `dev:${slug}:${clean}`;
}

const client = new ConcaveClient(SERVER_URL, {
  authToken: makeDevToken(storedHandle),
});
const analytics = createAnalytics(client, api.analytics);

// Seed default rooms & feature flags on boot if the database is empty.
void client.mutate(api.rooms.ensureDefaults, {}).then((rooms) => {
  if (!activeRoomId() && rooms.length > 0) {
    activeRoomId.set(rooms[0].id);
  }
});

// Capture initial `$pageview` once connected.
let pageviewSent = false;
effect(() => {
  if (client.status() === "connected" && !pageviewSent) {
    pageviewSent = true;
    void analytics.capturePageview({ app: "concave-chat" }).catch(() => {});
  }
});

// Identify the signed-in user in Analytics whenever identity changes (links anon_id -> subject).
/** @type {string | null} */
let lastIdentified = null;
effect(() => {
  const ident = client.identity();
  if (!ident || ident.subject === lastIdentified) return;
  lastIdentified = ident.subject;
  void analytics
    .identify(ident.subject, {
      set: { name: ident.name ?? ident.subject },
      setOnce: { first_handle: ident.name ?? ident.subject },
    })
    .catch(() => {});
});

// Track `room_viewed` whenever the user opens a room.
/** @type {string | null} */
let lastTrackedRoom = null;
effect(() => {
  const room = activeRoom();
  const ident = client.identity();
  if (!room || !ident || room.id === lastTrackedRoom) return;
  lastTrackedRoom = room.id;
  void analytics
    .capture("room_viewed", { room_id: room.id, room_name: room.name })
    .catch(() => {});
});

// Reactive queries directly wired to Concave WebSocket `commit_ts` transitions.
const roomsQuery = client.query(api.rooms.list, {});
const messagesQuery = client.query(api.messages.list, () => {
  const id = activeRoomId();
  return id ? { room_id: id } : null;
});
const presenceQuery = client.query(api.presence.listOnline, () => {
  const id = activeRoomId();
  return id ? { room_id: id } : null;
});
const rateLimitQuery = client.query(api.rate_limit.status, () => {
  const id = client.identity();
  return id ? { key: id.subject } : null;
});

// Live reactive Feature Flags (re-evaluates automatically on identity switch OR flag toggle!).
const flagsQuery = analytics.subscribeFlags(
  {},
  () => client.identity()?.subject ?? analytics.distinctId,
);

// Lazy reactive Analytics dashboard queries (only active while the Analytics drawer is open).
const summaryQuery = analytics.subscribeSummary(() =>
  showAnalytics() ? { top_n: 6 } : null,
);
const funnelQuery = analytics.subscribeFunnel(
  ["room_viewed", "message_sent", "link_preview_posted"],
  () => (showAnalytics() ? { conversion_window_ms: 3600000 } : null),
);
const recentEventsQuery = analytics.subscribeRecentEvents(() =>
  showAnalytics() ? { limit: 15 } : null,
);
const flagDefsQuery = client.query(api.analytics.listFlags, () =>
  showAnalytics() ? {} : null,
);

const rooms = computed(() => roomsQuery().data ?? []);
const activeRoom = computed(() => {
  const id = activeRoomId();
  return rooms().find((r) => r.id === id) ?? null;
});
const messages = computed(() => messagesQuery().data ?? []);
const onlineUsers = computed(() => presenceQuery().data ?? []);
const linkPreviewsEnabled = computed(() =>
  analytics.isEnabled(flagsQuery().data, "link-previews", true),
);
const composerCtaVariant = computed(() =>
  analytics.getVariant(flagsQuery().data, "composer-cta", "control"),
);
const topEvents = computed(() => summaryQuery().data?.top_events ?? []);
const funnelSteps = computed(() => funnelQuery().data?.steps ?? []);
const recentEvents = computed(() => recentEventsQuery().data ?? []);
const flagDefs = computed(() => flagDefsQuery().data ?? []);

// Auto-select the first room as soon as rooms arrive.
effect(() => {
  const list = rooms();
  if (!activeRoomId() && list.length > 0) {
    activeRoomId.set(list[0].id);
  }
});

// Presence heartbeat loop for the active room (mounted `presence` component).
effect(() => {
  const roomId = activeRoomId();
  const ident = client.identity();
  if (!roomId || !ident) return;

  /** @param {boolean} typing */
  const beat = (typing) => {
    void client
      .mutate(api.presence.heartbeat, { room_id: roomId, typing })
      .catch(() => {});
  };

  beat(false);
  const timer = setInterval(() => beat(draft().trim().length > 0), 8000);
  onCleanup(() => {
    clearInterval(timer);
    void client.mutate(api.presence.leave, { room_id: roomId }).catch(() => {});
  });
});

/** @type {ReturnType<typeof setTimeout> | null} */
let typingTimeout = null;
/** @param {boolean} isTyping */
function notifyTyping(isTyping) {
  const roomId = activeRoomId();
  if (!roomId || !client.identity()) return;
  void client
    .mutate(api.presence.heartbeat, { room_id: roomId, typing: isTyping })
    .catch(() => {});
}

/** @param {Event} ev */
async function handleSend(ev) {
  ev.preventDefault();
  errorMessage.set(null);
  const roomId = activeRoomId();
  const text = draft().trim();
  if (!roomId || !text) return;

  // Support `/preview https://...` slash command invoking the external HTTP Action!
  if (text.startsWith("/preview ")) {
    const url = text.slice("/preview ".length).trim();
    if (!url) return;
    draft.set("");
    previewBusy.set(true);
    try {
      await client.action(api.messages.fetchPreview, { room_id: roomId, url });
    } catch (err) {
      errorMessage.set(err instanceof Error ? err.message : String(err));
    } finally {
      previewBusy.set(false);
    }
    return;
  }

  const authorName = client.identity()?.name ?? handleSignal();
  const authorId = client.identity()?.subject ?? "me";
  draft.set("");
  notifyTyping(false);

  try {
    await client.mutate(
      api.messages.send,
      { room_id: roomId, body: text },
      {
        optimisticUpdate: (store) => {
          const current =
            store.getQuery(api.messages.list, { room_id: roomId }) ?? [];
          store.setQuery(api.messages.list, { room_id: roomId }, [
            ...current,
            {
              id: /** @type {MessageId} */ (`optimistic-${Date.now()}`),
              created_at: Date.now(),
              room_id: roomId,
              author_id: authorId,
              author_name: authorName,
              body: text,
              kind: "optimistic",
            },
          ]);
        },
      },
    );
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
  }
}

/** @param {Event} ev */
async function handleCreateRoom(ev) {
  ev.preventDefault();
  errorMessage.set(null);
  const name = newRoomName().trim();
  if (!name) return;
  try {
    const id = await client.mutate(api.rooms.create, {
      name,
      topic: newRoomTopic().trim() || "Reactive Concave room",
    });
    newRoomName.set("");
    newRoomTopic.set("");
    activeRoomId.set(id);
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
  }
}

/** @param {Event} ev */
function applyHandle(ev) {
  ev.preventDefault();
  const next = handleSignal().trim() || "guest";
  localStorage.setItem("concave_handle", next);
  client.setAuth(makeDevToken(next));
}

/** @param {number} ms */
function formatTime(ms) {
  return new Date(ms).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/** @param {import("/_concave/analytics.js").FeatureFlagDoc} flag */
async function toggleFlag(flag) {
  try {
    await analytics.upsertFlag({
      key: flag.key,
      name: flag.name,
      active: !flag.active,
      rollout_pct: flag.rollout_pct,
      filters: flag.filters,
      variants: flag.variants,
    });
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
  }
}

function AnalyticsPanel() {
  return el(
    "aside",
    { class: "analytics-panel" },
    el(
      "div",
      { class: "analytics-header" },
      el("h3", null, "Live Analytics"),
      el("span", { class: "badge connected" }, "reactive"),
    ),
    el(
      "div",
      { class: "kpi-grid" },
      el(
        "div",
        { class: "kpi-card" },
        el("div", { class: "kpi-label" }, "Events (24h)"),
        el("div", { class: "kpi-value" }, () =>
          String(summaryQuery().data?.total_events ?? 0),
        ),
      ),
      el(
        "div",
        { class: "kpi-card" },
        el("div", { class: "kpi-label" }, "Persons"),
        el("div", { class: "kpi-value" }, () =>
          String(summaryQuery().data?.unique_persons ?? 0),
        ),
      ),
      el(
        "div",
        { class: "kpi-card" },
        el("div", { class: "kpi-label" }, "Sessions"),
        el("div", { class: "kpi-value" }, () =>
          String(summaryQuery().data?.active_sessions ?? 0),
        ),
      ),
    ),
    el(
      "div",
      { class: "analytics-section" },
      el("div", { class: "section-title" }, "Feature Flags & Experiments"),
      each(
        flagDefs,
        (f) => f.key,
        (flag) =>
          el(
            "div",
            { class: "flag-row" },
            el(
              "div",
              { class: "flag-info" },
              el("div", { class: "flag-key" }, () => flag().key),
              el("div", { class: "flag-meta" }, () => {
                const evals = flagsQuery().data;
                const v = analytics.getVariant(evals, flag().key, "off");
                return `${flag().name} · you: ${v}`;
              }),
            ),
            el(
              "button",
              {
                class: () => `flag-toggle ${flag().active ? "on" : "off"}`,
                type: "button",
                onClick: () => void toggleFlag(flag()),
              },
              () => (flag().active ? "ON" : "OFF"),
            ),
          ),
      ),
    ),
    el(
      "div",
      { class: "analytics-section" },
      el("div", { class: "section-title" }, "Conversion Funnel"),
      each(
        funnelSteps,
        (s) => s.event,
        (step) =>
          el(
            "div",
            { class: "funnel-row" },
            el(
              "div",
              { class: "funnel-head" },
              el("span", { class: "mono" }, () => `${step().step_index + 1}. ${step().event}`),
              el(
                "span",
                { class: "mono muted" },
                () =>
                  `${step().count} (${Math.round(step().conversion_rate_from_start * 100)}%)`,
              ),
            ),
            el(
              "div",
              { class: "bar-track" },
              el("div", {
                class: "bar-fill",
                style: () =>
                  `width: ${Math.max(4, Math.round(step().conversion_rate_from_start * 100))}%`,
              }),
            ),
          ),
      ),
    ),
    el(
      "div",
      { class: "analytics-section" },
      el("div", { class: "section-title" }, "Top Events"),
      each(
        topEvents,
        (e) => e.event,
        (ev) =>
          el(
            "div",
            { class: "top-event-row" },
            el("span", { class: "mono" }, () => ev().event),
            el(
              "span",
              { class: "mono muted" },
              () => `${ev().count} (${ev().unique_persons}u)`,
            ),
          ),
      ),
    ),
    el(
      "div",
      { class: "analytics-section" },
      el("div", { class: "section-title" }, "Live Event Stream"),
      el(
        "div",
        { class: "event-stream" },
        each(
          recentEvents,
          (e) => e.id,
          (ev) =>
            el(
              "div",
              { class: "event-row" },
              el(
                "div",
                { class: "event-head" },
                el("span", { class: "event-name" }, () => ev().event),
                el("span", { class: "event-time" }, () =>
                  formatTime(ev().timestamp_ms),
                ),
              ),
              el("div", { class: "event-sub" }, () => {
                const props = fromProps(ev().properties);
                const summary = Object.entries(props)
                  .slice(0, 2)
                  .map(([k, v]) => `${k}=${v}`)
                  .join(" · ");
                return summary
                  ? `${ev().distinct_id} · ${summary}`
                  : ev().distinct_id;
              }),
            ),
        ),
      ),
    ),
  );
}

function AppView() {
  return el(
    "div",
    { class: () => `layout ${showAnalytics() ? "with-analytics" : ""}` },
    el(
      "aside",
      { class: "sidebar" },
      el(
        "div",
        { class: "brand" },
        el("h1", null, "Concave"),
        el(
          "span",
          {
            class: () => `badge ${client.status()}`,
          },
          () => `${client.status()} · ts:${client.commitTs()}`,
        ),
      ),
      el(
        "form",
        { class: "identity-box", onSubmit: applyHandle },
        el("div", { class: "section-title" }, "Identity (ctx.auth!)"),
        el("input", {
          class: "input",
          value: () => handleSignal(),
          placeholder: "Your handle",
          onInput: (/** @type {Event} */ e) =>
            handleSignal.set(/** @type {HTMLInputElement} */ (e.target).value),
        }),
        el(
          "button",
          { class: "btn secondary", type: "submit" },
          "Switch Identity",
        ),
      ),
      el(
        "div",
        { class: "room-list" },
        el("div", { class: "section-title" }, "Rooms (index-isolated)"),
        each(
          rooms,
          (r) => r.id,
          (room) =>
            el(
              "button",
              {
                class: () =>
                  `room-btn ${activeRoomId() === room().id ? "active" : ""}`,
                onClick: () => {
                  errorMessage.set(null);
                  activeRoomId.set(room().id);
                },
              },
              () => `# ${room().name}`,
            ),
        ),
      ),
      el(
        "form",
        { class: "new-room-form", onSubmit: handleCreateRoom },
        el("div", { class: "section-title" }, "New Room"),
        el("input", {
          class: "input",
          placeholder: "room-name",
          value: () => newRoomName(),
          onInput: (/** @type {Event} */ e) =>
            newRoomName.set(/** @type {HTMLInputElement} */ (e.target).value),
        }),
        el("input", {
          class: "input",
          placeholder: "topic (optional)",
          value: () => newRoomTopic(),
          onInput: (/** @type {Event} */ e) =>
            newRoomTopic.set(/** @type {HTMLInputElement} */ (e.target).value),
        }),
        el("button", { class: "btn", type: "submit" }, "Create Room"),
      ),
    ),
    el(
      "main",
      { class: "main" },
      el(
        "header",
        { class: "topbar" },
        el(
          "div",
          null,
          el("h2", { class: "room-title" }, () => {
            const r = activeRoom();
            return r ? `# ${r.name}` : "Loading rooms...";
          }),
          el("p", { class: "room-topic" }, () => activeRoom()?.topic ?? ""),
        ),
        el(
          "div",
          { class: "topbar-meta" },
          el("span", { class: "badge" }, () => {
            const rl = rateLimitQuery().data;
            return rl ? `quota: ${rl.remaining} msgs left` : "quota: --";
          }),
          el("span", { class: "badge" }, () => {
            const ident = client.identity();
            return ident ? `as ${ident.name ?? ident.subject}` : "unauthenticated";
          }),
          el(
            "button",
            {
              class: () => `btn secondary toggle-analytics ${showAnalytics() ? "active" : ""}`,
              type: "button",
              onClick: () => showAnalytics.set(!showAnalytics()),
            },
            () => (showAnalytics() ? "Hide Analytics" : "Analytics"),
          ),
        ),
      ),
      el(
        "div",
        { class: "presence-bar" },
        el("span", null, "Online here:"),
        each(
          onlineUsers,
          (u) => u.user_id,
          (u) =>
            el(
              "span",
              { class: "presence-pill" },
              el("span", { class: "dot" }),
              () =>
                u().typing ? `${u().user_name} (typing...)` : u().user_name,
            ),
        ),
      ),
      el(
        "section",
        { class: "messages" },
        each(
          messages,
          (m) => m.id,
          (m) =>
            el(
              "article",
              { class: () => `msg ${m().kind}` },
              el(
                "div",
                { class: "msg-head" },
                el("span", { class: "msg-author" }, () => m().author_name),
                el("span", { class: "msg-time" }, () =>
                  m().kind === "optimistic"
                    ? "sending..."
                    : formatTime(m().created_at),
                ),
              ),
              el("div", { class: "msg-body" }, () => m().body),
            ),
        ),
      ),
      show(errorMessage, (err) => el("div", { class: "error-banner" }, err)),
      el(
        "form",
        { class: "composer", onSubmit: handleSend },
        el("input", {
          class: "input",
          placeholder: () =>
            linkPreviewsEnabled()
              ? "Type a message, or `/preview https://example.com` to run an external Action..."
              : "Type a message (/preview disabled by feature flag)...",
          value: () => draft(),
          disabled: () => previewBusy(),
          onInput: (/** @type {Event} */ e) => {
            const val = /** @type {HTMLInputElement} */ (e.target).value;
            draft.set(val);
            notifyTyping(val.trim().length > 0);
            if (typingTimeout) clearTimeout(typingTimeout);
            typingTimeout = setTimeout(() => notifyTyping(false), 2500);
          },
        }),
        el(
          "button",
          { class: "btn", type: "submit", disabled: () => previewBusy() },
          () => {
            if (previewBusy()) return "Fetching...";
            return composerCtaVariant() === "rocket" ? "Send 🚀" : "Send";
          },
        ),
      ),
    ),
    show(showAnalytics, () => AnalyticsPanel()),
  );
}

const root = document.getElementById("app");
if (root) {
  mount(root, AppView);
}
