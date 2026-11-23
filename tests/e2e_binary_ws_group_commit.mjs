import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ConcaveClient } from '../client/concave-client/src/client.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const BIN = path.join(ROOT, 'examples/chat-app/.concave/dev-server');
const DB = path.join(ROOT, '.zig-cache/e2e-bin-ws-gc.wal');
const PORT = 34229;

async function startServer() {
  const proc = spawn(BIN, [
    '--serve',
    '--host', '127.0.0.1',
    '--port', String(PORT),
    '--db', DB,
    '--static-dir', 'examples/chat-app/frontend',
  ], {
    cwd: ROOT,
    env: { ...process.env, CONCAVE_COMMIT_POLL_MS: '0', CONCAVE_SCHEDULER_POLL_MS: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/health`);
      if (r.ok) return proc;
    } catch {}
    await new Promise((r) => setTimeout(r, 40));
  }
  proc.kill('SIGKILL');
  throw new Error('server failed to start');
}

async function waitFor(predicate, timeoutMs = 5000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const val = predicate();
    if (val) return val;
    await new Promise((r) => setTimeout(r, 15));
  }
  throw new Error('timed out waiting for condition');
}

test('Binary WebSocket framing (CBIN v1) + zero-parse raw queries + concurrent WAL group commit durability', async (t) => {
  fs.rmSync(DB, { force: true });
  let server = await startServer();
  t.after(() => {
    try { server.kill('SIGKILL'); } catch {}
    fs.rmSync(DB, { force: true });
  });

  // 1. Connect ConcaveClient using default binary WebSocket framing (?proto=bin, RFC 6455 opcode 0x02)
  const subClient = new ConcaveClient(`http://127.0.0.1:${PORT}`, {
    authToken: 'dev:sub_user:SubUser',
  });
  t.after(() => subClient.close());
  assert.equal(subClient._binary, true);
  assert.ok(subClient._wsUrl.includes('proto=bin'));

  await waitFor(() => subClient.status() === 'connected' && subClient.identity()?.subject === 'sub_user');

  // Seed default rooms via binary WS mutation
  const rooms = await subClient.mutate({ name: 'rooms.ensureDefaults' }, {});
  assert.ok(Array.isArray(rooms) && rooms.length >= 2);
  const general = rooms.find((r) => r.name === 'general');
  assert.ok(general?.id);

  // One-shot query over binary WS (opcode 0x07 -> 0x87, hitting zero-parse App.query_raw + Db.collect_raw!)
  const listed = await subClient.queryOnce({ name: 'rooms.list' }, {});
  assert.equal(listed.length, rooms.length);
  assert.equal(listed[0].name, rooms[0].name);

  // Reactive subscription receiving binary transition frames (opcode 0x83)
  const msgsSig = subClient.query({ name: 'messages.list' }, { room_id: general.id });
  t.after(() => msgsSig.dispose());
  await waitFor(() => msgsSig().status === 'ready' && msgsSig().data.length >= 1);
  const initialCount = msgsSig().data.length;

  // 2. Concurrent durable mutations across 8 parallel binary WS clients (exercising WAL Group Commit!)
  const CLIENTS = 8;
  const PER_CLIENT = 3;
  const writers = [];
  for (let c = 0; c < CLIENTS; c++) {
    const cli = new ConcaveClient(`http://127.0.0.1:${PORT}`, {
      authToken: `dev:writer_${c}:Writer${c}`,
    });
    t.after(() => cli.close());
    writers.push(cli);
  }
  await waitFor(() => writers.every((w) => w.status() === 'connected' && w.identity() !== null));

  const insertedIds = await Promise.all(
    writers.flatMap((w, c) =>
      Array.from({ length: PER_CLIENT }, (_, j) =>
        w.mutate({ name: 'messages.send' }, { room_id: general.id, body: `gc_${c}_${j}` }),
      ),
    ),
  );
  assert.equal(insertedIds.length, CLIENTS * PER_CLIENT);
  for (const id of insertedIds) assert.equal(typeof id, 'string');

  // Subscriber must receive reactive binary push with all 24 newly committed messages!
  const expectedCount = initialCount + CLIENTS * PER_CLIENT;
  await waitFor(() => msgsSig().status === 'ready' && msgsSig().data.length === expectedCount);

  // 3. Restart server from disk WAL and verify 100% of group-committed messages survived!
  for (const w of writers) w.close();
  subClient.close();
  server.kill('SIGKILL');
  await new Promise((r) => setTimeout(r, 120));

  server = await startServer();
  const verifyClient = new ConcaveClient(`http://127.0.0.1:${PORT}`);
  t.after(() => verifyClient.close());
  await waitFor(() => verifyClient.status() === 'connected');
  const recovered = await verifyClient.queryOnce({ name: 'messages.list' }, { room_id: general.id });
  assert.equal(recovered.length, expectedCount);
});
