import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import http from 'node:http';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const FIXTURE = path.join(ROOT, 'tests/fixtures/platform-features-app/main.roc');
const BIN = path.join(ROOT, '.zig-cache/platform-features-bin');
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

test('Track 3 E2E: RS256/EdDSA/ES256 JWKS + Key Rotation + Live Dashboard + Admin Guard + Graceful SIGTERM', async (t) => {
  fs.rmSync(DB_PATH, { force: true });
  fs.rmSync(STORAGE_DIR, { recursive: true, force: true });

  // Build fresh binary with Track 3 host
  execFileSync('roc', ['build', `--output=${BIN}`, FIXTURE], { cwd: ROOT, stdio: 'inherit' });

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

  const statsRes = await fetch(`${BASE_URL}/_admin/stats`, {
    headers: { Authorization: `Bearer ${ADMIN_KEY}` },
  });
  assert.equal(statsRes.status, 200);
  const stats = await statsRes.json();
  assert.equal(stats.app_name, 'platform-features-test');
  assert.ok(stats.commit_ts >= 3);
  assert.equal(stats.active_clients, 1);

  const tblRes = await fetch(`${BASE_URL}/_admin/table?ns=&table=notes&limit=10`, {
    headers: { Authorization: `Bearer ${ADMIN_KEY}` },
  });
  assert.equal(tblRes.status, 200);
  const notes = await tblRes.json();
  assert.equal(notes.length, 3);

  const jobsRes = await fetch(`${BASE_URL}/_admin/jobs`, {
    headers: { Authorization: `Bearer ${ADMIN_KEY}` },
  });
  assert.equal(jobsRes.status, 200);
  const jobs = await jobsRes.json();
  assert.ok(Array.isArray(jobs));

  // 6. Graceful SIGTERM drain: WS receives Close AND process exits with code 0!
  const wsClosed = new Promise((resolve) => ws.addEventListener('close', () => resolve(true), { once: true }));
  const procExited = new Promise((resolve) => server.once('exit', (code, signal) => resolve({ code, signal })));

  server.kill('SIGTERM');

  const closedOk = await Promise.race([
    wsClosed,
    new Promise((r) => setTimeout(() => r(false), 3000)),
  ]);
  const exitInfo = await Promise.race([
    procExited,
    new Promise((r) => setTimeout(() => r({ code: -1, signal: 'TIMEOUT' }), 3000)),
  ]);

  assert.equal(closedOk, true, 'connected WS client must receive Close frame on SIGTERM');
  assert.equal(exitInfo.code, 0, `server must exit cleanly with code 0 on SIGTERM (got ${JSON.stringify(exitInfo)})`);
});
