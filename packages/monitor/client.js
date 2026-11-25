// Zero-dependency browser & Node ESM helper for Concave's Monitor component.
// Works with any `ConcaveClient` instance and the generated `api.<namespace>` reference tree.

/**
 * Convert a plain JS object (or already-formatted `Array<{ key, value }>`) into
 * Concave Monitor's typed `Array<{ key: string, value: string }>` wire format.
 *
 * @param {Record<string, unknown> | Array<{ key: string, value: string }> | null | undefined} input
 * @returns {Array<{ key: string, value: string }>}
 */
export function toAttrs(input) {
  if (!input) return [];
  if (Array.isArray(input)) {
    return input
      .filter((a) => a && typeof a.key === "string" && a.key.length > 0)
      .map((a) => ({ key: a.key, value: String(a.value ?? "") }));
  }
  /** @type {Array<{ key: string, value: string }>} */
  const out = [];
  for (const [key, val] of Object.entries(input)) {
    if (val === undefined || val === null) continue;
    out.push({ key, value: typeof val === "string" ? val : String(val) });
  }
  return out;
}

const FORBIDDEN_ATTR_KEYS = new Set(["__proto__", "constructor", "prototype"]);

/**
 * Convert `Array<{ key: string, value: string }>` back into a null-prototype JS object.
 *
 * @param {Array<{ key: string, value: string }> | null | undefined} attrs
 * @returns {Record<string, string>}
 */
export function fromAttrs(attrs) {
  /** @type {Record<string, string>} */
  const out = Object.create(null);
  if (!attrs) return out;
  for (const a of attrs) {
    if (!a || typeof a.key !== "string" || FORBIDDEN_ATTR_KEYS.has(a.key)) continue;
    out[a.key] = a.value;
  }
  return out;
}

/** @param {string} prefix */
function randomId(prefix) {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return `${prefix}_${crypto.randomUUID().replace(/-/g, "").slice(0, 16)}`;
  }
  if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") {
    const bytes = new Uint8Array(8);
    crypto.getRandomValues(bytes);
    let hex = "";
    for (const b of bytes) hex += b.toString(16).padStart(2, "0");
    return `${prefix}_${hex}`;
  }
  throw new Error("Cryptographically secure random generator is unavailable");
}

/** @param {string} raw @param {boolean} keepQuery */
function sanitizeUrl(raw, keepQuery) {
  if (!raw || keepQuery) return raw;
  try {
    const u = new URL(raw);
    return `${u.origin}${u.pathname}`;
  } catch {
    return raw.split(/[?#]/, 1)[0];
  }
}

/**
 * Create a lightweight Sentry/observability client bound to a `ConcaveClient` and
 * a mounted `Monitor` component namespace (e.g. `api.monitor`).
 *
 * @param {import("../../client/concave-client/src/client.js").ConcaveClient} client
 * @param {any} monitorApi - e.g. `api.monitor` from `_generated/api.js`
 * @param {{
 *   service?: string,
 *   release?: string,
 *   environment?: string,
 *   captureGlobalErrors?: boolean,
 *   captureQueryParams?: boolean,
 *   maxBreadcrumbs?: number,
 * }} [options]
 */
export function createMonitor(client, monitorApi, options = {}) {
  const defaultService = options.service ?? "frontend";
  const release = options.release ?? "";
  const environment = options.environment ?? "";
  const captureQueryParams = options.captureQueryParams === true;
  const maxBreadcrumbs = options.maxBreadcrumbs ?? 20;

  /** @type {Array<{ ts: number, category: string, message: string }>} */
  const breadcrumbs = [];
  /** @type {Array<() => void>} */
  const globalCleanups = [];

  /** @param {string} category @param {string} message */
  function addBreadcrumb(category, message) {
    breadcrumbs.push({ ts: Date.now(), category, message });
    while (breadcrumbs.length > maxBreadcrumbs) {
      breadcrumbs.shift();
    }
  }

  /** @param {Record<string, unknown> | Array<{ key: string, value: string }>} [extra] */
  function buildAttrs(extra = {}) {
    /** @type {Record<string, unknown>} */
    const base = {};
    if (release) base.release = release;
    if (environment) base.environment = environment;
    if (typeof window !== "undefined" && window.location) {
      base.url = sanitizeUrl(window.location.href, captureQueryParams);
    }
    if (breadcrumbs.length > 0) {
      base.breadcrumbs = breadcrumbs
        .slice(-5)
        .map((b) => `[${b.category}] ${b.message}`)
        .join(" -> ");
    }
    const extraObj = Array.isArray(extra) ? fromAttrs(extra) : extra;
    return toAttrs({ ...base, ...extraObj });
  }

  /**
   * Capture an `Error` or message into the grouped Issues inbox.
   *
   * @param {unknown} err
   * @param {{
   *   source?: string,
   *   errorType?: string,
   *   level?: "debug" | "info" | "warn" | "error" | "fatal",
   *   traceId?: string,
   *   userId?: string,
   *   fingerprint?: string,
   *   attrs?: Record<string, unknown> | Array<{ key: string, value: string }>,
   *   timestampMs?: number,
   * }} [ctx]
   */
  async function captureException(err, ctx = {}) {
    const isErr = err instanceof Error;
    const message = isErr ? err.message || String(err) : String(err ?? "Unknown error");
    const errorType = ctx.errorType ?? (isErr && err.name ? err.name : "Error");
    const stack = isErr && typeof err.stack === "string" ? err.stack : "";
    const userId = ctx.userId ?? client.identity?.()?.subject ?? "";

    return await client.mutate(monitorApi.captureError, {
      source: ctx.source ?? defaultService,
      error_type: errorType,
      message,
      level: ctx.level ?? "error",
      stack,
      trace_id: ctx.traceId ?? "",
      user_id: userId,
      fingerprint: ctx.fingerprint ?? "",
      attrs: buildAttrs(ctx.attrs),
      timestamp_ms: ctx.timestampMs ?? 0,
    });
  }

  /** @param {string} issueId @param {"open" | "resolved" | "ignored"} status */
  async function updateIssueStatus(issueId, status) {
    return await client.mutate(monitorApi.updateIssueStatus, {
      issue_id: issueId,
      status,
    });
  }

  /**
   * Record a structured log entry or operation span.
   *
   * @param {"debug" | "info" | "warn" | "error" | "fatal"} level
   * @param {string} message
   * @param {{
   *   service?: string,
   *   fnName?: string,
   *   traceId?: string,
   *   spanId?: string,
   *   durationMs?: number,
   *   status?: string,
   *   attrs?: Record<string, unknown> | Array<{ key: string, value: string }>,
   *   timestampMs?: number,
   * }} [opts]
   */
  async function log(level, message, opts = {}) {
    return await client.mutate(monitorApi.log, {
      level,
      service: opts.service ?? defaultService,
      fn_name: opts.fnName ?? "",
      trace_id: opts.traceId ?? "",
      span_id: opts.spanId ?? "",
      duration_ms: opts.durationMs ?? 0,
      status: opts.status ?? (level === "error" || level === "fatal" ? "error" : "ok"),
      message,
      attrs: toAttrs(opts.attrs),
      timestamp_ms: opts.timestampMs ?? 0,
    });
  }

  /**
   * Record a custom application metric (`counter`, `gauge`, or `timing`).
   *
   * @param {string} name
   * @param {number} value
   * @param {{
   *   kind?: "counter" | "gauge" | "timing",
   *   service?: string,
   *   attrs?: Record<string, unknown> | Array<{ key: string, value: string }>,
   *   timestampMs?: number,
   * }} [opts]
   */
  async function metric(name, value, opts = {}) {
    return await client.mutate(monitorApi.recordMetric, {
      name,
      kind: opts.kind ?? "gauge",
      value,
      service: opts.service ?? defaultService,
      attrs: toAttrs(opts.attrs),
      timestamp_ms: opts.timestampMs ?? 0,
    });
  }

  /**
   * Time an async operation, recording a traced span log + timing metric,
   * and automatically capturing any thrown exception under the same `traceId`.
   *
   * @template T
   * @param {string} name
   * @param {(traceId: string) => Promise<T>} fn
   * @param {{ service?: string, traceId?: string, attrs?: Record<string, unknown> }} [opts]
   * @returns {Promise<T>}
   */
  async function time(name, fn, opts = {}) {
    const traceId = opts.traceId || randomId("tr");
    const spanId = randomId("sp");
    const service = opts.service ?? defaultService;
    const start = Date.now();
    try {
      const result = await fn(traceId);
      const durationMs = Math.max(0, Date.now() - start);
      await Promise.all([
        log("info", `${name} completed in ${durationMs}ms`, {
          service,
          fnName: name,
          traceId,
          spanId,
          durationMs,
          status: "ok",
          attrs: opts.attrs,
        }),
        metric(`${name}.duration_ms`, durationMs, {
          kind: "timing",
          service,
          attrs: opts.attrs,
        }),
      ]);
      return result;
    } catch (err) {
      const durationMs = Math.max(0, Date.now() - start);
      await captureException(err, {
        source: service,
        traceId,
        attrs: { ...(opts.attrs ?? {}), fn_name: name, duration_ms: durationMs },
      }).catch(() => {});
      throw err;
    }
  }

  /**
   * Create or update a threshold alert rule.
   *
   * @param {{
   *   key: string,
   *   name?: string,
   *   active?: boolean,
   *   kind: "error_count" | "log_count" | "metric",
   *   target?: string,
   *   aggregation?: "count" | "sum" | "avg" | "min" | "max" | "p50" | "p95" | "p99",
   *   op?: "gt" | "gte" | "lt" | "lte" | "eq",
   *   threshold: number,
   *   window_ms?: number,
   *   cooldown_ms?: number,
   *   webhook_url?: string,
   * }} rule
   */
  async function upsertAlertRule(rule) {
    return await client.mutate(monitorApi.upsertAlertRule, {
      key: rule.key,
      name: rule.name ?? rule.key,
      active: rule.active ?? true,
      kind: rule.kind,
      target: rule.target ?? "",
      aggregation: rule.aggregation ?? (rule.kind === "metric" ? "p95" : "count"),
      op: rule.op ?? "gte",
      threshold: rule.threshold,
      window_ms: rule.window_ms ?? 300000,
      cooldown_ms: rule.cooldown_ms ?? 60000,
      webhook_url: rule.webhook_url ?? "",
    });
  }

  /** @param {string} key */
  async function deleteAlertRule(key) {
    return await client.mutate(monitorApi.deleteAlertRule, { key });
  }

  /** @param {string} incidentId */
  async function acknowledgeIncident(incidentId) {
    return await client.mutate(monitorApi.acknowledgeIncident, { incident_id: incidentId });
  }

  /** Evaluate all alert rules (mutation) without sending HTTP webhooks. */
  async function evaluateAlerts() {
    return await client.mutate(monitorApi.evaluateAlerts, {});
  }

  /** Evaluate all alert rules and deliver HTTP webhooks (action). */
  async function evaluateAndNotify() {
    return await client.action(monitorApi.evaluateAndNotify, {});
  }

  /** @param {{ retention_ms?: number, max_delete?: number }} [opts] */
  async function prune(opts = {}) {
    return await client.mutate(monitorApi.prune, {
      retention_ms: opts.retention_ms ?? 0,
      max_delete: opts.max_delete ?? 200,
    });
  }

  // -------------------------------------------------------------------------
  // Reactive Subscriptions (Live WebSocket Updates)
  // -------------------------------------------------------------------------

  /** @param {{ window_ms?: number, top_n?: number } | (() => { window_ms?: number, top_n?: number } | null)} [opts] */
  function subscribeOverview(opts = {}) {
    if (typeof opts === "function") {
      return client.query(monitorApi.overview, () => {
        const v = opts();
        if (!v) return null;
        return { window_ms: v.window_ms ?? 3600000, top_n: v.top_n ?? 5 };
      });
    }
    return client.query(monitorApi.overview, {
      window_ms: opts.window_ms ?? 3600000,
      top_n: opts.top_n ?? 5,
    });
  }

  /** @param {{ status?: string, source?: string, limit?: number } | (() => { status?: string, source?: string, limit?: number } | null)} [opts] */
  function subscribeIssues(opts = {}) {
    if (typeof opts === "function") {
      return client.query(monitorApi.listIssues, () => {
        const v = opts();
        if (!v) return null;
        return { status: v.status ?? "", source: v.source ?? "", limit: v.limit ?? 50 };
      });
    }
    return client.query(monitorApi.listIssues, {
      status: opts.status ?? "",
      source: opts.source ?? "",
      limit: opts.limit ?? 50,
    });
  }

  /** @param {{ service?: string, level?: string, fn_name?: string, limit?: number } | (() => { service?: string, level?: string, fn_name?: string, limit?: number } | null)} [opts] */
  function subscribeLogs(opts = {}) {
    if (typeof opts === "function") {
      return client.query(monitorApi.recentLogs, () => {
        const v = opts();
        if (!v) return null;
        return {
          service: v.service ?? "",
          level: v.level ?? "",
          fn_name: v.fn_name ?? "",
          limit: v.limit ?? 50,
        };
      });
    }
    return client.query(monitorApi.recentLogs, {
      service: opts.service ?? "",
      level: opts.level ?? "",
      fn_name: opts.fn_name ?? "",
      limit: opts.limit ?? 50,
    });
  }

  /** @param {string | (() => string | null)} queryText @param {number} [limit] */
  function subscribeSearchLogs(queryText, limit = 50) {
    if (typeof queryText === "function") {
      return client.query(monitorApi.searchLogs, () => {
        const q = queryText();
        if (!q) return null;
        return { query: q, limit };
      });
    }
    return client.query(monitorApi.searchLogs, { query: queryText, limit });
  }

  /** @param {string | (() => string | null)} traceId @param {number} [limit] */
  function subscribeTrace(traceId, limit = 100) {
    if (typeof traceId === "function") {
      return client.query(monitorApi.traceLogs, () => {
        const tid = traceId();
        if (!tid) return null;
        return { trace_id: tid, limit };
      });
    }
    return client.query(monitorApi.traceLogs, { trace_id: traceId, limit });
  }

  /**
   * @param {string} name
   * @param {{ service?: string, from_ms?: number, to_ms?: number, bucket_ms?: number }} [opts]
   */
  function subscribeMetric(name, opts = {}) {
    return client.query(monitorApi.metricSeries, {
      name,
      service: opts.service ?? "",
      from_ms: opts.from_ms ?? 0,
      to_ms: opts.to_ms ?? 0,
      bucket_ms: opts.bucket_ms ?? 60000,
    });
  }

  function subscribeAlerts() {
    return client.query(monitorApi.listAlertRules, {});
  }

  /** @param {{ status?: string, rule_key?: string, limit?: number }} [opts] */
  function subscribeIncidents(opts = {}) {
    return client.query(monitorApi.listIncidents, {
      status: opts.status ?? "",
      rule_key: opts.rule_key ?? "",
      limit: opts.limit ?? 50,
    });
  }

  // Optional automatic browser global error + unhandledrejection hooks.
  if (options.captureGlobalErrors && typeof window !== "undefined" && typeof window.addEventListener === "function") {
    /** @param {ErrorEvent} ev */
    const onError = (ev) => {
      const err = ev.error ?? new Error(ev.message || "Uncaught window error");
      captureException(err, {
        source: defaultService,
        attrs: {
          filename: sanitizeUrl(ev.filename ?? "", captureQueryParams),
          lineno: ev.lineno ?? 0,
          colno: ev.colno ?? 0,
        },
      }).catch(() => {});
    };
    /** @param {PromiseRejectionEvent} ev */
    const onRejection = (ev) => {
      const err = ev.reason instanceof Error ? ev.reason : new Error(String(ev.reason ?? "Unhandled rejection"));
      captureException(err, {
        source: defaultService,
        errorType: "UnhandledRejection",
      }).catch(() => {});
    };
    window.addEventListener("error", onError);
    window.addEventListener("unhandledrejection", onRejection);
    globalCleanups.push(() => {
      window.removeEventListener("error", onError);
      window.removeEventListener("unhandledrejection", onRejection);
    });
  }

  function dispose() {
    while (globalCleanups.length > 0) {
      const fn = globalCleanups.pop();
      fn?.();
    }
  }

  return {
    addBreadcrumb,
    captureException,
    updateIssueStatus,
    log,
    metric,
    time,
    upsertAlertRule,
    deleteAlertRule,
    acknowledgeIncident,
    evaluateAlerts,
    evaluateAndNotify,
    prune,
    subscribeOverview,
    subscribeIssues,
    subscribeLogs,
    subscribeSearchLogs,
    subscribeTrace,
    subscribeMetric,
    subscribeAlerts,
    subscribeIncidents,
    dispose,
    toAttrs,
    fromAttrs,
  };
}
