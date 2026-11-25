// Zero-dependency browser & Node ESM helper for Concave's Auth v2 component.
// Works with any `ConcaveClient` instance and the generated `api.<namespace>` reference tree.

const DEFAULT_STORAGE_KEY = "concave_auth_refresh_token";
const ACCESS_TOKEN_FRESH_MARGIN_MS = 10_000;

/**
 * Derive an HTTP(S) base URL from a `ConcaveClient` WebSocket URL or `window.location.origin`.
 *
 * @param {any} client
 * @param {string | undefined} explicitBaseUrl
 * @returns {string}
 */
function resolveBaseUrl(client, explicitBaseUrl) {
  if (explicitBaseUrl) {
    return explicitBaseUrl.replace(/\/+$/, "");
  }
  if (client && typeof client._wsUrl === "string" && client._wsUrl.length > 0) {
    try {
      const u = new URL(client._wsUrl);
      const proto = u.protocol === "wss:" ? "https:" : "http:";
      return `${proto}//${u.host}`;
    } catch {
      // fall through
    }
  }
  if (typeof window !== "undefined" && window.location?.origin) {
    return window.location.origin;
  }
  return "";
}

/**
 * Return a safe default user-agent string in browsers (empty in headless/Node unless passed explicitly).
 * @returns {string}
 */
function defaultUserAgent() {
  if (typeof navigator !== "undefined" && typeof navigator.userAgent === "string") {
    return navigator.userAgent.slice(0, 200);
  }
  return "";
}

/**
 * Parse a JWT `exp` claim into Unix epoch milliseconds without external dependencies.
 * @param {string | null} token
 * @returns {number | null}
 */
function parseJwtExpMs(token) {
  if (typeof token !== "string") return null;
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
    let jsonStr;
    if (typeof atob === "function") {
      jsonStr = atob(padded);
    } else if (typeof Buffer !== "undefined") {
      jsonStr = Buffer.from(padded, "base64").toString("utf8");
    } else {
      return null;
    }
    const payload = JSON.parse(jsonStr);
    return payload && typeof payload.exp === "number" && Number.isFinite(payload.exp)
      ? payload.exp * 1000
      : null;
  } catch {
    return null;
  }
}

/**
 * Create an Auth v2 controller bound to a `ConcaveClient` and a mounted `Auth` component
 * namespace (e.g. `api.auth` from `_generated/api.js`).
 *
 * Automatically:
 * - Stores refresh tokens in memory or optional custom `storage` (e.g. `localStorage`).
 * - Plugs an automatic token-refreshing `fetchToken` into `client.setTokenFetcher(...)`.
 * - Subscribes to `authApi.sessionStatus` while authenticated so revoking a session
 *   (via `signOut`, `signOutAll`, or refresh replay detection) immediately clears local
 *   tokens and drops authentication across all connected tabs.
 *
 * @param {import("../../client/concave-client/src/client.js").ConcaveClient} client
 * @param {any} authApi - e.g. `api.auth` from `_generated/api.js`
 * @param {{
 *   storage?: { getItem(key: string): string | null, setItem(key: string, val: string): void, removeItem(key: string): void } | null,
 *   storageKey?: string,
 *   baseUrl?: string,
 *   oauthRoutePrefix?: string,
 *   userAgent?: string,
 *   onSignedOut?: (info: { reason: string }) => void,
 * }} [options]
 */
export function createAuth(client, authApi, options = {}) {
  const storage = options.storage ?? null;
  const storageKey = options.storageKey ?? DEFAULT_STORAGE_KEY;
  const oauthPrefix = (options.oauthRoutePrefix ?? "/auth/oauth").replace(/\/+$/, "");
  const baseUrl = resolveBaseUrl(client, options.baseUrl);
  const configuredUserAgent = options.userAgent ?? "";
  const onSignedOut = typeof options.onSignedOut === "function" ? options.onSignedOut : null;

  /** @type {string | null} */
  let accessToken = null;
  /** @type {number | null} */
  let accessExpiresAtMs = null;
  /** @type {string | null} */
  let refreshToken = readStoredRefreshToken();
  /** @type {string | null} */
  let currentSessionId = null;
  /** @type {string | null} */
  let currentUserId = null;
  /** @type {Promise<any> | null} */
  let inFlightRefresh = null;
  let disposed = false;

  function readStoredRefreshToken() {
    if (!storage) return null;
    try {
      const val = storage.getItem(storageKey);
      return typeof val === "string" && val.length > 0 ? val : null;
    } catch {
      return null;
    }
  }

  /** @param {string | null} token */
  function writeStoredRefreshToken(token) {
    refreshToken = token && token.length > 0 ? token : null;
    if (!storage) return;
    try {
      if (refreshToken) {
        storage.setItem(storageKey, refreshToken);
      } else {
        storage.removeItem(storageKey);
      }
    } catch {
      // ignore storage quota/privacy errors
    }
  }

  /** @param {string} reason @param {boolean} notifyClient */
  function clearLocalAuth(reason, notifyClient = true) {
    accessToken = null;
    accessExpiresAtMs = null;
    currentSessionId = null;
    currentUserId = null;
    writeStoredRefreshToken(null);
    if (notifyClient) {
      client.setAuth(null);
    }
    if (onSignedOut) {
      try {
        onSignedOut({ reason });
      } catch {
        // ignore user callback errors
      }
    }
  }

  /**
   * Apply a token bundle returned by `signUpPassword`, `signInPassword`, `verifyOtp`, `refresh`, or OAuth callback.
   *
   * @param {{
   *   access_token: string,
   *   refresh_token?: string,
   *   session_id?: string,
   *   user_id?: string,
   *   expires_at_ms?: number,
   * }} bundle
   * @param {boolean} [pushToClient]
   */
  function applyTokenBundle(bundle, pushToClient = true) {
    if (!bundle || typeof bundle.access_token !== "string" || !bundle.access_token) {
      throw new Error("Invalid auth token bundle: missing access_token");
    }
    accessToken = bundle.access_token;
    accessExpiresAtMs =
      typeof bundle.expires_at_ms === "number" && bundle.expires_at_ms > 0
        ? bundle.expires_at_ms
        : parseJwtExpMs(bundle.access_token);
    if (typeof bundle.refresh_token === "string" && bundle.refresh_token.length > 0) {
      writeStoredRefreshToken(bundle.refresh_token);
    }
    if (typeof bundle.session_id === "string" && bundle.session_id.length > 0) {
      currentSessionId = bundle.session_id;
    }
    if (typeof bundle.user_id === "string" && bundle.user_id.length > 0) {
      currentUserId = bundle.user_id;
    }
    if (pushToClient) {
      client.setAuth(accessToken);
    }
    return bundle;
  }

  /**
   * Rotate the current refresh token via `auth.refresh` (deduplicated across concurrent callers).
   * @param {{ pushToClient?: boolean }} [opts]
   */
  async function refresh(opts = {}) {
    const pushToClient = opts.pushToClient !== false;
    if (inFlightRefresh) {
      return await inFlightRefresh;
    }
    if (!refreshToken) {
      throw new Error("No refresh token available");
    }
    const tokenToExchange = refreshToken;
    const run = (async () => {
      try {
        const res = await client.action(authApi.refresh, { refresh_token: tokenToExchange });
        applyTokenBundle(res, pushToClient);
        return res;
      } catch (err) {
        clearLocalAuth("refresh_failed", true);
        throw err;
      } finally {
        if (inFlightRefresh === run) {
          inFlightRefresh = null;
        }
      }
    })();
    inFlightRefresh = run;
    return await run;
  }

  // Wire automatic token fetching & proactive refresh into `ConcaveClient`.
  client.setTokenFetcher(async ({ forceRefresh } = {}) => {
    if (disposed) return null;
    if (
      !forceRefresh &&
      accessToken &&
      (accessExpiresAtMs === null || accessExpiresAtMs - Date.now() > ACCESS_TOKEN_FRESH_MARGIN_MS)
    ) {
      return accessToken;
    }
    if (!refreshToken) {
      return null;
    }
    try {
      const res = await refresh({ pushToClient: false });
      return res.access_token ?? null;
    } catch {
      return null;
    }
  });

  // Live reactive subscription to `auth.sessionStatus`: active whenever the WS client is authenticated.
  const sessionStatusSub = client.query(authApi.sessionStatus, () =>
    client.isAuthenticated() ? {} : null,
  );

  // Zero-import reactive watcher leveraging `client.query`'s internal signal effect.
  // Always returns `null` so it never sends any network frames, yet fires synchronously
  // whenever `sessionStatusSub()` receives a live transition from the server!
  const sessionStatusWatcher = client.query({ name: "__concave_auth_session_watcher" }, () => {
    const st = sessionStatusSub();
    if (
      !disposed &&
      st.status === "ready" &&
      st.data &&
      st.data.active === false &&
      client.isAuthenticated.peek()
    ) {
      const subSid = typeof st.data.session_id === "string" ? st.data.session_id : "";
      if (!subSid || !currentSessionId || subSid === currentSessionId) {
        clearLocalAuth("session_revoked", true);
      }
    }
    return null;
  });

  /**
   * Sign up with email + password (Argon2id hashed server-side) and sign in immediately.
   * @param {{ email: string, password: string, name?: string, userAgent?: string }} args
   */
  async function signUpPassword(args) {
    const res = await client.action(authApi.signUpPassword, {
      email: args.email,
      password: args.password,
      name: args.name ?? "",
      user_agent: args.userAgent ?? configuredUserAgent ?? defaultUserAgent(),
    });
    return applyTokenBundle(res, true);
  }

  /**
   * Sign in with email + password and authenticate the `ConcaveClient`.
   * @param {{ email: string, password: string, userAgent?: string }} args
   */
  async function signInPassword(args) {
    const res = await client.action(authApi.signInPassword, {
      email: args.email,
      password: args.password,
      user_agent: args.userAgent ?? configuredUserAgent ?? defaultUserAgent(),
    });
    return applyTokenBundle(res, true);
  }

  /**
   * Request a 6-digit OTP verification code for `email`.
   * @param {string | { email: string }} emailOrArgs
   */
  async function requestOtp(emailOrArgs) {
    const email = typeof emailOrArgs === "string" ? emailOrArgs : emailOrArgs.email;
    return await client.action(authApi.requestOtp, { email });
  }

  /**
   * Verify an OTP code and sign in immediately.
   * @param {{ email: string, code: string, name?: string, userAgent?: string }} args
   */
  async function verifyOtp(args) {
    const res = await client.action(authApi.verifyOtp, {
      email: args.email,
      code: args.code,
      name: args.name ?? "",
      user_agent: args.userAgent ?? configuredUserAgent ?? defaultUserAgent(),
    });
    return applyTokenBundle(res, true);
  }

  /**
   * Request a single-use email magic link for `email`.
   * @param {string | { email: string, redirectTo?: string }} emailOrArgs
   */
  async function requestMagicLink(emailOrArgs) {
    const email = typeof emailOrArgs === "string" ? emailOrArgs : emailOrArgs.email;
    const redirectTo = typeof emailOrArgs === "string" ? "" : (emailOrArgs.redirectTo ?? "");
    return await client.action(authApi.requestMagicLink, {
      email,
      redirect_to: redirectTo,
    });
  }

  /**
   * Verify a magic link token directly via Action and sign in immediately.
   * @param {string | { token: string, name?: string, userAgent?: string }} tokenOrArgs
   */
  async function verifyMagicLink(tokenOrArgs) {
    const token = typeof tokenOrArgs === "string" ? tokenOrArgs : tokenOrArgs.token;
    const name = typeof tokenOrArgs === "string" ? "" : (tokenOrArgs.name ?? "");
    const userAgent =
      typeof tokenOrArgs === "string"
        ? configuredUserAgent || defaultUserAgent()
        : (tokenOrArgs.userAgent ?? configuredUserAgent ?? defaultUserAgent());
    const res = await client.action(authApi.verifyMagicLink, {
      token,
      name,
      user_agent: userAgent,
    });
    return applyTokenBundle(res, true);
  }

  /**
   * Exchange a short-lived single-use `oauth_code` (from OAuth or magic-link redirect)
   * for a fresh session, Ed25519 JWT, and rotating refresh token.
   * @param {string} code
   * @param {{ userAgent?: string }} [opts]
   */
  async function exchangeOAuthCode(code, opts = {}) {
    const res = await client.action(authApi.exchangeOAuthCode, {
      code,
      user_agent: opts.userAgent ?? configuredUserAgent ?? defaultUserAgent(),
    });
    return applyTokenBundle(res, true);
  }

  /**
   * Begin TOTP MFA enrollment for the currently authenticated user.
   * Returns `{ secret_base32, otpauth_uri }`.
   */
  async function enrollTotp() {
    return await client.action(authApi.enrollTotp, {});
  }

  /**
   * Confirm pending TOTP MFA enrollment with a valid 6-digit RFC 6238 code.
   * @param {string | { code: string }} codeOrArgs
   */
  async function confirmTotp(codeOrArgs) {
    const code = typeof codeOrArgs === "string" ? codeOrArgs : codeOrArgs.code;
    return await client.action(authApi.confirmTotp, { code });
  }

  /**
   * Verify a 6-digit TOTP code for the signed-in user (with replay prevention).
   * @param {string | { code: string }} codeOrArgs
   */
  async function verifyTotp(codeOrArgs) {
    const code = typeof codeOrArgs === "string" ? codeOrArgs : codeOrArgs.code;
    return await client.action(authApi.verifyTotp, { code });
  }

  /**
   * Disable TOTP MFA for the signed-in user after verifying a current 6-digit TOTP code.
   * @param {string | { code: string }} codeOrArgs
   */
  async function disableTotp(codeOrArgs) {
    const code = typeof codeOrArgs === "string" ? codeOrArgs : codeOrArgs.code;
    return await client.action(authApi.disableTotp, { code });
  }

  /**
   * Sign out the current session on the server and clear local tokens.
   */
  async function signOut() {
    try {
      if (client.isAuthenticated.peek() || accessToken) {
        await client.mutate(authApi.signOut, {});
      }
    } catch {
      // still clear local auth even if session was already revoked or offline
    } finally {
      clearLocalAuth("sign_out", true);
    }
  }

  /**
   * Revoke ALL sessions for the signed-in user across all devices & browser tabs.
   * @returns {Promise<number>} Number of revoked sessions
   */
  async function signOutAll() {
    let revoked = 0;
    try {
      if (client.isAuthenticated.peek() || accessToken) {
        revoked = await client.mutate(authApi.signOutAll, {});
      }
    } finally {
      clearLocalAuth("sign_out_all", true);
    }
    return revoked;
  }

  /**
   * Fetch all active sessions for the signed-in user (secrets redacted).
   */
  async function listSessions() {
    return await client.queryOnce(authApi.listSessions, {});
  }

  /**
   * Subscribe reactively to the signed-in user's active sessions.
   */
  function subscribeSessions() {
    return client.query(authApi.listSessions, () => (client.isAuthenticated() ? {} : null));
  }

  /**
   * Build the OAuth2 + PKCE start URL for a configured provider (e.g. `"google"`, `"github"`, `"discord"`).
   * @param {string} provider
   * @param {{ redirectTo?: string }} [opts]
   */
  function oauthUrl(provider, opts = {}) {
    const encodedProvider = encodeURIComponent(provider);
    const path = `${oauthPrefix}/${encodedProvider}/start`;
    const query = opts.redirectTo ? `?redirect_to=${encodeURIComponent(opts.redirectTo)}` : "";
    return `${baseUrl}${path}${query}`;
  }

  /**
   * Detect a single-use `?oauth_code=...` callback query parameter (from OAuth2 or Magic Link
   * redirects), immediately strip `oauth_code` from the browser URL via `history.replaceState`,
   * and exchange it via `auth.exchangeOAuthCode` for a fresh session.
   *
   * @param {string} [searchInput]
   * @param {{ userAgent?: string }} [opts]
   */
  async function consumeOAuthCallback(searchInput, opts = {}) {
    const raw =
      typeof searchInput === "string"
        ? searchInput
        : typeof window !== "undefined" && typeof window.location?.search === "string"
          ? window.location.search
          : "";
    if (!raw) return null;
    const params = new URLSearchParams(raw.startsWith("?") ? raw.slice(1) : raw);
    const code = params.get("oauth_code");
    if (!code) return null;

    if (
      searchInput === undefined &&
      typeof window !== "undefined" &&
      window.history?.replaceState &&
      window.location
    ) {
      params.delete("oauth_code");
      const remaining = params.toString();
      const nextUrl = `${window.location.pathname}${remaining ? `?${remaining}` : ""}${window.location.hash ?? ""}`;
      window.history.replaceState(null, "", nextUrl);
    }

    return await exchangeOAuthCode(code, opts);
  }

  /**
   * Legacy helper: parse tokens from a URL fragment (`#access_token=...`).
   * Prefer `consumeOAuthCallback()` with single-use `?oauth_code=...` handoff.
   *
   * @param {string} [hashInput]
   */
  function consumeOAuthFragment(hashInput) {
    const raw =
      typeof hashInput === "string"
        ? hashInput
        : typeof window !== "undefined" && window.location?.hash
          ? window.location.hash
          : "";
    const trimmed = raw.startsWith("#") ? raw.slice(1) : raw;
    if (!trimmed) return null;
    const params = new URLSearchParams(trimmed);
    const at = params.get("access_token");
    if (!at) return null;
    const bundle = {
      access_token: at,
      refresh_token: params.get("refresh_token") ?? "",
      session_id: params.get("session_id") ?? "",
      user_id: params.get("user_id") ?? "",
    };
    applyTokenBundle(bundle, true);
    if (
      hashInput === undefined &&
      typeof window !== "undefined" &&
      window.history?.replaceState &&
      window.location
    ) {
      window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`);
    }
    return bundle;
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    sessionStatusWatcher.dispose();
    sessionStatusSub.dispose();
    client.setTokenFetcher(null);
  }

  return {
    signUpPassword,
    signInPassword,
    requestOtp,
    verifyOtp,
    requestMagicLink,
    verifyMagicLink,
    exchangeOAuthCode,
    enrollTotp,
    confirmTotp,
    verifyTotp,
    disableTotp,
    refresh,
    signOut,
    signOutAll,
    listSessions,
    subscribeSessions,
    sessionStatus: sessionStatusSub,
    oauthUrl,
    consumeOAuthCallback,
    consumeOAuthFragment,
    setTokens: (bundle) => applyTokenBundle(bundle, true),
    getRefreshToken: () => refreshToken,
    getSessionId: () => currentSessionId,
    getUserId: () => currentUserId,
    dispose,
  };
}
