import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const FIXTURE = path.join(ROOT, "tests/fixtures/email-webhooks-app/main.roc");
const BIN = path.join(ROOT, ".zig-cache/email-webhooks-e2e-bin");
const DB_PATH = path.join(ROOT, ".zig-cache/email-webhooks-e2e.wal");
const SECRETS_DIR = path.join(ROOT, ".zig-cache/email-webhooks-e2e-secrets");
const SERVER_PORT = 13245;
const MOCK_PORT = 13298;
const BASE_URL = `http://127.0.0.1:${SERVER_PORT}`;

const EMAIL_API_KEY = "em_test_secret_98765";
const WEBHOOK_SIGNING_SECRET = "whsec_test_signing_secret_42";

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

async function waitForCondition(fn, timeoutMs = 8000, label = "condition") {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = await fn();
    if (val) return val;
    await new Promise((r) => setTimeout(r, 30));
  }
  throw new Error(`Timed out waiting for ${label} within ${timeoutMs}ms`);
}

async function rpc(kind, name, args = {}) {
  const res = await fetch(`${BASE_URL}/api/${kind}/${name}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  return { status: res.status, json: await res.json() };
}

function verifyConcaveSignature(secret, sigHeader, rawBody) {
  assert.ok(sigHeader, "X-Concave-Signature header must be present");
  const parts = Object.fromEntries(
    sigHeader.split(",").map((kv) => {
      const idx = kv.indexOf("=");
      return [kv.slice(0, idx).trim(), kv.slice(idx + 1).trim()];
    }),
  );
  assert.ok(parts.t, `signature header missing t=: ${sigHeader}`);
  assert.ok(parts.v1, `signature header missing v1=: ${sigHeader}`);
  const expected = crypto
    .createHmac("sha256", secret)
    .update(`${parts.t}.${rawBody}`)
    .digest("hex");
  assert.equal(parts.v1, expected, "HMAC-SHA256 signature must match exactly");
  return { timestamp: Number(parts.t), signature: parts.v1 };
}

function startMockReceiver(port) {
  const emailRequests = [];
  const retryWebhookRequests = [];
  const deadWebhookRequests = [];

  let emailFailRemaining = 1; // First email attempt gets HTTP 500
  let emailForceStatus = 0; // Optional forced HTTP status (e.g. 400) for dead-letter/retry testing
  let retryWebhookFailRemaining = 1; // First webhook attempt gets HTTP 503
  let deadWebhookStatus = 400; // Permanent 400 until flipped to 200 for replay test

  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${port}`);
    let rawBody = "";
    req.on("data", (chunk) => {
      rawBody += chunk.toString();
    });
    req.on("end", () => {
      if (req.method === "POST" && url.pathname === "/email") {
        emailRequests.push({
          headers: req.headers,
          rawBody,
          json: JSON.parse(rawBody),
        });
        if (emailForceStatus >= 400) {
          res.writeHead(emailForceStatus, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: `forced status ${emailForceStatus}` }));
          return;
        }
        if (emailFailRemaining > 0) {
          emailFailRemaining -= 1;
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "transient upstream 500" }));
          return;
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ id: `msg_mock_${emailRequests.length}` }));
        return;
      }

      if (req.method === "POST" && url.pathname === "/webhook-retry") {
        retryWebhookRequests.push({
          headers: req.headers,
          rawBody,
          json: JSON.parse(rawBody),
        });
        if (retryWebhookFailRemaining > 0) {
          retryWebhookFailRemaining -= 1;
          res.writeHead(503, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "service unavailable" }));
          return;
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ received: true }));
        return;
      }

      if (req.method === "POST" && url.pathname === "/webhook-dead") {
        deadWebhookRequests.push({
          headers: req.headers,
          rawBody,
          json: JSON.parse(rawBody),
        });
        if (deadWebhookStatus >= 400) {
          res.writeHead(deadWebhookStatus, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "bad payload rejected" }));
          return;
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ received: true, replayed: true }));
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "not_found" }));
    });
  });

  return new Promise((resolve, reject) => {
    server.listen(port, "127.0.0.1", () => {
      resolve({
        emailRequests,
        retryWebhookRequests,
        deadWebhookRequests,
        setEmailForceStatus(code) {
          emailForceStatus = code;
        },
        setDeadWebhookStatus(code) {
          deadWebhookStatus = code;
        },
        close: () => new Promise((r) => server.close(() => r())),
      });
    });
    server.on("error", reject);
  });
}

test("Pure-Roc Email + Signed Webhooks Components E2E", async (t) => {
  fs.mkdirSync(path.dirname(BIN), { recursive: true });
  fs.rmSync(SECRETS_DIR, { recursive: true, force: true });
  fs.mkdirSync(SECRETS_DIR, { recursive: true });
  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${DB_PATH}${suffix}`, { force: true });
  }

  fs.writeFileSync(path.join(SECRETS_DIR, "EMAIL_API_KEY"), EMAIL_API_KEY, { mode: 0o600 });
  fs.writeFileSync(path.join(SECRETS_DIR, "WEBHOOK_SIGNING_SECRET"), WEBHOOK_SIGNING_SECRET, {
    mode: 0o600,
  });

  // Compile fixture app with Concave platform host
  execFileSync("roc", ["build", "--opt=dev", `--output=${BIN}`, FIXTURE], {
    cwd: ROOT,
    stdio: "inherit",
  });

  // Verify --introspect emits both isolated components, secrets, and internal _deliver actions
  const manifest = JSON.parse(execFileSync(BIN, ["--introspect"], { cwd: ROOT, encoding: "utf8" }));
  assert.equal(manifest.app_name, "email-webhooks-test");

  const emailComp = manifest.components.find((c) => c.namespace === "email");
  assert.ok(emailComp, "manifest must declare email component");
  assert.equal(emailComp.package, "concave-email");
  assert.ok(emailComp.allowed_secrets.includes("EMAIL_API_KEY"));
  assert.ok(emailComp.tables.some((tbl) => tbl.name === "email_messages"));

  const webhooksComp = manifest.components.find((c) => c.namespace === "webhooks");
  assert.ok(webhooksComp, "manifest must declare webhooks component");
  assert.equal(webhooksComp.package, "concave-webhooks");
  assert.ok(webhooksComp.allowed_secrets.includes("WEBHOOK_SIGNING_SECRET"));
  assert.ok(webhooksComp.tables.some((tbl) => tbl.name === "webhooks_endpoints"));
  assert.ok(webhooksComp.tables.some((tbl) => tbl.name === "webhooks_deliveries"));

  const emailDeliverFn = manifest.functions.find((f) => f.name === "email._deliver");
  assert.ok(emailDeliverFn && emailDeliverFn.visibility === "internal" && emailDeliverFn.kind === "action");
  const webhooksDeliverFn = manifest.functions.find((f) => f.name === "webhooks._deliver");
  assert.ok(webhooksDeliverFn && webhooksDeliverFn.visibility === "internal" && webhooksDeliverFn.kind === "action");

  const mock = await startMockReceiver(MOCK_PORT);
  t.after(() => mock.close());

  const server = spawn(
    BIN,
    ["--serve", "--host", "127.0.0.1", "--port", String(SERVER_PORT), "--db", DB_PATH],
    {
      cwd: ROOT,
      env: {
        ...process.env,
        CONCAVE_SECRETS_DIR: SECRETS_DIR,
        CONCAVE_ALLOW_PRIVATE_HTTP: "true",
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
    fs.rmSync(SECRETS_DIR, { recursive: true, force: true });
    for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
      fs.rmSync(`${DB_PATH}${suffix}`, { force: true });
    }
  });

  await waitForHealth(BASE_URL);

  // Internal delivery actions must be blocked on public HTTP API
  const blockedEmailDeliver = await rpc("action", "email._deliver", { email_id: "fake" });
  assert.equal(blockedEmailDeliver.json.ok, false);
  assert.match(blockedEmailDeliver.json.error, /internal/i);

  const blockedWebhookDeliver = await rpc("action", "webhooks._deliver", { delivery_id: "fake" });
  assert.equal(blockedWebhookDeliver.json.ok, false);
  assert.match(blockedWebhookDeliver.json.error, /internal/i);

  // ---------------------------------------------------------------------------
  // 1. Register webhook endpoint #1 (503 once -> 200) and call transactional `orders.create`
  // ---------------------------------------------------------------------------
  const regRetryEp = await rpc("mutation", "webhooks.registerEndpoint", {
    name: "order-events-retry",
    url: `http://127.0.0.1:${MOCK_PORT}/webhook-retry`,
    events: ["order.created"],
    secret_name: "",
  });
  assert.equal(regRetryEp.status, 200);
  assert.equal(regRetryEp.json.ok, true);
  const retryEpId = regRetryEp.json.value;

  const order1 = await rpc("mutation", "orders.create", {
    customer_email: "alice@example.com",
    amount_cents: 4200,
    idempotency_key: "order-idem-1",
  });
  assert.equal(order1.status, 200);
  assert.equal(order1.json.ok, true, `orders.create failed: ${JSON.stringify(order1.json)}`);
  const { order_id: orderId1, email_id: emailId1, delivery_ids: delIds1 } = order1.json.value;
  assert.ok(orderId1);
  assert.ok(emailId1);
  assert.equal(delIds1.length, 1);
  const retryDeliveryId = delIds1[0];

  // Wait for Email retry after HTTP 500 -> "sent"
  const sentEmail = await waitForCondition(
    async () => {
      const res = await rpc("query", "email.get", { email_id: emailId1 });
      if (res.json.ok && res.json.value.status === "sent") return res.json.value;
      return null;
    },
    8000,
    `email sent (stderr: ${stderrLog})`,
  );
  assert.equal(sentEmail.found, true);
  assert.equal(sentEmail.status, "sent");
  assert.equal(sentEmail.attempts, 2);
  assert.equal(sentEmail.provider_id, "msg_mock_2");
  assert.equal(sentEmail.last_error, "");
  assert.ok(sentEmail.sent_at_ms > 0);

  // Verify email mock saw exactly 2 requests (initial 500 + retry 200) with Bearer auth
  assert.equal(mock.emailRequests.length, 2);
  for (const req of mock.emailRequests) {
    assert.equal(req.headers.authorization, `Bearer ${EMAIL_API_KEY}`);
    assert.equal(req.json.from, "orders@concave.test");
    assert.equal(req.json.to, "alice@example.com");
    assert.equal(req.json.idempotency_key, "order-idem-1");
  }

  // Verify `email.listByStatus` query
  const sentEmailsList = await rpc("query", "email.listByStatus", { status: "sent" });
  assert.equal(sentEmailsList.json.ok, true);
  assert.equal(sentEmailsList.json.value.length, 1);
  assert.equal(sentEmailsList.json.value[0].id, emailId1);

  // Wait for Webhook retry after HTTP 503 -> "delivered"
  const deliveredWh = await waitForCondition(
    async () => {
      const res = await rpc("query", "webhooks.listDeliveries", {
        status: "delivered",
        endpoint_id: retryEpId,
      });
      if (res.json.ok) {
        const found = res.json.value.find((d) => d.id === retryDeliveryId);
        if (found) return found;
      }
      return null;
    },
    8000,
    `webhook retry delivered (stderr: ${stderrLog})`,
  );
  assert.equal(deliveredWh.status, "delivered");
  assert.equal(deliveredWh.attempts, 2);
  assert.equal(deliveredWh.last_status, 200);
  assert.equal(deliveredWh.last_error, "");
  assert.ok(deliveredWh.delivered_at_ms > 0);

  // Verify Node HMAC-SHA256 matches exact `X-Concave-Signature` on both webhook attempts
  assert.equal(mock.retryWebhookRequests.length, 2);
  for (const req of mock.retryWebhookRequests) {
    assert.equal(req.headers["x-concave-delivery-id"], retryDeliveryId);
    assert.equal(req.headers["x-concave-event"], "order.created");
    verifyConcaveSignature(WEBHOOK_SIGNING_SECRET, req.headers["x-concave-signature"], req.rawBody);
    assert.equal(req.json.order_id, orderId1);
    assert.equal(req.json.amount_cents, 4200);
  }

  // Endpoint consecutive_failures must have reset to 0 after successful recovery
  const endpointsAfterRecovery = await rpc("query", "webhooks.listEndpoints", {});
  assert.equal(endpointsAfterRecovery.json.ok, true);
  const retryEpDoc = endpointsAfterRecovery.json.value.find((e) => e.id === retryEpId);
  assert.equal(retryEpDoc.consecutive_failures, 0);

  // ---------------------------------------------------------------------------
  // 2. Duplicate `idempotency_key` must return same `email_id` and NOT send a second email
  // ---------------------------------------------------------------------------
  const orderDup = await rpc("mutation", "orders.create", {
    customer_email: "alice@example.com",
    amount_cents: 4200,
    idempotency_key: "order-idem-1",
  });
  assert.equal(orderDup.status, 200);
  assert.equal(orderDup.json.ok, true);
  assert.equal(orderDup.json.value.email_id, emailId1, "duplicate idempotency_key must return existing email_id");

  // Wait briefly for scheduler to settle and verify no extra email was sent
  await new Promise((r) => setTimeout(r, 250));
  assert.equal(mock.emailRequests.length, 2, "duplicate idempotency_key must NOT trigger another email send");

  // ---------------------------------------------------------------------------
  // 3. Permanent HTTP 400 -> "dead", then flip mock to 200 & replay via `webhooks.retryDelivery`
  // ---------------------------------------------------------------------------
  const regDeadEp = await rpc("mutation", "webhooks.registerEndpoint", {
    name: "order-events-dead",
    url: `http://127.0.0.1:${MOCK_PORT}/webhook-dead`,
    events: ["order.*"],
    secret_name: "",
  });
  assert.equal(regDeadEp.status, 200);
  assert.equal(regDeadEp.json.ok, true);
  const deadEpId = regDeadEp.json.value;

  const order2 = await rpc("mutation", "orders.create", {
    customer_email: "bob@example.com",
    amount_cents: 9900,
    idempotency_key: "order-idem-2",
  });
  assert.equal(order2.status, 200);
  assert.equal(order2.json.ok, true);
  assert.equal(order2.json.value.delivery_ids.length, 2);

  // Wait for the delivery targeting `deadEpId` to transition directly to "dead" after 1 attempt
  const deadDel = await waitForCondition(
    async () => {
      const res = await rpc("query", "webhooks.listDeliveries", {
        status: "dead",
        endpoint_id: deadEpId,
      });
      if (res.json.ok && res.json.value.length > 0) return res.json.value[0];
      return null;
    },
    8000,
    `webhook dead on 400 (stderr: ${stderrLog})`,
  );
  assert.equal(deadDel.status, "dead");
  assert.equal(deadDel.attempts, 1, "permanent 400 must not retry");
  assert.equal(deadDel.last_status, 400);
  assert.match(deadDel.last_error, /400/);

  // Endpoint consecutive_failures incremented
  const endpointsAfterDead = await rpc("query", "webhooks.listEndpoints", {});
  const deadEpBeforeRetry = endpointsAfterDead.json.value.find((e) => e.id === deadEpId);
  assert.equal(deadEpBeforeRetry.consecutive_failures, 1);

  // Flip mock to return 200 and replay via `webhooks.retryDelivery`
  mock.setDeadWebhookStatus(200);
  const retryRes = await rpc("mutation", "webhooks.retryDelivery", { delivery_id: deadDel.id });
  assert.equal(retryRes.status, 200);
  assert.equal(retryRes.json.ok, true);
  assert.equal(retryRes.json.value, true);

  const replayedDel = await waitForCondition(
    async () => {
      const res = await rpc("query", "webhooks.listDeliveries", {
        status: "delivered",
        endpoint_id: deadEpId,
      });
      if (res.json.ok) {
        const found = res.json.value.find((d) => d.id === deadDel.id);
        if (found) return found;
      }
      return null;
    },
    8000,
    `replayed webhook delivered (stderr: ${stderrLog})`,
  );
  assert.equal(replayedDel.status, "delivered");
  assert.equal(replayedDel.attempts, 1);
  assert.equal(replayedDel.last_status, 200);

  // Verify the replayed request carried a valid HMAC-SHA256 signature and reset consecutive_failures
  assert.equal(mock.deadWebhookRequests.length, 2);
  const lastDeadReq = mock.deadWebhookRequests[1];
  verifyConcaveSignature(WEBHOOK_SIGNING_SECRET, lastDeadReq.headers["x-concave-signature"], lastDeadReq.rawBody);

  const endpointsAfterReplay = await rpc("query", "webhooks.listEndpoints", {});
  const deadEpAfterReplay = endpointsAfterReplay.json.value.find((e) => e.id === deadEpId);
  assert.equal(deadEpAfterReplay.consecutive_failures, 0);

  // ---------------------------------------------------------------------------
  // 3b. Email permanent 400 -> "dead", then flip mock to 200 & replay via `email.retry`
  // ---------------------------------------------------------------------------
  mock.setEmailForceStatus(400);
  const order3 = await rpc("mutation", "orders.create", {
    customer_email: "carol@example.com",
    amount_cents: 1200,
    idempotency_key: "order-idem-3",
  });
  assert.equal(order3.status, 200);
  assert.equal(order3.json.ok, true);
  const deadEmailId = order3.json.value.email_id;

  const deadEmail = await waitForCondition(
    async () => {
      const res = await rpc("query", "email.get", { email_id: deadEmailId });
      if (res.json.ok && res.json.value.status === "dead") return res.json.value;
      return null;
    },
    8000,
    `email dead on 400 (stderr: ${stderrLog})`,
  );
  assert.equal(deadEmail.status, "dead");
  assert.equal(deadEmail.attempts, 1, "permanent 400 email must not retry");
  assert.match(deadEmail.last_error, /400/);

  mock.setEmailForceStatus(0);
  const retryEmailRes = await rpc("mutation", "email.retry", { email_id: deadEmailId });
  assert.equal(retryEmailRes.status, 200);
  assert.equal(retryEmailRes.json.ok, true);
  assert.equal(retryEmailRes.json.value, true);

  const retriedEmail = await waitForCondition(
    async () => {
      const res = await rpc("query", "email.get", { email_id: deadEmailId });
      if (res.json.ok && res.json.value.status === "sent") return res.json.value;
      return null;
    },
    8000,
    `retried email sent (stderr: ${stderrLog})`,
  );
  assert.equal(retriedEmail.status, "sent");
  assert.equal(retriedEmail.attempts, 1);

  // ---------------------------------------------------------------------------
  // 4. Inbound `POST /webhooks/inbound` verification via `Webhooks.verify_signature!`
  // ---------------------------------------------------------------------------
  const inboundPayload = JSON.stringify({ event: "payment.succeeded", amount: 1500 });
  const nowSecs = Math.floor(Date.now() / 1000);

  // 4a. Missing signature -> 401
  const missingSigRes = await fetch(`${BASE_URL}/webhooks/inbound`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: inboundPayload,
  });
  assert.equal(missingSigRes.status, 401);
  assert.equal((await missingSigRes.json()).verified, false);

  // 4b. Forged signature -> 401
  const forgedSigRes = await fetch(`${BASE_URL}/webhooks/inbound`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Concave-Signature": `t=${nowSecs},v1=${"0".repeat(64)}`,
    },
    body: inboundPayload,
  });
  assert.equal(forgedSigRes.status, 401);
  const forgedBody = await forgedSigRes.json();
  assert.equal(forgedBody.verified, false);
  assert.match(forgedBody.error, /invalid webhook signature/i);

  // 4c. Replay / stale timestamp (600s old > 300s tolerance) -> 401
  const staleTs = nowSecs - 600;
  const staleSig = crypto
    .createHmac("sha256", WEBHOOK_SIGNING_SECRET)
    .update(`${staleTs}.${inboundPayload}`)
    .digest("hex");
  const staleRes = await fetch(`${BASE_URL}/webhooks/inbound`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Concave-Signature": `t=${staleTs},v1=${staleSig}`,
    },
    body: inboundPayload,
  });
  assert.equal(staleRes.status, 401);
  const staleBody = await staleRes.json();
  assert.equal(staleBody.verified, false);
  assert.match(staleBody.error, /tolerance/i);

  // 4d. Valid signature -> 200
  const validSig = crypto
    .createHmac("sha256", WEBHOOK_SIGNING_SECRET)
    .update(`${nowSecs}.${inboundPayload}`)
    .digest("hex");
  const validRes = await fetch(`${BASE_URL}/webhooks/inbound`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Concave-Signature": `t=${nowSecs},v1=${validSig}`,
    },
    body: inboundPayload,
  });
  assert.equal(validRes.status, 200);
  const validBody = await validRes.json();
  assert.equal(validBody.verified, true);
  assert.equal(validBody.bytes, Buffer.byteLength(inboundPayload, "utf8"));
});
