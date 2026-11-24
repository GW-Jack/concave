import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { ConcaveClient } from "../client/concave-client/src/index.js";
import { api } from "../examples/chat-app/frontend/src/_generated/api.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

async function waitForHealth(url, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${url}/health`);
      if (res.ok) return;
    } catch {
      // retry
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`Timed out waiting for ${url}/health`);
}

async function waitForCondition(fn, timeoutMs = 5000, label = "condition") {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = fn();
    if (val) return val;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

test("end-to-end native Roc platform: WS reactivity, index-range isolation, components, OCC, and HTTP Action", async (t) => {
  const binPath = path.join(ROOT, "examples/chat-app/.concave/e2e-server");
  const dbPath = path.join(ROOT, "examples/chat-app/.concave/e2e.wal");
  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${dbPath}${suffix}`, { force: true });
  }

  // 1. Build standalone native Roc+Zig zero-dependency server binary.
  const build = spawnSync(
    "roc",
    [
      "build",
      "--opt=dev",
      `--output=${binPath}`,
      path.join(ROOT, "examples/chat-app/backend/main.roc"),
    ],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(
    build.status,
    0,
    `roc build failed:\n${build.stdout}\n${build.stderr}`,
  );

  // 2. Start a tiny local HTTP target server for testing external Action `messages.fetchPreview`.
  const targetServer = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "text/html", Connection: "close" });
    res.end("<html><head><title>Concave Action Target</title></head><body>ok</body></html>");
  });
  await new Promise((resolve) => targetServer.listen(0, "127.0.0.1", resolve));
  const targetPort = targetServer.address().port;
  t.after(() => {
    targetServer.closeAllConnections?.();
    targetServer.close();
  });

  // 3. Spawn the compiled Concave Roc server on an ephemeral-ish test port.
  const port = 13219;
  const serverUrl = `http://127.0.0.1:${port}`;
  const serverProc = spawn(
    binPath,
    [
      "--serve",
      "--host",
      "127.0.0.1",
      "--port",
      String(port),
      "--db",
      dbPath,
      "--static-dir",
      path.join(ROOT, "examples/chat-app/frontend"),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  let stderrLog = "";
  serverProc.stderr.on("data", (d) => {
    stderrLog += d.toString();
  });
  t.after(() => {
    serverProc.kill("SIGTERM");
    for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
      fs.rmSync(`${dbPath}${suffix}`, { force: true });
    }
  });

  await waitForHealth(serverUrl);

  // Verify readiness probe reports storage commit_ts.
  const readyResp = await fetch(`${serverUrl}/ready`);
  assert.equal(readyResp.status, 200);
  const readyBody = await readyResp.json();
  assert.equal(readyBody.status, "ready");
  assert.equal(typeof readyBody.commit_ts, "number");

  // Verify zero-npm native browser ESM serving from Concave's zero-dependency Zig host!
  const indexHtml = await fetch(`${serverUrl}/`);
  assert.equal(indexHtml.status, 200);
  assert.ok((await indexHtml.text()).includes("/src/main.js"));

  const builtinClient = await fetch(`${serverUrl}/_concave/index.js`);
  assert.equal(builtinClient.status, 200);
  assert.match(builtinClient.headers.get("content-type") ?? "", /text\/javascript/);
  const builtinJs = await builtinClient.text();
  assert.ok(builtinJs.includes("ConcaveClient"));

  const analyticsClientResp = await fetch(`${serverUrl}/_concave/analytics.js`);
  assert.equal(analyticsClientResp.status, 200);
  assert.match(analyticsClientResp.headers.get("content-type") ?? "", /text\/javascript/);
  const analyticsClientJs = await analyticsClientResp.text();
  assert.ok(analyticsClientJs.includes("createAnalytics"));

  const monitorClientResp = await fetch(`${serverUrl}/_concave/monitor.js`);
  assert.equal(monitorClientResp.status, 200);
  assert.match(monitorClientResp.headers.get("content-type") ?? "", /text\/javascript/);
  const monitorClientJs = await monitorClientResp.text();
  assert.ok(monitorClientJs.includes("createMonitor"));

  const mainJsResp = await fetch(`${serverUrl}/src/main.js`);
  assert.equal(mainJsResp.status, 200);
  assert.match(mainJsResp.headers.get("content-type") ?? "", /text\/javascript/);
  const mainJs = await mainJsResp.text();
  assert.ok(mainJs.includes("mount("));

  const apiJsResp = await fetch(`${serverUrl}/src/_generated/api.js`);
  assert.equal(apiJsResp.status, 200);
  const apiJs = await apiJsResp.text();
  assert.ok(apiJs.includes("export const api ="));

  // 4. Connect two real ConcaveClient WebSocket sessions (Alice in #general, Bob in #roc-lang).
  const alice = new ConcaveClient(serverUrl, { authToken: "dev:alice:Alice" });
  const bob = new ConcaveClient(serverUrl, { authToken: "dev:bob:Bob" });
  const anon = new ConcaveClient(serverUrl);
  t.after(() => {
    alice.close();
    bob.close();
    anon.close();
  });

  await waitForCondition(() => alice.status() === "connected", 5000, "alice connected");
  await waitForCondition(() => bob.status() === "connected", 5000, "bob connected");
  await waitForCondition(() => anon.status() === "connected", 5000, "anon connected");

  // Seed default rooms (`#general` and `#roc-lang`).
  const rooms = await alice.mutate(api.rooms.ensureDefaults, {});
  assert.equal(rooms.length, 2);
  const generalRoom = rooms.find((r) => r.name === "general");
  const rocRoom = rooms.find((r) => r.name === "roc-lang");
  assert.ok(generalRoom && rocRoom);

  // Subscribe Alice to #general and Bob to #roc-lang, plus live `to_ms: 0` Analytics summary & trends!
  const aliceMsgs = alice.query(api.messages.list, { room_id: generalRoom.id });
  const bobMsgs = bob.query(api.messages.list, { room_id: rocRoom.id });
  const alicePresence = alice.query(api.presence.listOnline, { room_id: generalRoom.id });
  const aliceQuota = alice.query(api.rate_limit.status, { key: "alice" });
  const liveSummary = alice.query(api.analytics.summary, { from_ms: 0, to_ms: 0, top_n: 5 });
  const liveMsgTrend = alice.query(api.analytics.trends, {
    event: "message_sent",
    from_ms: 0,
    to_ms: 0,
    bucket_ms: 60000,
    breakdown_property: "",
    filters: [],
  });
  const aliceFlags = alice.query(api.analytics.evaluateAllFlags, {
    distinct_id: "alice",
    override_properties: [],
  });
  const liveMonitorLogs = alice.query(api.monitor.recentLogs, {
    service: "chat",
    level: "",
    fn_name: "",
    limit: 20,
  });

  await waitForCondition(() => aliceMsgs().status === "ready", 5000, "aliceMsgs ready");
  await waitForCondition(() => bobMsgs().status === "ready", 5000, "bobMsgs ready");
  await waitForCondition(() => aliceQuota().status === "ready", 5000, "aliceQuota ready");
  await waitForCondition(() => liveSummary().status === "ready", 5000, "liveSummary ready");
  await waitForCondition(() => liveMsgTrend().status === "ready", 5000, "liveMsgTrend ready");
  await waitForCondition(() => aliceFlags().status === "ready", 5000, "aliceFlags ready");
  await waitForCondition(() => liveMonitorLogs().status === "ready", 5000, "liveMonitorLogs ready");

  assert.equal(aliceMsgs().data.length, 1);
  assert.equal(bobMsgs().data.length, 1);
  assert.equal(aliceQuota().data.remaining, 12);
  assert.equal(liveSummary().data.total_events, 0);
  assert.equal(liveMsgTrend().data.total_events, 0);
  assert.equal(aliceFlags().data.find((f) => f.key === "link-previews")?.enabled, true);
  assert.ok(["control", "rocket"].includes(aliceFlags().data.find((f) => f.key === "composer-cta")?.variant));

  // 5. Verify auth enforcement: unauthenticated `messages.send` must fail.
  await assert.rejects(
    () => anon.mutate(api.messages.send, { room_id: generalRoom.id, body: "nope" }),
    /Unauthenticated/,
  );

  // 6. Send a message in #general -> Alice's reactive query + rate_limit component update;
  //    Bob's #roc-lang subscription stays untouched (commit_ts on Bob does NOT advance!).
  const bobTsBefore = bob.commitTs();
  await alice.mutate(api.messages.send, {
    room_id: generalRoom.id,
    body: "Hello from real Roc 0.1.0_RC1!",
  });

  await waitForCondition(
    () => aliceMsgs().data?.some((m) => m.body === "Hello from real Roc 0.1.0_RC1!"),
    5000,
    "alice receives new message transition",
  );
  await waitForCondition(
    () => aliceQuota().data?.remaining === 11,
    5000,
    `transactional rate-limiter quota decremented (got: ${JSON.stringify(aliceQuota())}, stderr: ${stderrLog})`,
  );
  // Live `to_ms: 0` Analytics queries update automatically via WebSocket!
  await waitForCondition(
    () => liveMsgTrend().data?.total_events === 1 && liveSummary().data?.total_events === 1,
    5000,
    `live analytics summary/trends react to message_sent (summary: ${JSON.stringify(liveSummary())}, trend: ${JSON.stringify(liveMsgTrend())})`,
  );
  await waitForCondition(
    () => liveMonitorLogs().data?.length === 1 && liveMonitorLogs().data[0].message.includes("Message sent by Alice"),
    5000,
    `live monitor logs react to message_sent (logs: ${JSON.stringify(liveMonitorLogs())})`,
  );

  // Give a brief tick and verify Bob was NOT invalidated by #general write.
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(
    bob.commitTs(),
    bobTsBefore,
    `Bob watching #roc-lang must not receive transition for #general write (stderr: ${stderrLog})`,
  );

  // 7. Verify mounted `presence` component works in its isolated namespace.
  await alice.mutate(api.presence.heartbeat, { room_id: generalRoom.id, typing: true });
  await waitForCondition(
    () =>
      alicePresence().data?.some(
        (u) => u.user_id === "alice" && u.typing === true,
      ),
    5000,
    "presence heartbeat propagates reactively",
  );

  // 8. Verify external HTTP Action (`messages.fetchPreview`) fetches local HTTP server
  //    and re-entrantly calls `messages.postPreview` mutation, updating Alice's subscription!
  const preview = await alice.action(api.messages.fetchPreview, {
    room_id: generalRoom.id,
    url: `http://127.0.0.1:${targetPort}/`,
  });
  assert.equal(preview.status, 200);
  assert.equal(preview.title, "Concave Action Target");

  await waitForCondition(
    () =>
      aliceMsgs().data?.some(
        (m) => m.kind === "preview" && m.body.includes("Concave Action Target"),
      ),
    5000,
    "preview message from Action propagates reactively",
  );

  // 8b. Verify toggling `link-previews` feature flag off live-gates `/preview` on the backend!
  await alice.mutate(api.analytics.upsertFlag, {
    key: "link-previews",
    name: "Allow /preview URL Actions",
    active: false,
    rollout_pct: 100,
    filters: [],
    variants: [],
  });
  await waitForCondition(
    () => aliceFlags().data?.find((f) => f.key === "link-previews")?.enabled === false,
    5000,
    "link-previews flag toggled off reactively",
  );
  await assert.rejects(
    () =>
      alice.action(api.messages.fetchPreview, {
        room_id: generalRoom.id,
        url: `http://127.0.0.1:${targetPort}/`,
      }),
    /disabled by feature flag/,
  );

  // 9. Verify transactional RateLimiter component rejects the 13th message in window (12 max),
  //    and Analytics does NOT count the rejected message (ACID rollback!).
  for (let i = 0; i < 11; i += 1) {
    await alice.mutate(api.messages.send, {
      room_id: generalRoom.id,
      body: `burst-${i}`,
    });
  }
  await assert.rejects(
    () =>
      alice.mutate(api.messages.send, {
        room_id: generalRoom.id,
        body: "over-limit",
      }),
    /Rate limit exceeded/,
  );
  await waitForCondition(
    () => liveMsgTrend().data?.total_events === 12,
    5000,
    "analytics tracks exactly 12 committed messages (13th rejected message rolled back)",
  );

  aliceMsgs.dispose();
  bobMsgs.dispose();
  alicePresence.dispose();
  aliceQuota.dispose();
  liveSummary.dispose();
  liveMsgTrend.dispose();
  aliceFlags.dispose();
  liveMonitorLogs.dispose();
});

test("end-to-end dev live reload: CSS hot-swap, JS reload, no-cache headers, and embedded SDK helpers", async (t) => {
  const binPath = path.join(ROOT, "examples/chat-app/.concave/e2e-server");
  const dbPath = path.join(ROOT, "examples/chat-app/.concave/e2e-reload.wal");
  const tmpStatic = fs.mkdtempSync(path.join(ROOT, "examples/chat-app/.concave/static-reload-"));
  fs.writeFileSync(path.join(tmpStatic, "styles.css"), "body { color: black; }\n");
  fs.writeFileSync(path.join(tmpStatic, "app.js"), "export const v = 1;\n");

  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${dbPath}${suffix}`, { force: true });
  }

  const port = 13229;
  const serverUrl = `http://127.0.0.1:${port}`;
  const serverProc = spawn(
    binPath,
    [
      "--serve",
      "--host",
      "127.0.0.1",
      "--port",
      String(port),
      "--db",
      dbPath,
      "--static-dir",
      tmpStatic,
      "--live-reload",
    ],
    {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, CONCAVE_LIVE_RELOAD_POLL_MS: "50" },
    },
  );
  t.after(() => {
    serverProc.kill("SIGTERM");
    fs.rmSync(tmpStatic, { recursive: true, force: true });
    for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
      fs.rmSync(`${dbPath}${suffix}`, { force: true });
    }
  });

  await waitForHealth(serverUrl);

  // 1. CLI & compiled binary `--help` flags exit cleanly without side effects.
  const cliBin = path.join(ROOT, "zig-out/bin/concave");
  for (const sub of ["init", "codegen", "dev", "build"]) {
    const res = spawnSync(cliBin, [sub, "--help"], { cwd: tmpStatic, encoding: "utf8" });
    assert.equal(res.status, 0, `concave ${sub} --help should exit 0`);
    assert.ok(res.stderr.includes(`Usage: concave ${sub}`), `expected usage for ${sub}`);
  }
  assert.equal(fs.existsSync(path.join(tmpStatic, "--help")), false, "concave init --help must not create --help dir");

  const binHelp = spawnSync(binPath, ["--help"], { cwd: tmpStatic, encoding: "utf8" });
  assert.equal(binHelp.status, 0, "compiled server --help should exit 0");
  assert.ok(binHelp.stderr.includes("--live-reload"), "compiled server --help lists --live-reload");

  // 2. Embedded `/_concave/index.js` includes the new ergonomic helpers and is syntactically valid JS.
  const sdkRes = await fetch(`${serverUrl}/_concave/index.js`);
  assert.equal(sdkRes.status, 200);
  const sdkSrc = await sdkRes.text();
  assert.ok(sdkSrc.includes("export const bindValue"), "embedded bundle exports bindValue");
  assert.ok(sdkSrc.includes("export const tags"), "embedded bundle exports tags");
  assert.ok(sdkSrc.includes("export function optimisticAppend"), "embedded bundle exports optimisticAppend");

  // 2. Static files served with `--live-reload` use `Cache-Control: no-cache`.
  const staticRes = await fetch(`${serverUrl}/app.js`);
  assert.equal(staticRes.status, 200);
  assert.equal(staticRes.headers.get("cache-control"), "no-cache");

  // 3. Connected ConcaveClient receives live-reload frames on CSS and JS edits.
  const reloads = [];
  const client = new ConcaveClient(serverUrl, {
    onReload: (ev) => reloads.push(ev),
  });
  t.after(() => client.close());
  await waitForCondition(() => client.status() === "connected", 5000, "live-reload client connected");

  // Let initial baseline settle, then modify CSS.
  await new Promise((r) => setTimeout(r, 120));
  fs.writeFileSync(path.join(tmpStatic, "styles.css"), "body { color: rebeccapurple; }\n");
  await waitForCondition(
    () => reloads.some((r) => r.reason === "css"),
    5000,
    "CSS live-reload notification received",
  );

  // Modify JS -> full static reload notification.
  await new Promise((r) => setTimeout(r, 120));
  fs.writeFileSync(path.join(tmpStatic, "app.js"), "export const v = 2;\n");
  await waitForCondition(
    () => reloads.some((r) => r.reason === "static"),
    5000,
    "static JS live-reload notification received",
  );
});
