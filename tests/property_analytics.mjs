import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import { fromProps } from "../packages/analytics/client.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

function makeRng(seed) {
  let state = seed >>> 0;
  return () => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) / 0x100000000;
  };
}

function pick(rng, arr) {
  return arr[Math.floor(rng() * arr.length)];
}

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

const ADMIN_TOKEN = "dev:admin:Admin:admin";

async function rpc(serverUrl, kind, name, args, authToken = ADMIN_TOKEN) {
  const headers = { "Content-Type": "application/json" };
  if (authToken) headers.Authorization = `Bearer ${authToken}`;
  const res = await fetch(`${serverUrl}/api/${kind}/${name}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
  });
  const body = await res.json();
  return { status: res.status, ...body };
}

/**
 * Independent reference oracle for PostHog-style Analytics semantics.
 */
class AnalyticsOracle {
  constructor() {
    /** @type {Map<string, string>} alias_id -> canonical_id */
    this.aliases = new Map();
    /** @type {Map<string, { props: Map<string, string>, eventCount: number }>} */
    this.persons = new Map();
    /** @type {Array<{ distinct_id: string, event: string, timestamp_ms: number, session_id: string, properties: Array<{ key: string, value: string }> }>} */
    this.events = [];
  }

  resolve(rawId) {
    let cur = rawId;
    for (let i = 0; i < 8; i += 1) {
      const next = this.aliases.get(cur);
      if (!next || next === cur) return cur;
      cur = next;
    }
    return cur;
  }

  capture(ev) {
    const canon = this.resolve(ev.distinct_id);
    this.events.push({
      distinct_id: canon,
      event: ev.event,
      timestamp_ms: ev.timestamp_ms,
      session_id: ev.session_id,
      properties: ev.properties,
    });
    const p = this.persons.get(canon) ?? { props: new Map(), eventCount: 0 };
    p.eventCount += 1;
    this.persons.set(canon, p);
  }

  identify(distinctId, anonId, setList, setOnceList) {
    const canon = this.resolve(distinctId);
    let anonProps = new Map();
    let anonCount = 0;

    if (anonId && anonId !== canon) {
      const anonRes = this.resolve(anonId);
      if (anonRes === anonId) {
        this.aliases.set(anonId, canon);
        const ap = this.persons.get(anonId);
        if (ap) {
          anonProps = ap.props;
          anonCount = ap.eventCount;
          this.persons.delete(anonId);
        }
      }
    }

    const existing = this.persons.get(canon);
    const merged = new Map(anonProps);
    if (existing) {
      for (const [k, v] of existing.props) merged.set(k, v);
    }
    for (const p of setOnceList) {
      if (p.key && !merged.has(p.key)) merged.set(p.key, p.value);
    }
    for (const p of setList) {
      if (p.key) merged.set(p.key, p.value);
    }
    this.persons.set(canon, {
      props: merged,
      eventCount: (existing?.eventCount ?? 0) + anonCount,
    });
  }

  alias(aliasId, distinctId) {
    if (!aliasId || !distinctId) return { ok: false };
    if (aliasId === distinctId) return { ok: true, changed: false };
    const target = this.resolve(distinctId);
    if (target === aliasId) return { ok: false };
    const srcRes = this.resolve(aliasId);
    if (srcRes === target) return { ok: true, changed: false };
    if (srcRes !== aliasId) return { ok: false };

    this.aliases.set(aliasId, target);
    const sp = this.persons.get(aliasId);
    if (sp) {
      this.persons.delete(aliasId);
      const dp = this.persons.get(target);
      if (!dp) {
        this.persons.set(target, { props: new Map(sp.props), eventCount: sp.eventCount });
      } else {
        const merged = new Map(sp.props);
        for (const [k, v] of dp.props) merged.set(k, v);
        this.persons.set(target, {
          props: merged,
          eventCount: dp.eventCount + sp.eventCount,
        });
      }
    }
    return { ok: true, changed: true };
  }

  resolvedEventCount(rootId) {
    let n = 0;
    for (const ev of this.events) {
      if (this.resolve(ev.distinct_id) === rootId) n += 1;
    }
    return n;
  }

  summary(fromMs, toMs) {
    const inRange = this.events.filter((e) => e.timestamp_ms >= fromMs && e.timestamp_ms <= toMs);
    const persons = new Set();
    const sessions = new Set();
    for (const ev of inRange) {
      persons.add(this.resolve(ev.distinct_id));
      if (ev.session_id) sessions.add(ev.session_id);
    }
    return {
      total_events: inRange.length,
      unique_persons: persons.size,
      active_sessions: sessions.size,
    };
  }

  funnel(steps, fromMs, toMs, windowMs) {
    const relevant = this.events
      .filter((e) => e.timestamp_ms >= fromMs && e.timestamp_ms <= toMs + windowMs && steps.includes(e.event))
      .map((e) => ({ canon: this.resolve(e.distinct_id), event: e.event, timestamp_ms: e.timestamp_ms }));
    const entrants = new Set(
      relevant.filter((e) => e.event === steps[0] && e.timestamp_ms <= toMs).map((e) => e.canon),
    );
    const maxSteps = [];
    for (const person of entrants) {
      const pe = relevant.filter((e) => e.canon === person).sort((a, b) => a.timestamp_ms - b.timestamp_ms);
      let best = -1;
      for (let i = 0; i < pe.length; i += 1) {
        if (pe[i].event === steps[0] && pe[i].timestamp_ms <= toMs) {
          const deadline = pe[i].timestamp_ms + windowMs;
          let reached = 0;
          let lastTs = pe[i].timestamp_ms;
          let want = 1;
          for (let j = i + 1; j < pe.length && want < steps.length; j += 1) {
            if (pe[j].timestamp_ms <= deadline && pe[j].event === steps[want] && pe[j].timestamp_ms >= lastTs) {
              reached = want;
              lastTs = pe[j].timestamp_ms;
              want += 1;
            }
          }
          if (reached > best) best = reached;
        }
      }
      if (best >= 0) maxSteps.push(best);
    }
    return {
      total_entered: maxSteps.length,
      counts: steps.map((_, idx) => maxSteps.filter((m) => m >= idx).length),
    };
  }

  retention(cohortEvent, returnEvent, fromMs, periodMs, numPeriods) {
    const endMs = fromMs + numPeriods * periodMs;
    const earliest = new Map();
    const returns = [];
    for (const ev of this.events) {
      if (ev.timestamp_ms >= fromMs && ev.timestamp_ms < endMs) {
        const canon = this.resolve(ev.distinct_id);
        const p = Math.floor((ev.timestamp_ms - fromMs) / periodMs);
        if (ev.event === cohortEvent) {
          const prev = earliest.get(canon);
          if (prev === undefined || p < prev) earliest.set(canon, p);
        }
        if (ev.event === returnEvent) {
          returns.push({ canon, p });
        }
      }
    }
    const cohorts = [];
    for (let c = 0; c < numPeriods; c += 1) {
      const members = [...earliest.entries()].filter(([, p]) => p === c).map(([id]) => id);
      const memberSet = new Set(members);
      const retained_counts = [];
      for (let off = 0; c + off < numPeriods; off += 1) {
        const hit = new Set(returns.filter((r) => r.p === c + off && memberSet.has(r.canon)).map((r) => r.canon));
        retained_counts.push(hit.size);
      }
      cohorts.push({ cohort_size: members.length, retained_counts });
    }
    return cohorts;
  }
}

test("model-based differential oracle & boundary fuzz test against compiled native Analytics server", async (t) => {
  const appDir = path.join(ROOT, "tests/fixtures/analytics-app");
  const entryRoc = path.join(appDir, "main.roc");
  const binPath = path.join(appDir, ".concave/prop-analytics-server");
  const dbPath = path.join(appDir, ".concave/prop-analytics.wal");
  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${dbPath}${suffix}`, { force: true });
  }

  const build = spawnSync("roc", ["build", "--opt=dev", `--output=${binPath}`, entryRoc], {
    cwd: ROOT,
    encoding: "utf8",
  });
  assert.equal(build.status, 0, `roc build failed:\n${build.stdout}\n${build.stderr}`);

  const port = 13227;
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

  const rng = makeRng(0xC04CA7E1);
  const oracle = new AnalyticsOracle();
  const ids = ["u0", "u1", "u2", "u3", "u4", "u5", "u6", "u7"];
  const eventNames = ["visit", "signup", "click", "buy", "active"];
  const sessions = ["s0", "s1", "s2", "s3", ""];
  const plans = ["free", "pro", "enterprise"];

  async function verifyAgainstOracle(stepLabel) {
    // 1. Summary exact match
    const sumRes = await rpc(serverUrl, "query", "analytics.summary", {
      from_ms: 0,
      to_ms: 200000,
      top_n: 10,
    });
    assert.equal(sumRes.ok, true, `summary failed at ${stepLabel}: ${JSON.stringify(sumRes)}`);
    const expSum = oracle.summary(0, 200000);
    assert.equal(sumRes.value.total_events, expSum.total_events, `total_events at ${stepLabel}`);
    assert.equal(sumRes.value.unique_persons, expSum.unique_persons, `unique_persons at ${stepLabel}`);
    assert.equal(sumRes.value.active_sessions, expSum.active_sessions, `active_sessions at ${stepLabel}`);

    // 2. Identity invariants: NO orphan non-root person rows, exact event conservation, exact props!
    const listP = await rpc(serverUrl, "query", "analytics.listPersons", { limit: 100 });
    assert.equal(listP.ok, true);
    let totalPersonEvents = 0;
    for (const p of listP.value) {
      assert.equal(
        oracle.resolve(p.distinct_id),
        p.distinct_id,
        `ORPHAN NON-ROOT PERSON ROW ${p.distinct_id} at ${stepLabel}`,
      );
      totalPersonEvents += p.event_count;
      // No duplicate keys in person properties
      const keys = p.properties.map((kv) => kv.key);
      assert.equal(new Set(keys).size, keys.length, `duplicate keys on ${p.distinct_id} at ${stepLabel}`);
    }
    assert.equal(
      totalPersonEvents,
      oracle.events.length,
      `EVENT CONSERVATION VIOLATED at ${stepLabel}: sum(person.event_count)=${totalPersonEvents} vs events=${oracle.events.length}`,
    );

    for (const id of ids) {
      const gp = await rpc(serverUrl, "query", "analytics.getPerson", { distinct_id: id });
      assert.equal(gp.ok, true);
      const canon = oracle.resolve(id);
      assert.equal(gp.value.distinct_id, canon, `resolve(${id}) mismatch at ${stepLabel}`);
      const expPerson = oracle.persons.get(canon);
      if (expPerson) {
        assert.equal(gp.value.found, true);
        assert.equal(gp.value.event_count, expPerson.eventCount, `event_count(${id}) at ${stepLabel}`);
        assert.equal(gp.value.event_count, oracle.resolvedEventCount(canon), `conservation(${id}) at ${stepLabel}`);
        const actualProps = { ...fromProps(gp.value.properties) };
        assert.deepEqual(actualProps, Object.fromEntries(expPerson.props), `props(${id}) at ${stepLabel}`);
      } else {
        assert.equal(gp.value.found, false);
      }
    }

    // 3. Trends bucket conservation (even with tiny bucket_ms forcing auto-widening!)
    const tr = await rpc(serverUrl, "query", "analytics.trends", {
      event: "visit",
      from_ms: 0,
      to_ms: 200000,
      bucket_ms: 100, // 2000 buckets requested -> auto-widens to <= 500!
      breakdown_property: "plan",
      filters: [],
    });
    assert.equal(tr.ok, true);
    assert.ok(tr.value.buckets.length <= 500);
    const bucketSum = tr.value.buckets.reduce((acc, b) => acc + b.count, 0);
    assert.equal(
      bucketSum,
      tr.value.total_events,
      `BUCKET CONSERVATION VIOLATED at ${stepLabel}: sum=${bucketSum} vs total=${tr.value.total_events}`,
    );

    // 4. Funnel exact match & monotonicity
    const funnelSteps = ["visit", "signup", "buy"];
    const fnRes = await rpc(serverUrl, "query", "analytics.funnel", {
      steps: funnelSteps,
      from_ms: 0,
      to_ms: 200000,
      conversion_window_ms: 25000,
      filters: [],
    });
    assert.equal(fnRes.ok, true);
    const expFunnel = oracle.funnel(funnelSteps, 0, 200000, 25000);
    assert.equal(fnRes.value.total_entered, expFunnel.total_entered, `funnel entered at ${stepLabel}`);
    assert.deepEqual(
      fnRes.value.steps.map((s) => s.count),
      expFunnel.counts,
      `funnel step counts at ${stepLabel}`,
    );
    for (let i = 1; i < fnRes.value.steps.length; i += 1) {
      assert.ok(fnRes.value.steps[i].count <= fnRes.value.steps[i - 1].count);
    }

    // 5. Retention exact match + self-retention period-0 exactness
    const retRes = await rpc(serverUrl, "query", "analytics.retention", {
      cohort_event: "signup",
      return_event: "active",
      from_ms: 0,
      period_ms: 40000,
      num_periods: 4,
    });
    assert.equal(retRes.ok, true);
    const expRet = oracle.retention("signup", "active", 0, 40000, 4);
    assert.deepEqual(
      retRes.value.cohorts.map((c) => ({
        cohort_size: c.cohort_size,
        retained_counts: c.retained_counts,
      })),
      expRet,
      `retention mismatch at ${stepLabel}`,
    );

    const selfRet = await rpc(serverUrl, "query", "analytics.retention", {
      cohort_event: "visit",
      return_event: "visit",
      from_ms: 0,
      period_ms: 40000,
      num_periods: 4,
    });
    assert.equal(selfRet.ok, true);
    for (const c of selfRet.value.cohorts) {
      assert.equal(c.retained_counts[0], c.cohort_size, `self-retention period-0 exact at ${stepLabel}`);
    }
  }

  // Run 140 randomized adversarial operations!
  for (let step = 1; step <= 140; step += 1) {
    const roll = rng();
    if (roll < 0.55) {
      // Capture event
      const ev = {
        distinct_id: pick(rng, ids),
        event: pick(rng, eventNames),
        properties: [
          { key: "plan", value: pick(rng, plans) },
          { key: "step", value: String(step) },
        ],
        session_id: pick(rng, sessions),
        group_type: "",
        group_key: "",
        timestamp_ms: 1000 + Math.floor(rng() * 150000),
      };
      const res = await rpc(serverUrl, "mutation", "analytics.capture", ev);
      assert.equal(res.ok, true, `capture failed at step ${step}: ${JSON.stringify(res)}`);
      oracle.capture(ev);
    } else if (roll < 0.72) {
      // Identify with random anon_id (including potential cycle / re-alias / duplicate key attempts!)
      const did = pick(rng, ids);
      const aid = rng() < 0.75 ? pick(rng, ids) : "";
      const setList = [{ key: "plan", value: pick(rng, plans) }];
      const setOnceList = [
        { key: "first_tag", value: `tag-${step}` },
        { key: "plan", value: "ignored_by_set" },
      ];
      const res = await rpc(serverUrl, "mutation", "analytics.identify", {
        distinct_id: did,
        anon_id: aid,
        set: setList,
        set_once: setOnceList,
      });
      assert.equal(res.ok, true, `identify failed at step ${step}: ${JSON.stringify(res)}`);
      oracle.identify(did, aid, setList, setOnceList);
    } else if (roll < 0.85) {
      // Alias (adversarially attempts cycles & re-aliasing)
      const a = pick(rng, ids);
      const b = pick(rng, ids);
      const res = await rpc(serverUrl, "mutation", "analytics.alias", {
        alias_id: a,
        distinct_id: b,
      });
      const expected = oracle.alias(a, b);
      assert.equal(res.ok, expected.ok, `alias(${a}->${b}) ok mismatch at step ${step}: ${JSON.stringify(res)}`);
    } else {
      // Parent mutation with 50% ACID rollback!
      const user = pick(rng, ids);
      const amount = rng() < 0.5 ? -10 : 50;
      const res = await rpc(serverUrl, "mutation", "orders.place", { amount }, `dev:${user}:${user}`);
      if (amount > 0) {
        assert.equal(res.ok, true, `orders.place(${amount}) should commit`);
        // Note: `orders.place` uses server `now_ms!()` (> 200000) so fetch it to keep oracle event count in sync
        const recent = await rpc(serverUrl, "query", "analytics.recentEvents", {
          event: "order_placed",
          limit: 1,
        });
        assert.equal(recent.ok, true);
        const ev = recent.value[0];
        oracle.capture({
          distinct_id: user,
          event: "order_placed",
          timestamp_ms: ev.timestamp_ms,
          session_id: "",
          properties: ev.properties,
        });
      } else {
        assert.equal(res.ok, false, `orders.place(${amount}) must roll back`);
      }
    }

    if (step % 35 === 0) {
      await verifyAgainstOracle(`step-${step}`);
    }
  }

  await verifyAgainstOracle("final");

  // Boundary & Overflow Fuzzing (must NEVER panic or return 500!)
  const MAX_SAFE = Number.MAX_SAFE_INTEGER;
  const boundaryCalls = [
    ["query", "analytics.summary", { from_ms: 5000, to_ms: 1000, top_n: 5 }], // inverted range
    ["query", "analytics.summary", { from_ms: 0, to_ms: MAX_SAFE, top_n: 0 }],
    ["query", "analytics.trends", { event: "visit", from_ms: 0, to_ms: MAX_SAFE, bucket_ms: 1, breakdown_property: "", filters: [] }],
    ["query", "analytics.trends", { event: "visit", from_ms: 5000, to_ms: 1000, bucket_ms: -5, breakdown_property: "", filters: [{ key: "plan", op: "in", value: "" }] }],
    ["query", "analytics.funnel", { steps: [], from_ms: 0, to_ms: 1000, conversion_window_ms: MAX_SAFE, filters: [] }],
    ["query", "analytics.funnel", { steps: ["visit", "visit"], from_ms: 0, to_ms: MAX_SAFE, conversion_window_ms: MAX_SAFE, filters: [] }],
    ["query", "analytics.retention", { cohort_event: "visit", return_event: "", from_ms: 0, period_ms: MAX_SAFE, num_periods: 60 }],
    ["mutation", "analytics.upsertFlag", {
      key: "huge-weights",
      name: "Large weights > 10k",
      active: true,
      rollout_pct: 100,
      filters: [],
      variants: [
        { key: "v1", weight: 50000 },
        { key: "v2", weight: 50000 },
      ],
    }],
  ];

  for (const [kind, name, args] of boundaryCalls) {
    const res = await rpc(serverUrl, kind, name, args);
    assert.equal(res.status, 200, `Boundary call ${name} returned HTTP ${res.status}: ${JSON.stringify(res)} (stderr: ${stderrLog})`);
    assert.equal(res.ok, true, `Boundary call ${name} failed: ${JSON.stringify(res)}`);
  }

  // Verify large-weight flag (`50000 / 50000`) actually reaches BOTH `v1` and `v2`!
  const seenVariants = new Set();
  for (let i = 0; i < 40; i += 1) {
    const ev = await rpc(serverUrl, "query", "analytics.evaluateFlag", {
      key: "huge-weights",
      distinct_id: `fuzz-user-${i}`,
      override_properties: [],
    });
    assert.equal(ev.ok, true);
    assert.equal(ev.value.enabled, true);
    seenVariants.add(ev.value.variant);
  }
  assert.deepEqual([...seenVariants].sort(), ["v1", "v2"], "Both large-weight variants must be reachable");

  // Verify excessively huge variant weight (> 10,000,000) is rejected cleanly (not overflow panic!).
  const overflowFlag = await rpc(serverUrl, "mutation", "analytics.upsertFlag", {
    key: "bad-weights",
    name: "Overflow test",
    active: true,
    rollout_pct: 100,
    filters: [],
    variants: [
      { key: "a", weight: 9000000 },
      { key: "b", weight: 9000000 },
    ],
  });
  assert.equal(overflowFlag.ok, false);
  assert.match(overflowFlag.error, /exceeds maximum/);
});
