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

/**
 * Convert `Array<{ key: string, value: string }>` back into a plain JS object.
 *
 * @param {Array<{ key: string, value: string }> | null | undefined} props
 * @returns {Record<string, string>}
 */
export function fromProps(props) {
  /** @type {Record<string, string>} */
  const out = {};
  if (!props) return out;
  for (const p of props) {
    out[p.key] = p.value;
  }
  return out;
}

/** @param {string} prefix */
function randomId(prefix) {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return `${prefix}_${crypto.randomUUID()}`;
  }
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;
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
 * }} [options]
 */
export function createAnalytics(client, analyticsApi, options = {}) {
  const prefix = options.storageKeyPrefix ?? "concave_analytics";
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
      autoProps.$current_url = window.location.href;
      autoProps.$pathname = window.location.pathname;
      autoProps.$host = window.location.host;
    }
    if (typeof document !== "undefined" && document.referrer) {
      autoProps.$referrer = document.referrer;
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
    return await client.mutate(analyticsApi.identify, {
      distinct_id: newDistinctId,
      anon_id: previousAnon === newDistinctId ? "" : previousAnon,
      set: toProps(opts.set),
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

  /** Subscribe reactively to all feature flags for the current or specified user. */
  function subscribeFlags(overrideProperties = {}, targetDistinctId) {
    return client.query(analyticsApi.evaluateAllFlags, {
      distinct_id: targetDistinctId ?? distinctId,
      override_properties: toProps(overrideProperties),
    });
  }

  /** Subscribe reactively to a single feature flag. */
  function subscribeFlag(key, overrideProperties = {}, targetDistinctId) {
    return client.query(analyticsApi.evaluateFlag, {
      key,
      distinct_id: targetDistinctId ?? distinctId,
      override_properties: toProps(overrideProperties),
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
    evaluateFlagAndTrack,
    toProps,
    fromProps,
  };
}
