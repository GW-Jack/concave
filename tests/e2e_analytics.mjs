import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import { ConcaveClient } from "../client/concave-client/src/index.js";
import { createAnalytics, fromProps } from "../packages/analytics/client.js";

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

test("end-to-end PostHog-style Analytics component: capture, identify/alias, flags, reactive insights, ACID rollback, and isolation", async (t) => {
  const appDir = path.join(ROOT, "tests/fixtures/analytics-app");
  const entryRoc = path.join(appDir, "main.roc");
  const genDir = path.join(appDir, "_generated");
  const binPath = path.join(appDir, ".concave/e2e-analytics-server");
  const dbPath = path.join(appDir, ".concave/e2e-analytics.wal");
  const cliPath = path.join(ROOT, "zig-out/bin/concave");

  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${dbPath}${suffix}`, { force: true });
  }

  // 1. Run `concave codegen` to verify `--introspect` + typed ESM/TS generation for Analytics component.
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
  assert.ok(dataModelDts.includes("export interface AnalyticsEventsDoc"));
  assert.ok(dataModelDts.includes("export interface AnalyticsPersonsDoc"));
  assert.ok(dataModelDts.includes("export interface AnalyticsAliasesDoc"));
  assert.ok(dataModelDts.includes("export interface AnalyticsFeatureFlagsDoc"));
  assert.ok(dataModelDts.includes("export interface BillingAnalyticsEventsDoc"));

  const apiDts = fs.readFileSync(path.join(genDir, "api.d.ts"), "utf8");
  assert.ok(apiDts.includes("readonly capture:"));
  assert.ok(apiDts.includes("readonly evaluateAllFlags:"));
  assert.ok(apiDts.includes("readonly funnel:"));
  assert.ok(apiDts.includes("readonly retention:"));

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

  // 3. Start the server.
  const port = 13221;
  const serverUrl = `http://127.0.0.1:${port}`;
  const serverProc = spawn(
    binPath,
    ["--serve", "--host", "127.0.0.1", "--port", String(port), "--db", dbPath],
    {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, CONCAVE_ALLOW_DEV_TOKENS: "true" },
    },
  );
  let stderrLog = "";
  serverProc.stderr.on("data", (d) => {
    stderrLog += d.toString();
  });
  t.after(() => {
    serverProc.kill("SIGTERM");
    for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
      fs.rmSync(`${dbPath}${suffix}`, { force: true });
    }
  });

  await waitForHealth(serverUrl);

  // 4. Connect admin, non-admin, and anonymous ConcaveClient sessions.
  const aliceClient = new ConcaveClient(serverUrl, { authToken: "dev:alice:Alice:admin" });
  const bobClient = new ConcaveClient(serverUrl, { authToken: "dev:bob:Bob" });
  const anonClient = new ConcaveClient(serverUrl);
  t.after(() => {
    aliceClient.close();
    bobClient.close();
    anonClient.close();
  });

  await waitForCondition(() => aliceClient.status() === "connected", 5000, "alice connected");
  await waitForCondition(() => bobClient.status() === "connected", 5000, "bob connected");
  await waitForCondition(() => anonClient.status() === "connected", 5000, "anon connected");

  const ph = createAnalytics(aliceClient, api.analytics, {
    distinctId: "anon_alice_1",
    sessionId: "sess_alice_1",
    storage: null,
  });

  // 5. Capture pre-login anonymous event, then `identify` to link `anon_alice_1 -> alice`.
  await ph.capture("$pageview", { path: "/pricing", plan_seen: "pro" }, { timestampMs: 1000 });
  const identified = await ph.identify("alice", {
    set: { email: "alice@acme.io", plan: "pro" },
    setOnce: { initial_referrer: "hn", plan: "free" },
  });
  assert.equal(identified.found, true);
  assert.equal(identified.distinct_id, "alice");
  assert.equal(identified.event_count, 1);
  assert.deepEqual(identified.aliases, ["anon_alice_1"]);
  const propsMap = fromProps(identified.properties);
  assert.equal(propsMap.plan, "pro"); // $set beats $set_once
  assert.equal(propsMap.initial_referrer, "hn");

  // Re-identifying with different setOnce must NOT overwrite initial_referrer.
  const reIdentified = await ph.identify("alice", {
    set: { country: "US" },
    setOnce: { initial_referrer: "google" },
  });
  assert.equal(fromProps(reIdentified.properties).initial_referrer, "hn");
  assert.equal(fromProps(reIdentified.properties).country, "US");

  // Querying `getPerson` by the old anonymous ID resolves to canonical `alice`!
  const personByAnon = aliceClient.query(api.analytics.getPerson, { distinct_id: "anon_alice_1" });
  await waitForCondition(() => personByAnon().status === "ready", 5000, "personByAnon ready");
  assert.equal(personByAnon().data.distinct_id, "alice");
  assert.equal(personByAnon().data.found, true);
  personByAnon.dispose();

  // Capture post-login events for alice (with B2B group), plus bob & carol via batch.
  ph.group("company", "acme");
  await ph.capture("signup", { plan: "pro" }, { timestampMs: 1500 });
  await ph.capture("purchase", { plan: "pro", amount: 99 }, { timestampMs: 2100 });
  await ph.capture("active", {}, { timestampMs: 101500 }); // Period 1 retention return
  ph.group("", "");

  const batchRes = await ph.captureBatch([
    { distinctId: "bob", sessionId: "sess_bob", event: "$pageview", properties: { path: "/pricing" }, timestampMs: 1100 },
    { distinctId: "bob", sessionId: "sess_bob", event: "signup", properties: { plan: "free" }, timestampMs: 1400 },
    { distinctId: "carol", sessionId: "sess_carol", event: "$pageview", properties: { path: "/blog" }, timestampMs: 1200 },
    // Carol signs up outside the 3000ms funnel conversion window:
    { distinctId: "carol", sessionId: "sess_carol", event: "signup", properties: { plan: "free" }, timestampMs: 9900 },
    // Dave joins in retention period 1:
    { distinctId: "dave", sessionId: "sess_dave", event: "signup", properties: { plan: "pro" }, timestampMs: 102000 },
  ]);
  assert.equal(batchRes.accepted, 5);
  assert.equal(batchRes.event_ids.length, 5);

  // Verify unified person timeline merges pre-identify `anon_alice_1` + post-identify `alice` events!
  const aliceTimeline = aliceClient.query(api.analytics.personEvents, { distinct_id: "alice", limit: 20 });
  await waitForCondition(() => aliceTimeline().status === "ready", 5000, "aliceTimeline ready");
  assert.equal(aliceTimeline().data.length, 4);
  assert.deepEqual(
    aliceTimeline().data.map((e) => e.event),
    ["active", "purchase", "signup", "$pageview"],
  );
  aliceTimeline.dispose();

  // Verify session and B2B group timelines.
  const sessTimeline = aliceClient.query(api.analytics.sessionEvents, { session_id: "sess_alice_1", limit: 10 });
  await waitForCondition(() => sessTimeline().status === "ready", 5000, "sessTimeline ready");
  assert.equal(sessTimeline().data.length, 4);
  sessTimeline.dispose();

  const groupTimeline = aliceClient.query(api.analytics.groupEvents, {
    group_type: "company",
    group_key: "acme",
    limit: 10,
  });
  await waitForCondition(() => groupTimeline().status === "ready", 5000, "groupTimeline ready");
  assert.equal(groupTimeline().data.length, 3);
  groupTimeline.dispose();

  // 6. Verify Insights: summary, trends (with breakdown & filters), funnel, and retention!
  const summaryQ = aliceClient.query(api.analytics.summary, { from_ms: 0, to_ms: 200000, top_n: 5 });
  await waitForCondition(() => summaryQ().status === "ready", 5000, "summary ready");
  assert.equal(summaryQ().data.total_events, 9);
  assert.equal(summaryQ().data.unique_persons, 4); // alice (unified!), bob, carol, dave
  assert.equal(summaryQ().data.active_sessions, 4);
  assert.equal(summaryQ().data.top_events[0].event, "signup");
  assert.equal(summaryQ().data.top_events[0].count, 4);

  const trendsQ = aliceClient.query(api.analytics.trends, {
    event: "$pageview",
    from_ms: 1000,
    to_ms: 1999,
    bucket_ms: 500,
    breakdown_property: "path",
    filters: [],
  });
  await waitForCondition(() => trendsQ().status === "ready", 5000, "trends ready");
  assert.equal(trendsQ().data.total_events, 3);
  assert.equal(trendsQ().data.unique_persons, 3);
  assert.equal(trendsQ().data.buckets.length, 2);
  assert.equal(trendsQ().data.buckets[0].count, 3);
  assert.equal(trendsQ().data.breakdown[0].value, "/pricing");
  assert.equal(trendsQ().data.breakdown[0].count, 2);

  const funnelQ = aliceClient.query(api.analytics.funnel, {
    steps: ["$pageview", "signup", "purchase"],
    from_ms: 0,
    to_ms: 5000,
    conversion_window_ms: 3000,
    filters: [],
  });
  await waitForCondition(() => funnelQ().status === "ready", 5000, "funnel ready");
  assert.equal(funnelQ().data.total_entered, 3);
  assert.deepEqual(
    funnelQ().data.steps.map((s) => s.count),
    [3, 2, 1],
  );
  // Step 1 avg time: alice (1500-1000=500) + bob (1400-1100=300) -> avg 400ms
  assert.equal(funnelQ().data.steps[1].avg_time_from_prev_ms, 400);
  // Step 2 avg time: alice (2100-1500=600) -> 600ms
  assert.equal(funnelQ().data.steps[2].avg_time_from_prev_ms, 600);
  funnelQ.dispose();

  const retentionQ = aliceClient.query(api.analytics.retention, {
    cohort_event: "signup",
    return_event: "active",
    from_ms: 0,
    period_ms: 100000,
    num_periods: 2,
  });
  await waitForCondition(() => retentionQ().status === "ready", 5000, "retention ready");
  assert.equal(retentionQ().data.cohorts.length, 2);
  assert.equal(retentionQ().data.cohorts[0].cohort_size, 3); // alice, bob, carol signed up in [0, 100000)
  assert.deepEqual(retentionQ().data.cohorts[0].retained_counts, [0, 1]); // alice returned in period 1
  assert.equal(retentionQ().data.cohorts[1].cohort_size, 1); // dave signed up in [100000, 200000)
  retentionQ.dispose();

  // 7. Verify surgical ReadSet reactivity:
  //    Subscribe a second admin client strictly to `recentEvents(event: "rare_event")`.
  //    Capturing `$pageview` updates `trendsQ` immediately, while `observerClient` commitTs does NOT advance!
  const observerClient = new ConcaveClient(serverUrl, { authToken: "dev:observer:Obs:admin" });
  t.after(() => observerClient.close());
  await waitForCondition(() => observerClient.status() === "connected", 5000, "observer connected");

  const rareSub = observerClient.query(api.analytics.recentEvents, { event: "rare_event", limit: 10 });
  await waitForCondition(() => rareSub().status === "ready", 5000, "rareSub ready");
  const obsTsBefore = observerClient.commitTs();

  await ph.capture("$pageview", { path: "/pricing" }, { timestampMs: 1600 });
  await waitForCondition(
    () => trendsQ().data?.total_events === 4,
    5000,
    `trendsQ updates reactively (stderr: ${stderrLog})`,
  );
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(
    observerClient.commitTs(),
    obsTsBefore,
    "Subscriber watching `rare_event` must not be invalidated by `$pageview` capture",
  );
  rareSub.dispose();
  trendsQ.dispose();
  summaryQ.dispose();

  // Verify unauthenticated & non-admin callers cannot read admin BI endpoints or alias another user.
  await assert.rejects(
    () => anonClient.queryOnce(api.analytics.summary, { from_ms: 0, to_ms: 200000, top_n: 5 }),
    /Unauthenticated/,
  );
  await assert.rejects(
    () => bobClient.queryOnce(api.analytics.listPersons, { limit: 10 }),
    /Forbidden/,
  );
  await assert.rejects(
    () => bobClient.mutate(api.analytics.alias, { alias_id: "alice", distinct_id: "bob" }),
    /Forbidden/,
  );

  // 8. Feature Flags & Multivariate Experiments (with live WebSocket kill-switch updates!).
  await aliceClient.mutate(api.analytics.upsertFlag, {
    key: "free-shipping",
    name: "Free shipping for Pro users",
    active: true,
    rollout_pct: 100,
    filters: [{ key: "plan", op: "eq", value: "pro" }],
    variants: [],
  });
  await aliceClient.mutate(api.analytics.upsertFlag, {
    key: "checkout-ab",
    name: "Checkout A/B experiment",
    active: true,
    rollout_pct: 100,
    filters: [],
    variants: [
      { key: "control", weight: 50 },
      { key: "one-click", weight: 50 },
    ],
  });

  const aliceFlags = ph.subscribeFlags();
  await waitForCondition(
    () => aliceFlags().status === "ready" && aliceFlags().data.length === 2,
    5000,
    "aliceFlags ready",
  );
  const freeShip = aliceFlags().data.find((f) => f.key === "free-shipping");
  const abFlag = aliceFlags().data.find((f) => f.key === "checkout-ab");
  assert.equal(freeShip.enabled, true);
  assert.equal(abFlag.enabled, true);
  assert.ok(["control", "one-click"].includes(abFlag.variant));

  // Bob (plan != pro) does NOT match `free-shipping`.
  const bobFlag = aliceClient.query(api.analytics.evaluateFlag, {
    key: "free-shipping",
    distinct_id: "bob",
    override_properties: [],
  });
  await waitForCondition(() => bobFlag().status === "ready", 5000, "bobFlag ready");
  assert.equal(bobFlag().data.enabled, false);
  assert.equal(bobFlag().data.reason, "filter_mismatch");
  bobFlag.dispose();

  // Evaluate + atomically record `$feature_flag_called` exposure event.
  const trackedEval = await ph.evaluateFlagAndTrack("checkout-ab");
  assert.equal(trackedEval.variant, abFlag.variant);
  const exposureEvents = aliceClient.query(api.analytics.recentEvents, {
    event: "$feature_flag_called",
    limit: 5,
  });
  await waitForCondition(
    () => exposureEvents().status === "ready" && exposureEvents().data.length === 1,
    5000,
    "exposure event captured",
  );
  assert.equal(fromProps(exposureEvents().data[0].properties).$feature_flag, "checkout-ab");
  exposureEvents.dispose();

  // 9. Server-side ACID integration (`orders.place`) + rollback verification!
  //    Alice has `free-shipping` enabled -> order commits with `free_shipping: true` AND tracks `order_placed`.
  const goodOrder = await aliceClient.mutate(api.orders.place, { amount: 42 });
  assert.equal(goodOrder.free_shipping, true);

  //    Invalid order (`amount: -5`) calls `Analytics.track_event!` and then returns `Err` ->
  //    ACID rollback MUST leave zero additional `order_placed` events!
  await assert.rejects(
    () => aliceClient.mutate(api.orders.place, { amount: -5 }),
    /Order amount must be positive/,
  );

  const orderEvents = aliceClient.query(api.analytics.recentEvents, { event: "order_placed", limit: 10 });
  await waitForCondition(() => orderEvents().status === "ready", 5000, "orderEvents ready");
  assert.equal(orderEvents().data.length, 1);
  assert.equal(fromProps(orderEvents().data[0].properties).amount, "42");
  orderEvents.dispose();

  // Toggle kill switch on `free-shipping` -> live WebSocket subscription pushes update!
  await aliceClient.mutate(api.analytics.upsertFlag, {
    key: "free-shipping",
    name: "Free shipping for Pro users",
    active: false,
    rollout_pct: 100,
    filters: [{ key: "plan", op: "eq", value: "pro" }],
    variants: [],
  });
  await waitForCondition(
    () => aliceFlags().data?.find((f) => f.key === "free-shipping")?.enabled === false,
    5000,
    "kill switch propagates reactively via WebSocket",
  );
  const deleted = await aliceClient.mutate(api.analytics.deleteFlag, { key: "checkout-ab" });
  assert.equal(deleted, true);
  await waitForCondition(
    () => aliceFlags().data?.length === 1,
    5000,
    "deleted flag removed reactively",
  );
  aliceFlags.dispose();

  // 10. Verify second mounted instance (`billing_analytics`) enforces auth, max_batch_size, and namespace isolation!
  await assert.rejects(
    () =>
      anonClient.mutate(api.billing_analytics.upsertFlag, {
        key: "promo",
        name: "Promo",
        active: true,
        rollout_pct: 100,
        filters: [],
        variants: [],
      }),
    /Unauthenticated/,
  );

  await assert.rejects(
    () =>
      aliceClient.mutate(api.billing_analytics.captureBatch, {
        events: [
          { distinct_id: "alice", event: "e1", properties: [], session_id: "", group_type: "", group_key: "", timestamp_ms: 1 },
          { distinct_id: "alice", event: "e2", properties: [], session_id: "", group_type: "", group_key: "", timestamp_ms: 2 },
          { distinct_id: "alice", event: "e3", properties: [], session_id: "", group_type: "", group_key: "", timestamp_ms: 3 },
        ],
      }),
    /exceeds max_batch_size/,
  );

  await aliceClient.mutate(api.billing_analytics.capture, {
    distinct_id: "alice",
    event: "invoice_paid",
    properties: [{ key: "usd", value: "299" }],
    session_id: "",
    group_type: "",
    group_key: "",
    timestamp_ms: 5000,
  });

  const billingEvents = aliceClient.query(api.billing_analytics.recentEvents, { event: "", limit: 10 });
  const productInvoiceEvents = aliceClient.query(api.analytics.recentEvents, {
    event: "invoice_paid",
    limit: 10,
  });
  await waitForCondition(() => billingEvents().status === "ready", 5000, "billingEvents ready");
  await waitForCondition(() => productInvoiceEvents().status === "ready", 5000, "productInvoiceEvents ready");
  assert.equal(billingEvents().data.length, 1);
  assert.equal(productInvoiceEvents().data.length, 0);
  billingEvents.dispose();
  productInvoiceEvents.dispose();
});
