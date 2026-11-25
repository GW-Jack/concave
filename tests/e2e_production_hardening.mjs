import test, { before } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http from 'node:http';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const FIXTURE = path.join(ROOT, 'tests/fixtures/platform-features-app/main.roc');
const BIN = path.join(ROOT, '.zig-cache/production-hardening-bin');
const CONCAVE_CLI = path.join(ROOT, 'zig-out/bin/concave');
const DB_PATH = path.join(ROOT, '.zig-cache/prod-hardening-e2e.wal');
const STORAGE_DIR = path.join(ROOT, '.zig-cache/prod-hardening-storage');
const PORT = 34215;
const BASE_URL = `http://127.0.0.1:${PORT}`;
const WS_URL = `ws://127.0.0.1:${PORT}/ws`;

function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

function signJwt({ header, payload, privateKey, alg }) {
  const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  let sig;
  if (alg === 'RS256') {
    sig = crypto.sign('sha256', Buffer.from(input), privateKey);
  } else if (alg === 'EdDSA') {
    sig = crypto.sign(null, Buffer.from(input), privateKey);
  } else if (alg === 'ES256') {
    sig = crypto.sign('sha256', Buffer.from(input), { key: privateKey, dsaEncoding: 'ieee-p1363' });
  } else {
    throw new Error(`unsupported alg ${alg}`);
  }
  return `${input}.${b64url(sig)}`;
}

async function waitForHealth(url, timeoutMs = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const res = await fetch(`${url}/health`);
      if (res.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`server at ${url} did not become healthy`);
}

async function pollUntil(predicate, timeoutMs = 10000, intervalMs = 50, label = 'condition') {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const v = await predicate();
    if (v) return v;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`timed out waiting for ${label} after ${timeoutMs}ms`);
}

async function stopServerCleanly(proc, timeoutMs = 5000) {
  if (proc.exitCode !== null) return { code: proc.exitCode, signal: proc.signalCode };
  const exited = new Promise((resolve) => proc.once('exit', (code, signal) => resolve({ code, signal })));
  proc.kill('SIGTERM');
  return Promise.race([
    exited,
    new Promise((r) => setTimeout(() => r({ code: -1, signal: 'TIMEOUT' }), timeoutMs)),
  ]);
}

before(() => {
  // Build fresh Roc+Zig fixture binary once for all production hardening E2E tests
  execFileSync('roc', ['build', `--output=${BIN}`, FIXTURE], { cwd: ROOT, stdio: 'inherit' });
  if (!fs.existsSync(CONCAVE_CLI)) {
    execFileSync('zig', ['build'], { cwd: ROOT, stdio: 'inherit' });
  }
});

test('Track 3 E2E: RS256/EdDSA/ES256 JWKS + Key Rotation + Live Dashboard + Admin Mutations + Graceful SIGTERM', async (t) => {
  fs.rmSync(DB_PATH, { force: true });
  fs.rmSync(STORAGE_DIR, { recursive: true, force: true });

  // Generate real RSA-2048, Ed25519, and P-256 keypairs + a rotated RSA-2048 keypair
  const rsa1 = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const rsa2 = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const ed1 = crypto.generateKeyPairSync('ed25519');
  const ec1 = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });

  const toJwk = (pub, kid) => ({ ...pub.export({ format: 'jwk' }), kid });
  let activeKeys = [
    toJwk(rsa1.publicKey, 'rsa-1'),
    toJwk(ed1.publicKey, 'ed-1'),
    toJwk(ec1.publicKey, 'ec-1'),
  ];
  let jwksFetches = 0;

  const jwksServer = http.createServer((req, res) => {
    if (req.url === '/.well-known/jwks.json') {
      jwksFetches += 1;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ keys: activeKeys }));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((resolve) => jwksServer.listen(0, '127.0.0.1', resolve));
  const jwksPort = jwksServer.address().port;
  const jwksUrl = `http://127.0.0.1:${jwksPort}/.well-known/jwks.json`;

  const ADMIN_KEY = 'prod-super-secret-admin-key';
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
      CONCAVE_SCHEDULER_POLL_MS: '100',
      CONCAVE_COMMIT_POLL_MS: '50',
      CONCAVE_ALLOW_DEV_TOKENS: 'false',
      CONCAVE_ALLOW_PRIVATE_HTTP: 'true',
      CONCAVE_JWKS_URL: jwksUrl,
      CONCAVE_JWT_ISSUER: 'https://idp.concave.test',
      CONCAVE_JWT_AUDIENCE: 'concave-prod',
      CONCAVE_ADMIN_KEY: ADMIN_KEY,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  t.after(() => {
    try { server.kill('SIGKILL'); } catch {}
    try { jwksServer.close(); } catch {}
    fs.rmSync(DB_PATH, { force: true });
    fs.rmSync(STORAGE_DIR, { recursive: true, force: true });
  });

  await waitForHealth(BASE_URL);

  const nowSec = Math.floor(Date.now() / 1000);
  const validClaims = {
    sub: 'user_42',
    iss: 'https://idp.concave.test',
    aud: 'concave-prod',
    name: 'Alice Prod',
    exp: nowSec + 300,
    nbf: nowSec - 10,
  };

  // 1. Dev token MUST be rejected when CONCAVE_ALLOW_DEV_TOKENS=false
  const devRes = await fetch(`${BASE_URL}/api/query/events.list`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer dev:alice' },
    body: '{}',
  });
  assert.equal(devRes.status, 401);

  // 2. Valid RS256, EdDSA, and ES256 JWTs all succeed via live JWKS endpoint!
  const rsJwt = signJwt({ header: { alg: 'RS256', kid: 'rsa-1', typ: 'JWT' }, payload: validClaims, privateKey: rsa1.privateKey, alg: 'RS256' });
  const edJwt = signJwt({ header: { alg: 'EdDSA', kid: 'ed-1', typ: 'JWT' }, payload: validClaims, privateKey: ed1.privateKey, alg: 'EdDSA' });
  const ecJwt = signJwt({ header: { alg: 'ES256', kid: 'ec-1', typ: 'JWT' }, payload: validClaims, privateKey: ec1.privateKey, alg: 'ES256' });

  for (const [label, tok] of [['RS256', rsJwt], ['EdDSA', edJwt], ['ES256', ecJwt]]) {
    const r = await fetch(`${BASE_URL}/api/mutation/notes.create`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${tok}` },
      body: JSON.stringify({ title: label, body: `Authenticated via ${label}`, seq: 1 }),
    });
    assert.equal(r.status, 200, `${label} JWT should authenticate`);
    const j = await r.json();
    assert.equal(j.ok, true);
  }
  assert.equal(jwksFetches, 1, 'JWKS should be cached after initial fetch');

  // 3. Tampered RS256 signature & wrong audience MUST be rejected (401)
  const badSig = rsJwt.slice(0, -4) + (rsJwt.endsWith('AAAA') ? 'BBBB' : 'AAAA');
  assert.equal((await fetch(`${BASE_URL}/api/query/events.list`, {
    method: 'POST', headers: { Authorization: `Bearer ${badSig}` }, body: '{}',
  })).status, 401);

  const wrongAud = signJwt({
    header: { alg: 'RS256', kid: 'rsa-1' },
    payload: { ...validClaims, aud: 'other-app' },
    privateKey: rsa1.privateKey,
    alg: 'RS256',
  });
  assert.equal((await fetch(`${BASE_URL}/api/query/events.list`, {
    method: 'POST', headers: { Authorization: `Bearer ${wrongAud}` }, body: '{}',
  })).status, 401);

  // 4. Live JWKS Key Rotation: publish `rsa-2` after refresh cooldown and authenticate immediately!
  activeKeys = [toJwk(rsa2.publicKey, 'rsa-2')];
  await new Promise((r) => setTimeout(r, 1100));
  const rs2Jwt = signJwt({ header: { alg: 'RS256', kid: 'rsa-2' }, payload: validClaims, privateKey: rsa2.privateKey, alg: 'RS256' });
  const rotRes = await fetch(`${BASE_URL}/api/query/events.list`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${rs2Jwt}` },
    body: '{}',
  });
  assert.equal(rotRes.status, 200, 'rotated RSA-2048 kid should trigger JWKS refresh and succeed');
  assert.equal(jwksFetches, 2);

  // 5. Built-in Live Dev Dashboard (`/_dashboard`) + Admin API (`/_admin/*`) + Admin Key Guard
  const dashHtml = await fetch(`${BASE_URL}/_dashboard`);
  assert.equal(dashHtml.status, 200);
  assert.ok((await dashHtml.text()).includes('Concave Dashboard'));
  assert.equal((await fetch(`${BASE_URL}/_dashboard/styles.css`)).status, 200);
  assert.equal((await fetch(`${BASE_URL}/_dashboard/app.js`)).status, 200);

  // Admin API without key -> 401; with key -> 200
  assert.equal((await fetch(`${BASE_URL}/_admin/stats`)).status, 401);
  assert.equal((await fetch(`${BASE_URL}/_admin/stats`, { headers: { Authorization: 'Bearer wrong' } })).status, 401);

  // Interactive admin mutation endpoints MUST reject unauthenticated calls with 401
  for (const [ep, payload] of [
    ['/_admin/doc/patch', { ns: '', table: 'notes', id: 'x', patch: { title: 'nope' } }],
    ['/_admin/doc/delete', { ns: '', table: 'notes', id: 'x' }],
    ['/_admin/jobs/cancel', { job_id: 'x' }],
    ['/_admin/jobs/retry', { job_id: 'x' }],
  ]) {
    const unauth = await fetch(`${BASE_URL}${ep}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    assert.equal(unauth.status, 401, `${ep} must reject unauthenticated POST with 401`);
  }

  // Open a live WS connection + authenticate with rotated RS256 JWT before inspecting `/_admin/stats`
  const ws = new WebSocket(WS_URL);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });
  const authPromise = new Promise((resolve) => {
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.type === 'auth_result') resolve(m);
    });
  });
  ws.send(JSON.stringify({ type: 'authenticate', token: rs2Jwt }));
  const wsAuth = await authPromise;
  assert.equal(wsAuth.ok, true);
  assert.equal(wsAuth.identity.subject, 'user_42');

  const adminHeaders = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${ADMIN_KEY}`,
  };

  const statsRes = await fetch(`${BASE_URL}/_admin/stats`, { headers: adminHeaders });
  assert.equal(statsRes.status, 200);
  const stats = await statsRes.json();
  assert.equal(stats.app_name, 'platform-features-test');
  assert.ok(stats.commit_ts >= 3);
  assert.equal(stats.active_clients, 1);

  const tblRes = await fetch(`${BASE_URL}/_admin/table?ns=&table=notes&limit=10`, { headers: adminHeaders });
  assert.equal(tblRes.status, 200);
  const notes = await tblRes.json();
  assert.equal(notes.length, 3);

  // 5b. Authenticated `/_admin/doc/patch` and `/_admin/doc/delete`
  const patchRes = await fetch(`${BASE_URL}/_admin/doc/patch`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({
      ns: '',
      table: 'notes',
      id: notes[0].id,
      patch: { title: 'Patched By Admin', body: 'Admin updated body content' },
    }),
  });
  assert.equal(patchRes.status, 200);
  assert.equal((await patchRes.json()).ok, true);

  const searchRes = await fetch(`${BASE_URL}/api/query/notes.search`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${rs2Jwt}` },
    body: JSON.stringify({ q: 'admin updated', limit: 10 }),
  });
  assert.equal(searchRes.status, 200);
  const searchJson = await searchRes.json();
  assert.equal(searchJson.ok, true);
  assert.equal(searchJson.value.length, 1);
  assert.equal(searchJson.value[0].id, notes[0].id);
  assert.equal(searchJson.value[0].title, 'Patched By Admin');

  const delRes = await fetch(`${BASE_URL}/_admin/doc/delete`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({ ns: '', table: 'notes', id: notes[2].id }),
  });
  assert.equal(delRes.status, 200);
  assert.equal((await delRes.json()).ok, true);

  const notesAfterDel = await (await fetch(`${BASE_URL}/_admin/table?ns=&table=notes&limit=10`, { headers: adminHeaders })).json();
  assert.equal(notesAfterDel.length, 2);
  assert.equal(notesAfterDel.some((n) => n.id === notes[2].id), false);

  // 5c. Authenticated `/_admin/jobs/cancel` + `/_admin/jobs/retry` on a delayed scheduled job
  const schedRes = await fetch(`${BASE_URL}/api/mutation/jobs.schedule_commit`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${rs2Jwt}` },
    body: JSON.stringify({ delay_ms: 60_000, detail: 'admin-retried-live-job' }),
  });
  assert.equal(schedRes.status, 200);
  const schedJson = await schedRes.json();
  assert.equal(schedJson.ok, true);
  const jobId = schedJson.value;

  const jobsRes = await fetch(`${BASE_URL}/_admin/jobs`, { headers: adminHeaders });
  assert.equal(jobsRes.status, 200);
  const jobs = await jobsRes.json();
  assert.ok(Array.isArray(jobs));
  const pendingJob = jobs.find((j) => j.id === jobId);
  assert.ok(pendingJob, 'newly scheduled job must appear in /_admin/jobs');
  assert.equal(pendingJob.status, 'pending');

  const cancelJobRes = await fetch(`${BASE_URL}/_admin/jobs/cancel`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({ job_id: jobId }),
  });
  assert.equal(cancelJobRes.status, 200);
  assert.equal((await cancelJobRes.json()).ok, true);

  const jobsAfterCancel = await (await fetch(`${BASE_URL}/_admin/jobs`, { headers: adminHeaders })).json();
  assert.equal(jobsAfterCancel.find((j) => j.id === jobId)?.status, 'canceled');

  const retryJobRes = await fetch(`${BASE_URL}/_admin/jobs/retry`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({ job_id: jobId }),
  });
  assert.equal(retryJobRes.status, 200);
  assert.equal((await retryJobRes.json()).ok, true);

  // Retrying schedules immediate execution; verify it transitions out of canceled and completes!
  await pollUntil(async () => {
    const evRes = await fetch(`${BASE_URL}/api/query/events.list`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${rs2Jwt}` },
      body: '{}',
    });
    const evJson = await evRes.json();
    return evJson.ok && evJson.value.some((e) => e.detail === 'admin-retried-live-job');
  }, 4000, 50, 'retried job to execute');

  // 6. Graceful SIGTERM drain: WS receives Close AND process exits with code 0!
  const wsClosed = new Promise((resolve) => ws.addEventListener('close', () => resolve(true), { once: true }));
  const exitInfo = await stopServerCleanly(server, 3000);
  const closedOk = await Promise.race([
    wsClosed,
    new Promise((r) => setTimeout(() => r(false), 3000)),
  ]);

  assert.equal(closedOk, true, 'connected WS client must receive Close frame on SIGTERM');
  assert.equal(exitInfo.code, 0, `server must exit cleanly with code 0 on SIGTERM (got ${JSON.stringify(exitInfo)})`);
});

test('Per-IP edge rate limiting returns 429 + Retry-After while /health and /ready stay 200 OK', async (t) => {
  const rlPort = 13246;
  const rlBase = `http://127.0.0.1:${rlPort}`;
  const rlDb = path.join(ROOT, '.zig-cache/prod-hardening-ratelimit.wal');
  fs.rmSync(rlDb, { force: true });

  const srv = spawn(BIN, [
    '--serve',
    '--host', '127.0.0.1',
    '--port', String(rlPort),
    '--db', rlDb,
  ], {
    cwd: ROOT,
    env: {
      ...process.env,
      CONCAVE_RATE_LIMIT_RPS: '2',
      CONCAVE_RATE_LIMIT_BURST: '3',
      CONCAVE_SCHEDULER_POLL_MS: '0',
      CONCAVE_COMMIT_POLL_MS: '0',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => {
    try { srv.kill('SIGKILL'); } catch {}
    fs.rmSync(rlDb, { force: true });
  });

  await waitForHealth(rlBase);

  let okCount = 0;
  let rateLimitedResp = null;
  for (let i = 0; i < 10; i++) {
    const res = await fetch(`${rlBase}/api/query/events.list`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (res.status === 200) {
      okCount += 1;
    } else if (res.status === 429) {
      rateLimitedResp = {
        status: res.status,
        retryAfter: res.headers.get('retry-after'),
        body: await res.json(),
      };
      break;
    }
  }

  assert.ok(okCount >= 1 && okCount <= 4, `expected initial burst of ~3 allowed requests, got ${okCount}`);
  assert.ok(rateLimitedResp, 'rapid burst must trigger HTTP 429');
  assert.equal(rateLimitedResp.status, 429);
  assert.match(String(rateLimitedResp.retryAfter ?? ''), /^\d+$/, 'Retry-After must be a numeric header');
  assert.ok(Number(rateLimitedResp.retryAfter) >= 1, 'Retry-After must be >= 1 second');
  assert.equal(rateLimitedResp.body.error, 'rate limit exceeded');

  // Health and readiness probes MUST remain 200 OK even while the caller IP is rate-limited!
  const healthRes = await fetch(`${rlBase}/health`);
  const readyRes = await fetch(`${rlBase}/ready`);
  assert.equal(healthRes.status, 200, '/health must remain exempt from rate limiting');
  assert.equal(readyRes.status, 200, '/ready must remain exempt from rate limiting');

  const exitInfo = await stopServerCleanly(srv);
  assert.equal(exitInfo.code, 0);
});

test('Scheduler exponential backoff retry and dead-letter ("dead") status', async (t) => {
  const schedPort = 13247;
  const schedBase = `http://127.0.0.1:${schedPort}`;
  const schedDb = path.join(ROOT, '.zig-cache/prod-hardening-scheduler-dlq.wal');
  const adminKey = 'sched-dlq-admin-key';
  fs.rmSync(schedDb, { force: true });

  const srv = spawn(BIN, [
    '--serve',
    '--host', '127.0.0.1',
    '--port', String(schedPort),
    '--db', schedDb,
  ], {
    cwd: ROOT,
    env: {
      ...process.env,
      CONCAVE_SCHEDULER_POLL_MS: '50',
      CONCAVE_COMMIT_POLL_MS: '0',
      CONCAVE_ADMIN_KEY: adminKey,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(() => {
    try { srv.kill('SIGKILL'); } catch {}
    fs.rmSync(schedDb, { force: true });
  });

  await waitForHealth(schedBase);

  // Internal mutation MUST NOT be directly callable via public HTTP RPC
  const directFail = await fetch(`${schedBase}/api/mutation/jobs.always_fail`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ reason: 'direct-call' }),
  });
  assert.ok(directFail.status === 403 || directFail.status === 404 || (await directFail.json()).ok === false);

  const scheduledAt = Date.now();
  const schedRes = await fetch(`${schedBase}/api/mutation/jobs.schedule_failing`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ delay_ms: 0, reason: 'boom-dlq' }),
  });
  assert.equal(schedRes.status, 200);
  const schedJson = await schedRes.json();
  assert.equal(schedJson.ok, true);
  const failJobId = schedJson.value;

  const fetchJob = async () => {
    const r = await fetch(`${schedBase}/_admin/jobs`, {
      headers: { Authorization: `Bearer ${adminKey}` },
    });
    assert.equal(r.status, 200);
    const list = await r.json();
    return list.find((j) => j.id === failJobId);
  };

  // 1. First failure -> rescheduled as pending with exponential backoff and recorded last_error
  const afterFirst = await pollUntil(async () => {
    const j = await fetchJob();
    return j && j.attempts >= 1 && j.status === 'pending' && j.last_error ? j : null;
  }, 5000, 50, 'failing job attempt 1 retry backoff');
  assert.ok(afterFirst.last_error.includes('always_fail: boom-dlq'), `unexpected last_error: ${afterFirst.last_error}`);
  assert.ok(afterFirst.run_at_ms >= scheduledAt + 500, 'retry run_at_ms must include backoff delay');

  // 2. Subsequent retry executes and increments attempts
  const afterSecond = await pollUntil(async () => {
    const j = await fetchJob();
    return j && j.attempts >= 2 ? j : null;
  }, 5000, 100, 'failing job attempt 2');
  assert.ok(afterSecond.attempts >= 2);

  // 3. Exhausting all 5 attempts (1s + 2s + 4s + 8s = 15s) transitions job to dead-letter ("dead")
  const deadJob = await pollUntil(async () => {
    const j = await fetchJob();
    return j && j.status === 'dead' ? j : null;
  }, 22_000, 150, 'failing job dead-letter transition');
  assert.equal(deadJob.status, 'dead');
  assert.equal(deadJob.attempts, 5);
  assert.ok(deadJob.last_error.includes('always_fail: boom-dlq'));

  const exitInfo = await stopServerCleanly(srv);
  assert.equal(exitInfo.code, 0);
});

test('CLI concave backup + concave restore E2E preserves committed WAL documents', async (t) => {
  const bkPort = 13248;
  const bkBase = `http://127.0.0.1:${bkPort}`;
  const srcDb = path.join(ROOT, '.zig-cache/prod-hardening-backup-src.wal');
  const bakFile = path.join(ROOT, '.zig-cache/prod-hardening-backup.bak');
  const restoredDb = path.join(ROOT, '.zig-cache/prod-hardening-backup-restored.wal');

  for (const p of [srcDb, bakFile, restoredDb]) fs.rmSync(p, { force: true });
  let srv1 = null;
  let srv2 = null;
  t.after(() => {
    try { srv1?.kill('SIGKILL'); } catch {}
    try { srv2?.kill('SIGKILL'); } catch {}
    for (const p of [srcDb, bakFile, restoredDb]) fs.rmSync(p, { force: true });
  });

  // 1. Start server on srcDb and commit 3 documents
  srv1 = spawn(BIN, ['--serve', '--host', '127.0.0.1', '--port', String(bkPort), '--db', srcDb], {
    cwd: ROOT,
    env: { ...process.env, CONCAVE_SCHEDULER_POLL_MS: '0', CONCAVE_COMMIT_POLL_MS: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await waitForHealth(bkBase);

  for (const n of [
    { title: 'Backup-1', body: 'First durable note', seq: 10 },
    { title: 'Backup-2', body: 'Second durable note', seq: 20 },
    { title: 'Backup-3', body: 'Third durable note', seq: 30 },
  ]) {
    const r = await fetch(`${bkBase}/api/mutation/notes.create`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(n),
    });
    assert.equal(r.status, 200);
    assert.equal((await r.json()).ok, true);
  }

  // Stop server cleanly before backup
  const exit1 = await stopServerCleanly(srv1);
  assert.equal(exit1.code, 0);

  // 2. Run `concave backup --db <src> --out <bak>`
  const bkRun = spawnSync(CONCAVE_CLI, ['backup', '--db', srcDb, '--out', bakFile], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  assert.equal(bkRun.status, 0, `concave backup failed: ${bkRun.stderr}`);
  assert.ok(fs.existsSync(bakFile) && fs.statSync(bakFile).size > 0, 'backup file must exist and be non-empty');

  // 3. Corrupt srcDb and verify restore refuses to overwrite without --force
  fs.writeFileSync(srcDb, 'CORRUPTED-WAL-DATA');
  const refuseRun = spawnSync(CONCAVE_CLI, ['restore', '--in', bakFile, '--db', srcDb], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  assert.notEqual(refuseRun.status, 0, 'concave restore must refuse to overwrite existing db without --force');

  // 4. Delete srcDb and run `concave restore --in <bak> --db <restored>`
  fs.rmSync(srcDb, { force: true });
  const restRun = spawnSync(CONCAVE_CLI, ['restore', '--in', bakFile, '--db', restoredDb], {
    cwd: ROOT,
    encoding: 'utf8',
  });
  assert.equal(restRun.status, 0, `concave restore failed: ${restRun.stderr}`);
  assert.ok(fs.existsSync(restoredDb), 'restored WAL file must exist');

  // 5. Restart server on restoredDb and verify all 3 committed documents are intact!
  srv2 = spawn(BIN, ['--serve', '--host', '127.0.0.1', '--port', String(bkPort), '--db', restoredDb], {
    cwd: ROOT,
    env: { ...process.env, CONCAVE_SCHEDULER_POLL_MS: '0', CONCAVE_COMMIT_POLL_MS: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await waitForHealth(bkBase);

  const pageRes = await fetch(`${bkBase}/api/query/notes.paginate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ cursor: '', page_size: 10 }),
  });
  assert.equal(pageRes.status, 200);
  const pageJson = await pageRes.json();
  assert.equal(pageJson.ok, true);
  assert.deepEqual(
    pageJson.value.page.map((d) => ({ title: d.title, seq: d.seq })),
    [
      { title: 'Backup-1', seq: 10 },
      { title: 'Backup-2', seq: 20 },
      { title: 'Backup-3', seq: 30 },
    ],
  );

  const exit2 = await stopServerCleanly(srv2);
  assert.equal(exit2.code, 0);
});

test('CLI concave secrets encrypted dev vault E2E + deterministic admin job cancel -> canceled -> retry -> pending', async (t) => {
  const secPort = 13249;
  const secBase = `http://127.0.0.1:${secPort}`;
  const secDb = path.join(ROOT, '.zig-cache/prod-hardening-secrets.wal');
  const tmpVault = path.join(ROOT, '.zig-cache/prod-hardening-dev.vault');
  const adminKey = 'vault-e2e-admin-key';

  fs.rmSync(secDb, { force: true });
  fs.rmSync(tmpVault, { force: true });

  let srv = null;
  t.after(() => {
    try { srv?.kill('SIGKILL'); } catch {}
    fs.rmSync(secDb, { force: true });
    fs.rmSync(tmpVault, { force: true });
  });

  // 1. Set secrets via CLI `concave secrets set` and verify `concave secrets list`
  const setAllowed = spawnSync(
    CONCAVE_CLI,
    ['secrets', 'set', 'VAULT_TEST_KEY', '--value', 'super-secret-42', '--vault', tmpVault, '--passphrase', 'e2e-pass'],
    { cwd: ROOT, encoding: 'utf8' },
  );
  assert.equal(setAllowed.status, 0, `concave secrets set failed: ${setAllowed.stderr}`);

  const setBlocked = spawnSync(
    CONCAVE_CLI,
    ['secrets', 'set', 'UNDECLARED_SECRET', '--value', 'must-not-leak', '--vault', tmpVault, '--passphrase', 'e2e-pass'],
    { cwd: ROOT, encoding: 'utf8' },
  );
  assert.equal(setBlocked.status, 0, `concave secrets set (undeclared) failed: ${setBlocked.stderr}`);

  const listRes = spawnSync(
    CONCAVE_CLI,
    ['secrets', 'list', '--vault', tmpVault, '--passphrase', 'e2e-pass'],
    { cwd: ROOT, encoding: 'utf8' },
  );
  assert.equal(listRes.status, 0, `concave secrets list failed: ${listRes.stderr}`);
  const listOut = listRes.stdout + listRes.stderr;
  assert.ok(listOut.includes('VAULT_TEST_KEY'), `expected VAULT_TEST_KEY in list output: ${listOut}`);
  assert.ok(listOut.includes('UNDECLARED_SECRET'), `expected UNDECLARED_SECRET in list output: ${listOut}`);
  assert.equal(listOut.includes('super-secret-42'), false, 'secrets list must NEVER print secret values');

  // Vault file on disk MUST be encrypted (no plaintext secret values)
  const rawVault = fs.readFileSync(tmpVault);
  assert.equal(rawVault.includes(Buffer.from('super-secret-42')), false);

  // 2. Start server configured with encrypted vault + passphrase (scheduler paused for deterministic cancel->retry->pending check)
  srv = spawn(BIN, ['--serve', '--host', '127.0.0.1', '--port', String(secPort), '--db', secDb], {
    cwd: ROOT,
    env: {
      ...process.env,
      CONCAVE_SECRETS_VAULT: tmpVault,
      CONCAVE_VAULT_PASSPHRASE: 'e2e-pass',
      CONCAVE_ADMIN_KEY: adminKey,
      CONCAVE_SCHEDULER_POLL_MS: '0',
      CONCAVE_COMMIT_POLL_MS: '0',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await waitForHealth(secBase);

  // 3. Action reads allowlisted VAULT_TEST_KEY via ctx.secrets.get! -> returns "super-secret-42"
  const okSecret = await fetch(`${secBase}/api/action/secrets.read`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'VAULT_TEST_KEY' }),
  });
  assert.equal(okSecret.status, 200);
  const okJson = await okSecret.json();
  assert.equal(okJson.ok, true);
  assert.equal(okJson.value, 'super-secret-42');

  // 4. Non-allowlisted secret MUST be rejected even though it exists in the vault!
  const deniedSecret = await fetch(`${secBase}/api/action/secrets.read`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'UNDECLARED_SECRET' }),
  });
  const deniedJson = await deniedSecret.json();
  assert.equal(deniedJson.ok, false, 'non-allowlisted secret must be rejected');

  // 5. Deterministic `/_admin/jobs/cancel` -> "canceled" -> `/_admin/jobs/retry` -> "pending"
  const schedRes = await fetch(`${secBase}/api/mutation/jobs.schedule_commit`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ delay_ms: 60_000, detail: 'deterministic-cancel-retry' }),
  });
  const schedJson = await schedRes.json();
  assert.equal(schedJson.ok, true);
  const jobId = schedJson.value;

  const adminHeaders = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${adminKey}`,
  };

  assert.equal((await fetch(`${secBase}/_admin/jobs/cancel`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({ job_id: jobId }),
  })).status, 200);
  const afterCancel = await (await fetch(`${secBase}/_admin/jobs`, { headers: adminHeaders })).json();
  assert.equal(afterCancel.find((j) => j.id === jobId)?.status, 'canceled');

  assert.equal((await fetch(`${secBase}/_admin/jobs/retry`, {
    method: 'POST',
    headers: adminHeaders,
    body: JSON.stringify({ job_id: jobId }),
  })).status, 200);
  const afterRetry = await (await fetch(`${secBase}/_admin/jobs`, { headers: adminHeaders })).json();
  assert.equal(afterRetry.find((j) => j.id === jobId)?.status, 'pending');

  const exitInfo = await stopServerCleanly(srv);
  assert.equal(exitInfo.code, 0);
});
