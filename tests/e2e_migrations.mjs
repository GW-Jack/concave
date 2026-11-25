import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ConcaveClient } from "../client/concave-client/src/index.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const FIXTURE = path.join(ROOT, "tests/fixtures/migrations-app/main.roc");
const BIN = path.join(ROOT, ".zig-cache/migrations-e2e-bin");
const DB_PATH = path.join(ROOT, ".zig-cache/migrations-e2e.wal");
const PORT = 34218;
const BASE_URL = `http://127.0.0.1:${PORT}`;

const ADMIN_TOKEN = "dev:admin1:Admin:admin";
const MEMBER_TOKEN = "dev:alice:Alice:member";

async function waitForHealth(url, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${url}/health`);
      if (res.ok) return;
    } catch {
      // retry until ready
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server at ${url} did not become healthy within ${timeoutMs}ms`);
}

async function waitForCondition(fn, timeoutMs = 6000, label = "condition") {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = await fn();
    if (val) return val;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`Timed out waiting for ${label} within ${timeoutMs}ms`);
}

async function rpc(kind, name, args = {}, token = null) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${BASE_URL}/api/${kind}/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
  });
  return { status: res.status, json: await res.json() };
}

test("Pure-Roc Resumable Batched Migrations Component E2E", async (t) => {
  fs.mkdirSync(path.dirname(BIN), { recursive: true });
  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${DB_PATH}${suffix}`, { force: true });
  }

  // Compile fixture app with Concave platform host
  execFileSync("roc", ["build", "--opt=dev", `--output=${BIN}`, FIXTURE], {
    cwd: ROOT,
    stdio: "inherit",
  });

  // Verify --introspect emits isolated `migrations` component and internal `_runBatch`
  const manifestRaw = execFileSync(BIN, ["--introspect"], {
    cwd: ROOT,
    encoding: "utf8",
  });
  const manifest = JSON.parse(manifestRaw);
  assert.equal(manifest.app_name, "migrations-test");

  const migComp = manifest.components.find((c) => c.namespace === "migrations");
  assert.ok(migComp, "manifest must declare migrations component");
  assert.equal(migComp.package, "concave-migrations");
  assert.ok(
    migComp.tables.some((tbl) => tbl.name === "migration_runs"),
    "migrations component must declare isolated migration_runs table",
  );

  const runBatchFn = manifest.functions.find((f) => f.name === "migrations._runBatch");
  assert.ok(runBatchFn, "manifest must include migrations._runBatch");
  assert.equal(runBatchFn.visibility, "internal");
  assert.equal(runBatchFn.namespace, "");

  const server = spawn(
    BIN,
    ["--serve", "--host", "127.0.0.1", "--port", String(PORT), "--db", DB_PATH],
    {
      cwd: ROOT,
      env: {
        ...process.env,
        CONCAVE_ALLOW_DEV_TOKENS: "true",
        CONCAVE_SCHEDULER_POLL_MS: "25",
        CONCAVE_COMMIT_POLL_MS: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  let stderrLog = "";
  server.stderr.on("data", (d) => {
    stderrLog += d.toString();
  });

  t.after(() => {
    try {
      server.kill("SIGKILL");
    } catch {}
    for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
      fs.rmSync(`${DB_PATH}${suffix}`, { force: true });
    }
  });

  await waitForHealth(BASE_URL);

  // ---------------------------------------------------------------------------
  // 1. Seed 12 unmigrated users (`role: "legacy"`, `migrated: false`)
  // ---------------------------------------------------------------------------
  for (let i = 1; i <= 12; i++) {
    const res = await rpc("mutation", "users.seed", {
      name: `User ${i}`,
      role: "legacy",
      migrated: false,
    });
    assert.equal(res.status, 200);
    assert.equal(res.json.ok, true);
  }

  const beforeUsers = await rpc("query", "users.list", {});
  assert.equal(beforeUsers.json.ok, true);
  assert.equal(beforeUsers.json.value.length, 12);
  assert.ok(beforeUsers.json.value.every((u) => u.role === "legacy" && u.migrated === false));

  // ---------------------------------------------------------------------------
  // 2. Auth & internal visibility enforcement
  // ---------------------------------------------------------------------------
  // Unauthenticated callers rejected on migrations.status & migrations.start
  const unauthStatus = await rpc("query", "migrations.status", {});
  assert.equal(unauthStatus.json.ok, false);
  assert.match(unauthStatus.json.error, /Unauthenticated/i);

  const unauthStart = await rpc("mutation", "migrations.start", {
    name: "backfill_user_roles",
    batch_size: 3,
    dry_run: false,
    force: false,
  });
  assert.equal(unauthStart.json.ok, false);
  assert.match(unauthStart.json.error, /Unauthenticated/i);

  // Non-admin caller rejected on migrations.status & migrations.start
  const memberStatus = await rpc("query", "migrations.status", {}, MEMBER_TOKEN);
  assert.equal(memberStatus.json.ok, false);
  assert.match(memberStatus.json.error, /Forbidden/i);

  const memberStart = await rpc(
    "mutation",
    "migrations.start",
    {
      name: "backfill_user_roles",
      batch_size: 3,
      dry_run: false,
      force: false,
    },
    MEMBER_TOKEN,
  );
  assert.equal(memberStart.json.ok, false);
  assert.match(memberStart.json.error, /Forbidden/i);

  // Internal mutation `migrations._runBatch` rejected on public HTTP API (even for admin)
  const internalHttp = await rpc(
    "mutation",
    "migrations._runBatch",
    { name: "backfill_user_roles", dry_run: false },
    ADMIN_TOKEN,
  );
  assert.equal(internalHttp.status, 400);
  assert.equal(internalHttp.json.ok, false);
  assert.match(internalHttp.json.error, /internal/i);

  // Connect authenticated admin WebSocket client and verify `_runBatch` is also rejected over WS
  const adminClient = new ConcaveClient(BASE_URL, { authToken: ADMIN_TOKEN });
  t.after(() => adminClient.close());
  await waitForCondition(() => adminClient.status() === "connected", 5000, "admin ws connected");

  await assert.rejects(
    () =>
      adminClient.mutate(
        { name: "migrations._runBatch" },
        { name: "backfill_user_roles", dry_run: false },
      ),
    /internal/i,
  );

  // ---------------------------------------------------------------------------
  // 3. Live WS subscription on `migrations.status` + start batched migration (`batch_size: 3`)
  // ---------------------------------------------------------------------------
  const statusSub = adminClient.query({ name: "migrations.status" }, {});
  t.after(() => statusSub.dispose());

  await waitForCondition(
    () => statusSub().status === "ready",
    5000,
    "initial migrations.status subscription ready",
  );
  const initialRuns = statusSub().data;
  assert.equal(initialRuns.length, 1);
  assert.equal(initialRuns[0].name, "backfill_user_roles");
  assert.equal(initialRuns[0].status, "idle");

  const startRes = await adminClient.mutate(
    { name: "migrations.start" },
    {
      name: "backfill_user_roles",
      batch_size: 3,
      dry_run: false,
      force: false,
    },
  );
  assert.equal(startRes.name, "backfill_user_roles");
  assert.equal(startRes.status, "running");
  assert.equal(startRes.batch_size, 3);
  assert.ok(startRes.job_id.length > 0);

  // Wait for live reactive subscription to converge to completed with 12 docs across >= 4 batches
  const finalRun = await waitForCondition(
    () => {
      const rows = statusSub().data;
      if (!Array.isArray(rows)) return null;
      const run = rows.find((r) => r.name === "backfill_user_roles");
      return run && run.status === "completed" ? run : null;
    },
    8000,
    `migration completion (stderr: ${stderrLog})`,
  );

  assert.equal(finalRun.status, "completed");
  assert.equal(finalRun.processed_count, 12);
  assert.ok(finalRun.batches_run >= 4, `expected batches_run >= 4, got ${finalRun.batches_run}`);
  assert.equal(finalRun.cursor, "");
  assert.equal(finalRun.last_error, "");
  assert.ok(finalRun.started_at_ms > 0);
  assert.ok(finalRun.completed_at_ms >= finalRun.started_at_ms);

  // Also verify single-migration `migrations.get` query
  const getRes = await rpc("query", "migrations.get", { name: "backfill_user_roles" }, ADMIN_TOKEN);
  assert.equal(getRes.json.ok, true);
  assert.equal(getRes.json.value.found, true);
  assert.equal(getRes.json.value.registered, true);
  assert.equal(getRes.json.value.status, "completed");
  assert.equal(getRes.json.value.processed_count, 12);
  assert.ok(getRes.json.value.batches_run >= 4);

  // ---------------------------------------------------------------------------
  // 4. Verify all 12 users are now migrated (`role === "member"`, `migrated === true`)
  // ---------------------------------------------------------------------------
  const afterUsers = await rpc("query", "users.list", {});
  assert.equal(afterUsers.json.ok, true);
  assert.equal(afterUsers.json.value.length, 12);
  for (const u of afterUsers.json.value) {
    assert.equal(u.role, "member", `user ${u.name} role should be backfilled to member`);
    assert.equal(u.migrated, true, `user ${u.name} should have migrated === true`);
  }

  // ---------------------------------------------------------------------------
  // 5. Idempotency guard: restarting completed migration without `force: true` is rejected
  // ---------------------------------------------------------------------------
  const restartRejected = await rpc(
    "mutation",
    "migrations.start",
    {
      name: "backfill_user_roles",
      batch_size: 3,
      dry_run: false,
      force: false,
    },
    ADMIN_TOKEN,
  );
  assert.equal(restartRejected.json.ok, false);
  assert.match(restartRejected.json.error, /already completed/i);
});
