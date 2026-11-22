import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const FIXTURE = path.join(ROOT, 'tests/fixtures/platform-features-app/main.roc');
const BIN = path.join(ROOT, '.zig-cache/platform-features-bin');
const DB_PATH = path.join(ROOT, '.zig-cache/platform-features-e2e.wal');
const STORAGE_DIR = path.join(ROOT, '.zig-cache/platform-features-storage');
const PORT = 34210;
const BASE_URL = `http://127.0.0.1:${PORT}`;
const WS_URL = `ws://127.0.0.1:${PORT}/ws`;

async function waitForHealth(url, timeoutMs = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`${url}/health`);
      if (res.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server at ${url} did not become healthy within ${timeoutMs}ms`);
}

async function rpc(kind, name, args = {}) {
  const res = await fetch(`${BASE_URL}/api/${kind}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  return { status: res.status, json: await res.json() };
}

async function pollUntil(predicate, timeoutMs = 4000, intervalMs = 50) {
  const start = Date.now();
  let last;
  while (Date.now() - start < timeoutMs) {
    last = await predicate();
    if (last) return last;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`condition not met within ${timeoutMs}ms`);
}

test('Track 2 E2E: Scheduler + Crons + HTTP Routes + Blob Storage + Reactive Pagination & Search', async (t) => {
  fs.rmSync(DB_PATH, { force: true });
  fs.rmSync(STORAGE_DIR, { recursive: true, force: true });

  // Compile the Roc fixture app against Concave's Zig platform host
  execFileSync('roc', ['build', `--output=${BIN}`, FIXTURE], { cwd: ROOT, stdio: 'inherit' });

  // Verify --introspect emits crons & http_routes
  const manifestRaw = execFileSync(BIN, ['--introspect'], { cwd: ROOT, encoding: 'utf8' });
  const manifest = JSON.parse(manifestRaw);
  assert.equal(manifest.app_name, 'platform-features-test');
  assert.equal(manifest.crons.length, 1);
  assert.equal(manifest.crons[0].name, 'heartbeat');
  assert.equal(manifest.http_routes.length, 2);

  const server = spawn(BIN, [
    '--serve',
    '--host', '127.0.0.1',
    '--port', String(PORT),
    '--db', DB_PATH,
  ], {
    cwd: ROOT,
    env: {
      ...process.env,
      CONCAVE_STORAGE_DIR: STORAGE_DIR,
      CONCAVE_SCHEDULER_POLL_MS: '40',
      CONCAVE_COMMIT_POLL_MS: '0',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  t.after(() => {
    try { server.kill('SIGKILL'); } catch {}
    fs.rmSync(DB_PATH, { force: true });
    fs.rmSync(STORAGE_DIR, { recursive: true, force: true });
  });

  await waitForHealth(BASE_URL);

  // ---------------------------------------------------------------------------
  // 1. Transactional Scheduler + Rollback Atomicity + Cancel + Recurring Crons
  // ---------------------------------------------------------------------------
  const schedOk = await rpc('mutation', 'jobs.schedule_commit', { delay_ms: 40, detail: 'committed-job' });
  assert.equal(schedOk.json.ok, true);

  // Schedule and abort: MUST NOT execute!
  const schedAbort = await rpc('mutation', 'jobs.schedule_abort', { delay_ms: 10, detail: 'aborted-job' });
  assert.equal(schedAbort.json.ok, false);

  // Schedule with 500ms delay then immediately cancel: MUST NOT execute!
  const schedCancel = await rpc('mutation', 'jobs.schedule_commit', { delay_ms: 400, detail: 'canceled-job' });
  assert.equal(schedCancel.json.ok, true);
  const cancelRes = await rpc('mutation', 'jobs.cancel', { job_id: schedCancel.json.value });
  assert.equal(cancelRes.json.ok, true);

  // Wait until committed job + at least 2 cron ticks have fired!
  const events = await pollUntil(async () => {
    const res = await rpc('query', 'events.list', {});
    assert.equal(res.json.ok, true);
    const list = res.json.value;
    const hasCommitted = list.some((e) => e.kind === 'scheduled' && e.detail === 'committed-job');
    const cronCount = list.filter((e) => e.kind === 'cron' && e.detail === 'tick').length;
    return hasCommitted && cronCount >= 2 ? list : null;
  }, 4000);

  // Wait past the canceled job's delay to prove neither aborted nor canceled jobs ever ran
  await new Promise((r) => setTimeout(r, 450));
  const eventsFinal = (await rpc('query', 'events.list', {})).json.value;
  assert.equal(eventsFinal.some((e) => e.kind === 'rolled_back'), false, 'aborted mutation must NOT execute scheduled job');
  assert.equal(eventsFinal.some((e) => e.detail === 'canceled-job'), false, 'canceled job must NOT execute');
  assert.ok(events.length >= 3);

  // ---------------------------------------------------------------------------
  // 2. Blob / File Storage (Signed Upload URL -> Upload -> Download -> Delete)
  // ---------------------------------------------------------------------------
  const uploadUrlRes = await rpc('mutation', 'files.upload_url', {});
  assert.equal(uploadUrlRes.json.ok, true);
  const uploadUrl = uploadUrlRes.json.value;
  assert.ok(uploadUrl.startsWith(`${BASE_URL}/_storage/upload/`));

  const blobPayload = 'Hello Concave Zero-Dep Blob Storage!';
  const upResp = await fetch(uploadUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    body: blobPayload,
  });
  assert.equal(upResp.status, 200);
  const { storage_id } = await upResp.json();
  assert.ok(storage_id && storage_id.length > 0);

  // Tampered upload URL must be rejected with 403
  const badUp = await fetch(`${uploadUrl}tampered`, { method: 'POST', body: 'evil' });
  assert.equal(badUp.status, 403);

  const dlUrlRes = await rpc('query', 'files.download_url', { storage_id });
  assert.equal(dlUrlRes.json.ok, true);
  const dlResp = await fetch(dlUrlRes.json.value);
  assert.equal(dlResp.status, 200);
  assert.equal(dlResp.headers.get('content-type'), 'text/plain; charset=utf-8');
  assert.equal(await dlResp.text(), blobPayload);

  const delRes = await rpc('mutation', 'files.delete', { storage_id });
  assert.equal(delRes.json.ok, true);
  const dlAfterDelete = await fetch(dlUrlRes.json.value);
  assert.equal(dlAfterDelete.status, 404);

  // ---------------------------------------------------------------------------
  // 3. Reactive Cursor Pagination + Full-Text Search + Live Custom HTTP Webhooks
  // ---------------------------------------------------------------------------
  const seedNotes = [
    { title: 'One', body: 'Zero dependency Zig runtime', seq: 1 },
    { title: 'Two', body: 'Roc functional backend platform', seq: 2 },
    { title: 'Three', body: 'Formal verification with Lean and Zig', seq: 3 },
    { title: 'Four', body: 'PostgreSQL wire protocol TLS 1.3', seq: 4 },
    { title: 'Five', body: 'Reactive signals in vanilla browser ESM', seq: 5 },
  ];
  for (const n of seedNotes) {
    const r = await rpc('mutation', 'notes.create', n);
    assert.equal(r.json.ok, true);
  }

  // Step through 3 pages of size 2: [1,2] -> [3,4] -> [5]
  const p1 = (await rpc('query', 'notes.paginate', { cursor: '', page_size: 2 })).json.value;
  assert.deepEqual(p1.page.map((d) => d.seq), [1, 2]);
  assert.equal(p1.is_done, false);
  assert.ok(p1.next_cursor.length > 0);

  const p2 = (await rpc('query', 'notes.paginate', { cursor: p1.next_cursor, page_size: 2 })).json.value;
  assert.deepEqual(p2.page.map((d) => d.seq), [3, 4]);
  assert.equal(p2.is_done, false);

  const p3 = (await rpc('query', 'notes.paginate', { cursor: p2.next_cursor, page_size: 2 })).json.value;
  assert.deepEqual(p3.page.map((d) => d.seq), [5]);
  assert.equal(p3.is_done, true);
  assert.equal(p3.next_cursor, '');

  // Full-text multi-token case-insensitive search
  const s1 = (await rpc('query', 'notes.search', { q: 'zig lean', limit: 10 })).json.value;
  assert.equal(s1.length, 1);
  assert.equal(s1[0].title, 'Three');

  // Open a live WebSocket subscription to `notes.search` ("webhook") AND trigger a Custom HTTP Route!
  const ws = new WebSocket(WS_URL);
  const transitions = [];
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });
  ws.addEventListener('message', (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'transition') transitions.push(msg);
  });

  ws.send(JSON.stringify({
    type: 'subscribe',
    sub_id: 'search_sub',
    name: 'notes.search',
    args: { q: 'webhook zig', limit: 10 },
  }));

  await pollUntil(() => transitions.length >= 1);
  assert.deepEqual(transitions[0].updates[0].value, []);

  // Hit custom POST /webhooks/note?source=stripe -> inserts matching note -> pushes live WS update!
  const whResp = await fetch(`${BASE_URL}/webhooks/note?source=stripe`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: 'Six', body: 'Incoming Stripe Webhook via Zig', seq: 6 }),
  });
  assert.equal(whResp.status, 201);
  const whJson = await whResp.json();
  assert.equal(whJson.received, true);
  assert.equal(whJson.query, 'source=stripe');
  assert.ok(whJson.note_id.length > 0);

  // Verify live WS reactive search subscription updated automatically!
  await pollUntil(() => transitions.length >= 2);
  const liveDocs = transitions[1].updates[0].value;
  assert.equal(liveDocs.length, 1);
  assert.equal(liveDocs[0].title, 'Six');

  // Verify wildcard custom HTTP route (`GET /webhooks/echo/*`)
  const echoResp = await fetch(`${BASE_URL}/webhooks/echo/v1/ping?hello=world`);
  assert.equal(echoResp.status, 200);
  const echoJson = await echoResp.json();
  assert.equal(echoJson.method, 'GET');
  assert.equal(echoJson.path, '/webhooks/echo/v1/ping');
  assert.equal(echoJson.query, 'hello=world');

  ws.close();
});
