import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

function buildWsFrame({ fin = true, rsv = 0, opcode = 0x1, masked = true, payload = Buffer.alloc(0), forceLenBits = null }) {
  const b0 = (fin ? 0x80 : 0x00) | ((rsv & 0x7) << 4) | (opcode & 0x0f);
  const len = payload.length;
  let hdr;
  const mbit = masked ? 0x80 : 0x00;

  if (forceLenBits === 127 || len > 65535) {
    hdr = Buffer.alloc(10);
    hdr[0] = b0;
    hdr[1] = mbit | 127;
    hdr.writeBigUInt64BE(BigInt(len), 2);
  } else if (forceLenBits === 126 || len >= 126) {
    hdr = Buffer.alloc(4);
    hdr[0] = b0;
    hdr[1] = mbit | 126;
    hdr.writeUInt16BE(len, 2);
  } else {
    hdr = Buffer.alloc(2);
    hdr[0] = b0;
    hdr[1] = mbit | len;
  }

  if (!masked) return Buffer.concat([hdr, payload]);
  const mask = crypto.randomBytes(4);
  const maskedBody = Buffer.alloc(len);
  for (let i = 0; i < len; i += 1) maskedBody[i] = payload[i] ^ mask[i & 3];
  return Buffer.concat([hdr, mask, maskedBody]);
}

function parseNextServerFrame(buf) {
  if (buf.length < 2) return null;
  const fin = (buf[0] & 0x80) !== 0;
  const opcode = buf[0] & 0x0f;
  const masked = (buf[1] & 0x80) !== 0;
  let len = buf[1] & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buf.length < 4) return null;
    len = buf.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    if (buf.length < 10) return null;
    len = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }
  if (buf.length < offset + len) return null;
  return {
    fin,
    opcode,
    masked,
    payload: buf.subarray(offset, offset + len),
    rest: buf.subarray(offset + len),
  };
}

class RawWsConn {
  constructor(port) {
    this.port = port;
    this.buf = Buffer.alloc(0);
    this.closed = false;
    this.waiters = [];
  }

  async connect(wsKey = crypto.randomBytes(16).toString("base64")) {
    this.sock = net.createConnection({ host: "127.0.0.1", port: this.port });
    await new Promise((resolve, reject) => {
      this.sock.once("connect", resolve);
      this.sock.once("error", reject);
    });
    this.sock.on("data", (chunk) => {
      this.buf = Buffer.concat([this.buf, chunk]);
      this._drainWaiters();
    });
    this.sock.on("close", () => {
      this.closed = true;
      this._drainWaiters();
    });
    this.sock.on("error", () => {
      this.closed = true;
      this._drainWaiters();
    });

    const req =
      `GET /ws HTTP/1.1\r\n` +
      `Host: 127.0.0.1:${this.port}\r\n` +
      `Upgrade: websocket\r\n` +
      `Connection: Upgrade\r\n` +
      `Sec-WebSocket-Key: ${wsKey}\r\n` +
      `Sec-WebSocket-Version: 13\r\n\r\n`;
    this.sock.write(req);

    const headerEnd = await this._waitFor(() => {
      const idx = this.buf.indexOf("\r\n\r\n");
      return idx >= 0 ? idx : null;
    });
    const rawHeaders = this.buf.subarray(0, headerEnd).toString("utf8");
    this.buf = this.buf.subarray(headerEnd + 4);

    const expectedAccept = crypto
      .createHash("sha1")
      .update(wsKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      .digest("base64");
    assert.ok(rawHeaders.startsWith("HTTP/1.1 101 "), `expected 101, got: ${rawHeaders}`);
    assert.ok(rawHeaders.includes(`Sec-WebSocket-Accept: ${expectedAccept}`));
    return rawHeaders;
  }

  _drainWaiters() {
    for (let i = this.waiters.length - 1; i >= 0; i -= 1) {
      const w = this.waiters[i];
      const val = w.check();
      if (val !== null) {
        this.waiters.splice(i, 1);
        w.resolve(val);
      } else if (this.closed && w.onClose) {
        this.waiters.splice(i, 1);
        w.resolve(w.onClose());
      }
    }
  }

  _waitFor(check, timeoutMs = 3000, onClose = null) {
    const immediate = check();
    if (immediate !== null) return Promise.resolve(immediate);
    if (this.closed && onClose) return Promise.resolve(onClose());
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error("Timed out waiting on raw WS TCP socket"));
      }, timeoutMs);
      this.waiters.push({
        check,
        onClose,
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
      });
    });
  }

  sendRaw(buf) {
    this.sock.write(buf);
  }

  async readFrame(timeoutMs = 3000) {
    return this._waitFor(() => {
      const parsed = parseNextServerFrame(this.buf);
      if (!parsed) return null;
      this.buf = parsed.rest;
      return parsed;
    }, timeoutMs);
  }

  async waitForClose(timeoutMs = 3000) {
    return this._waitFor(() => (this.closed ? true : null), timeoutMs, () => true);
  }

  destroy() {
    this.sock?.destroy();
  }
}

async function rawHttp(port, rawRequest) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: "127.0.0.1", port });
    const chunks = [];
    sock.on("connect", () => sock.write(rawRequest));
    sock.on("data", (c) => chunks.push(c));
    sock.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    sock.on("error", reject);
  });
}

test("Wave 3 RFC 6455 WebSocket & HTTP/1.1 wire-level conformance against live Roc+Zig binary", async (t) => {
  const binPath = path.join(ROOT, "examples/chat-app/.concave/ws-conformance-server");
  const walPath = path.join(ROOT, "examples/chat-app/.concave/ws-conformance.wal");
  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  fs.rmSync(walPath, { force: true });

  const build = spawnSync(
    "roc",
    ["build", "--opt=dev", `--output=${binPath}`, path.join(ROOT, "examples/chat-app/backend/main.roc")],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(build.status, 0, `roc build failed:\n${build.stderr}`);

  const port = 13229;
  const proc = spawn(
    binPath,
    ["--serve", "--host", "127.0.0.1", "--port", String(port), "--db", walPath, "--static-dir", path.join(ROOT, "examples/chat-app/frontend")],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  t.after(() => {
    proc.kill("SIGTERM");
    fs.rmSync(walPath, { force: true });
  });

  // Wait for /health
  for (let i = 0; i < 60; i += 1) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) break;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }

  // 1. Handshake & Framing: Ping/Pong echo (0 bytes & 125 bytes max control payload).
  {
    const ws = new RawWsConn(port);
    await ws.connect();
    t.after(() => ws.destroy());

    for (const payload of [Buffer.alloc(0), Buffer.alloc(125, 0x42)]) {
      ws.sendRaw(buildWsFrame({ opcode: 0x9, payload }));
      const pong = await ws.readFrame();
      assert.equal(pong.opcode, 0xa, "server must reply with Pong (0xA)");
      assert.equal(pong.masked, false, "server frames must be unmasked (RFC 6455 §5.1)");
      assert.deepEqual(pong.payload, payload);
    }

    // 2. Fragmented JSON message split across 1-byte TCP writes WITH interleaved Ping inside!
    const jsonMsg = Buffer.from(JSON.stringify({ type: "ping", ts: 4242 }));
    const f1 = buildWsFrame({ fin: false, opcode: 0x1, payload: jsonMsg.subarray(0, 7) });
    const fPing = buildWsFrame({ fin: true, opcode: 0x9, payload: Buffer.from("mid") });
    const f2 = buildWsFrame({ fin: false, opcode: 0x0, payload: jsonMsg.subarray(7, 15) });
    const f3 = buildWsFrame({ fin: true, opcode: 0x0, payload: jsonMsg.subarray(15) });
    const combined = Buffer.concat([f1, fPing, f2, f3]);
    // Drip-feed 3 bytes per write to stress TCP stream reassembly!
    for (let i = 0; i < combined.length; i += 3) {
      ws.sendRaw(combined.subarray(i, Math.min(i + 3, combined.length)));
    }
    const resp = await ws.readFrame();
    assert.equal(resp.opcode, 0x1);
    assert.deepEqual(JSON.parse(resp.payload.toString("utf8")), { type: "pong", ts: 4242 });

    // 3. Large 16-bit (1000 bytes) & 64-bit (70000 bytes) masked JSON frames!
    for (const padLen of [1000, 70000]) {
      const bigJson = Buffer.from(
        JSON.stringify({ type: "ping", ts: padLen, pad: "x".repeat(padLen) }),
      );
      ws.sendRaw(buildWsFrame({ opcode: 0x1, payload: bigJson }));
      const bigResp = await ws.readFrame();
      assert.equal(bigResp.opcode, 0x1);
      assert.deepEqual(JSON.parse(bigResp.payload.toString("utf8")), { type: "pong", ts: padLen });
    }

    // 4. Malformed WS JSON types (must NOT crash server!).
    ws.sendRaw(buildWsFrame({ opcode: 0x1, payload: Buffer.from('{"type":"subscribe","sub_id":123,"name":null}') }));
    ws.sendRaw(buildWsFrame({ opcode: 0x1, payload: Buffer.from("not-json") }));
    const errFrame = await ws.readFrame();
    assert.equal(JSON.parse(errFrame.payload.toString("utf8")).type, "error");

    // Clean Close frame
    ws.sendRaw(buildWsFrame({ opcode: 0x8, payload: Buffer.alloc(0) }));
    assert.equal(await ws.waitForClose(), true);
  }

  // 5. Protocol violations (RFC 6455 §5.2 & §5.5): server must close each violating connection cleanly!
  const violations = [
    ["RSV1 set", buildWsFrame({ rsv: 0b100, opcode: 0x1, payload: Buffer.from("hi") })],
    ["Fragmented Ping", buildWsFrame({ fin: false, opcode: 0x9, payload: Buffer.from("p") })],
    ["Oversized Ping (>125)", Buffer.from([0x89, 0xfe, 0x00, 0x7e, 1, 2, 3, 4, ...Array(126).fill(0x41)])],
    ["Unexpected continuation", buildWsFrame({ fin: true, opcode: 0x0, payload: Buffer.from("x") })],
    ["64-bit length MSB set", Buffer.from([0x81, 0xff, 0x80, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4, 0x41])],
  ];
  for (const [label, badFrame] of violations) {
    const ws = new RawWsConn(port);
    await ws.connect();
    ws.sendRaw(badFrame);
    const closed = await ws.waitForClose(2000);
    ws.destroy();
    assert.equal(closed, true, `server must close connection on violation: ${label}`);
  }

  // 6. HTTP/1.1 security conformance: missing WS key -> 400, path traversal -> 403, server still healthy!
  const missingKeyResp = await rawHttp(
    port,
    `GET /ws HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n`,
  );
  assert.ok(missingKeyResp.startsWith("HTTP/1.1 400 "));

  const traversalResp = await rawHttp(
    port,
    `GET /%2e%2e/Cargo.toml HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\n\r\n`,
  );
  assert.ok(traversalResp.startsWith("HTTP/1.1 403 "));

  const health = await fetch(`http://127.0.0.1:${port}/health`);
  assert.equal(health.status, 200, "server must remain completely healthy after all hostile frames");
});
