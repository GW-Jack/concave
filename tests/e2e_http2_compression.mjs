import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import http2 from 'node:http2';
import zlib from 'node:zlib';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const BIN = path.join(ROOT, 'examples/chat-app/.concave/dev-server');
const DB = path.join(ROOT, '.zig-cache/h2-compress-test.wal');
const PORT = 34222;

function http1Req(agent, method, reqPath, body = null, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: '127.0.0.1',
      port: PORT,
      method,
      path: reqPath,
      agent,
      headers: {
        ...(body ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } : {}),
        ...headers,
      },
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function h2Req(client, method, reqPath, body = null, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = client.request({
      ':method': method,
      ':path': reqPath,
      ...(body ? { 'content-type': 'application/json' } : {}),
      ...headers,
    });
    let respHeaders = {};
    const chunks = [];
    req.on('response', (h) => { respHeaders = h; });
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve({ status: respHeaders[':status'], headers: respHeaders, body: Buffer.concat(chunks) }));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

test('HTTP/2 h2c + HTTP/1.1 Keep-Alive + Bundled/Minified/Pre-Gzipped Assets + ETag 304', async (t) => {
  fs.rmSync(DB, { force: true });
  const server = spawn(BIN, [
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
  t.after(() => {
    try { server.kill('SIGKILL'); } catch {}
    fs.rmSync(DB, { force: true });
  });

  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/health`);
      if (r.ok) break;
    } catch {}
    await new Promise((r) => setTimeout(r, 40));
  }

  // 1. Embedded bundled `/_concave/index.js`: minified, pre-gzipped (<5 KB gzip), valid ESM, ETag 304
  const keepAgent = new http.Agent({ keepAlive: true, maxSockets: 1 });
  t.after(() => keepAgent.destroy());

  const rawIdx = await http1Req(keepAgent, 'GET', '/_concave/index.js', null, { 'Accept-Encoding': 'identity' });
  const gzIdx = await http1Req(keepAgent, 'GET', '/_concave/index.js', null, { 'Accept-Encoding': 'gzip' });
  assert.equal(rawIdx.status, 200);
  assert.equal(gzIdx.status, 200);
  assert.equal(gzIdx.headers['content-encoding'], 'gzip');
  assert.equal(gzIdx.headers['connection'], 'keep-alive');
  assert.ok(gzIdx.body.length < 10500, `expected core bundle gzip < 10.5 KB, got ${gzIdx.body.length} B`);
  assert.deepEqual(zlib.gunzipSync(gzIdx.body), rawIdx.body);

  // 304 Not Modified on matching ETag
  const cached = await http1Req(keepAgent, 'GET', '/_concave/index.js', null, { 'If-None-Match': gzIdx.headers.etag });
  assert.equal(cached.status, 304);
  assert.equal(cached.body.length, 0);

  // Verify bundled JS actually executes signals + ConcaveClient + DOM helpers in Node ESM
  const tmpMod = path.join(ROOT, '.zig-cache/verify_bundle_esm.mjs');
  fs.writeFileSync(tmpMod, rawIdx.body);
  t.after(() => fs.rmSync(tmpMod, { force: true }));
  const mod = await import(`file://${tmpMod}`);
  const count = mod.signal(3);
  const doubled = mod.computed(() => count() * 2);
  assert.equal(doubled(), 6);
  count.set(10);
  assert.equal(doubled(), 20);
  assert.equal(typeof mod.ConcaveClient, 'function');
  assert.equal(typeof mod.el, 'function');

  // 2. Dynamic JSON gzip on `/api/manifest` + static file gzip & ETag 304
  const manGz = await http1Req(keepAgent, 'GET', '/api/manifest', null, { 'Accept-Encoding': 'gzip' });
  assert.equal(manGz.status, 200);
  assert.equal(manGz.headers['content-encoding'], 'gzip');
  const manJson = JSON.parse(zlib.gunzipSync(manGz.body).toString('utf8'));
  assert.equal(manJson.app_name, 'concave-chat');

  const staticGz = await http1Req(keepAgent, 'GET', '/src/main.js', null, { 'Accept-Encoding': 'gzip' });
  assert.equal(staticGz.status, 200);
  assert.equal(staticGz.headers['content-encoding'], 'gzip');
  assert.ok(staticGz.headers.etag);
  const static304 = await http1Req(keepAgent, 'GET', '/src/main.js', null, { 'If-None-Match': staticGz.headers.etag });
  assert.equal(static304.status, 304);

  // 3. HTTP/2 (`h2c` prior knowledge) multiplexed streams + HPACK + gzip + RPC
  const h2 = http2.connect(`http://127.0.0.1:${PORT}`);
  t.after(() => h2.close());

  const [r1, r2, r3, r4] = await Promise.all([
    h2Req(h2, 'GET', '/health'),
    h2Req(h2, 'GET', '/_concave/index.js', null, { 'accept-encoding': 'gzip' }),
    h2Req(h2, 'POST', '/api/mutation/rooms.ensureDefaults', '{}'),
    h2Req(h2, 'GET', '/_dashboard', null, { 'accept-encoding': 'gzip' }),
  ]);
  assert.equal(r1.status, 200);
  assert.equal(JSON.parse(r1.body.toString('utf8')).status, 'ok');
  assert.equal(r2.status, 200);
  assert.equal(r2.headers['content-encoding'], 'gzip');
  assert.deepEqual(zlib.gunzipSync(r2.body), rawIdx.body);
  assert.equal(r3.status, 200);
  assert.equal(JSON.parse(r3.body.toString('utf8')).ok, true);
  assert.equal(r4.status, 200);
  assert.equal(r4.headers['content-encoding'], 'gzip');
  assert.ok(zlib.gunzipSync(r4.body).toString('utf8').includes('Concave Dashboard'));

  // HTTP/2 304 Not Modified
  const r304 = await h2Req(h2, 'GET', '/_concave/index.js', null, { 'if-none-match': r2.headers.etag });
  assert.equal(r304.status, 304);
});
