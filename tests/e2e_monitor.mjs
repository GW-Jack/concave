import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import { ConcaveClient } from "../client/concave-client/src/index.js";
import { createMonitor, fromAttrs } from "../packages/monitor/client.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

async function waitForHealth(url, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${url}/health`);
      if (res.ok) return;
    } catch {
      // retry
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`Timed out waiting for ${url}/health`);
}

async function waitForCondition(fn, timeoutMs = 5000, label = "condition") {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const val = fn();
    if (val) return val;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

function startWebhookServer() {
  /** @type {Array<{ url: string, body: any }>} */
  const received = [];
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk.toString();
    });
    req.on("end", () => {
      let body = raw;
      try {
        body = JSON.parse(raw);
      } catch {
        // leave as string
      }
      received.push({ url: req.url ?? "/", body });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    });
  });

  return new Promise((resolve, reject) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        reject(new Error("failed to bind webhook server"));
        return;
      }
      resolve({
        url: `http://127.0.0.1:${addr.port}/alert`,
        received,
        close: () => new Promise((r) => server.close(() => r())),
      });
    });
    server.on("error", reject);
  });
}

test("end-to-end Observability: Layer 1 Zig operator telemetry + Layer 2 pure-Roc Monitor component", async (t) => {
  const appDir = path.join(ROOT, "tests/fixtures/monitor-app");
  const entryRoc = path.join(appDir, "main.roc");
  const genDir = path.join(appDir, "_generated");
  const binPath = path.join(appDir, ".concave/e2e-monitor-server");
  const dbPath = path.join(appDir, ".concave/e2e-monitor.wal");
  const cliPath = path.join(ROOT, "zig-out/bin/concave");

  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${dbPath}${suffix}`, { force: true });
  }

  // 1. Verify `--introspect` + typed ESM/TS codegen for both Monitor instances.
  const codegen = spawnSync(
    cliPath,
    ["codegen", "--entry", entryRoc, "--out", genDir],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(
    codegen.status,
    0,
    `concave codegen failed:\n${codegen.stdout}\n${codegen.stderr}`,
  );

  const dataModelDts = fs.readFileSync(path.join(genDir, "dataModel.d.ts"), "utf8");
  assert.ok(dataModelDts.includes("export interface MonitorIssuesDoc"));
  assert.ok(dataModelDts.includes("export interface MonitorLogsDoc"));
  assert.ok(dataModelDts.includes("export interface MonitorMetricsDoc"));
  assert.ok(dataModelDts.includes("export interface MonitorAlertRulesDoc"));
  assert.ok(dataModelDts.includes("export interface MonitorIncidentsDoc"));
  assert.ok(dataModelDts.includes("export interface OpsMonitorIssuesDoc"));

  const apiDts = fs.readFileSync(path.join(genDir, "api.d.ts"), "utf8");
  assert.ok(apiDts.includes("readonly captureError:"));
  assert.ok(apiDts.includes("readonly searchLogs:"));
  assert.ok(apiDts.includes("readonly metricSeries:"));
  assert.ok(apiDts.includes("readonly evaluateAndNotify:"));

  const { api } = await import(pathToFileURL(path.join(genDir, "api.js")).href);

  // 2. Compile standalone native Roc + Zig server binary.
  const build = spawnSync(
    "roc",
    ["build", "--opt=dev", `--output=${binPath}`, entryRoc],
    { cwd: ROOT, encoding: "utf8" },
  );
  assert.equal(
    build.status,
    0,
    `roc build failed:\n${build.stdout}\n${build.stderr}`,
  );

  // 3. Start local webhook receiver + Concave server with operator token configured.
  const webhook = await startWebhookServer();
  const operatorToken = "op-secret-token-42";
  const port = 13231;
  const serverUrl = `http://127.0.0.1:${port}`;
  const serverProc = spawn(
    binPath,
    ["--serve", "--host", "127.0.0.1", "--port", String(port), "--db", dbPath],
    {
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        CONCAVE_OPERATOR_TOKEN: operatorToken,
      },
    },
  );
  let stderrLog = "";
  serverProc.stderr.on("data", (d) => {
    stderrLog += d.toString();
  });

  t.after(async () => {
    serverProc.kill("SIGTERM");
    await webhook.close();
  });

  await waitForHealth(serverUrl);

  // 4. Verify embedded zero-dep browser helper `/_concave/monitor.js` is served.
  const monitorJsRes = await fetch(`${serverUrl}/_concave/monitor.js`);
  assert.equal(monitorJsRes.status, 200);
  const monitorJsBody = await monitorJsRes.text();
  assert.ok(monitorJsBody.includes("export function createMonitor"));

  // 5. Layer 1 — Platform Operator endpoints require operator token & expose Prometheus + JSON.
  const unauthMetrics = await fetch(`${serverUrl}/_internal/metrics`);
  assert.equal(unauthMetrics.status, 401);
  const unauthStatus = await fetch(`${serverUrl}/_internal/status`);
  assert.equal(unauthStatus.status, 401);

  const wrongTok = await fetch(`${serverUrl}/_internal/status`, {
    headers: { Authorization: "Bearer wrong-token" },
  });
  assert.equal(wrongTok.status, 401);

  const promInitialRes = await fetch(`${serverUrl}/_internal/metrics`, {
    headers: { Authorization: `Bearer ${operatorToken}` },
  });
  assert.equal(promInitialRes.status, 200);
  assert.ok(promInitialRes.headers.get("content-type")?.includes("text/plain"));
  const promInitial = await promInitialRes.text();
  assert.ok(promInitial.includes('concave_up{storage="wal"} 1'));
  assert.ok(promInitial.includes("concave_query_duration_seconds_bucket"));
  assert.ok(promInitial.includes("concave_mutation_duration_seconds_bucket"));
  assert.ok(promInitial.includes("concave_occ_retries_total"));

  // Also test `?token=` query auth for `/_internal/status`.
  const statusInitialRes = await fetch(`${serverUrl}/_internal/status?token=${operatorToken}`);
  assert.equal(statusInitialRes.status, 200);
  const statusInitial = await statusInitialRes.json();
  assert.equal(statusInitial.status, "ok");
  assert.equal(statusInitial.app_name, "concave-monitor-test");
  assert.equal(statusInitial.storage_backend, "wal");

  // 6. Connect reactive WebSocket client and instantiate `createMonitor`.
  const client = new ConcaveClient(serverUrl);
  t.after(() => client.close());
  await waitForCondition(() => client.status() === "connected", 5000, "ws connected");

  const monitor = createMonitor(client, api.monitor, {
    service: "web",
    release: "v1.0.0",
    environment: "test",
  });
  const opsMonitor = createMonitor(client, api.ops_monitor, { service: "ops" });

  // Live reactive subscriptions for issues, overview, search, and alerts.
  const openIssuesSub = monitor.subscribeIssues({ status: "open" });
  const overviewSub = monitor.subscribeOverview({ window_ms: 3600000, top_n: 5 });
  const alertsSub = monitor.subscribeAlerts();
  t.after(() => {
    openIssuesSub.dispose();
    overviewSub.dispose();
    alertsSub.dispose();
    monitor.dispose();
    opsMonitor.dispose();
  });

  await waitForCondition(() => overviewSub().status === "ready", 5000, "overview ready");
  assert.equal(overviewSub().data.open_issues, 0);

  // 7. Sentry-style error grouping (volatile numbers/UUIDs normalize to same fingerprint) + reopen on regression.
  monitor.addBreadcrumb("checkout", "User clicked pay");
  const err1 = await monitor.captureException(
    new Error("Order 1001 failed for user 550e8400-e29b-41d4-a716-446655440000"),
    { source: "checkout", errorType: "PaymentError", traceId: "tr_pay_1" },
  );
  assert.equal(err1.is_new, true);
  assert.equal(err1.reopened, false);
  assert.equal(err1.count, 1);

  const err2 = await monitor.captureException(
    new Error("Order 9942 failed for user 123e4567-e89b-12d3-a456-426614174000"),
    { source: "checkout", errorType: "PaymentError", traceId: "tr_pay_2" },
  );
  assert.equal(err2.is_new, false);
  assert.equal(err2.issue_id, err1.issue_id);
  assert.equal(err2.fingerprint, err1.fingerprint);
  assert.equal(err2.count, 2);

  await waitForCondition(
    () => openIssuesSub().data?.length === 1 && openIssuesSub().data[0].count === 2,
    5000,
    "grouped issue count=2",
  );
  const issueAttrs = fromAttrs(openIssuesSub().data[0].attrs);
  assert.equal(issueAttrs.release, "v1.0.0");
  assert.ok(issueAttrs.breadcrumbs.includes("User clicked pay"));

  // Resolve the issue, verify open inbox drops to 0, then trigger a regression to verify auto-reopen!
  const resolvedOk = await monitor.updateIssueStatus(err1.issue_id, "resolved");
  assert.equal(resolvedOk, true);
  await waitForCondition(
    () => openIssuesSub().data?.length === 0,
    5000,
    "resolved issue leaves open inbox",
  );

  const err3 = await monitor.captureException(new Error("Order 7777 failed for user 999e8400-e29b-41d4-a716-446655440000"), {
    source: "checkout",
    errorType: "PaymentError",
    traceId: "tr_pay_3",
  });
  assert.equal(err3.issue_id, err1.issue_id);
  assert.equal(err3.reopened, true);
  assert.equal(err3.count, 3);

  await waitForCondition(
    () => openIssuesSub().data?.length === 1 && openIssuesSub().data[0].status === "open",
    5000,
    "issue auto-reopened on regression",
  );

  // 8. Structured logs, trace correlation (client `time()` + server `jobs.process`), and full-text `Db.search!`.
  const sharedTrace = "tr_order_flow_42";
  const jobId = await monitor.time(
    "checkout.submit",
    async (tid) => {
      return await client.mutate(api.jobs.process, {
        name: "invoice-42",
        amount: 250,
        trace_id: tid,
      });
    },
    { service: "web", traceId: sharedTrace },
  );
  assert.ok(typeof jobId === "string" && jobId.length > 0);

  const traceSub = monitor.subscribeTrace(sharedTrace);
  t.after(() => traceSub.dispose());
  await waitForCondition(
    () => (traceSub().data?.length ?? 0) >= 2,
    5000,
    "trace timeline has server + client spans",
  );
  const traceServices = traceSub().data.map((d) => d.service);
  assert.ok(traceServices.includes("billing"));
  assert.ok(traceServices.includes("web"));

  // Full-text search across log messages (`Db.search!`).
  await monitor.log("warn", "Upstream payment gateway timeout after 3000ms", {
    service: "billing",
    attrs: { provider: "stripe" },
  });
  const searchSub = monitor.subscribeSearchLogs("payment gateway timeout");
  t.after(() => searchSub.dispose());
  await waitForCondition(
    () => (searchSub().data?.length ?? 0) === 1,
    5000,
    "reactive full-text log search",
  );
  assert.ok(searchSub().data[0].message.includes("gateway timeout"));

  // 9. Transactional ACID rollback: failing `jobs.process` (amount <= 0) must leave ZERO ghost logs/metrics!
  const rollbackTrace = "tr_must_rollback";
  await assert.rejects(
    client.mutate(api.jobs.process, {
      name: "bad-job",
      amount: -50,
      trace_id: rollbackTrace,
    }),
    /Job amount must be positive/,
  );
  const rollbackTraceSub = monitor.subscribeTrace(rollbackTrace);
  t.after(() => rollbackTraceSub.dispose());
  await waitForCondition(() => rollbackTraceSub().status === "ready", 5000, "rollback trace ready");
  assert.equal(rollbackTraceSub().data.length, 0, "rolled-back mutation must not persist ghost spans");

  // 10. Metric time-series rollups with exact p50 / p95 / p99 percentiles.
  const baseTs = Date.now() - 120000;
  for (const [offset, val] of [
    [0, 10],
    [500, 20],
    [1000, 30],
    [60000, 40],
    [61000, 100],
  ]) {
    await monitor.metric("api.latency_ms", val, {
      kind: "timing",
      service: "api",
      timestampMs: baseTs + offset,
    });
  }
  const seriesSub = monitor.subscribeMetric("api.latency_ms", {
    service: "api",
    from_ms: baseTs - 1000,
    to_ms: baseTs + 120000,
    bucket_ms: 60000,
  });
  t.after(() => seriesSub.dispose());
  await waitForCondition(
    () => seriesSub().data?.count === 5,
    5000,
    "metric series count=5",
  );
  const series = seriesSub().data;
  assert.equal(series.min, 10);
  assert.equal(series.max, 100);
  assert.equal(series.avg, 40);
  assert.equal(series.p50, 30);
  assert.equal(series.p95, 100);
  assert.equal(series.buckets.length, 2);

  // 11. Threshold Alert Rules + Live Webhook Delivery (`evaluateAndNotify` Action) + Incident Lifecycle.
  await monitor.upsertAlertRule({
    key: "checkout-errors",
    name: "Checkout Error Spike",
    active: true,
    kind: "error_count",
    target: "checkout",
    op: "gte",
    threshold: 2,
    window_ms: 3600000,
    cooldown_ms: 0,
    webhook_url: webhook.url,
  });

  const eval1 = await monitor.evaluateAndNotify();
  assert.equal(eval1.evaluated, 1);
  assert.equal(eval1.firing, 1);
  assert.equal(eval1.webhooks_sent, 1);
  assert.equal(eval1.webhooks_failed, 0);
  assert.equal(webhook.received.length, 1);
  assert.equal(webhook.received[0].body.event, "alert.firing");
  assert.equal(webhook.received[0].body.rule_key, "checkout-errors");

  await waitForCondition(
    () => alertsSub().data?.some((r) => r.key === "checkout-errors" && r.status === "firing"),
    5000,
    "alert rule firing reactively",
  );
  await waitForCondition(
    () => overviewSub().data?.firing_alerts === 1,
    5000,
    "overview reflects firing_alerts=1",
  );

  const incidentsSub = monitor.subscribeIncidents({ rule_key: "checkout-errors" });
  t.after(() => incidentsSub.dispose());
  await waitForCondition(
    () => incidentsSub().data?.length === 1 && incidentsSub().data[0].webhook_delivered === true,
    5000,
    "incident recorded with webhook_delivered=true",
  );
  const incId = incidentsSub().data[0].id;

  // Acknowledge incident -> transitions both incident & rule to `acked`.
  assert.equal(await monitor.acknowledgeIncident(incId), true);
  await waitForCondition(
    () => alertsSub().data?.some((r) => r.key === "checkout-errors" && r.status === "acked"),
    5000,
    "alert rule acked",
  );

  // Raise threshold so condition clears -> next `evaluateAndNotify` resolves incident & sends resolved webhook!
  await monitor.upsertAlertRule({
    key: "checkout-errors",
    name: "Checkout Error Spike",
    active: true,
    kind: "error_count",
    target: "checkout",
    op: "gte",
    threshold: 999,
    window_ms: 3600000,
    cooldown_ms: 0,
    webhook_url: webhook.url,
  });
  const eval2 = await monitor.evaluateAndNotify();
  assert.equal(eval2.resolved, 1);
  assert.equal(eval2.webhooks_sent, 1);
  assert.equal(webhook.received.length, 2);
  assert.equal(webhook.received[1].body.event, "alert.resolved");

  await waitForCondition(
    () => alertsSub().data?.some((r) => r.key === "checkout-errors" && r.status === "ok"),
    5000,
    "alert rule back to ok",
  );

  // 12. Retention pruning deletes old logs & metrics while leaving recent data intact.
  await monitor.log("info", "ancient log entry", { service: "legacy", timestampMs: 1000 });
  await monitor.metric("legacy.gauge", 1, { service: "legacy", timestampMs: 1000 });
  const pruned = await monitor.prune({ retention_ms: 60 * 60 * 1000, max_delete: 50 });
  assert.ok(pruned.deleted_logs >= 1);
  assert.ok(pruned.deleted_metrics >= 1);

  // 13. Strict namespace isolation + `require_auth_for_admin` + `max_batch_size` on `ops_monitor`.
  const opsIssuesSub = opsMonitor.subscribeIssues();
  t.after(() => opsIssuesSub.dispose());
  await waitForCondition(() => opsIssuesSub().status === "ready", 5000, "ops_monitor ready");
  assert.equal(opsIssuesSub().data.length, 0, "ops_monitor must be strictly isolated from monitor");

  await assert.rejects(
    opsMonitor.upsertAlertRule({
      key: "unauth-rule",
      kind: "error_count",
      threshold: 1,
    }),
    /Unauthenticated/,
  );

  await assert.rejects(
    client.mutate(api.ops_monitor.logBatch, {
      entries: [
        { level: "info", service: "s", fn_name: "", trace_id: "", span_id: "", duration_ms: 0, status: "ok", message: "a", attrs: [], timestamp_ms: 0 },
        { level: "info", service: "s", fn_name: "", trace_id: "", span_id: "", duration_ms: 0, status: "ok", message: "b", attrs: [], timestamp_ms: 0 },
        { level: "info", service: "s", fn_name: "", trace_id: "", span_id: "", duration_ms: 0, status: "ok", message: "c", attrs: [], timestamp_ms: 0 },
      ],
    }),
    /exceeds max_batch_size/,
  );

  // 14. Re-check Layer 1 Platform Operator status & Prometheus after real traffic!
  const statusFinalRes = await fetch(`${serverUrl}/_internal/status`, {
    headers: { Authorization: `Bearer ${operatorToken}` },
  });
  assert.equal(statusFinalRes.status, 200);
  const statusFinal = await statusFinalRes.json();
  assert.ok(statusFinal.active_clients >= 1, `expected active_clients >= 1, got ${statusFinal.active_clients}`);
  assert.ok(statusFinal.active_subscriptions >= 1, `expected active_subscriptions >= 1`);
  assert.ok(statusFinal.rpcs.queries_total > 0, "queries_total should increment");
  assert.ok(statusFinal.rpcs.mutations_total > 0, "mutations_total should increment");
  assert.ok(statusFinal.rpcs.mutations_err >= 3, "mutations_err should count failed mutations");
  assert.ok(statusFinal.rpcs.actions_total >= 2, "actions_total should count evaluateAndNotify calls");
  assert.ok(statusFinal.storage.commits > 0, "storage.commits should increment");
  assert.ok(statusFinal.websocket.connections_total >= 1, "ws connections_total should increment");
  assert.ok(statusFinal.websocket.transitions_sent > 0, "ws transitions_sent should increment");
  assert.ok(statusFinal.http.requests_total > 0, "http requests_total should increment");
  assert.ok(statusFinal.http.errors_4xx >= 3, "http errors_4xx should record unauthorized requests");

  const promFinalRes = await fetch(`${serverUrl}/_internal/metrics`, {
    headers: { Authorization: `Bearer ${operatorToken}` },
  });
  const promFinal = await promFinalRes.text();
  assert.ok(promFinal.includes("concave_ws_transitions_sent_total "));
  assert.ok(promFinal.includes("concave_storage_commits_total "));
  assert.equal(stderrLog.includes("panic"), false, `unexpected panic in stderr:\n${stderrLog}`);
});
