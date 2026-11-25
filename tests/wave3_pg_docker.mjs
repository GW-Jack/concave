import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { ConcaveClient } from "../client/concave-client/src/index.js";
import { api } from "../examples/chat-app/frontend/src/_generated/api.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

async function waitFor(fn, timeoutMs = 15000, label = "condition") {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const v = await fn();
    if (v) return v;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

test("Wave 3 Real PostgreSQL 16 (SCRAM-SHA-256) + PgBouncer (transaction mode): PgStore == WalStore differential & 2-replica Cloud Run reactivity", async (t) => {
  const netName = "concave-wave3-net";
  const pgName = "concave-wave3-pg";
  const pgbName = "concave-wave3-pgbouncer";

  const cleanup = () => {
    for (const c of [pgbName, pgName]) {
      spawnSync("docker", ["rm", "-f", c], { stdio: "ignore" });
    }
    spawnSync("docker", ["network", "rm", netName], { stdio: "ignore" });
  };
  cleanup();
  t.after(cleanup);

  // 1. Build `pg-diff` binary and compiled Roc+Zig chat server.
  const zigBuild = spawnSync("zig", ["build", "pg-diff"], { cwd: ROOT, encoding: "utf8" });
  assert.equal(zigBuild.status, 0, `zig build pg-diff failed:\n${zigBuild.stderr}`);

  const binPath = path.join(ROOT, "examples/chat-app/.concave/pg-replica-server");
  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  const rocBuild = spawnSync(
    "roc",
    ["build", "--opt=dev", `--output=${binPath}`, path.join(ROOT, "examples/chat-app/backend/main.roc")],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(rocBuild.status, 0, `roc build failed:\n${rocBuild.stderr}`);

  // 2. Generate ephemeral self-signed TLS cert on host and start PostgreSQL 16 (SCRAM-SHA-256 + TLS 1.3)!
  const tlsDir = path.join(ROOT, ".zig-cache/wave3-pg-tls");
  fs.mkdirSync(tlsDir, { recursive: true });
  const keyFile = path.join(tlsDir, "server.key");
  const crtFile = path.join(tlsDir, "server.crt");
  execFileSync(
    "openssl",
    [
      "req",
      "-new",
      "-x509",
      "-days",
      "1",
      "-nodes",
      "-out",
      crtFile,
      "-keyout",
      keyFile,
      "-subj",
      "/CN=localhost",
    ],
    { stdio: "ignore" },
  );
  fs.chmodSync(keyFile, 0o600);

  execFileSync("docker", ["network", "create", netName], { stdio: "ignore" });
  execFileSync(
    "docker",
    [
      "run",
      "-d",
      "--name",
      pgName,
      "--network",
      netName,
      "-p",
      "15432:5432",
      "-v",
      `${tlsDir}:/pg-tls-in:ro`,
      "-e",
      "POSTGRES_USER=concave",
      "-e",
      "POSTGRES_PASSWORD=concave_secret",
      "-e",
      "POSTGRES_DB=concave",
      "-e",
      "POSTGRES_HOST_AUTH_METHOD=scram-sha-256",
      "-e",
      "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256",
      "--entrypoint",
      "sh",
      "postgres:16-alpine",
      "-c",
      "cp /pg-tls-in/server.crt /pg-tls-in/server.key /tmp/ && chmod 600 /tmp/server.key && chown postgres:postgres /tmp/server.key /tmp/server.crt && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key",
    ],
    { stdio: "pipe" },
  );

  await waitFor(() => {
    const r = spawnSync("docker", ["exec", pgName, "pg_isready", "-U", "concave", "-d", "concave"], {
      stdio: "ignore",
    });
    return r.status === 0;
  }, 30000, "PostgreSQL 16 ready");

  // Start PgBouncer in transaction pooling mode pointing at Postgres 16!
  execFileSync(
    "docker",
    [
      "run",
      "-d",
      "--name",
      pgbName,
      "--network",
      netName,
      "-p",
      "16432:5432",
      "-e",
      `DB_HOST=${pgName}`,
      "-e",
      "DB_PORT=5432",
      "-e",
      "DB_USER=concave",
      "-e",
      "DB_PASSWORD=concave_secret",
      "-e",
      "DB_NAME=concave",
      "-e",
      "POOL_MODE=transaction",
      "-e",
      "AUTH_TYPE=scram-sha-256",
      "-e",
      "LISTEN_PORT=5432",
      "edoburu/pgbouncer:latest",
    ],
    { stdio: "pipe" },
  );

  // Wait a moment for PgBouncer to accept connections.
  await new Promise((r) => setTimeout(r, 1500));

  // 3a. Run Zig `pg-diff` directly against PostgreSQL 16 over native Zig TLS 1.3 (`sslmode=require` + SCRAM-SHA-256)!
  const tlsUrl = "postgres://concave:concave_secret@127.0.0.1:15432/concave?sslmode=require";
  const tlsDiff = spawnSync(
    path.join(ROOT, "zig-out/bin/pg-diff"),
    [tlsUrl, "tls13-pg16"],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(
    tlsDiff.status,
    0,
    `pg-diff TLS 1.3 Postgres 16 failed:\nstdout: ${tlsDiff.stdout}\nstderr: ${tlsDiff.stderr}`,
  );
  assert.match(tlsDiff.stderr + tlsDiff.stdout, /pg-diff PASSED/);

  // 3b. Run Zig `pg-diff` directly against PostgreSQL 16 (plaintext + SCRAM-SHA-256)!
  const directUrl = "postgres://concave:concave_secret@127.0.0.1:15432/concave?sslmode=disable";
  const directDiff = spawnSync(
    path.join(ROOT, "zig-out/bin/pg-diff"),
    [directUrl, "direct-pg16"],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(
    directDiff.status,
    0,
    `pg-diff direct Postgres 16 failed:\nstdout: ${directDiff.stdout}\nstderr: ${directDiff.stderr}`,
  );
  assert.match(directDiff.stderr + directDiff.stdout, /pg-diff PASSED/);

  // 4. Run Zig `pg-diff` through PgBouncer (`pool_mode=transaction`)!
  const pgbUrl = "postgres://concave:concave_secret@127.0.0.1:16432/concave?sslmode=disable";
  const pgbDiff = spawnSync(
    path.join(ROOT, "zig-out/bin/pg-diff"),
    [pgbUrl, "pgbouncer-tx-mode"],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(
    pgbDiff.status,
    0,
    `pg-diff PgBouncer transaction-mode failed:\nstdout: ${pgbDiff.stdout}\nstderr: ${pgbDiff.stderr}`,
  );
  assert.match(pgbDiff.stderr + pgbDiff.stdout, /pg-diff PASSED/);

  // 5. Launch TWO live compiled Roc+Zig `chat-app` replicas sharing PgBouncer/Postgres!
  //    Alice connects to Replica 1 (:13241), Bob connects to Replica 2 (:13242).
  //    Alice mutates on Replica 1 -> Bob receives live transition on Replica 2 via `commit_log` tailing!
  const repEnv = {
    ...process.env,
    DATABASE_URL: pgbUrl,
    CONCAVE_DEPLOYMENT_ID: "cloud-run-cluster-test",
    CONCAVE_COMMIT_POLL_MS: "50",
    CONCAVE_PG_COMMIT_LOG_KEEP: "5",
    CONCAVE_SCHEDULER_POLL_MS: "10",
  };
  const rep1 = spawn(binPath, ["--serve", "--host", "127.0.0.1", "--port", "13241"], {
    env: repEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const rep2 = spawn(binPath, ["--serve", "--host", "127.0.0.1", "--port", "13242"], {
    env: repEnv,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let repErr = "";
  rep1.stderr.on("data", (d) => (repErr += `[rep1] ${d}`));
  rep2.stderr.on("data", (d) => (repErr += `[rep2] ${d}`));
  t.after(() => {
    rep1.kill("SIGTERM");
    rep2.kill("SIGTERM");
  });

  for (const port of [13241, 13242]) {
    await waitFor(async () => {
      try {
        const r = await fetch(`http://127.0.0.1:${port}/ready`);
        return r.ok;
      } catch {
        return false;
      }
    }, 10000, `replica on :${port} ready (${repErr})`);
  }

  const alice = new ConcaveClient("http://127.0.0.1:13241", { authToken: "dev:alice:Alice" });
  const bob = new ConcaveClient("http://127.0.0.1:13242", { authToken: "dev:bob:Bob" });
  t.after(() => {
    alice.close();
    bob.close();
  });

  await waitFor(() => alice.status() === "connected", 5000, "alice connected to rep1");
  await waitFor(() => bob.status() === "connected", 5000, "bob connected to rep2");

  const rooms = await alice.mutate(api.rooms.ensureDefaults, {});
  const general = rooms.find((r) => r.name === "general");
  assert.ok(general);

  const bobMsgs = bob.query(api.messages.list, { room_id: general.id });
  t.after(() => bobMsgs.dispose());
  await waitFor(() => bobMsgs().status === "ready", 5000, "bob subscribed on rep2");

  // Alice posts on Replica 1 -> Bob on Replica 2 MUST receive it reactively via Postgres commit_log!
  await alice.mutate(api.messages.send, {
    room_id: general.id,
    body: "Hello across Cloud Run replicas via pure Zig PG Wire v3 + PgBouncer!",
  });

  await waitFor(
    () =>
      bobMsgs().data?.some(
        (m) => m.body === "Hello across Cloud Run replicas via pure Zig PG Wire v3 + PgBouncer!",
      ),
    5000,
    `bob on replica 2 receives live commit_log transition (${repErr})`,
  );

  const psqlScalar = (sql) =>
    execFileSync(
      "docker",
      ["exec", pgName, "psql", "-U", "concave", "-d", "concave", "-tAc", sql],
      { encoding: "utf8" },
    ).trim();

  // 6. Verify `--backfill-indexes` CLI flag rebuilds secondary indexes cleanly against live PostgreSQL 16!
  psqlScalar("DELETE FROM index_entries WHERE deployment_id = 'cloud-run-cluster-test'");
  assert.equal(
    Number(psqlScalar("SELECT COUNT(*) FROM index_entries WHERE deployment_id = 'cloud-run-cluster-test'")),
    0,
    "index_entries should be cleared prior to backfill",
  );

  const backfill = spawnSync(binPath, ["--backfill-indexes"], {
    cwd: ROOT,
    env: {
      ...process.env,
      DATABASE_URL: directUrl,
      CONCAVE_DEPLOYMENT_ID: "cloud-run-cluster-test",
    },
    encoding: "utf8",
  });
  assert.equal(
    backfill.status,
    0,
    `--backfill-indexes failed:\nstdout: ${backfill.stdout}\nstderr: ${backfill.stderr}`,
  );
  const backfillOut = backfill.stdout + backfill.stderr;
  const backfillMatch = backfillOut.match(
    /Backfilled secondary indexes for (\d+) document\(s\) in deployment `cloud-run-cluster-test`/,
  );
  assert.ok(backfillMatch, `unexpected --backfill-indexes output: ${backfillOut}`);
  assert.ok(Number(backfillMatch[1]) >= 2, `expected >= 2 backfilled docs, got ${backfillMatch[1]}`);

  const rebuiltIdxCount = Number(
    psqlScalar("SELECT COUNT(*) FROM index_entries WHERE deployment_id = 'cloud-run-cluster-test'"),
  );
  assert.ok(rebuiltIdxCount > 0, "index_entries must be repopulated after --backfill-indexes");

  // Confirm live secondary-index query still returns Alice's message after backfill!
  const listResp = await fetch("http://127.0.0.1:13241/api/query/messages.list", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer dev:alice:Alice" },
    body: JSON.stringify({ room_id: general.id }),
  });
  assert.equal(listResp.status, 200);
  const listJson = await listResp.json();
  assert.equal(listJson.ok, true);
  assert.ok(
    listJson.value.some((m) => m.body === "Hello across Cloud Run replicas via pure Zig PG Wire v3 + PgBouncer!"),
    "secondary-index query must return existing message after --backfill-indexes",
  );

  // 7. Verify `CONCAVE_PG_COMMIT_LOG_KEEP=5` prunes older `commit_log` rows while preserving recent commits & live reactivity!
  for (let i = 1; i <= 10; i++) {
    await alice.mutate(api.messages.send, {
      room_id: general.id,
      body: `Commit log prune batch message #${i}`,
    });
  }

  const prunedStats = await waitFor(() => {
    const row = psqlScalar(
      "SELECT COUNT(*), COALESCE(MIN(commit_ts), 0), COALESCE(MAX(commit_ts), 0) FROM commit_log WHERE deployment_id = 'cloud-run-cluster-test'",
    );
    const [cnt, minTs, maxTs] = row.split("|").map(Number);
    if (cnt >= 1 && cnt <= 5 && minTs > 1 && maxTs >= 10) {
      return { cnt, minTs, maxTs };
    }
    return null;
  }, 15000, `commit_log pruning to <= 5 rows (${repErr})`);
  assert.ok(prunedStats.cnt >= 1 && prunedStats.cnt <= 5);
  assert.ok(prunedStats.minTs > 1, `expected older commits to be pruned (min_ts=${prunedStats.minTs})`);

  // Verify live cross-replica reactivity still works seamlessly after commit_log pruning!
  await alice.mutate(api.messages.send, {
    room_id: general.id,
    body: "Post-prune live reactivity check!",
  });
  await waitFor(
    () => bobMsgs().data?.some((m) => m.body === "Post-prune live reactivity check!"),
    5000,
    `bob on replica 2 receives post-prune live commit_log transition (${repErr})`,
  );
});
