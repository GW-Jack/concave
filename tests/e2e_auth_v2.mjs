import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

import { ConcaveClient } from "../client/concave-client/src/index.js";
import { createAuth } from "../packages/auth/client.js";

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

/**
 * Local mock OAuth2 + PKCE S256 server verifying `client_secret` and `code_verifier`.
 * @param {number} port
 * @param {string} expectedSecret
 */
function startMockOAuthServer(port, expectedSecret) {
  /** @type {Map<string, { codeChallenge: string, redirectUri: string }>} */
  const issuedCodes = new Map();
  /** @type {Map<string, { sub: string, email: string, email_verified: boolean, name: string }>} */
  const issuedAccessTokens = new Map();
  let tokenExchangeCount = 0;

  const server = http.createServer((req, res) => {
    const reqUrl = new URL(req.url ?? "/", `http://127.0.0.1:${port}`);

    if (req.method === "POST" && reqUrl.pathname === "/token") {
      let body = "";
      req.on("data", (chunk) => {
        body += chunk.toString();
      });
      req.on("end", () => {
        const params = new URLSearchParams(body);
        const grantType = params.get("grant_type");
        const code = params.get("code") ?? "";
        const clientId = params.get("client_id");
        const clientSecret = params.get("client_secret");
        const codeVerifier = params.get("code_verifier") ?? "";

        if (grantType !== "authorization_code" || clientId !== "mock-client-id" || clientSecret !== expectedSecret) {
          res.writeHead(401, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "invalid_client", error_description: "bad client credentials" }));
          return;
        }

        const entry = issuedCodes.get(code);
        if (!entry) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "invalid_grant", error_description: "unknown authorization code" }));
          return;
        }
        issuedCodes.delete(code);

        // Cryptographically verify PKCE S256: base64url(sha256(code_verifier)) === code_challenge
        const computedChallenge = crypto
          .createHash("sha256")
          .update(codeVerifier)
          .digest("base64url");
        if (computedChallenge !== entry.codeChallenge) {
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "invalid_grant", error_description: "PKCE verification failed" }));
          return;
        }

        tokenExchangeCount += 1;
        const accessToken = `mock_at_${crypto.randomBytes(12).toString("hex")}`;
        issuedAccessTokens.set(accessToken, {
          sub: "mock_sub_42",
          email: "oauth.user@example.com",
          email_verified: true,
          name: "OAuth Alice",
        });

        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            access_token: accessToken,
            token_type: "Bearer",
            expires_in: 3600,
            scope: "openid email profile",
          }),
        );
      });
      return;
    }

    if (req.method === "GET" && reqUrl.pathname === "/userinfo") {
      const authz = req.headers.authorization ?? "";
      const tok = authz.startsWith("Bearer ") ? authz.slice(7).trim() : "";
      const user = issuedAccessTokens.get(tok);
      if (!user) {
        res.writeHead(401, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "invalid_token" }));
        return;
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(user));
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not_found" }));
  });

  return new Promise((resolve, reject) => {
    server.listen(port, "127.0.0.1", () => {
      resolve({
        registerAuthorizeCode(codeChallenge, redirectUri) {
          const code = `mock_code_${crypto.randomBytes(8).toString("hex")}`;
          issuedCodes.set(code, { codeChallenge, redirectUri });
          return code;
        },
        getTokenExchangeCount: () => tokenExchangeCount,
        close: () => new Promise((r) => server.close(() => r())),
      });
    });
    server.on("error", reject);
  });
}

test("end-to-end Convex Auth v2 pure-Roc component: Ed25519 JWKS, rotation/replay, global sign-out, lockout, OTP, OAuth2 PKCE, secret isolation", async (t) => {
  const appDir = path.join(ROOT, "tests/fixtures/auth-app");
  const entryRoc = path.join(appDir, "main.roc");
  const genDir = path.join(appDir, "_generated");
  const binPath = path.join(appDir, ".concave/e2e-auth-server");
  const dbPath = path.join(appDir, ".concave/e2e-auth.wal");
  const secretsDir = path.join(appDir, ".concave/secrets");
  const cliPath = path.join(ROOT, "zig-out/bin/concave");

  fs.mkdirSync(path.dirname(binPath), { recursive: true });
  fs.rmSync(secretsDir, { recursive: true, force: true });
  fs.mkdirSync(secretsDir, { recursive: true });
  for (const suffix of ["", "-wal", "-shm", ".tmp"]) {
    fs.rmSync(`${dbPath}${suffix}`, { force: true });
  }

  // Provision local secrets directory (same SecretProvider contract as GCP Secret Manager).
  const jwtPrivateSeedHex = crypto.randomBytes(32).toString("hex");
  const mockOAuthSecret = "mock-oauth-client-secret-v2";
  fs.writeFileSync(path.join(secretsDir, "AUTH_JWT_PRIVATE_KEY"), jwtPrivateSeedHex, { mode: 0o600 });
  fs.writeFileSync(path.join(secretsDir, "MOCK_OAUTH_SECRET"), mockOAuthSecret, { mode: 0o600 });

  // 1. Verify `--introspect` + typed ESM/TS codegen for the Auth v2 component & app `users` table.
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

  const apiDts = fs.readFileSync(path.join(genDir, "api.d.ts"), "utf8");
  assert.ok(apiDts.includes("readonly signUpPassword:"));
  assert.ok(apiDts.includes("readonly signInPassword:"));
  assert.ok(apiDts.includes("readonly requestOtp:"));
  assert.ok(apiDts.includes("readonly verifyOtp:"));
  assert.ok(apiDts.includes("readonly refresh:"));
  assert.ok(apiDts.includes("readonly signOut:"));
  assert.ok(apiDts.includes("readonly signOutAll:"));
  assert.ok(apiDts.includes("readonly listSessions:"));
  assert.ok(apiDts.includes("readonly sessionStatus:"));
  assert.ok(apiDts.includes("readonly exchangeOAuthCode:"));
  assert.ok(apiDts.includes("readonly requestMagicLink:"));
  assert.ok(apiDts.includes("readonly verifyMagicLink:"));
  assert.ok(apiDts.includes("readonly enrollTotp:"));
  assert.ok(apiDts.includes("readonly confirmTotp:"));
  assert.ok(apiDts.includes("readonly verifyTotp:"));
  assert.ok(apiDts.includes("readonly disableTotp:"));
  // Internal DB transitions MUST NOT be exposed in public generated client API.
  assert.equal(apiDts.includes("_findPasswordAccount"), false);
  assert.equal(apiDts.includes("_rotateRefreshToken"), false);
  assert.equal(apiDts.includes("_consumeOAuthExchangeCode"), false);
  assert.equal(apiDts.includes("_getTotpFactor"), false);

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

  // 3. Start local mock OAuth2 PKCE server (13299) and Concave server (13241) with live JWKS verification!
  const mockOAuthPort = 13299;
  const serverPort = 13241;
  const serverUrl = `http://127.0.0.1:${serverPort}`;
  const mockOAuth = await startMockOAuthServer(mockOAuthPort, mockOAuthSecret);

  const serverProc = spawn(
    binPath,
    ["--serve", "--host", "127.0.0.1", "--port", String(serverPort), "--db", dbPath],
    {
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        CONCAVE_SECRETS_DIR: secretsDir,
        CONCAVE_JWKS_URL: `${serverUrl}/.well-known/jwks.json`,
        CONCAVE_JWT_ISSUER: "concave-auth-e2e",
        CONCAVE_JWT_AUDIENCE: "concave-auth-e2e-app",
        CONCAVE_ALLOW_PRIVATE_HTTP: "true",
      },
    },
  );
  let stderrLog = "";
  serverProc.stderr.on("data", (d) => {
    stderrLog += d.toString();
  });

  t.after(async () => {
    serverProc.kill("SIGTERM");
    await mockOAuth.close();
  });

  await waitForHealth(serverUrl);

  // ---------------------------------------------------------------------------
  // Test 1: `GET /.well-known/jwks.json` returns valid Ed25519 JWK with Cache-Control
  // ---------------------------------------------------------------------------
  const jwksRes = await fetch(`${serverUrl}/.well-known/jwks.json`);
  assert.equal(jwksRes.status, 200);
  assert.match(jwksRes.headers.get("cache-control") ?? "", /max-age=300/);
  const jwks = await jwksRes.json();
  assert.ok(Array.isArray(jwks.keys) && jwks.keys.length === 1);
  assert.equal(jwks.keys[0].kty, "OKP");
  assert.equal(jwks.keys[0].crv, "Ed25519");
  assert.equal(jwks.keys[0].alg, "EdDSA");
  assert.equal(jwks.keys[0].use, "sig");
  assert.equal(jwks.keys[0].kid, "concave-auth-v1");
  assert.ok(typeof jwks.keys[0].x === "string" && jwks.keys[0].x.length >= 40);

  // Internal DB transition functions MUST be rejected on public HTTP API.
  const internalRes = await fetch(`${serverUrl}/api/query/auth._findPasswordAccount`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: "alice@example.com" }),
  });
  assert.equal(internalRes.status, 400);
  const internalJson = await internalRes.json();
  assert.equal(internalJson.ok, false);
  assert.match(internalJson.error, /internal/i);

  // ---------------------------------------------------------------------------
  // Test 2: Password Sign-Up -> Ed25519 JWT -> App-owned `users` table
  // ---------------------------------------------------------------------------
  const client1 = new ConcaveClient(serverUrl);
  const auth1 = createAuth(client1, api.auth, { userAgent: "e2e-tab-1" });
  t.after(() => {
    auth1.dispose();
    client1.close();
  });
  await waitForCondition(() => client1.status() === "connected", 5000, "client1 connected");

  const signUpRes = await auth1.signUpPassword({
    email: "Alice@Example.com",
    password: "SuperSecretPassword123!",
    name: "Alice",
  });
  assert.ok(signUpRes.access_token.split(".").length === 3);
  assert.ok(signUpRes.refresh_token.startsWith("rt_"));
  assert.ok(signUpRes.user_id.startsWith("usr_"));
  assert.ok(signUpRes.session_id.length > 0);
  assert.equal(signUpRes.email, "alice@example.com");

  await waitForCondition(() => client1.isAuthenticated() === true, 5000, "client1 authenticated via JWKS");
  await waitForCondition(
    () => auth1.sessionStatus().status === "ready" && auth1.sessionStatus().data?.active === true,
    5000,
    "sessionStatus active=true",
  );

  await client1.mutate(api.users.upsertProfile, {
    display_name: "Alice Wonderland",
    bio: "Concave Auth v2 tester",
  });
  const me = await client1.queryOnce(api.users.me, {});
  assert.equal(me.user_id, signUpRes.user_id);
  assert.equal(me.session_id, signUpRes.session_id);
  assert.equal(me.email, "alice@example.com");
  assert.equal(me.display_name, "Alice Wonderland");
  assert.equal(me.bio, "Concave Auth v2 tester");

  const sessions1 = await auth1.listSessions();
  assert.equal(sessions1.length, 1);
  assert.equal(sessions1[0].id, signUpRes.session_id);
  assert.equal(sessions1[0].is_current, true);
  assert.equal(sessions1[0].secret_hash, undefined);

  // ---------------------------------------------------------------------------
  // Test 3: Refresh Token Rotation, Grace Window, and Replay Family Revocation
  // ---------------------------------------------------------------------------
  const rt1 = signUpRes.refresh_token;
  const rot1 = await auth1.refresh();
  const rt2 = rot1.refresh_token;
  const jwt2 = rot1.access_token;
  assert.ok(rt2.startsWith("rt_") && rt2 !== rt1);
  assert.notEqual(jwt2, signUpRes.access_token);
  assert.equal(rot1.session_id, signUpRes.session_id);

  // Grace window (within 250ms): re-presenting rt1 succeeds WITHOUT revoking the session!
  const graceRes = await client1.action(api.auth.refresh, { refresh_token: rt1 });
  assert.ok(graceRes.access_token.split(".").length === 3);
  assert.equal(graceRes.refresh_token, "");
  assert.equal(graceRes.session_id, signUpRes.session_id);

  // Wait past the 250ms reuse grace window, then replay rt1 -> MUST REVOKE ENTIRE SESSION FAMILY!
  await new Promise((r) => setTimeout(r, 350));
  await assert.rejects(
    client1.action(api.auth.refresh, { refresh_token: rt1 }),
    /Refresh token reuse detected; session revoked/,
  );

  // Even the newer rt2 from the same session family MUST now be revoked!
  await assert.rejects(
    client1.action(api.auth.refresh, { refresh_token: rt2 }),
    /Session has been revoked|Refresh token reuse detected/,
  );

  // Live reactive client1 MUST automatically sign itself out via `sessionStatus` push!
  await waitForCondition(() => client1.isAuthenticated() === false, 5000, "client1 auto-signed-out after replay revocation");

  // Still-unexpired Ed25519 JWT (`jwt2`) MUST be rejected by `Auth.require_active_session!`!
  const revokedMeRes = await fetch(`${serverUrl}/api/query/users.me`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${jwt2}`,
    },
    body: "{}",
  });
  const revokedMeJson = await revokedMeRes.json();
  assert.equal(revokedMeJson.ok, false);
  assert.match(revokedMeJson.error, /Session revoked or expired/);

  // ---------------------------------------------------------------------------
  // Test 4: Instant Global Sign-Out (`signOutAll`) Across Two Live Tabs
  // ---------------------------------------------------------------------------
  const tabA = new ConcaveClient(serverUrl);
  const tabB = new ConcaveClient(serverUrl);
  const authA = createAuth(tabA, api.auth, { userAgent: "tab-A" });
  const authB = createAuth(tabB, api.auth, { userAgent: "tab-B" });
  let tabBSignedOutReason = null;
  const tabBWatcherClient = new ConcaveClient(serverUrl);
  const authBWatcher = createAuth(tabBWatcherClient, api.auth, {
    userAgent: "tab-B-watcher",
    onSignedOut: (info) => {
      tabBSignedOutReason = info.reason;
    },
  });
  t.after(() => {
    authA.dispose();
    authB.dispose();
    authBWatcher.dispose();
    tabA.close();
    tabB.close();
    tabBWatcherClient.close();
  });

  await waitForCondition(() => tabA.status() === "connected" && tabB.status() === "connected" && tabBWatcherClient.status() === "connected", 5000, "tabs connected");

  const loginA = await authA.signInPassword({ email: "alice@example.com", password: "SuperSecretPassword123!" });
  const loginB = await authB.signInPassword({ email: "alice@example.com", password: "SuperSecretPassword123!" });
  await authBWatcher.signInPassword({ email: "alice@example.com", password: "SuperSecretPassword123!" });
  assert.notEqual(loginA.session_id, loginB.session_id);

  await waitForCondition(
    () =>
      tabA.isAuthenticated() &&
      tabB.isAuthenticated() &&
      tabBWatcherClient.isAuthenticated() &&
      authBWatcher.sessionStatus().data?.active === true,
    5000,
    "all tabs authenticated & subscribed to sessionStatus",
  );

  const activeSessionsBefore = await authA.listSessions();
  assert.equal(activeSessionsBefore.length, 3);

  const tabBJwt = loginB.access_token;
  const revokedCount = await authA.signOutAll();
  assert.equal(revokedCount, 3);

  // Tab B & Watcher MUST drop auth immediately via live `sessionStatus` transition!
  await waitForCondition(() => tabB.isAuthenticated() === false, 5000, "tabB instant global sign-out");
  await waitForCondition(() => tabBWatcherClient.isAuthenticated() === false, 5000, "tabBWatcher instant global sign-out");
  assert.equal(tabBSignedOutReason, "session_revoked");

  // Unexpired JWT from Tab B MUST be rejected by `Auth.require_active_session!`!
  const tabBMeRes = await fetch(`${serverUrl}/api/query/users.me`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${tabBJwt}`,
    },
    body: "{}",
  });
  const tabBMeJson = await tabBMeRes.json();
  assert.equal(tabBMeJson.ok, false);
  assert.match(tabBMeJson.error, /Session revoked or expired/);

  // ---------------------------------------------------------------------------
  // Test 5: Brute-Force Rate Limit Lockout After Repeated Wrong Passwords
  // ---------------------------------------------------------------------------
  await assert.rejects(
    auth1.signInPassword({ email: "alice@example.com", password: "wrong-password-1" }),
    /Invalid email or password/,
  );
  await assert.rejects(
    auth1.signInPassword({ email: "alice@example.com", password: "wrong-password-2" }),
    /Invalid email or password/,
  );
  await assert.rejects(
    auth1.signInPassword({ email: "alice@example.com", password: "wrong-password-3" }),
    /Too many failed attempts; account temporarily locked/,
  );
  // Even the correct password MUST be rejected while locked out!
  await assert.rejects(
    auth1.signInPassword({ email: "alice@example.com", password: "SuperSecretPassword123!" }),
    /Too many failed attempts; account temporarily locked/,
  );

  // ---------------------------------------------------------------------------
  // Test 6: OTP Request + Constant-Time Verify Flow
  // ---------------------------------------------------------------------------
  const otpReq = await auth1.requestOtp("otp.bob@example.com");
  assert.equal(otpReq.sent, true);
  assert.match(otpReq.dev_code, /^\d{6}$/);

  const wrongCode = otpReq.dev_code === "000000" ? "111111" : "000000";
  await assert.rejects(
    auth1.verifyOtp({ email: "otp.bob@example.com", code: wrongCode, name: "Bob OTP" }),
    /Invalid or expired verification code/,
  );

  const otpRes = await auth1.verifyOtp({
    email: "otp.bob@example.com",
    code: otpReq.dev_code,
    name: "Bob OTP",
  });
  assert.equal(otpRes.email, "otp.bob@example.com");
  assert.ok(otpRes.access_token.split(".").length === 3);
  await waitForCondition(() => client1.isAuthenticated() === true, 5000, "otp client authenticated");
  const bobMe = await client1.queryOnce(api.users.me, {});
  assert.equal(bobMe.email, "otp.bob@example.com");
  assert.equal(bobMe.email_verified, true);
  assert.equal(bobMe.name, "Bob OTP");

  // Replaying the consumed OTP code MUST fail!
  await assert.rejects(
    client1.action(api.auth.verifyOtp, {
      email: "otp.bob@example.com",
      code: otpReq.dev_code,
      name: "Bob OTP",
      user_agent: "replay",
    }),
    /Invalid or expired verification code/,
  );

  // ---------------------------------------------------------------------------
  // Test 7: Modular OAuth2 + PKCE Flow (`/auth/oauth/mock/start` -> `/callback`)
  // ---------------------------------------------------------------------------
  const oauthStartUrl = auth1.oauthUrl("mock", { redirectTo: "/dashboard" });
  const startRes = await fetch(oauthStartUrl, { redirect: "manual" });
  if (startRes.status !== 302) {
    assert.fail(`expected 302 from ${oauthStartUrl}, got ${startRes.status}: ${await startRes.text()}`);
  }
  const locationHdr = startRes.headers.get("location") ?? "";
  const setCookieHdr = startRes.headers.get("set-cookie") ?? "";
  assert.ok(locationHdr.startsWith(`http://127.0.0.1:${mockOAuthPort}/authorize?`), `unexpected Location: ${locationHdr}`);
  assert.match(setCookieHdr, /concave_oauth_state=[^;]+/);
  assert.match(setCookieHdr, /HttpOnly/i);
  assert.match(setCookieHdr, /SameSite=Lax/i);

  const authzUrl = new URL(locationHdr);
  const oauthState = authzUrl.searchParams.get("state");
  const codeChallenge = authzUrl.searchParams.get("code_challenge");
  const codeChallengeMethod = authzUrl.searchParams.get("code_challenge_method");
  const redirectUri = authzUrl.searchParams.get("redirect_uri");
  assert.ok(oauthState && oauthState.length >= 20);
  assert.ok(codeChallenge && codeChallenge.length >= 40);
  assert.equal(codeChallengeMethod, "S256");

  const authCode = mockOAuth.registerAuthorizeCode(codeChallenge, redirectUri ?? "");

  // CSRF check: callback without matching state cookie MUST be rejected with 400!
  const csrfFailRes = await fetch(
    `${serverUrl}/auth/oauth/mock/callback?code=${encodeURIComponent(authCode)}&state=${encodeURIComponent(oauthState)}`,
    { headers: { Accept: "application/json", Cookie: "concave_oauth_state=forged_state" } },
  );
  assert.equal(csrfFailRes.status, 400);
  const csrfFailJson = await csrfFailRes.json();
  assert.match(csrfFailJson.error, /CSRF state mismatch/i);

  // Legitimate callback with matching state cookie exchanges code + PKCE verifier & creates session!
  const cbRes = await fetch(
    `${serverUrl}/auth/oauth/mock/callback?code=${encodeURIComponent(authCode)}&state=${encodeURIComponent(oauthState)}`,
    {
      headers: {
        Accept: "application/json",
        Cookie: `concave_oauth_state=${oauthState}`,
      },
    },
  );
  assert.equal(cbRes.status, 200);
  assert.equal(mockOAuth.getTokenExchangeCount(), 1);
  const oauthSession = await cbRes.json();
  assert.ok(oauthSession.access_token.split(".").length === 3);
  assert.ok(oauthSession.refresh_token.startsWith("rt_"));
  assert.equal(oauthSession.email, "oauth.user@example.com");
  assert.equal(oauthSession.name, "OAuth Alice");

  // Verify the OAuth-minted Ed25519 JWT authenticates `users.me` immediately!
  const oauthMeRes = await fetch(`${serverUrl}/api/query/users.me`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${oauthSession.access_token}`,
    },
    body: "{}",
  });
  assert.equal(oauthMeRes.status, 200);
  const oauthMeJson = await oauthMeRes.json();
  assert.equal(oauthMeJson.ok, true);
  assert.equal(oauthMeJson.value.user_id, oauthSession.user_id);
  assert.equal(oauthMeJson.value.email, "oauth.user@example.com");
  assert.equal(oauthMeJson.value.email_verified, true);

  // ---------------------------------------------------------------------------
  // Test 8: Per-Namespace Secret Allowlist Isolation
  // ---------------------------------------------------------------------------
  const secretLeakRes = await fetch(`${serverUrl}/api/action/debug.tryReadAuthSecret`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  const secretLeakJson = await secretLeakRes.json();
  assert.equal(secretLeakJson.ok, false, "root app action must NOT be able to read auth component's private signing key");
  assert.ok(
    typeof secretLeakJson.error === "string" && secretLeakJson.error.length > 0,
    "expected secret allowlist denial error",
  );

  // ---------------------------------------------------------------------------
  // Test 9: Browser OAuth2 302 Single-Use Exchange Code Handoff (?oauth_code=...)
  // ---------------------------------------------------------------------------
  const oauthStart2Res = await fetch(auth1.oauthUrl("mock", { redirectTo: "/app?tab=profile" }), {
    redirect: "manual",
  });
  assert.equal(oauthStart2Res.status, 302);
  const authzUrl2 = new URL(oauthStart2Res.headers.get("location") ?? "");
  const oauthState2 = authzUrl2.searchParams.get("state") ?? "";
  const codeChallenge2 = authzUrl2.searchParams.get("code_challenge") ?? "";
  const redirectUri2 = authzUrl2.searchParams.get("redirect_uri") ?? "";
  const authCode2 = mockOAuth.registerAuthorizeCode(codeChallenge2, redirectUri2);

  const browserCbRes = await fetch(
    `${serverUrl}/auth/oauth/mock/callback?code=${encodeURIComponent(authCode2)}&state=${encodeURIComponent(oauthState2)}`,
    {
      redirect: "manual",
      headers: {
        Accept: "text/html",
        Cookie: `concave_oauth_state=${oauthState2}`,
      },
    },
  );
  assert.equal(browserCbRes.status, 302);
  assert.match(browserCbRes.headers.get("cache-control") ?? "", /no-store/i);
  assert.match(browserCbRes.headers.get("set-cookie") ?? "", /Max-Age=0/i);

  const browserLoc = browserCbRes.headers.get("location") ?? "";
  assert.equal(browserLoc.includes("access_token"), false, `access_token must never appear in Location: ${browserLoc}`);
  assert.equal(browserLoc.includes("refresh_token"), false, `refresh_token must never appear in Location: ${browserLoc}`);
  assert.equal(browserLoc.includes("#"), false, `URL fragment must not be used for token handoff: ${browserLoc}`);
  assert.ok(browserLoc.startsWith("/app?tab=profile&oauth_code=oac_"), `unexpected Location: ${browserLoc}`);

  const parsedBrowserLoc = new URL(browserLoc, serverUrl);
  const oauthExchangeCode = parsedBrowserLoc.searchParams.get("oauth_code") ?? "";
  assert.ok(oauthExchangeCode.startsWith("oac_"));

  const exchangedSession = await auth1.consumeOAuthCallback(parsedBrowserLoc.search);
  assert.ok(exchangedSession && exchangedSession.access_token.split(".").length === 3);
  assert.ok(exchangedSession.refresh_token.startsWith("rt_"));
  assert.equal(exchangedSession.email, "oauth.user@example.com");

  await waitForCondition(() => client1.isAuthenticated() === true, 5000, "client1 authenticated via exchangeOAuthCode");
  const exchangedMe = await client1.queryOnce(api.users.me, {});
  assert.equal(exchangedMe.user_id, exchangedSession.user_id);
  assert.equal(exchangedMe.email, "oauth.user@example.com");

  // Replaying the single-use `oauth_code` MUST fail!
  await assert.rejects(
    auth1.exchangeOAuthCode(oauthExchangeCode),
    /already consumed|Invalid or expired OAuth exchange code/i,
  );

  // ---------------------------------------------------------------------------
  // Test 10: Magic-Link Email Auth (Action verify + HTTP JSON & 302 + Replay)
  // ---------------------------------------------------------------------------
  const mlReq1 = await auth1.requestMagicLink({
    email: "Magic.Carol@Example.COM",
    redirectTo: "/welcome",
  });
  assert.equal(mlReq1.sent, true);
  assert.ok(mlReq1.dev_token.startsWith("ml_"));
  assert.ok(mlReq1.magic_url.startsWith(`${serverUrl}/auth/magic-link/verify?token=ml_`));
  assert.ok(mlReq1.expires_at_ms > Date.now());

  const mlVerify1 = await auth1.verifyMagicLink({
    token: mlReq1.dev_token,
    name: "Magic Carol",
  });
  assert.equal(mlVerify1.email, "magic.carol@example.com");
  assert.ok(mlVerify1.access_token.split(".").length === 3);
  assert.ok(mlVerify1.refresh_token.startsWith("rt_"));

  const carolMeRes = await fetch(`${serverUrl}/api/query/users.me`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${mlVerify1.access_token}`,
    },
    body: "{}",
  });
  const carolMeJson = await carolMeRes.json();
  assert.equal(carolMeJson.ok, true);
  assert.equal(carolMeJson.value.email, "magic.carol@example.com");
  assert.equal(carolMeJson.value.email_verified, true);
  assert.equal(carolMeJson.value.name, "Magic Carol");

  // Replaying the consumed magic-link token MUST fail!
  await assert.rejects(
    auth1.verifyMagicLink({ token: mlReq1.dev_token }),
    /Invalid or expired magic link/i,
  );

  // HTTP GET /auth/magic-link/verify with Accept: application/json
  const mlReq2 = await auth1.requestMagicLink("magic.carol@example.com");
  const mlHttpJsonRes = await fetch(mlReq2.magic_url, {
    headers: { Accept: "application/json" },
  });
  assert.equal(mlHttpJsonRes.status, 200);
  assert.match(mlHttpJsonRes.headers.get("cache-control") ?? "", /no-store/i);
  const mlHttpSession = await mlHttpJsonRes.json();
  assert.equal(mlHttpSession.user_id, mlVerify1.user_id);
  assert.ok(mlHttpSession.access_token.split(".").length === 3);

  // Replaying HTTP GET /auth/magic-link/verify MUST return 400!
  const mlHttpReplayRes = await fetch(mlReq2.magic_url, {
    headers: { Accept: "application/json" },
  });
  assert.equal(mlHttpReplayRes.status, 400);

  // HTTP GET /auth/magic-link/verify with browser Accept: text/html -> 302 with ?oauth_code=...
  const mlReq3 = await auth1.requestMagicLink({
    email: "magic.dave@example.com",
    redirectTo: "/inbox",
  });
  const mlRedirectRes = await fetch(mlReq3.magic_url, {
    redirect: "manual",
    headers: { Accept: "text/html" },
  });
  assert.equal(mlRedirectRes.status, 302);
  assert.match(mlRedirectRes.headers.get("cache-control") ?? "", /no-store/i);
  const mlRedirectLoc = mlRedirectRes.headers.get("location") ?? "";
  assert.equal(mlRedirectLoc.includes("access_token"), false);
  assert.equal(mlRedirectLoc.includes("refresh_token"), false);
  assert.ok(mlRedirectLoc.startsWith("/inbox?oauth_code=oac_"), `unexpected magic-link redirect: ${mlRedirectLoc}`);

  const mlParsedLoc = new URL(mlRedirectLoc, serverUrl);
  const daveSession = await auth1.consumeOAuthCallback(mlParsedLoc.search);
  assert.ok(daveSession && daveSession.email === "magic.dave@example.com");
  await waitForCondition(
    () => client1.isAuthenticated() === true && auth1.getUserId() === daveSession.user_id,
    5000,
    "client1 authenticated as magic.dave",
  );
  const daveMe = await client1.queryOnce(api.users.me, {});
  assert.equal(daveMe.email, "magic.dave@example.com");
  assert.equal(daveMe.email_verified, true);

  // ---------------------------------------------------------------------------
  // Test 11: Pure-Roc RFC 6238 TOTP MFA (enroll, confirm, verify + replay, disable)
  // ---------------------------------------------------------------------------
  /** @param {string} b32 */
  function base32Decode(b32) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let bits = 0;
    let value = 0;
    /** @type {number[]} */
    const out = [];
    for (const ch of b32.toUpperCase().replace(/[=\s-]/g, "")) {
      const idx = alphabet.indexOf(ch);
      if (idx < 0) throw new Error(`Invalid Base32 char: ${ch}`);
      value = (value << 5) | idx;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.push((value >>> bits) & 0xff);
      }
    }
    return Buffer.from(out);
  }

  /** @param {Buffer} secretBuf @param {number} step @param {number} [digits] */
  function computeHotp(secretBuf, step, digits = 6) {
    const counterBuf = Buffer.alloc(8);
    counterBuf.writeBigUInt64BE(BigInt(step), 0);
    const mac = crypto.createHmac("sha1", secretBuf).update(counterBuf).digest();
    const offset = mac[mac.length - 1] & 0x0f;
    const binCode =
      ((mac[offset] & 0x7f) << 24) |
      ((mac[offset + 1] & 0xff) << 16) |
      ((mac[offset + 2] & 0xff) << 8) |
      (mac[offset + 3] & 0xff);
    return String(binCode % 10 ** digits).padStart(digits, "0");
  }

  // Avoid straddling a 30s TOTP boundary mid-test.
  const msIntoStep = Date.now() % 30_000;
  if (msIntoStep > 27_500) {
    await new Promise((r) => setTimeout(r, 30_000 - msIntoStep + 150));
  }

  const enrollRes = await auth1.enrollTotp();
  assert.match(enrollRes.secret_base32, /^[A-Z2-7]{32}$/);
  assert.ok(enrollRes.otpauth_uri.startsWith("otpauth://totp/"));
  assert.ok(enrollRes.otpauth_uri.includes(`secret=${enrollRes.secret_base32}`));
  assert.ok(enrollRes.otpauth_uri.includes("issuer=concave-auth-e2e"));

  const totpSecretBuf = base32Decode(enrollRes.secret_base32);
  const currentStep = Math.floor(Date.now() / 1000 / 30);
  const codePrev = computeHotp(totpSecretBuf, currentStep - 1);
  const codeCurr = computeHotp(totpSecretBuf, currentStep);
  const codeNext = computeHotp(totpSecretBuf, currentStep + 1);
  const wrongTotpCode = codeCurr === "000000" ? "111111" : "000000";

  // Confirm with wrong code MUST fail.
  await assert.rejects(auth1.confirmTotp(wrongTotpCode), /Invalid TOTP code/i);

  // Confirm with valid code at `currentStep - 1` (within ±1 window).
  const confirmRes = await auth1.confirmTotp(codePrev);
  assert.equal(confirmRes.enabled, true);

  // Replaying the same step (`currentStep - 1`) in `verifyTotp` MUST fail!
  await assert.rejects(auth1.verifyTotp(codePrev), /TOTP code already used/i);

  // Wrong TOTP code MUST fail!
  await assert.rejects(auth1.verifyTotp(wrongTotpCode), /Invalid TOTP code/i);

  // Next step (`currentStep`, strictly greater than `last_used_step`) MUST succeed!
  const verifyRes = await auth1.verifyTotp(codeCurr);
  assert.equal(verifyRes.valid, true);
  assert.equal(verifyRes.step, currentStep);

  // Replaying `currentStep` again MUST fail!
  await assert.rejects(auth1.verifyTotp(codeCurr), /TOTP code already used/i);

  // Disabling with wrong code MUST fail, then disabling with valid code MUST succeed!
  await assert.rejects(auth1.disableTotp(wrongTotpCode), /Invalid TOTP code/i);
  const disableRes = await auth1.disableTotp(codeNext);
  assert.equal(disableRes.disabled, true);

  // Verifying TOTP after disabling MUST fail!
  await assert.rejects(auth1.verifyTotp(codeNext), /TOTP is not enabled/i);

  assert.equal(stderrLog.includes("panic"), false, `unexpected panic in stderr:\n${stderrLog}`);
});
