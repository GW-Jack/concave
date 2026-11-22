import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { ConcaveClient } from "../client/concave-client/src/index.ts";
import { api } from "../examples/chat-app/frontend/src/_generated/api.ts";

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
  const dbPath = path.join(ROOT, "examples/chat-app/.concave/e2e.db");
  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  for (const suffix of ["", "-wal", "-shm"]) {
    fs.rmSync(`${dbPath}${suffix}`, { force: true });
  }

  // 1. Build standalone native Roc+Rust server binary.
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
    for (const suffix of ["", "-wal", "-shm"]) {
      fs.rmSync(`${dbPath}${suffix}`, { force: true });
    }
  });

  await waitForHealth(serverUrl);

  // Verify zero-npm TypeScript serving via Concave's built-in Rust `oxc` transpiler!
  const indexHtml = await fetch(`${serverUrl}/`);
  assert.equal(indexHtml.status, 200);
  assert.ok((await indexHtml.text()).includes("/src/main.ts"));

  const builtinClient = await fetch(`${serverUrl}/_concave/index.ts`);
  assert.equal(builtinClient.status, 200);
  assert.match(builtinClient.headers.get("content-type") ?? "", /text\/javascript/);
  const builtinJs = await builtinClient.text();
  assert.ok(builtinJs.includes("ConcaveClient"));
  assert.ok(!builtinJs.includes("type Accessor"), "oxc must strip TypeScript types");

  const mainTsResp = await fetch(`${serverUrl}/src/main.ts`);
  assert.equal(mainTsResp.status, 200);
  assert.match(mainTsResp.headers.get("content-type") ?? "", /text\/javascript/);
  const mainJs = await mainTsResp.text();
  assert.ok(mainJs.includes("mount("));
  assert.ok(!mainJs.includes("Promise<void>"), "oxc must strip TypeScript return types");

  const apiTsResp = await fetch(`${serverUrl}/src/_generated/api.ts`);
  assert.equal(apiTsResp.status, 200);
  const apiJs = await apiTsResp.text();
  assert.ok(apiJs.includes("export const api ="));
  assert.ok(!apiJs.includes("export interface FunctionReference"));

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

  // Subscribe Alice to #general and Bob to #roc-lang.
  const aliceMsgs = alice.query(api.messages.list, { room_id: generalRoom.id });
  const bobMsgs = bob.query(api.messages.list, { room_id: rocRoom.id });
  const alicePresence = alice.query(api.presence.listOnline, { room_id: generalRoom.id });
  const aliceQuota = alice.query(api.rate_limit.status, { key: "alice" });

  await waitForCondition(() => aliceMsgs().status === "ready", 5000, "aliceMsgs ready");
  await waitForCondition(() => bobMsgs().status === "ready", 5000, "bobMsgs ready");
  await waitForCondition(() => aliceQuota().status === "ready", 5000, "aliceQuota ready");

  assert.equal(aliceMsgs().data.length, 1);
  assert.equal(bobMsgs().data.length, 1);
  assert.equal(aliceQuota().data.remaining, 12);

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

  // 9. Verify transactional RateLimiter component rejects the 13th message in window (12 max).
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

  aliceMsgs.dispose();
  bobMsgs.dispose();
  alicePresence.dispose();
  aliceQuota.dispose();
});
