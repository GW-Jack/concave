// Native browser ESM served directly by Concave's zero-dependency Zig host.
// Zero npm, zero node_modules, zero transpiler, zero bundler!
// Full IDE type-checking via JSDoc + generated `.d.ts` files.
// @ts-check

import {
  ConcaveClient,
  bindValue,
  computed,
  each,
  effect,
  el,
  mount,
  onCleanup,
  show,
  signal,
  tags,
} from "/_concave/index.js";
import { createAnalytics, fromProps } from "/_concave/analytics.js";
import { createMonitor } from "/_concave/monitor.js";
import { api, createApi } from "./_generated/api.js";

const { article, aside, button, div, form, h1, h2, header, input, main, p, section, span } = tags;

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
/** @type {import("/_concave/index.d.ts").Signal<"none" | "analytics" | "monitor">} */
const activeDrawer = signal("none");
const showAnalytics = computed(() => activeDrawer() === "analytics");
const showMonitor = computed(() => activeDrawer() === "monitor");
const logSearchQuery = signal("");

/** @param {string} handle */
function makeDevToken(handle) {
  const clean = handle.trim() || "guest";
  const slug = clean.toLowerCase().replace(/[^a-z0-9_-]/g, "-") || "guest";
  return `dev:${slug}:${clean}`;
}

const client = new ConcaveClient(SERVER_URL, {
  authToken: makeDevToken(storedHandle),
});
const db = createApi(client);
const analytics = createAnalytics(client, api.analytics);
const monitor = createMonitor(client, api.monitor, {
  service: "chat-web",
  release: "v1.0.0",
  environment: "dev",
  captureGlobalErrors: true,
});

// Seed default rooms & feature flags on boot if the database is empty.
void db.rooms.ensureDefaults().then((rooms) => {
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
  monitor.addBreadcrumb("navigation", `Opened #${room.name}`);
});

// Reactive queries directly wired to Concave WebSocket `commit_ts` transitions.
const roomsQuery = db.rooms.list();
const messagesQuery = db.messages.list(() => {
  const id = activeRoomId();
  return id ? { room_id: id } : null;
});
const presenceQuery = db.presence.listOnline(() => {
  const id = activeRoomId();
  return id ? { room_id: id } : null;
});
const rateLimitQuery = db.rate_limit.status(() => {
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

// Lazy reactive Monitor dashboard queries (only active while the Monitor drawer is open).
const monitorOverviewQuery = monitor.subscribeOverview(() =>
  showMonitor() ? { window_ms: 3600000, top_n: 5 } : null,
);
const monitorIssuesQuery = monitor.subscribeIssues(() =>
  showMonitor() ? { limit: 15 } : null,
);
const monitorAlertsQuery = client.query(api.monitor.listAlertRules, () =>
  showMonitor() ? {} : null,
);
const monitorLogsQuery = monitor.subscribeLogs(() =>
  showMonitor() && logSearchQuery().trim().length === 0 ? { limit: 15 } : null,
);
const monitorSearchLogsQuery = monitor.subscribeSearchLogs(() => {
  if (!showMonitor()) return null;
  const q = logSearchQuery().trim();
  return q.length > 0 ? q : null;
}, 15);

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
const monitorIssues = computed(() => monitorIssuesQuery().data ?? []);
const monitorAlerts = computed(() => monitorAlertsQuery().data ?? []);
const monitorVisibleLogs = computed(() =>
  logSearchQuery().trim().length > 0
    ? (monitorSearchLogsQuery().data ?? [])
    : (monitorLogsQuery().data ?? []),
);

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
    void db.presence.heartbeat({ room_id: roomId, typing }).catch(() => {});
  };

  beat(false);
  const timer = setInterval(() => beat(draft().trim().length > 0), 8000);
  onCleanup(() => {
    clearInterval(timer);
    void db.presence.leave({ room_id: roomId }).catch(() => {});
  });
});

/** @type {ReturnType<typeof setTimeout> | null} */
let typingTimeout = null;
/** @param {boolean} isTyping */
function notifyTyping(isTyping) {
  const roomId = activeRoomId();
  if (!roomId || !client.identity()) return;
  void db.presence.heartbeat({ room_id: roomId, typing: isTyping }).catch(() => {});
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
      await db.messages.fetchPreview({ room_id: roomId, url });
    } catch (err) {
      errorMessage.set(err instanceof Error ? err.message : String(err));
      void monitor.captureException(err, { source: "chat-web", attrs: { action: "preview", url } }).catch(() => {});
    } finally {
      previewBusy.set(false);
    }
    return;
  }

  const authorName = client.identity()?.name ?? handleSignal();
  const authorId = client.identity()?.subject ?? "me";
  draft.set("");
  notifyTyping(false);
  monitor.addBreadcrumb("chat", `Sent message in ${roomId}`);

  try {
    await db.messages.send(
      { room_id: roomId, body: text },
      client.optimisticAppend(db.messages.list, { room_id: roomId }, {
        id: /** @type {MessageId} */ (`optimistic-${Date.now()}`),
        created_at: Date.now(),
        room_id: roomId,
        author_id: authorId,
        author_name: authorName,
        body: text,
        kind: "optimistic",
      }),
    );
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
    void monitor.captureException(err, { source: "chat-web", attrs: { action: "send", room_id: roomId } }).catch(() => {});
  }
}

/** @param {Event} ev */
async function handleCreateRoom(ev) {
  ev.preventDefault();
  errorMessage.set(null);
  const name = newRoomName().trim();
  if (!name) return;
  try {
    const id = await db.rooms.create({
      name,
      topic: newRoomTopic().trim() || "Reactive Concave room",
    });
    newRoomName.set("");
    newRoomTopic.set("");
    activeRoomId.set(id);
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
    void monitor.captureException(err, { source: "chat-web", attrs: { action: "create_room", name } }).catch(() => {});
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

/** @param {import("/_concave/monitor.js").IssueDoc} issue */
async function toggleIssueStatus(issue) {
  try {
    const next = issue.status === "resolved" ? "open" : "resolved";
    await monitor.updateIssueStatus(issue.id, next);
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
  }
}

async function simulateSampleError() {
  try {
    const reqId = Math.floor(1000 + Math.random() * 9000);
    await monitor.captureException(
      new Error(`Delivery retry failed for message ${reqId} in room ${activeRoom()?.name ?? "general"}`),
      {
        source: "chat-web",
        errorType: "DeliveryError",
        attrs: { room: activeRoom()?.name ?? "general" },
      },
    );
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
  }
}

async function evaluateChatAlerts() {
  try {
    await monitor.evaluateAlerts();
  } catch (err) {
    errorMessage.set(err instanceof Error ? err.message : String(err));
  }
}

function MonitorPanel() {
  return el(
    "aside",
    { class: "analytics-panel" },
    el(
      "div",
      { class: "analytics-header" },
      el("h3", null, "App Monitor"),
      el("span", { class: "badge connected" }, "reactive"),
    ),
    el(
      "div",
      { class: "kpi-grid" },
      el(
        "div",
        { class: "kpi-card" },
        el("div", { class: "kpi-label" }, "Open Issues"),
        el("div", { class: "kpi-value" }, () =>
          String(monitorOverviewQuery().data?.open_issues ?? 0),
        ),
      ),
      el(
        "div",
        { class: "kpi-card" },
        el("div", { class: "kpi-label" }, "Errors (1h)"),
        el("div", { class: "kpi-value" }, () =>
          String(monitorOverviewQuery().data?.error_logs_in_window ?? 0),
        ),
      ),
      el(
        "div",
        { class: "kpi-card" },
        el("div", { class: "kpi-label" }, "Firing Alerts"),
        el("div", { class: "kpi-value" }, () =>
          String(monitorOverviewQuery().data?.firing_alerts ?? 0),
        ),
      ),
    ),
    el(
      "div",
      { class: "monitor-actions" },
      el(
        "button",
        {
          class: "btn secondary",
          type: "button",
          onClick: () => void simulateSampleError(),
        },
        "Simulate Error",
      ),
      el(
        "button",
        {
          class: "btn secondary",
          type: "button",
          onClick: () => void evaluateChatAlerts(),
        },
        "Evaluate Alerts",
      ),
    ),
    el(
      "div",
      { class: "analytics-section" },
      el("div", { class: "section-title" }, "Grouped Issues (Sentry-style)"),
      each(
        monitorIssues,
        (i) => i.id,
        (issue) =>
          el(
            "div",
            { class: "flag-row" },
            el(
              "div",
              { class: "flag-info" },
              el("div", { class: "flag-key issue-title" }, () => issue().title),
              el(
                "div",
                { class: "flag-meta" },
                () =>
                  `${issue().source} · ×${issue().count} · ${issue().status}`,
              ),
            ),
            el(
              "button",
              {
                class: () =>
                  `flag-toggle ${issue().status === "resolved" ? "on" : "off"}`,
                type: "button",
                onClick: () => void toggleIssueStatus(issue()),
              },
              () => (issue().status === "resolved" ? "REOPEN" : "RESOLVE"),
            ),
          ),
      ),
    ),
    el(
      "div",
      { class: "analytics-section" },
      el("div", { class: "section-title" }, "Alert Rules"),
      each(
        monitorAlerts,
        (r) => r.key,
        (rule) =>
          el(
            "div",
            { class: "flag-row" },
            el(
              "div",
              { class: "flag-info" },
              el("div", { class: "flag-key" }, () => rule().name),
              el(
                "div",
                { class: "flag-meta" },
                () =>
                  `val=${rule().last_value} ${rule().op} ${rule().threshold}`,
              ),
            ),
            el(
              "span",
              {
                class: () => `alert-pill ${rule().status}`,
              },
              () => rule().status.toUpperCase(),
            ),
          ),
      ),
    ),
    el(
      "div",
      { class: "analytics-section" },
      el("div", { class: "section-title" }, "Live Logs & Search (Db.search!)"),
      el("input", {
        class: "input",
        placeholder: "Full-text search logs...",
        value: () => logSearchQuery(),
        onInput: (/** @type {Event} */ e) =>
          logSearchQuery.set(/** @type {HTMLInputElement} */ (e.target).value),
      }),
      el(
        "div",
        { class: "event-stream" },
        each(
          monitorVisibleLogs,
          (l) => l.id,
          (entry) =>
            el(
              "div",
              { class: "event-row" },
              el(
                "div",
                { class: "event-head" },
                el(
                  "span",
                  { class: () => `log-level ${entry().level}` },
                  () => `${entry().level.toUpperCase()} · ${entry().service}`,
                ),
                el("span", { class: "event-time" }, () =>
                  formatTime(entry().timestamp_ms),
                ),
              ),
              el("div", { class: "event-sub" }, () => entry().message),
            ),
        ),
      ),
    ),
  );
}

function AppView() {
  return div(
    { class: () => `layout ${activeDrawer() !== "none" ? "with-analytics" : ""}` },
    aside(
      { class: "sidebar" },
      div(
        { class: "brand" },
        h1("Concave"),
        span(
          { class: () => `badge ${client.status()}` },
          () => `${client.status()} · ts:${client.commitTs()}`,
        ),
      ),
      form(
        { class: "identity-box", onSubmit: applyHandle },
        div({ class: "section-title" }, "Identity (ctx.auth!)"),
        input({
          class: "input",
          placeholder: "Your handle",
          ...bindValue(handleSignal),
        }),
        button({ class: "btn secondary", type: "submit" }, "Switch Identity"),
      ),
      div(
        { class: "room-list" },
        div({ class: "section-title" }, "Rooms (index-isolated)"),
        each(
          rooms,
          (r) => r.id,
          (room) =>
            button(
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
      form(
        { class: "new-room-form", onSubmit: handleCreateRoom },
        div({ class: "section-title" }, "New Room"),
        input({
          class: "input",
          placeholder: "room-name",
          ...bindValue(newRoomName),
        }),
        input({
          class: "input",
          placeholder: "topic (optional)",
          ...bindValue(newRoomTopic),
        }),
        button({ class: "btn", type: "submit" }, "Create Room"),
      ),
    ),
    main(
      { class: "main" },
      header(
        { class: "topbar" },
        div(
          h2({ class: "room-title" }, () => {
            const r = activeRoom();
            return r ? `# ${r.name}` : "Loading rooms...";
          }),
          p({ class: "room-topic" }, () => activeRoom()?.topic ?? ""),
        ),
        div(
          { class: "topbar-meta" },
          span({ class: "badge" }, () => {
            const rl = rateLimitQuery().data;
            return rl ? `quota: ${rl.remaining} msgs left` : "quota: --";
          }),
          span({ class: "badge" }, () => {
            const ident = client.identity();
            return ident ? `as ${ident.name ?? ident.subject}` : "unauthenticated";
          }),
          button(
            {
              class: () => `btn secondary toggle-analytics ${showAnalytics() ? "active" : ""}`,
              type: "button",
              onClick: () =>
                activeDrawer.set(showAnalytics() ? "none" : "analytics"),
            },
            () => (showAnalytics() ? "Hide Analytics" : "Analytics"),
          ),
          button(
            {
              class: () => `btn secondary toggle-analytics ${showMonitor() ? "active" : ""}`,
              type: "button",
              onClick: () =>
                activeDrawer.set(showMonitor() ? "none" : "monitor"),
            },
            () => (showMonitor() ? "Hide Monitor" : "Monitor"),
          ),
        ),
      ),
      div(
        { class: "presence-bar" },
        span("Online here:"),
        each(
          onlineUsers,
          (u) => u.user_id,
          (u) =>
            span(
              { class: "presence-pill" },
              span({ class: "dot" }),
              () =>
                u().typing ? `${u().user_name} (typing...)` : u().user_name,
            ),
        ),
      ),
      section(
        { class: "messages" },
        each(
          messages,
          (m) => m.id,
          (m) =>
            article(
              { class: () => `msg ${m().kind}` },
              div(
                { class: "msg-head" },
                span({ class: "msg-author" }, () => m().author_name),
                span({ class: "msg-time" }, () =>
                  m().kind === "optimistic"
                    ? "sending..."
                    : formatTime(m().created_at),
                ),
              ),
              div({ class: "msg-body" }, () => m().body),
            ),
        ),
      ),
      show(errorMessage, (err) => div({ class: "error-banner" }, err)),
      form(
        { class: "composer", onSubmit: handleSend },
        input({
          class: "input",
          placeholder: () =>
            linkPreviewsEnabled()
              ? "Type a message, or `/preview https://example.com` to run an external Action..."
              : "Type a message (/preview disabled by feature flag)...",
          disabled: () => previewBusy(),
          ...bindValue(draft, (val) => {
            notifyTyping(val.trim().length > 0);
            if (typingTimeout) clearTimeout(typingTimeout);
            typingTimeout = setTimeout(() => notifyTyping(false), 2500);
          }),
        }),
        button(
          { class: "btn", type: "submit", disabled: () => previewBusy() },
          () => {
            if (previewBusy()) return "Fetching...";
            return composerCtaVariant() === "rocket" ? "Send 🚀" : "Send";
          },
        ),
      ),
    ),
    show(showAnalytics, () => AnalyticsPanel()),
    show(showMonitor, () => MonitorPanel()),
  );
}

const root = document.getElementById("app");
if (root) {
  mount(root, AppView);
}
