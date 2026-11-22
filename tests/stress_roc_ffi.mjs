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

async function waitFor(fn, timeoutMs = 8000, label = "condition") {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const v = fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

test("Wave 3 Roc 0.1.0_RC1 + Zig FFI concurrency stress: 12 WS clients, OCC bursts, re-entrant Actions, and abrupt disconnects", async (t) => {
  const binPath = path.join(ROOT, "examples/chat-app/.concave/stress-server");
  const walPath = path.join(ROOT, "examples/chat-app/.concave/stress.wal");
  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  fs.rmSync(walPath, { force: true });

  const build = spawnSync(
    "roc",
    ["build", "--opt=dev", `--output=${binPath}`, path.join(ROOT, "examples/chat-app/backend/main.roc")],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(build.status, 0, `roc build failed:\n${build.stderr}`);

  // Local HTTP target for concurrent re-entrant Actions (`messages.fetchPreview`).
  let hits = 0;
  const targetServer = http.createServer((_req, res) => {
    hits += 1;
    res.writeHead(200, { "Content-Type": "text/html", Connection: "close" });
    res.end(`<html><head><title>Preview-${hits}</title></head><body>ok</body></html>`);
  });
  await new Promise((resolve) => targetServer.listen(0, "127.0.0.1", resolve));
  const targetPort = targetServer.address().port;
  t.after(() => {
    targetServer.closeAllConnections?.();
    targetServer.close();
  });

  const port = 13239;
  const url = `http://127.0.0.1:${port}`;
  const proc = spawn(binPath, ["--serve", "--host", "127.0.0.1", "--port", String(port), "--db", walPath], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  proc.stderr.on("data", (d) => {
    stderr += d.toString();
  });
  t.after(() => {
    proc.kill("SIGTERM");
    fs.rmSync(walPath, { force: true });
  });

  for (let i = 0; i < 60; i += 1) {
    try {
      const r = await fetch(`${url}/health`);
      if (r.ok) break;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }

  // Spawn 12 distinct authenticated WS clients (distinct subjects so rate-limiter allows burst!).
  const clients = Array.from({ length: 12 }, (_, i) =>
    new ConcaveClient(url, { authToken: `dev:user${i}:User-${i}` }),
  );
  t.after(() => {
    for (const c of clients) c.close();
  });

  for (let i = 0; i < clients.length; i += 1) {
    await waitFor(() => clients[i].status() === "connected", 5000, `client ${i} connected`);
  }

  const rooms = await clients[0].mutate(api.rooms.ensureDefaults, {});
  const general = rooms.find((r) => r.name === "general");
  assert.ok(general);

  // Track monotonic commit_ts invariant on every client!
  const lastSeenTs = clients.map(() => 0);
  const subs = clients.map((c, idx) => {
    const q = c.query(api.messages.list, { room_id: general.id });
    return { q, idx };
  });
  t.after(() => {
    for (const s of subs) s.q.dispose();
  });

  for (const s of subs) {
    await waitFor(() => s.q().status === "ready", 5000, `sub ${s.idx} ready`);
  }

  // Hammer concurrently:
  // - 8 clients send 3 messages each in parallel (24 concurrent mutations hitting shared room index!)
  // - 2 clients fire re-entrant HTTP Actions (`messages.fetchPreview` -> `messages.postPreview`)
  // - 2 clients (`clients[10]`, `clients[11]`) disconnect abruptly mid-storm (stressing WsSender lifetime!)
  const ops = [];
  for (let i = 0; i < 8; i += 1) {
    for (let m = 0; m < 3; m += 1) {
      ops.push(
        clients[i].mutate(api.messages.send, {
          room_id: general.id,
          body: `storm-u${i}-m${m}`,
        }),
      );
    }
  }
  for (let i = 8; i < 10; i += 1) {
    ops.push(
      clients[i].action(api.messages.fetchPreview, {
        room_id: general.id,
        url: `http://127.0.0.1:${targetPort}/`,
      }),
    );
  }

  // Abruptly disconnect 2 clients mid-flight while broadcasts are actively firing!
  setTimeout(() => {
    clients[10].close();
    clients[11].close();
  }, 15);

  await Promise.all(ops);

  // Expected total messages in #general: 1 welcome + 24 storm messages + 2 preview messages = 27!
  const expectedCount = 27;
  for (let i = 0; i < 10; i += 1) {
    await waitFor(
      () => (subs[i].q().data?.length ?? 0) === expectedCount,
      8000,
      `client ${i} converged to ${expectedCount} msgs (got ${subs[i].q().data?.length}, stderr=${stderr})`,
    );
    const ts = clients[i].commitTs();
    assert.ok(ts >= lastSeenTs[i], `client ${i} commit_ts went backwards`);
    lastSeenTs[i] = ts;
  }

  // All 10 surviving clients must have the EXACT same ordered message IDs!
  const canonicalIds = subs[0].q().data.map((m) => m.id);
  for (let i = 1; i < 10; i += 1) {
    assert.deepEqual(
      subs[i].q().data.map((m) => m.id),
      canonicalIds,
      `client ${i} message ordering diverged from client 0`,
    );
  }

  // Server health & readiness check after the storm.
  const ready = await fetch(`${url}/ready`);
  assert.equal(ready.status, 200);
  const readyJson = await ready.json();
  assert.equal(readyJson.status, "ready");
  assert.ok(readyJson.commit_ts >= expectedCount);
});
