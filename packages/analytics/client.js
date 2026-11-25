// Zero-dependency PostHog-style browser & Node ESM helper for Concave's Analytics component.
// Works with any `ConcaveClient` instance and the generated `api.<namespace>` reference tree.

/**
 * Convert a plain JS object (or already-formatted `Array<{ key, value }>`) into
 * Concave Analytics' typed `Array<{ key: string, value: string }>` wire format.
 *
 * @param {Record<string, unknown> | Array<{ key: string, value: string }> | null | undefined} input
 * @returns {Array<{ key: string, value: string }>}
 */
export function toProps(input) {
  if (!input) return [];
  if (Array.isArray(input)) {
    return input
      .filter((p) => p && typeof p.key === "string" && p.key.length > 0)
      .map((p) => ({ key: p.key, value: String(p.value ?? "") }));
  }
  /** @type {Array<{ key: string, value: string }>} */
  const out = [];
  for (const [key, val] of Object.entries(input)) {
    if (val === undefined || val === null) continue;
    out.push({ key, value: typeof val === "string" ? val : String(val) });
  }
  return out;
}

const FORBIDDEN_PROP_KEYS = new Set(["__proto__", "constructor", "prototype"]);

/**
 * Convert `Array<{ key: string, value: string }>` back into a null-prototype JS object.
 *
 * @param {Array<{ key: string, value: string }> | null | undefined} props
 * @returns {Record<string, string>}
 */
export function fromProps(props) {
  /** @type {Record<string, string>} */
  const out = Object.create(null);
  if (!props) return out;
  for (const p of props) {
    if (!p || typeof p.key !== "string" || FORBIDDEN_PROP_KEYS.has(p.key)) continue;
    out[p.key] = p.value;
  }
  return out;
}

/** @param {string} prefix */
function randomId(prefix) {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return `${prefix}_${crypto.randomUUID()}`;
  }
  if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") {
    const bytes = new Uint8Array(16);
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
 * Create a PostHog-style analytics client bound to a `ConcaveClient` and
 * a mounted `Analytics` component namespace (e.g. `api.analytics`).
 *
 * @param {import("../../client/concave-client/src/client.js").ConcaveClient} client
 * @param {any} analyticsApi - e.g. `api.analytics` from `_generated/api.js`
 * @param {{
 *   distinctId?: string,
 *   sessionId?: string,
 *   storageKeyPrefix?: string,
 *   storage?: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null,
 *   defaultGroup?: { type: string, key: string } | null,
 *   captureQueryParams?: boolean,
 * }} [options]
 */
export function createAnalytics(client, analyticsApi, options = {}) {
  const prefix = options.storageKeyPrefix ?? "concave_analytics";
  const captureQueryParams = options.captureQueryParams === true;
  const storage =
    options.storage !== undefined
      ? options.storage
      : typeof localStorage !== "undefined"
        ? localStorage
        : null;

  const DISTINCT_KEY = `${prefix}:distinct_id`;
  const ANON_KEY = `${prefix}:anon_id`;
  const SESSION_KEY = `${prefix}:session_id`;

  let anonId = storage?.getItem(ANON_KEY) || randomId("anon");
  let distinctId = options.distinctId || storage?.getItem(DISTINCT_KEY) || anonId;
  let sessionId = options.sessionId || storage?.getItem(SESSION_KEY) || randomId("sess");
  /** @type {{ type: string, key: string } | null} */
  let activeGroup = options.defaultGroup ?? null;

  storage?.setItem(ANON_KEY, anonId);
  storage?.setItem(DISTINCT_KEY, distinctId);
  storage?.setItem(SESSION_KEY, sessionId);

  /** @param {string} event @param {Record<string, unknown> | Array<{ key: string, value: string }>} [properties] @param {{ distinctId?: string, sessionId?: string, groupType?: string, groupKey?: string, timestampMs?: number }} [meta] */
  async function capture(event, properties = {}, meta = {}) {
    return await client.mutate(analyticsApi.capture, {
      distinct_id: meta.distinctId ?? distinctId,
      event,
      properties: toProps(properties),
      session_id: meta.sessionId ?? sessionId,
      group_type: meta.groupType ?? activeGroup?.type ?? "",
      group_key: meta.groupKey ?? activeGroup?.key ?? "",
      timestamp_ms: meta.timestampMs ?? 0,
    });
  }

  /** @param {Array<{ event: string, properties?: Record<string, unknown> | Array<{ key: string, value: string }>, distinctId?: string, sessionId?: string, groupType?: string, groupKey?: string, timestampMs?: number }>} events */
  async function captureBatch(events) {
    return await client.mutate(analyticsApi.captureBatch, {
      events: events.map((e) => ({
        distinct_id: e.distinctId ?? distinctId,
        event: e.event,
        properties: toProps(e.properties),
        session_id: e.sessionId ?? sessionId,
        group_type: e.groupType ?? activeGroup?.type ?? "",
        group_key: e.groupKey ?? activeGroup?.key ?? "",
        timestamp_ms: e.timestampMs ?? 0,
      })),
    });
  }

  /** @param {Record<string, unknown>} [extraProps] */
  async function capturePageview(extraProps = {}) {
    /** @type {Record<string, unknown>} */
    const autoProps = {};
    if (typeof window !== "undefined" && window.location) {
      autoProps.$current_url = sanitizeUrl(window.location.href, captureQueryParams);
      autoProps.$pathname = window.location.pathname;
      autoProps.$host = window.location.host;
    }
    if (typeof document !== "undefined" && document.referrer) {
      autoProps.$referrer = sanitizeUrl(document.referrer, captureQueryParams);
    }
    return await capture("$pageview", { ...autoProps, ...extraProps });
  }

  /**
   * Identify the current user, automatically aliasing their anonymous ID
   * and applying PostHog `$set` / `$set_once` person properties.
   *
   * @param {string} newDistinctId
   * @param {{ set?: Record<string, unknown>, setOnce?: Record<string, unknown>, anonId?: string }} [opts]
   */
  async function identify(newDistinctId, opts = {}) {
    const previousAnon = opts.anonId ?? (distinctId !== newDistinctId ? distinctId : anonId);
    distinctId = newDistinctId;
    storage?.setItem(DISTINCT_KEY, distinctId);
    // Support both `{ set: { ... }, setOnce: { ... } }` and shorthand flat `{ name: "Alice" }` objects.
    let setInput = opts.set;
    if (!setInput && opts && typeof opts === "object") {
      /** @type {Record<string, unknown>} */
      const flat = {};
      let hasFlat = false;
      for (const [k, v] of Object.entries(opts)) {
        if (k === "set" || k === "setOnce" || k === "anonId") continue;
        flat[k] = v;
        hasFlat = true;
      }
      if (hasFlat) setInput = flat;
    }
    return await client.mutate(analyticsApi.identify, {
      distinct_id: newDistinctId,
      anon_id: previousAnon === newDistinctId ? "" : previousAnon,
      set: toProps(setInput),
      set_once: toProps(opts.setOnce),
    });
  }

  /** @param {string} aliasId @param {string} [targetDistinctId] */
  async function alias(aliasId, targetDistinctId = distinctId) {
    return await client.mutate(analyticsApi.alias, {
      alias_id: aliasId,
      distinct_id: targetDistinctId,
    });
  }

  /** @param {string} type @param {string} key */
  function group(type, key) {
    activeGroup = type && key ? { type, key } : null;
  }

  /** Reset anonymous & session IDs (e.g. on user sign-out). */
  function reset() {
    anonId = randomId("anon");
    distinctId = anonId;
    sessionId = randomId("sess");
    activeGroup = null;
    storage?.setItem(ANON_KEY, anonId);
    storage?.setItem(DISTINCT_KEY, distinctId);
    storage?.setItem(SESSION_KEY, sessionId);
  }

  /**
   * Subscribe reactively to all feature flags.
   * Pass a reactive accessor for `targetDistinctId` (e.g. `() => client.identity()?.subject ?? analytics.distinctId`)
   * to automatically re-evaluate whenever the user switches identity.
   *
   * @param {Record<string, unknown> | Array<{ key: string, value: string }> | (() => Record<string, unknown> | Array<{ key: string, value: string }>)} [overrideProperties]
   * @param {string | (() => string | null | undefined)} [targetDistinctId]
   */
  function subscribeFlags(overrideProperties = {}, targetDistinctId) {
    const reactive =
      typeof overrideProperties === "function" || typeof targetDistinctId === "function";
    if (!reactive) {
      return client.query(analyticsApi.evaluateAllFlags, {
        distinct_id: /** @type {string | undefined} */ (targetDistinctId) ?? distinctId,
        override_properties: toProps(
          /** @type {Record<string, unknown> | Array<{ key: string, value: string }>} */ (
            overrideProperties
          ),
        ),
      });
    }
    return client.query(analyticsApi.evaluateAllFlags, () => {
      const id =
        typeof targetDistinctId === "function"
          ? targetDistinctId()
          : (targetDistinctId ?? distinctId);
      if (!id) return null;
      const rawProps =
        typeof overrideProperties === "function" ? overrideProperties() : overrideProperties;
      return {
        distinct_id: id,
        override_properties: toProps(rawProps),
      };
    });
  }

  /**
   * Subscribe reactively to a single feature flag.
   *
   * @param {string} key
   * @param {Record<string, unknown> | Array<{ key: string, value: string }> | (() => Record<string, unknown> | Array<{ key: string, value: string }>)} [overrideProperties]
   * @param {string | (() => string | null | undefined)} [targetDistinctId]
   */
  function subscribeFlag(key, overrideProperties = {}, targetDistinctId) {
    const reactive =
      typeof overrideProperties === "function" || typeof targetDistinctId === "function";
    if (!reactive) {
      return client.query(analyticsApi.evaluateFlag, {
        key,
        distinct_id: /** @type {string | undefined} */ (targetDistinctId) ?? distinctId,
        override_properties: toProps(
          /** @type {Record<string, unknown> | Array<{ key: string, value: string }>} */ (
            overrideProperties
          ),
        ),
      });
    }
    return client.query(analyticsApi.evaluateFlag, () => {
      const id =
        typeof targetDistinctId === "function"
          ? targetDistinctId()
          : (targetDistinctId ?? distinctId);
      if (!id) return null;
      const rawProps =
        typeof overrideProperties === "function" ? overrideProperties() : overrideProperties;
      return {
        key,
        distinct_id: id,
        override_properties: toProps(rawProps),
      };
    });
  }

  /** Evaluate a feature flag AND atomically record `$feature_flag_called` exposure. */
  async function evaluateFlagAndTrack(key, overrideProperties = {}, targetDistinctId) {
    return await client.mutate(analyticsApi.evaluateFlagAndTrack, {
      key,
      distinct_id: targetDistinctId ?? distinctId,
      override_properties: toProps(overrideProperties),
      session_id: sessionId,
    });
  }

  /** Subscribe reactively to all configured feature flag definitions. */
  function subscribeListFlags() {
    return client.query(analyticsApi.listFlags, {});
  }

  /**
   * Create or update a feature flag / multivariate experiment.
   *
   * @param {{
   *   key: string,
   *   name?: string,
   *   active: boolean,
   *   rollout_pct?: number,
   *   filters?: Array<{ key: string, op: string, value: string }>,
   *   variants?: Array<{ key: string, weight: number }>,
   * }} flag
   */
  async function upsertFlag(flag) {
    return await client.mutate(analyticsApi.upsertFlag, {
      key: flag.key,
      name: flag.name ?? flag.key,
      active: flag.active,
      rollout_pct: flag.rollout_pct ?? 100,
      filters: flag.filters ?? [],
      variants: flag.variants ?? [],
    });
  }

  /** @param {string} key */
  async function deleteFlag(key) {
    return await client.mutate(analyticsApi.deleteFlag, { key });
  }

  /**
   * Subscribe reactively to live overview KPIs (`total_events`, `unique_persons`, `active_sessions`, `top_events`).
   *
   * @param {{ from_ms?: number, to_ms?: number, top_n?: number } | (() => { from_ms?: number, to_ms?: number, top_n?: number } | null)} [opts]
   */
  function subscribeSummary(opts = {}) {
    if (typeof opts === "function") {
      return client.query(analyticsApi.summary, () => {
        const v = opts();
        if (!v) return null;
        return { from_ms: v.from_ms ?? 0, to_ms: v.to_ms ?? 0, top_n: v.top_n ?? 8 };
      });
    }
    return client.query(analyticsApi.summary, {
      from_ms: opts.from_ms ?? 0,
      to_ms: opts.to_ms ?? 0,
      top_n: opts.top_n ?? 8,
    });
  }

  /**
   * Subscribe reactively to time-bucketed event trends.
   *
   * @param {string} event
   * @param {{ from_ms?: number, to_ms?: number, bucket_ms?: number, breakdown_property?: string, filters?: Array<{ key: string, op: string, value: string }> }} [opts]
   */
  function subscribeTrends(event, opts = {}) {
    return client.query(analyticsApi.trends, {
      event,
      from_ms: opts.from_ms ?? 0,
      to_ms: opts.to_ms ?? 0,
      bucket_ms: opts.bucket_ms ?? 60000,
      breakdown_property: opts.breakdown_property ?? "",
      filters: opts.filters ?? [],
    });
  }

  /**
   * Subscribe reactively to an ordered multi-step conversion funnel.
   *
   * @param {string[]} steps
   * @param {{ from_ms?: number, to_ms?: number, conversion_window_ms?: number, filters?: Array<{ key: string, op: string, value: string }> } | (() => { from_ms?: number, to_ms?: number, conversion_window_ms?: number, filters?: Array<{ key: string, op: string, value: string }> } | null)} [opts]
   */
  function subscribeFunnel(steps, opts = {}) {
    if (typeof opts === "function") {
      return client.query(analyticsApi.funnel, () => {
        const v = opts();
        if (!v) return null;
        return {
          steps,
          from_ms: v.from_ms ?? 0,
          to_ms: v.to_ms ?? 0,
          conversion_window_ms: v.conversion_window_ms ?? 3600000,
          filters: v.filters ?? [],
        };
      });
    }
    return client.query(analyticsApi.funnel, {
      steps,
      from_ms: opts.from_ms ?? 0,
      to_ms: opts.to_ms ?? 0,
      conversion_window_ms: opts.conversion_window_ms ?? 3600000,
      filters: opts.filters ?? [],
    });
  }

  /**
   * Subscribe reactively to the live event stream (optionally filtered to a single event name).
   *
   * @param {{ event?: string, limit?: number } | (() => { event?: string, limit?: number } | null)} [opts]
   */
  function subscribeRecentEvents(opts = {}) {
    if (typeof opts === "function") {
      return client.query(analyticsApi.recentEvents, () => {
        const v = opts();
        if (!v) return null;
        return { event: v.event ?? "", limit: v.limit ?? 25 };
      });
    }
    return client.query(analyticsApi.recentEvents, {
      event: opts.event ?? "",
      limit: opts.limit ?? 25,
    });
  }

  /**
   * Helper to read a flag's boolean status from a `subscribeFlags()` query state.
   *
   * @param {Array<{ key: string, enabled: boolean, variant: string }> | undefined} evals
   * @param {string} key
   * @param {boolean} [fallback]
   */
  function isEnabled(evals, key, fallback = false) {
    const list = Array.isArray(evals) ? evals : evals?.data;
    if (!Array.isArray(list)) return fallback;
    const match = list.find((f) => f.key === key);
    return match ? match.enabled : fallback;
  }

  /**
   * Helper to read a flag's variant string from a `subscribeFlags()` query state.
   *
   * @param {Array<{ key: string, enabled: boolean, variant: string }> | { data?: Array<{ key: string, enabled: boolean, variant: string }> } | undefined} evals
   * @param {string} key
   * @param {string} [fallback]
   */
  function getVariant(evals, key, fallback = "") {
    const list = Array.isArray(evals) ? evals : evals?.data;
    if (!Array.isArray(list)) return fallback;
    const match = list.find((f) => f.key === key);
    return match && match.enabled ? match.variant : fallback;
  }

  return {
    get distinctId() {
      return distinctId;
    },
    get anonId() {
      return anonId;
    },
    get sessionId() {
      return sessionId;
    },
    capture,
    captureBatch,
    capturePageview,
    identify,
    alias,
    group,
    reset,
    subscribeFlags,
    subscribeFlag,
    subscribeListFlags,
    subscribeSummary,
    subscribeTrends,
    subscribeFunnel,
    subscribeRecentEvents,
    evaluateFlagAndTrack,
    upsertFlag,
    deleteFlag,
    isEnabled,
    getVariant,
    toProps,
    fromProps,
  };
}
