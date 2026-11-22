// Strict TypeScript served directly by Concave's Rust server (`oxc` on-the-fly TS stripping).
// Zero npm, zero node_modules, zero bundler!

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
} from "/_concave/index.ts";
import { api } from "./_generated/api.ts";
import type { Id } from "./_generated/dataModel.ts";

const SERVER_URL = window.location.origin;

const storedHandle =
  localStorage.getItem("concave_handle") ??
  `user-${Math.floor(100 + Math.random() * 900)}`;

const handleSignal = signal(storedHandle);
const activeRoomId = signal<Id<"rooms"> | null>(null);
const draft = signal("");
const newRoomName = signal("");
const newRoomTopic = signal("");
const errorMessage = signal<string | null>(null);
const previewBusy = signal(false);

function makeDevToken(handle: string): string {
  const clean = handle.trim() || "guest";
  const slug = clean.toLowerCase().replace(/[^a-z0-9_-]/g, "-") || "guest";
  return `dev:${slug}:${clean}`;
}

const client = new ConcaveClient(SERVER_URL, {
  authToken: makeDevToken(storedHandle),
});

// Seed default rooms on boot if the database is empty.
void client.mutate(api.rooms.ensureDefaults, {}).then((rooms) => {
  if (!activeRoomId() && rooms.length > 0) {
    activeRoomId.set(rooms[0].id);
  }
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

const rooms = computed(() => roomsQuery().data ?? []);
const activeRoom = computed(() => {
  const id = activeRoomId();
  return rooms().find((r) => r.id === id) ?? null;
});
const messages = computed(() => messagesQuery().data ?? []);
const onlineUsers = computed(() => presenceQuery().data ?? []);

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

  const beat = (typing: boolean) => {
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

let typingTimeout: ReturnType<typeof setTimeout> | null = null;
function notifyTyping(isTyping: boolean): void {
  const roomId = activeRoomId();
  if (!roomId || !client.identity()) return;
  void client
    .mutate(api.presence.heartbeat, { room_id: roomId, typing: isTyping })
    .catch(() => {});
}

async function handleSend(ev: Event): Promise<void> {
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
              id: `optimistic-${Date.now()}` as Id<"messages">,
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

async function handleCreateRoom(ev: Event): Promise<void> {
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

function applyHandle(ev: Event): void {
  ev.preventDefault();
  const next = handleSignal().trim() || "guest";
  localStorage.setItem("concave_handle", next);
  client.setAuth(makeDevToken(next));
}

function formatTime(ms: number): string {
  return new Date(ms).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function AppView() {
  return el(
    "div",
    { class: "layout" },
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
          onInput: (e: Event) =>
            handleSignal.set((e.target as HTMLInputElement).value),
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
          onInput: (e: Event) =>
            newRoomName.set((e.target as HTMLInputElement).value),
        }),
        el("input", {
          class: "input",
          placeholder: "topic (optional)",
          value: () => newRoomTopic(),
          onInput: (e: Event) =>
            newRoomTopic.set((e.target as HTMLInputElement).value),
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
          el("h2", { class: "room-title" }, () =>
            activeRoom() ? `# ${activeRoom()!.name}` : "Loading rooms...",
          ),
          el("p", { class: "room-topic" }, () => activeRoom()?.topic ?? ""),
        ),
        el(
          "div",
          { class: "topbar-meta" },
          el("span", { class: "badge" }, () => {
            const rl = rateLimitQuery().data;
            return rl ? `quota: ${rl.remaining} msgs left` : "quota: --";
          }),
          el("span", { class: "badge" }, () =>
            client.identity()
              ? `as ${client.identity()!.name ?? client.identity()!.subject}`
              : "unauthenticated",
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
          placeholder:
            "Type a message, or `/preview https://example.com` to run an external Action...",
          value: () => draft(),
          disabled: () => previewBusy(),
          onInput: (e: Event) => {
            const val = (e.target as HTMLInputElement).value;
            draft.set(val);
            notifyTyping(val.trim().length > 0);
            if (typingTimeout) clearTimeout(typingTimeout);
            typingTimeout = setTimeout(() => notifyTyping(false), 2500);
          },
        }),
        el(
          "button",
          { class: "btn", type: "submit", disabled: () => previewBusy() },
          () => (previewBusy() ? "Fetching..." : "Send"),
        ),
      ),
    ),
  );
}

const root = document.getElementById("app");
if (root) {
  mount(root, AppView);
}
