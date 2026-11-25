const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const storage_mod = @import("storage.zig");

const DEFAULT_GCP_SECRET_API_BASE = "https://secretmanager.googleapis.com";
const DEFAULT_OAUTH2_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GCE_METADATA_TOKEN_URL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
const GCP_CLOUD_PLATFORM_SCOPE = "https://www.googleapis.com/auth/cloud-platform";
const VAULT_MAGIC = "CCVAULT1";
const VAULT_SALT_LEN: usize = 16;
const VAULT_PBKDF2_ROUNDS: u32 = 10_000;

pub const SecretError = error{
    InvalidSecretRef,
    SecretNotFound,
    ProjectNotConfigured,
    InsecureApiUrl,
    GcpAuthFailed,
    GcpApiError,
    InvalidSecretPayload,
    VaultCorrupted,
    VaultAuthFailed,
    OutOfMemory,
};

pub const SecretRef = struct {
    project: ?[]const u8,
    name: []const u8,
    version: []const u8,
};

/// Strictly validate a single path/identifier segment: 1..255 bytes, only `[A-Za-z0-9_-]`.
pub fn isValidSegment(seg: []const u8) bool {
    if (seg.len == 0 or seg.len > 255) return false;
    for (seg) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Parse a secret reference in any of the supported forms:
/// - `"STRIPE_KEY"` -> `{ .project = null, .name = "STRIPE_KEY", .version = "latest" }`
/// - `"STRIPE_KEY@3"` -> `{ .project = null, .name = "STRIPE_KEY", .version = "3" }`
/// - `"projects/<proj>/secrets/<name>/versions/<ver>"` -> extracts all 3 segments.
pub fn parseSecretRef(raw: []const u8) !SecretRef {
    if (raw.len == 0) return error.InvalidSecretRef;

    if (std.mem.startsWith(u8, raw, "projects/")) {
        var it = std.mem.splitScalar(u8, raw, '/');
        const p_lit = it.next() orelse return error.InvalidSecretRef;
        const proj = it.next() orelse return error.InvalidSecretRef;
        const s_lit = it.next() orelse return error.InvalidSecretRef;
        const name = it.next() orelse return error.InvalidSecretRef;
        const v_lit = it.next() orelse return error.InvalidSecretRef;
        const ver = it.next() orelse return error.InvalidSecretRef;
        if (it.next() != null) return error.InvalidSecretRef;
        if (!std.mem.eql(u8, p_lit, "projects") or
            !std.mem.eql(u8, s_lit, "secrets") or
            !std.mem.eql(u8, v_lit, "versions"))
        {
            return error.InvalidSecretRef;
        }
        if (!isValidSegment(proj) or !isValidSegment(name) or !isValidSegment(ver)) {
            return error.InvalidSecretRef;
        }
        return .{ .project = proj, .name = name, .version = ver };
    }

    if (std.mem.indexOfScalar(u8, raw, '@')) |at_idx| {
        const name = raw[0..at_idx];
        const ver = raw[at_idx + 1 ..];
        if (!isValidSegment(name) or !isValidSegment(ver)) {
            return error.InvalidSecretRef;
        }
        return .{ .project = null, .name = name, .version = ver };
    }

    if (!isValidSegment(raw)) return error.InvalidSecretRef;
    return .{ .project = null, .name = raw, .version = "latest" };
}

pub const SecretProviderConfig = struct {
    gcp_project: ?[]const u8 = null,
    secrets_dir: ?[]const u8 = null,
    local_vault_path: ?[]const u8 = null,
    vault_passphrase: ?[]const u8 = null,
    gcp_api_base: ?[]const u8 = null,
    gcp_access_token_override: ?[]const u8 = null,
    google_application_credentials: ?[]const u8 = null,
    home_dir: ?[]const u8 = null,
    allow_insecure_api: bool = false,
    cache_ttl_ms: i64 = 300_000,
};

const CacheEntry = struct {
    value: []u8,
    expires_at_ms: i64,
};

pub const SecretProvider = struct {
    allocator: Allocator,
    io: std.Io,
    gcp_project: ?[]u8 = null,
    secrets_dir: ?[]u8 = null,
    local_vault_path: ?[]u8 = null,
    vault_passphrase: ?[]u8 = null,
    gcp_api_base: ?[]u8 = null,
    gcp_access_token_override: ?[]u8 = null,
    google_application_credentials: ?[]u8 = null,
    home_dir: ?[]u8 = null,
    allow_insecure_api: bool = false,
    cache_ttl_ms: i64 = 300_000,

    mutex: std.Io.Mutex = .init,
    cache: std.StringHashMapUnmanaged(CacheEntry) = .empty,
    cached_token: ?[]u8 = null,
    cached_token_expires_ms: i64 = 0,

    pub fn init(allocator: Allocator, io: std.Io, cfg: SecretProviderConfig) !*SecretProvider {
        const self = try allocator.create(SecretProvider);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .allow_insecure_api = cfg.allow_insecure_api,
            .cache_ttl_ms = cfg.cache_ttl_ms,
        };
        errdefer self.freeOwnedFields();

        if (cfg.gcp_project) |v| if (v.len > 0) {
            self.gcp_project = try allocator.dupe(u8, v);
        };
        if (cfg.secrets_dir) |v| if (v.len > 0) {
            self.secrets_dir = try allocator.dupe(u8, v);
        };
        if (cfg.local_vault_path) |v| if (v.len > 0) {
            self.local_vault_path = try allocator.dupe(u8, v);
        };
        if (cfg.vault_passphrase) |v| if (v.len > 0) {
            self.vault_passphrase = try allocator.dupe(u8, v);
        };
        if (cfg.gcp_api_base) |v| if (v.len > 0) {
            self.gcp_api_base = try allocator.dupe(u8, std.mem.trimEnd(u8, v, "/"));
        };
        if (cfg.gcp_access_token_override) |v| if (v.len > 0) {
            self.gcp_access_token_override = try allocator.dupe(u8, v);
        };
        if (cfg.google_application_credentials) |v| if (v.len > 0) {
            self.google_application_credentials = try allocator.dupe(u8, v);
        };
        if (cfg.home_dir) |v| if (v.len > 0) {
            self.home_dir = try allocator.dupe(u8, v);
        };
        return self;
    }

    fn freeOwnedFields(self: *SecretProvider) void {
        if (self.gcp_project) |v| self.allocator.free(v);
        if (self.secrets_dir) |v| self.allocator.free(v);
        if (self.local_vault_path) |v| self.allocator.free(v);
        if (self.vault_passphrase) |v| {
            std.crypto.secureZero(u8, v);
            self.allocator.free(v);
        }
        if (self.gcp_api_base) |v| self.allocator.free(v);
        if (self.gcp_access_token_override) |v| {
            std.crypto.secureZero(u8, v);
            self.allocator.free(v);
        }
        if (self.google_application_credentials) |v| self.allocator.free(v);
        if (self.home_dir) |v| self.allocator.free(v);
        if (self.cached_token) |t| {
            std.crypto.secureZero(u8, t);
            self.allocator.free(t);
        }
        var it = self.cache.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            std.crypto.secureZero(u8, e.value_ptr.value);
            self.allocator.free(e.value_ptr.value);
        }
        self.cache.deinit(self.allocator);
    }

    pub fn deinit(self: *SecretProvider) void {
        self.freeOwnedFields();
        self.allocator.destroy(self);
    }

    /// Clear all cached secrets and OAuth tokens, zeroizing their memory.
    pub fn clearCache(self: *SecretProvider) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var it = self.cache.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            std.crypto.secureZero(u8, e.value_ptr.value);
            self.allocator.free(e.value_ptr.value);
        }
        self.cache.clearRetainingCapacity();
        if (self.cached_token) |t| {
            std.crypto.secureZero(u8, t);
            self.allocator.free(t);
            self.cached_token = null;
            self.cached_token_expires_ms = 0;
        }
    }

    /// Resolve a bootstrap config value: if prefixed with `"gcp-secret://"`, fetch via
    /// `getSecret`; otherwise return an owned duplicate of `raw`.
    pub fn resolveBootstrapValue(self: *SecretProvider, allocator: Allocator, raw: []const u8) ![]u8 {
        const prefix = "gcp-secret://";
        if (std.mem.startsWith(u8, raw, prefix)) {
            return try self.getSecret(allocator, raw[prefix.len..]);
        }
        return try allocator.dupe(u8, raw);
    }

    /// Fetch a secret by short name, `NAME@VERSION`, or full GCP Secret Manager resource name.
    /// Priority:
    /// 1. In-memory TTL cache
    /// 2. Mounted secrets directory (`CONCAVE_SECRETS_DIR/<name>`)
    /// 3. Google Cloud Secret Manager REST API
    /// 4. Offline encrypted local dev vault (`CONCAVE_SECRETS_VAULT`)
    pub fn getSecret(self: *SecretProvider, allocator: Allocator, raw_ref: []const u8) ![]u8 {
        const ref = try parseSecretRef(raw_ref);
        const now_ms = storage_mod.nowMillis(self.io);

        // 1. In-memory TTL cache
        if (self.cache_ttl_ms > 0) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.cache.get(raw_ref)) |entry| {
                if (now_ms < entry.expires_at_ms) {
                    return try allocator.dupe(u8, entry.value);
                }
                // Evict expired entry and zeroize its bytes.
                if (self.cache.fetchRemove(raw_ref)) |old| {
                    self.allocator.free(old.key);
                    std.crypto.secureZero(u8, old.value.value);
                    self.allocator.free(old.value.value);
                }
            }
        }

        // 2. Mounted secrets directory (`<secrets_dir>/<name>`)
        if (self.secrets_dir) |dir| {
            if (try readMountedSecretFile(allocator, self.io, dir, ref.name)) |val| {
                self.putCache(raw_ref, val);
                return val;
            }
        }

        // 3. Google Cloud Secret Manager REST API
        const eff_project = ref.project orelse self.gcp_project;
        if (eff_project) |project| {
            if (self.fetchFromGcpSecretManager(allocator, project, ref.name, ref.version)) |val| {
                self.putCache(raw_ref, val);
                return val;
            } else |err| {
                // If local dev vault is NOT configured, propagate the GCP error directly.
                if (self.local_vault_path == null) return err;
            }
        }

        // 4. Offline encrypted local dev vault
        if (self.local_vault_path) |vault_path| {
            if (try vaultGet(self.io, allocator, vault_path, self.vault_passphrase, ref.name)) |val| {
                self.putCache(raw_ref, val);
                return val;
            }
        }

        return error.SecretNotFound;
    }

    fn putCache(self: *SecretProvider, key: []const u8, value: []const u8) void {
        if (self.cache_ttl_ms <= 0) return;
        const exp_ms = storage_mod.nowMillis(self.io) + self.cache_ttl_ms;
        const val_copy = self.allocator.dupe(u8, value) catch return;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.cache.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            std.crypto.secureZero(u8, old.value.value);
            self.allocator.free(old.value.value);
        }
        const key_copy = self.allocator.dupe(u8, key) catch {
            std.crypto.secureZero(u8, val_copy);
            self.allocator.free(val_copy);
            return;
        };
        self.cache.put(self.allocator, key_copy, .{
            .value = val_copy,
            .expires_at_ms = exp_ms,
        }) catch {
            self.allocator.free(key_copy);
            std.crypto.secureZero(u8, val_copy);
            self.allocator.free(val_copy);
        };
    }

    fn fetchFromGcpSecretManager(
        self: *SecretProvider,
        allocator: Allocator,
        project: []const u8,
        name: []const u8,
        version: []const u8,
    ) ![]u8 {
        const api_base = self.gcp_api_base orelse DEFAULT_GCP_SECRET_API_BASE;
        if (!std.ascii.startsWithIgnoreCase(api_base, "https://") and !self.allow_insecure_api) {
            return error.InsecureApiUrl;
        }

        const token = try self.acquireGcpAccessToken(allocator);
        defer {
            std.crypto.secureZero(u8, token);
            allocator.free(token);
        }

        const url = try std.fmt.allocPrint(
            allocator,
            "{s}/v1/projects/{s}/secrets/{s}/versions/{s}:access",
            .{ api_base, project, name, version },
        );
        defer allocator.free(url);

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        defer {
            std.crypto.secureZero(u8, auth_header);
            allocator.free(auth_header);
        }

        const resp = try internalHttpRequest(allocator, self.io, .GET, url, &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/json" },
        }, null);
        defer allocator.free(resp.body);

        if (resp.status == 404) return error.SecretNotFound;
        if (resp.status < 200 or resp.status >= 300) return error.GcpApiError;

        return parseGcpSecretAccessResponse(allocator, resp.body);
    }

    fn parseGcpSecretAccessResponse(allocator: Allocator, body: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return error.InvalidSecretPayload;
        if (parsed != .object) return error.InvalidSecretPayload;
        const payload_v = parsed.object.get("payload") orelse return error.InvalidSecretPayload;
        if (payload_v != .object) return error.InvalidSecretPayload;
        const data_v = payload_v.object.get("data") orelse return error.InvalidSecretPayload;
        if (data_v != .string) return error.InvalidSecretPayload;

        return decodeStandardOrUrlBase64(allocator, data_v.string) catch return error.InvalidSecretPayload;
    }

    fn acquireGcpAccessToken(self: *SecretProvider, allocator: Allocator) ![]u8 {
        // a. Explicit token override (testing / CI)
        if (self.gcp_access_token_override) |tok| {
            return try allocator.dupe(u8, tok);
        }

        const now_ms = storage_mod.nowMillis(self.io);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.cached_token) |tok| {
                if (now_ms + 60_000 < self.cached_token_expires_ms) {
                    return try allocator.dupe(u8, tok);
                }
                std.crypto.secureZero(u8, tok);
                self.allocator.free(tok);
                self.cached_token = null;
                self.cached_token_expires_ms = 0;
            }
        }

        // b. GOOGLE_APPLICATION_CREDENTIALS JSON file
        if (self.google_application_credentials) |cred_path| {
            if (self.acquireTokenFromCredFile(allocator, cred_path)) |tr| {
                self.cacheAccessToken(tr.token, tr.expires_at_ms);
                return tr.token;
            } else |_| {}
        }

        // c. Default ADC path: $HOME/.config/gcloud/application_default_credentials.json
        if (self.home_dir) |home| {
            const adc_path = try std.fmt.allocPrint(allocator, "{s}/.config/gcloud/application_default_credentials.json", .{
                std.mem.trimEnd(u8, home, "/"),
            });
            defer allocator.free(adc_path);
            if (self.acquireTokenFromCredFile(allocator, adc_path)) |tr| {
                self.cacheAccessToken(tr.token, tr.expires_at_ms);
                return tr.token;
            } else |_| {}
        }

        // d. GCE / Cloud Run Metadata Server (exclusively inside secrets.zig)
        if (self.acquireTokenFromMetadataServer(allocator)) |tr| {
            self.cacheAccessToken(tr.token, tr.expires_at_ms);
            return tr.token;
        } else |_| {}

        return error.GcpAuthFailed;
    }

    fn cacheAccessToken(self: *SecretProvider, token: []const u8, expires_at_ms: i64) void {
        const copy = self.allocator.dupe(u8, token) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.cached_token) |old| {
            std.crypto.secureZero(u8, old);
            self.allocator.free(old);
        }
        self.cached_token = copy;
        self.cached_token_expires_ms = expires_at_ms;
    }

    const TokenResult = struct {
        token: []u8,
        expires_at_ms: i64,
    };

    fn acquireTokenFromCredFile(self: *SecretProvider, allocator: Allocator, path: []const u8) !TokenResult {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(256 * 1024)) catch return error.GcpAuthFailed;
        defer {
            std.crypto.secureZero(u8, bytes);
            allocator.free(bytes);
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return error.GcpAuthFailed;
        if (parsed != .object) return error.GcpAuthFailed;
        const obj = parsed.object;
        const cred_type = getJsonStr(obj, "type") orelse return error.GcpAuthFailed;

        if (std.mem.eql(u8, cred_type, "authorized_user")) {
            const client_id = getJsonStr(obj, "client_id") orelse return error.GcpAuthFailed;
            const client_secret = getJsonStr(obj, "client_secret") orelse return error.GcpAuthFailed;
            const refresh_token = getJsonStr(obj, "refresh_token") orelse return error.GcpAuthFailed;
            const token_uri = getJsonStr(obj, "token_uri") orelse DEFAULT_OAUTH2_TOKEN_URL;

            const cid_enc = try urlEncodeForm(a, client_id);
            const csec_enc = try urlEncodeForm(a, client_secret);
            const rtok_enc = try urlEncodeForm(a, refresh_token);
            const form = try std.fmt.allocPrint(
                a,
                "grant_type=refresh_token&client_id={s}&client_secret={s}&refresh_token={s}",
                .{ cid_enc, csec_enc, rtok_enc },
            );
            defer std.crypto.secureZero(u8, form);

            return try self.postOAuthTokenEndpoint(allocator, token_uri, form);
        }

        if (std.mem.eql(u8, cred_type, "service_account")) {
            const client_email = getJsonStr(obj, "client_email") orelse return error.GcpAuthFailed;
            const private_key_pem = getJsonStr(obj, "private_key") orelse return error.GcpAuthFailed;
            const token_uri = getJsonStr(obj, "token_uri") orelse DEFAULT_OAUTH2_TOKEN_URL;

            const now_secs = @divTrunc(storage_mod.nowMillis(self.io), 1000);
            const assertion = try signServiceAccountJwt(a, client_email, token_uri, private_key_pem, now_secs);
            const form = try std.fmt.allocPrint(
                a,
                "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}",
                .{assertion},
            );
            defer std.crypto.secureZero(u8, form);

            return try self.postOAuthTokenEndpoint(allocator, token_uri, form);
        }

        return error.GcpAuthFailed;
    }

    fn postOAuthTokenEndpoint(self: *SecretProvider, allocator: Allocator, token_uri: []const u8, form_body: []const u8) !TokenResult {
        if (!std.ascii.startsWithIgnoreCase(token_uri, "https://") and !self.allow_insecure_api) {
            return error.InsecureApiUrl;
        }
        const resp = try internalHttpRequest(allocator, self.io, .POST, token_uri, &.{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "Accept", .value = "application/json" },
        }, form_body);
        defer {
            std.crypto.secureZero(u8, resp.body);
            allocator.free(resp.body);
        }
        if (resp.status < 200 or resp.status >= 300) return error.GcpAuthFailed;
        return try parseOAuthTokenResponse(allocator, self.io, resp.body);
    }

    fn acquireTokenFromMetadataServer(self: *SecretProvider, allocator: Allocator) !TokenResult {
        const resp = try internalHttpRequest(allocator, self.io, .GET, GCE_METADATA_TOKEN_URL, &.{
            .{ .name = "Metadata-Flavor", .value = "Google" },
        }, null);
        defer {
            std.crypto.secureZero(u8, resp.body);
            allocator.free(resp.body);
        }
        if (resp.status < 200 or resp.status >= 300) return error.GcpAuthFailed;
        return try parseOAuthTokenResponse(allocator, self.io, resp.body);
    }

    fn parseOAuthTokenResponse(allocator: Allocator, io: std.Io, body: []const u8) !TokenResult {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return error.GcpAuthFailed;
        if (parsed != .object) return error.GcpAuthFailed;
        const tok = getJsonStr(parsed.object, "access_token") orelse return error.GcpAuthFailed;
        const expires_in_secs: i64 = if (parsed.object.get("expires_in")) |ev|
            (if (ev == .integer and ev.integer > 0) ev.integer else 3600)
        else
            3600;
        const now_ms = storage_mod.nowMillis(io);
        return .{
            .token = try allocator.dupe(u8, tok),
            .expires_at_ms = now_ms + expires_in_secs * 1000,
        };
    }
};

fn readMountedSecretFile(allocator: Allocator, io: std.Io, secrets_dir: []const u8, name: []const u8) !?[]u8 {
    if (!isValidSegment(name)) return error.InvalidSecretRef;
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, secrets_dir, "/"), name });
    defer allocator.free(full_path);

    const raw = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer {
        std.crypto.secureZero(u8, raw);
        allocator.free(raw);
    }
    const trimmed = std.mem.trimEnd(u8, raw, "\r\n");
    return try allocator.dupe(u8, trimmed);
}

// =============================================================================
// Offline Encrypted Local Dev Vault (XChaCha20-Poly1305 + PBKDF2-HMAC-SHA256)
// =============================================================================

fn deriveVaultKey(passphrase: ?[]const u8, vault_path: []const u8, salt: *const [VAULT_SALT_LEN]u8) ![32]u8 {
    var key: [32]u8 = undefined;
    if (passphrase) |pp| {
        if (pp.len > 0) {
            try std.crypto.pwhash.pbkdf2(&key, pp, salt, VAULT_PBKDF2_ROUNDS, HmacSha256);
            return key;
        }
    }
    // Machine/path-derived fallback for zero-friction offline local dev vault (never plaintext).
    var fallback_h = Sha256.init(.{});
    fallback_h.update("concave-dev-vault-v1:");
    fallback_h.update(vault_path);
    var fallback_seed: [32]u8 = undefined;
    fallback_h.final(&fallback_seed);
    defer std.crypto.secureZero(u8, &fallback_seed);
    try std.crypto.pwhash.pbkdf2(&key, &fallback_seed, salt, VAULT_PBKDF2_ROUNDS, HmacSha256);
    return key;
}

fn loadVaultMap(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    passphrase: ?[]const u8,
) !std.StringHashMapUnmanaged([]u8) {
    var map: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer freeVaultMap(allocator, &map);

    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return map,
        else => return err,
    };
    defer allocator.free(raw);

    const header_len = VAULT_MAGIC.len + VAULT_SALT_LEN + XChaCha20Poly1305.nonce_length + XChaCha20Poly1305.tag_length;
    if (raw.len < header_len) return error.VaultCorrupted;
    if (!std.mem.eql(u8, raw[0..VAULT_MAGIC.len], VAULT_MAGIC)) return error.VaultCorrupted;

    var off: usize = VAULT_MAGIC.len;
    var salt: [VAULT_SALT_LEN]u8 = undefined;
    @memcpy(&salt, raw[off .. off + VAULT_SALT_LEN]);
    off += VAULT_SALT_LEN;

    var nonce: [XChaCha20Poly1305.nonce_length]u8 = undefined;
    @memcpy(&nonce, raw[off .. off + XChaCha20Poly1305.nonce_length]);
    off += XChaCha20Poly1305.nonce_length;

    var tag: [XChaCha20Poly1305.tag_length]u8 = undefined;
    @memcpy(&tag, raw[off .. off + XChaCha20Poly1305.tag_length]);
    off += XChaCha20Poly1305.tag_length;

    const ct = raw[off..];
    var key = try deriveVaultKey(passphrase, path, &salt);
    defer std.crypto.secureZero(u8, &key);

    const pt = try allocator.alloc(u8, ct.len);
    defer {
        std.crypto.secureZero(u8, pt);
        allocator.free(pt);
    }
    const aad = raw[0 .. VAULT_MAGIC.len + VAULT_SALT_LEN];
    XChaCha20Poly1305.decrypt(pt, ct, tag, aad, nonce, key) catch return error.VaultAuthFailed;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), pt, .{}) catch return error.VaultCorrupted;
    if (parsed != .object) return error.VaultCorrupted;

    var it = parsed.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .string) continue;
        const k = try allocator.dupe(u8, e.key_ptr.*);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, e.value_ptr.string);
        errdefer {
            std.crypto.secureZero(u8, v);
            allocator.free(v);
        }
        try map.put(allocator, k, v);
    }
    return map;
}

fn saveVaultMap(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    passphrase: ?[]const u8,
    map: *const std.StringHashMapUnmanaged([]u8),
) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, json_out.written());
        json_out.deinit();
    }
    try json_out.writer.writeByte('{');
    var it = map.iterator();
    var idx: usize = 0;
    while (it.next()) |e| {
        if (idx > 0) try json_out.writer.writeByte(',');
        try storage_mod.writeJsonString(&json_out.writer, e.key_ptr.*);
        try json_out.writer.writeByte(':');
        try storage_mod.writeJsonString(&json_out.writer, e.value_ptr.*);
        idx += 1;
    }
    try json_out.writer.writeByte('}');
    const pt = json_out.written();

    var salt: [VAULT_SALT_LEN]u8 = undefined;
    io.random(&salt);
    var nonce: [XChaCha20Poly1305.nonce_length]u8 = undefined;
    io.random(&nonce);

    var key = try deriveVaultKey(passphrase, path, &salt);
    defer std.crypto.secureZero(u8, &key);

    const header_len = VAULT_MAGIC.len + VAULT_SALT_LEN + XChaCha20Poly1305.nonce_length + XChaCha20Poly1305.tag_length;
    const out_buf = try allocator.alloc(u8, header_len + pt.len);
    defer allocator.free(out_buf);

    var off: usize = 0;
    @memcpy(out_buf[off .. off + VAULT_MAGIC.len], VAULT_MAGIC);
    off += VAULT_MAGIC.len;
    @memcpy(out_buf[off .. off + VAULT_SALT_LEN], &salt);
    off += VAULT_SALT_LEN;
    @memcpy(out_buf[off .. off + XChaCha20Poly1305.nonce_length], &nonce);
    off += XChaCha20Poly1305.nonce_length;
    const tag_slice = out_buf[off .. off + XChaCha20Poly1305.tag_length];
    off += XChaCha20Poly1305.tag_length;
    const ct_slice = out_buf[off..];

    var tag: [XChaCha20Poly1305.tag_length]u8 = undefined;
    const aad = out_buf[0 .. VAULT_MAGIC.len + VAULT_SALT_LEN];
    XChaCha20Poly1305.encrypt(ct_slice, &tag, pt, aad, nonce, key);
    @memcpy(tag_slice, &tag);

    try writeFileAtomic(allocator, io, path, out_buf);
}

fn freeVaultMap(allocator: Allocator, map: *std.StringHashMapUnmanaged([]u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        std.crypto.secureZero(u8, e.value_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    map.deinit(allocator);
}

pub fn vaultSet(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
    value: []const u8,
) !void {
    if (!isValidSegment(name)) return error.InvalidSecretRef;
    var map = try loadVaultMap(io, allocator, path, passphrase);
    defer freeVaultMap(allocator, &map);

    if (map.fetchRemove(name)) |old| {
        allocator.free(old.key);
        std.crypto.secureZero(u8, old.value);
        allocator.free(old.value);
    }
    const k = try allocator.dupe(u8, name);
    errdefer allocator.free(k);
    const v = try allocator.dupe(u8, value);
    errdefer {
        std.crypto.secureZero(u8, v);
        allocator.free(v);
    }
    try map.put(allocator, k, v);
    try saveVaultMap(io, allocator, path, passphrase, &map);
}

pub fn vaultGet(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
) !?[]u8 {
    if (!isValidSegment(name)) return error.InvalidSecretRef;
    var map = try loadVaultMap(io, allocator, path, passphrase);
    defer freeVaultMap(allocator, &map);
    const val = map.get(name) orelse return null;
    return try allocator.dupe(u8, val);
}

pub fn vaultDelete(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    passphrase: ?[]const u8,
    name: []const u8,
) !bool {
    if (!isValidSegment(name)) return error.InvalidSecretRef;
    var map = try loadVaultMap(io, allocator, path, passphrase);
    defer freeVaultMap(allocator, &map);

    if (map.fetchRemove(name)) |old| {
        allocator.free(old.key);
        std.crypto.secureZero(u8, old.value);
        allocator.free(old.value);
        try saveVaultMap(io, allocator, path, passphrase, &map);
        return true;
    }
    return false;
}

pub fn vaultList(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    passphrase: ?[]const u8,
) ![][]u8 {
    var map = try loadVaultMap(io, allocator, path, passphrase);
    defer freeVaultMap(allocator, &map);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = map.keyIterator();
    while (it.next()) |k| {
        try names.append(allocator, try allocator.dupe(u8, k.*));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return try names.toOwnedSlice(allocator);
}

// =============================================================================
// Pure-Zig GCP Service Account RS256 JWT Signing (PKCS#8 DER + BigInt CRT)
// =============================================================================

const DerCursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readTlv(self: *DerCursor, expected_tag: u8) ![]const u8 {
        if (self.pos >= self.buf.len) return error.GcpAuthFailed;
        const tag = self.buf[self.pos];
        if (tag != expected_tag) return error.GcpAuthFailed;
        self.pos += 1;
        if (self.pos >= self.buf.len) return error.GcpAuthFailed;
        const first_len = self.buf[self.pos];
        self.pos += 1;
        var len: usize = 0;
        if ((first_len & 0x80) == 0) {
            len = first_len;
        } else {
            const num_bytes = first_len & 0x7F;
            if (num_bytes == 0 or num_bytes > 4 or self.pos + num_bytes > self.buf.len) return error.GcpAuthFailed;
            for (0..num_bytes) |_| {
                len = (len << 8) | self.buf[self.pos];
                self.pos += 1;
            }
        }
        if (self.pos + len > self.buf.len) return error.GcpAuthFailed;
        const slice = self.buf[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }
};

const RsaPrivateKeyParts = struct {
    n: []const u8,
    d: []const u8,
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
};

fn stripLeadingZero(b: []const u8) []const u8 {
    var s = b;
    while (s.len > 1 and s[0] == 0) s = s[1..];
    return s;
}

fn parsePkcs8RsaPem(allocator: Allocator, pem: []const u8) !RsaPrivateKeyParts {
    var b64_buf: std.ArrayList(u8) = .empty;
    defer b64_buf.deinit(allocator);

    var lines = std.mem.splitAny(u8, pem, "\r\n");
    var in_body = false;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "-----BEGIN ")) {
            in_body = true;
            continue;
        }
        if (std.mem.startsWith(u8, t, "-----END ")) break;
        if (in_body) try b64_buf.appendSlice(allocator, t);
    }
    if (b64_buf.items.len == 0) return error.GcpAuthFailed;

    const der_len = std.base64.standard.Decoder.calcSizeForSlice(b64_buf.items) catch return error.GcpAuthFailed;
    const der = try allocator.alloc(u8, der_len);
    std.base64.standard.Decoder.decode(der, b64_buf.items) catch return error.GcpAuthFailed;

    // Outer PKCS#8 PrivateKeyInfo SEQUENCE
    var outer = DerCursor{ .buf = der };
    const pki_seq = try outer.readTlv(0x30);
    var pki = DerCursor{ .buf = pki_seq };
    _ = try pki.readTlv(0x02); // version
    _ = try pki.readTlv(0x30); // algorithmIdentifier
    const pkcs1_octets = try pki.readTlv(0x04); // privateKey OCTET STRING

    // Inner PKCS#1 RSAPrivateKey SEQUENCE
    var inner_outer = DerCursor{ .buf = pkcs1_octets };
    const rsa_seq = try inner_outer.readTlv(0x30);
    var rsa_cur = DerCursor{ .buf = rsa_seq };
    _ = try rsa_cur.readTlv(0x02); // version
    const n = stripLeadingZero(try rsa_cur.readTlv(0x02));
    _ = try rsa_cur.readTlv(0x02); // e
    const d = stripLeadingZero(try rsa_cur.readTlv(0x02));
    const p = stripLeadingZero(try rsa_cur.readTlv(0x02));
    const q = stripLeadingZero(try rsa_cur.readTlv(0x02));
    const dp = stripLeadingZero(try rsa_cur.readTlv(0x02));
    const dq = stripLeadingZero(try rsa_cur.readTlv(0x02));
    const qinv = stripLeadingZero(try rsa_cur.readTlv(0x02));

    if (n.len < 256) return error.GcpAuthFailed;
    return .{ .n = n, .d = d, .p = p, .q = q, .dp = dp, .dq = dq, .qinv = qinv };
}

fn bigIntFromBeBytes(allocator: Allocator, bytes: []const u8) !std.math.big.int.Managed {
    var out = try std.math.big.int.Managed.initSet(allocator, 0);
    errdefer out.deinit();
    var byte_val = try std.math.big.int.Managed.initSet(allocator, 0);
    defer byte_val.deinit();
    for (bytes) |b| {
        try out.shiftLeft(&out, 8);
        try byte_val.set(b);
        try out.add(&out, &byte_val);
    }
    return out;
}

fn bigIntModExp(
    allocator: Allocator,
    base: *const std.math.big.int.Managed,
    exp_bytes: []const u8,
    modulus: *const std.math.big.int.Managed,
) !std.math.big.int.Managed {
    var result = try std.math.big.int.Managed.initSet(allocator, 1);
    errdefer result.deinit();
    var cur = try std.math.big.int.Managed.init(allocator);
    defer cur.deinit();
    var q_tmp = try std.math.big.int.Managed.init(allocator);
    defer q_tmp.deinit();
    var prod = try std.math.big.int.Managed.init(allocator);
    defer prod.deinit();

    // cur = base mod modulus
    try q_tmp.divTrunc(&cur, base, modulus);

    // Process exponent from LSB to MSB
    var byte_idx: usize = exp_bytes.len;
    while (byte_idx > 0) {
        byte_idx -= 1;
        var b = exp_bytes[byte_idx];
        for (0..8) |_| {
            if ((b & 1) != 0) {
                try prod.mul(&result, &cur);
                try q_tmp.divTrunc(&result, &prod, modulus);
            }
            try prod.mul(&cur, &cur);
            try q_tmp.divTrunc(&cur, &prod, modulus);
            b >>= 1;
        }
    }
    return result;
}

fn bigIntToBeBytesFixed(val: *const std.math.big.int.Managed, out: []u8) !void {
    @memset(out, 0);
    var tmp = try val.clone();
    defer tmp.deinit();
    var byte_idx: usize = out.len;
    while (byte_idx > 0 and !tmp.eqlZero()) {
        byte_idx -= 1;
        out[byte_idx] = @truncate(tmp.limbs[0]);
        try tmp.shiftRight(&tmp, 8);
    }
}

fn rsaPkcs1v15Sha256Sign(allocator: Allocator, key: RsaPrivateKeyParts, msg: []const u8) ![]u8 {
    const k = key.n.len;
    // RFC 8017 SHA-256 DigestInfo DER prefix (19 bytes)
    const digest_info_prefix = [_]u8{
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
        0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
        0x00, 0x04, 0x20,
    };
    const t_len = digest_info_prefix.len + 32;
    if (k < t_len + 11) return error.GcpAuthFailed;

    var digest: [32]u8 = undefined;
    Sha256.hash(msg, &digest, .{});

    const em = try allocator.alloc(u8, k);
    defer allocator.free(em);
    em[0] = 0x00;
    em[1] = 0x01;
    const ps_len = k - t_len - 3;
    @memset(em[2 .. 2 + ps_len], 0xFF);
    em[2 + ps_len] = 0x00;
    @memcpy(em[3 + ps_len .. 3 + ps_len + digest_info_prefix.len], &digest_info_prefix);
    @memcpy(em[3 + ps_len + digest_info_prefix.len ..], &digest);

    var m_int = try bigIntFromBeBytes(allocator, em);
    defer m_int.deinit();
    var p_int = try bigIntFromBeBytes(allocator, key.p);
    defer p_int.deinit();
    var q_int = try bigIntFromBeBytes(allocator, key.q);
    defer q_int.deinit();
    var qinv_int = try bigIntFromBeBytes(allocator, key.qinv);
    defer qinv_int.deinit();

    // CRT RSA signing: m1 = m^dP mod p, m2 = m^dQ mod q, h = qInv*(m1 - m2) mod p, s = m2 + h*q
    var m1 = try bigIntModExp(allocator, &m_int, key.dp, &p_int);
    defer m1.deinit();
    var m2 = try bigIntModExp(allocator, &m_int, key.dq, &q_int);
    defer m2.deinit();

    var diff = try std.math.big.int.Managed.init(allocator);
    defer diff.deinit();
    try diff.sub(&m1, &m2);
    while (!diff.isPositive()) {
        try diff.add(&diff, &p_int);
    }

    var h_prod = try std.math.big.int.Managed.init(allocator);
    defer h_prod.deinit();
    try h_prod.mul(&qinv_int, &diff);

    var q_tmp = try std.math.big.int.Managed.init(allocator);
    defer q_tmp.deinit();
    var h = try std.math.big.int.Managed.init(allocator);
    defer h.deinit();
    try q_tmp.divTrunc(&h, &h_prod, &p_int);

    var hq = try std.math.big.int.Managed.init(allocator);
    defer hq.deinit();
    try hq.mul(&h, &q_int);

    var sig_int = try std.math.big.int.Managed.init(allocator);
    defer sig_int.deinit();
    try sig_int.add(&m2, &hq);

    const sig_bytes = try allocator.alloc(u8, k);
    errdefer allocator.free(sig_bytes);
    try bigIntToBeBytesFixed(&sig_int, sig_bytes);
    return sig_bytes;
}

fn signServiceAccountJwt(
    allocator: Allocator,
    client_email: []const u8,
    token_uri: []const u8,
    private_key_pem: []const u8,
    now_secs: i64,
) ![]u8 {
    const key_parts = try parsePkcs8RsaPem(allocator, private_key_pem);

    const hdr_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    var pay_out: std.Io.Writer.Allocating = .init(allocator);
    try pay_out.writer.writeAll("{\"iss\":");
    try storage_mod.writeJsonString(&pay_out.writer, client_email);
    try pay_out.writer.writeAll(",\"scope\":\"");
    try pay_out.writer.writeAll(GCP_CLOUD_PLATFORM_SCOPE);
    try pay_out.writer.writeAll("\",\"aud\":");
    try storage_mod.writeJsonString(&pay_out.writer, token_uri);
    try pay_out.writer.print(",\"iat\":{d},\"exp\":{d}}}", .{ now_secs, now_secs + 3600 });
    const pay_json = pay_out.written();

    const hdr_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(hdr_json.len);
    const pay_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(pay_json.len);
    const signing_input = try allocator.alloc(u8, hdr_b64_len + 1 + pay_b64_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(signing_input[0..hdr_b64_len], hdr_json);
    signing_input[hdr_b64_len] = '.';
    _ = std.base64.url_safe_no_pad.Encoder.encode(signing_input[hdr_b64_len + 1 ..], pay_json);

    const sig_bytes = try rsaPkcs1v15Sha256Sign(allocator, key_parts, signing_input);
    const sig_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(sig_bytes.len);
    const sig_b64 = try allocator.alloc(u8, sig_b64_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(sig_b64, sig_bytes);

    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, sig_b64 });
}

// =============================================================================
// Internal HTTP helper (exclusively for GCP Secret Manager / OAuth / Metadata)
// =============================================================================

const InternalHttpResp = struct {
    status: u16,
    body: []u8,
};

fn internalHttpRequest(
    allocator: Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    headers: []const std.http.Header,
    body: ?[]const u8,
) !InternalHttpResp {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(method, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .extra_headers = headers,
    });
    defer req.deinit();

    if (req.connection) |conn| {
        const tv = std.posix.timeval{ .sec = 10, .usec = 0 };
        std.posix.setsockopt(conn.stream_reader.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        std.posix.setsockopt(conn.stream_reader.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    if (body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var bw = try req.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(payload);
        try bw.end();
        if (req.connection) |conn| try conn.flush();
    } else {
        try req.sendBodiless();
    }

    var head_buf: [8192]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    const status_code: u16 = @intFromEnum(resp.head.status);

    var transfer_buf: [8192]u8 = undefined;
    const reader = resp.reader(&transfer_buf);
    const resp_body = reader.allocRemaining(allocator, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return resp.bodyErr() orelse error.ReadFailed,
        else => return err,
    };
    return .{ .status = status_code, .body = resp_body };
}

fn decodeStandardOrUrlBase64(allocator: Allocator, b64: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, b64, " \t\r\n");
    if (std.base64.standard.Decoder.calcSizeForSlice(trimmed)) |len| {
        const out = try allocator.alloc(u8, len);
        errdefer allocator.free(out);
        if (std.base64.standard.Decoder.decode(out, trimmed)) |_| {
            return out;
        } else |_| {
            allocator.free(out);
        }
    } else |_| {}
    const no_pad = std.mem.trimEnd(u8, trimmed, "=");
    const ulen = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(no_pad);
    const out = try allocator.alloc(u8, ulen);
    errdefer allocator.free(out);
    try std.base64.url_safe_no_pad.Decoder.decode(out, no_pad);
    return out;
}

fn getJsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

fn urlEncodeForm(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0F]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn writeFileAtomic(allocator: Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    var rand_buf: [8]u8 = undefined;
    io.random(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ path, hex });
    defer allocator.free(tmp_path);

    {
        const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        errdefer {
            f.close(io);
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        }
        try f.writePositionalAll(io, bytes, 0);
        f.close(io);
    }
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp_path, std.Io.Dir.cwd(), path, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };
}

// =============================================================================
// Unit Tests
// =============================================================================

test "secrets: parseSecretRef supports short names, @version, full resource paths, and rejects traversal" {
    const r1 = try parseSecretRef("STRIPE_KEY");
    try std.testing.expect(r1.project == null);
    try std.testing.expectEqualStrings("STRIPE_KEY", r1.name);
    try std.testing.expectEqualStrings("latest", r1.version);

    const r2 = try parseSecretRef("STRIPE_KEY@3");
    try std.testing.expect(r2.project == null);
    try std.testing.expectEqualStrings("STRIPE_KEY", r2.name);
    try std.testing.expectEqualStrings("3", r2.version);

    const r3 = try parseSecretRef("projects/my-prod-1/secrets/JWT_SEED/versions/12");
    try std.testing.expectEqualStrings("my-prod-1", r3.project.?);
    try std.testing.expectEqualStrings("JWT_SEED", r3.name);
    try std.testing.expectEqualStrings("12", r3.version);

    // Invalid / path-traversal / injection attempts MUST be rejected
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef(""));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("../etc/passwd"));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("STRIPE%2FKEY"));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("STRIPE KEY"));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("STRIPE_KEY@"));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("STRIPE_KEY@1@2"));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("projects/../secrets/A/versions/latest"));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("projects/p/secrets/a/versions/1/extra"));
    try std.testing.expectError(error.InvalidSecretRef, parseSecretRef("a/b"));
}

test "secrets: mounted secrets_dir read, TTL cache hit, and resolveBootstrapValue" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const dir = ".zig-cache/test-secrets-dir";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const secret_file = dir ++ "/DB_PASS";
    try writeFileAtomic(allocator, io, secret_file, "s3cr3t-pass\r\n");
    defer std.Io.Dir.cwd().deleteFile(io, secret_file) catch {};

    const sp = try SecretProvider.init(allocator, io, .{
        .secrets_dir = dir,
        .cache_ttl_ms = 60_000,
    });
    defer sp.deinit();

    // First read comes from mounted secrets_dir and strips trailing CRLF
    const v1 = try sp.getSecret(allocator, "DB_PASS");
    defer allocator.free(v1);
    try std.testing.expectEqualStrings("s3cr3t-pass", v1);

    // Delete underlying file; second read MUST still hit TTL cache!
    std.Io.Dir.cwd().deleteFile(io, secret_file) catch {};
    const v2 = try sp.getSecret(allocator, "DB_PASS");
    defer allocator.free(v2);
    try std.testing.expectEqualStrings("s3cr3t-pass", v2);

    // resolveBootstrapValue passes through plain values and resolves gcp-secret:// values
    const plain = try sp.resolveBootstrapValue(allocator, "postgres://localhost/app");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("postgres://localhost/app", plain);

    const resolved = try sp.resolveBootstrapValue(allocator, "gcp-secret://DB_PASS");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("s3cr3t-pass", resolved);

    // Clearing cache drops the cached secret
    sp.clearCache();
    try std.testing.expectError(error.SecretNotFound, sp.getSecret(allocator, "DB_PASS"));
}

test "secrets: encrypted local vault set/get/list/delete and tamper detection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const vault_path = ".zig-cache/test-secrets-vault.enc";
    std.Io.Dir.cwd().deleteFile(io, vault_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, vault_path) catch {};

    const pass = "dev-vault-passphrase-123";
    try vaultSet(io, allocator, vault_path, pass, "STRIPE_KEY", "sk_test_999");
    try vaultSet(io, allocator, vault_path, pass, "AUTH_SEED", "seed_abc");

    // Verify file on disk is NOT plaintext
    const raw_disk = try std.Io.Dir.cwd().readFileAlloc(io, vault_path, allocator, .limited(64 * 1024));
    defer allocator.free(raw_disk);
    try std.testing.expect(std.mem.indexOf(u8, raw_disk, "sk_test_999") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw_disk, "STRIPE_KEY") == null);

    // Read via SecretProvider fallback
    const sp = try SecretProvider.init(allocator, io, .{
        .local_vault_path = vault_path,
        .vault_passphrase = pass,
    });
    defer sp.deinit();

    const got = try sp.getSecret(allocator, "STRIPE_KEY");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("sk_test_999", got);

    // List keys (sorted)
    const names = try vaultList(io, allocator, vault_path, pass);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("AUTH_SEED", names[0]);
    try std.testing.expectEqualStrings("STRIPE_KEY", names[1]);

    // Wrong passphrase MUST fail authentication
    try std.testing.expectError(error.VaultAuthFailed, vaultGet(io, allocator, vault_path, "wrong-pass", "STRIPE_KEY"));

    // Delete key
    try std.testing.expect(try vaultDelete(io, allocator, vault_path, pass, "AUTH_SEED"));
    try std.testing.expect(!(try vaultDelete(io, allocator, vault_path, pass, "NON_EXISTENT")));
    try std.testing.expect((try vaultGet(io, allocator, vault_path, pass, "AUTH_SEED")) == null);

    // Tampering with ciphertext byte MUST fail authentication
    const tampered = try std.Io.Dir.cwd().readFileAlloc(io, vault_path, allocator, .limited(64 * 1024));
    defer allocator.free(tampered);
    tampered[tampered.len - 1] ^= 0x01;
    try writeFileAtomic(allocator, io, vault_path, tampered);
    try std.testing.expectError(error.VaultAuthFailed, vaultGet(io, allocator, vault_path, pass, "STRIPE_KEY"));
}

test "secrets: GCP Secret Manager access JSON parsing (UTF-8, binary, empty, URL-safe b64, malformed) and HTTPS enforcement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 1. Standard GCP Secret Manager access response with UTF-8 payload
    const utf8_resp =
        \\{"name":"projects/123456789/secrets/STRIPE_KEY/versions/3","payload":{"data":"c2tfbGl2ZV9zZWNyZXRf4pyT","dataCrc32c":"123456789"}}
    ;
    const decoded_utf8 = try SecretProvider.parseGcpSecretAccessResponse(allocator, utf8_resp);
    defer allocator.free(decoded_utf8);
    try std.testing.expectEqualStrings("sk_live_secret_\xe2\x9c\x93", decoded_utf8);

    // 2. Empty payload
    const empty_resp =
        \\{"name":"projects/my-proj/secrets/EMPTY/versions/1","payload":{"data":""}}
    ;
    const decoded_empty = try SecretProvider.parseGcpSecretAccessResponse(allocator, empty_resp);
    defer allocator.free(decoded_empty);
    try std.testing.expectEqual(@as(usize, 0), decoded_empty.len);

    // 3. Binary payload (with NUL and high bytes) in both standard and URL-safe base64
    const expected_bin = [_]u8{ 0x00, 0x05, 0xff, 0x80, 0xfe, 0xff };
    const bin_std_resp =
        \\{"name":"projects/my-proj/secrets/BIN/versions/1","payload":{"data":"AAX/gP7/"}}
    ;
    const decoded_bin_std = try SecretProvider.parseGcpSecretAccessResponse(allocator, bin_std_resp);
    defer allocator.free(decoded_bin_std);
    try std.testing.expectEqualSlices(u8, &expected_bin, decoded_bin_std);

    const bin_url_resp =
        \\{"name":"projects/my-proj/secrets/BIN/versions/2","payload":{"data":"AAX_gP7_"}}
    ;
    const decoded_bin_url = try SecretProvider.parseGcpSecretAccessResponse(allocator, bin_url_resp);
    defer allocator.free(decoded_bin_url);
    try std.testing.expectEqualSlices(u8, &expected_bin, decoded_bin_url);

    // 4. Malformed responses MUST return InvalidSecretPayload
    try std.testing.expectError(error.InvalidSecretPayload, SecretProvider.parseGcpSecretAccessResponse(allocator, "not-json"));
    try std.testing.expectError(error.InvalidSecretPayload, SecretProvider.parseGcpSecretAccessResponse(allocator, "[]"));
    try std.testing.expectError(error.InvalidSecretPayload, SecretProvider.parseGcpSecretAccessResponse(allocator, "{}"));
    try std.testing.expectError(error.InvalidSecretPayload, SecretProvider.parseGcpSecretAccessResponse(allocator, "{\"payload\":\"oops\"}"));
    try std.testing.expectError(error.InvalidSecretPayload, SecretProvider.parseGcpSecretAccessResponse(allocator, "{\"payload\":{}}"));
    try std.testing.expectError(error.InvalidSecretPayload, SecretProvider.parseGcpSecretAccessResponse(allocator, "{\"payload\":{\"data\":123}}"));
    try std.testing.expectError(error.InvalidSecretPayload, SecretProvider.parseGcpSecretAccessResponse(allocator, "{\"payload\":{\"data\":\"!!!not-base64!!!\"}}"));

    // 5. OAuth token response parsing (explicit expires_in, default expires_in, and malformed rejection)
    const tok1 = try SecretProvider.parseOAuthTokenResponse(allocator, io, "{\"access_token\":\"ya29.test-token\",\"expires_in\":1800,\"token_type\":\"Bearer\"}");
    defer allocator.free(tok1.token);
    try std.testing.expectEqualStrings("ya29.test-token", tok1.token);
    try std.testing.expect(tok1.expires_at_ms > storage_mod.nowMillis(io) + 1_700_000);

    const tok2 = try SecretProvider.parseOAuthTokenResponse(allocator, io, "{\"access_token\":\"ya29.default-ttl\"}");
    defer allocator.free(tok2.token);
    try std.testing.expectEqualStrings("ya29.default-ttl", tok2.token);
    try std.testing.expect(tok2.expires_at_ms > storage_mod.nowMillis(io) + 3_500_000);

    try std.testing.expectError(error.GcpAuthFailed, SecretProvider.parseOAuthTokenResponse(allocator, io, "{}"));
    try std.testing.expectError(error.GcpAuthFailed, SecretProvider.parseOAuthTokenResponse(allocator, io, "{\"access_token\":\"\"}"));

    // 6. Plaintext http:// GCP API base MUST be rejected when allow_insecure_api is false
    const sp = try SecretProvider.init(allocator, io, .{
        .gcp_project = "my-prod-proj",
        .gcp_api_base = "http://secretmanager.example.com",
        .gcp_access_token_override = "tok",
        .allow_insecure_api = false,
    });
    defer sp.deinit();
    try std.testing.expectError(error.InsecureApiUrl, sp.getSecret(allocator, "STRIPE_KEY"));
}

test "secrets: PKCS#8 RSA-2048 parsing, RS256 service account JWT assertion signing + verification, and malformed PEM rejection" {
    // Ephemeral synthetic test-only RSA-2048 PKCS#8 key (never used in any environment)
    const test_rsa2048_pkcs8_pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC4jKXKnSCRG9us
        \\RPJQQ+IAO6d0g/RoQXD91AbctWfRtW489nuFL6MM63gx4TRjcRGcaQB0e50MllPP
        \\MJ00BRP/DucfNMJmScizyqGj+P0qWbpZOqhtiML+ljxMgk4oQwY5T0BUTmrzx58D
        \\1sEusy0FiN7HyFbBoTXaJyOxWLm0UJe4XAUMrcUsUZldYkaiWkxxfOVMAfZeomxa
        \\HBDdwhR7e2tKwaMk9BPJimKuBRPyMZ6yJP3PF6g9s+GsQJo6jqouSvr4+NNzaWhS
        \\Nfzm6W/5KCBh7lwHPdaE7TYiJa5lLx67ZNrRCoZrA2ISVfJKTOL4iG4/M4JH08fG
        \\JKqWHgGnAgMBAAECggEAAXF0IHP/G7NkkeHOJUuKmmbdBd+8Sw5r9Egyr4opoC2z
        \\iX2B9MYtF75Fp9ozfy2UrizyCHcpAL6yNBYUvKHniKCUtR1EAenEzIcioXYigLDH
        \\8MexJn4hzDzfhtekBdOUWmFgxugAFRz0BOMqipNzIC50U4qhBw2cLrMMp+fiN+NA
        \\BV9lrhH+QPGDFi5iabjyuLrslRvht7h4uFwPVFNsb2uXrygVlhBdwgXrNIG3ix6E
        \\Umv8E6qIy2oOtAzGOo7Z8mMQcGmwO8pMqhLkZeHA9VDrmUsjIeeCYIPaAO5GBcjJ
        \\gpiezxUzS9ACzSOL+BifT4SRTlgFDryCX0oi3Xv+4QKBgQD6m6hJCD//KiqFahIN
        \\V/BQL77l+6TAJxg+hxVUq/86h/AXl+bILnOgHaWR0faHua4rYYngO8/aP8mz4s3z
        \\fxA8eZ9frkLzNcWar7Y2jNultNXiQn77KMsiPYmry0FDfByFXzUsqR0LxeYI05d/
        \\PBAaegG1YXyZxuEdkyhVaLAARwKBgQC8hSQZMUxk4oz2oehHOUAN5oImQmVKZWZ+
        \\VIKFDiteZmsOZEwfkl+SskyZs2KwxFjFg+cKxK05qZI0uflhYkp6ExKXzoSZ0fp9
        \\xq9+CQ6ehlFJQUi0BFcXK409hfUssTjqFvBKJuyKX4dwJdge0QBjhdR7+EaRNfzZ
        \\wNfKgKsDoQKBgEXYBfG8u+FIhitCoZ9YZ+BhPinolUT8YFRk33wGp45PfomEy0v1
        \\LkJsoM1gH/45sKHkgEGfSdGAv51D07ROMF86YkGPVpdj4Bu5ZuYTIdAv8wApGiyz
        \\dNGpJupbLmg5edVt8GrvAupaED9bgThzq+VFJZ7AebJ97BWLAs2y7IJXAoGBAJ04
        \\bGKWOp/oUKdfX9gGZuUw2FoQBWmGJ3Q0BqXwqzqPL7lQ7CtoZ0xwZnHIqQXCukX/
        \\OzA/1jfAs65FazVMQ9CLF3aDRRMDi2RZzwHNi+OpISF20KtQ81DfgWtNzKr5If4Y
        \\I020KJE+GjXtWdBZfXmCozLAXBm+bKEtssmvhPABAoGBANDJ30MdI0lmSTgYPgvP
        \\bp9PI2AWQOZmmhU6TtLDmxLfZr2kk2hVRUfop5/bzPh0GEr/DoF5h3JqOBZuuJpU
        \\enws4taw/9k2BgloXG9D6D6PMWUML7Lxc+S8FtCCIM2M71ipUaiJceo2WJM8w7XZ
        \\nR3qL4xUiXkkxdi8PEZviU8I
        \\-----END PRIVATE KEY-----
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Parse valid PKCS#8 RSA-2048 PEM
    const parts = try parsePkcs8RsaPem(a, test_rsa2048_pkcs8_pem);
    try std.testing.expectEqual(@as(usize, 256), parts.n.len);
    try std.testing.expectEqual(@as(usize, 128), parts.p.len);
    try std.testing.expectEqual(@as(usize, 128), parts.q.len);

    // 2. Sign GCP service account JWT assertion and inspect header, claims, and RSA signature
    const sa_email = "concave-runner@prod-proj-1.iam.gserviceaccount.com";
    const token_uri = "https://oauth2.googleapis.com/token";
    const now_secs: i64 = 1_700_000_000;
    const jwt = try signServiceAccountJwt(a, sa_email, token_uri, test_rsa2048_pkcs8_pem, now_secs);

    var segs = std.mem.splitScalar(u8, jwt, '.');
    const hdr_b64 = segs.next() orelse return error.TestUnexpectedResult;
    const pay_b64 = segs.next() orelse return error.TestUnexpectedResult;
    const sig_b64 = segs.next() orelse return error.TestUnexpectedResult;
    try std.testing.expect(segs.next() == null);

    // Verify JWT header
    const hdr_bytes = try decodeStandardOrUrlBase64(a, hdr_b64);
    try std.testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", hdr_bytes);

    // Verify JWT claims
    const pay_bytes = try decodeStandardOrUrlBase64(a, pay_b64);
    const pay_val = try std.json.parseFromSliceLeaky(std.json.Value, a, pay_bytes, .{});
    try std.testing.expect(pay_val == .object);
    try std.testing.expectEqualStrings(sa_email, pay_val.object.get("iss").?.string);
    try std.testing.expectEqualStrings(GCP_CLOUD_PLATFORM_SCOPE, pay_val.object.get("scope").?.string);
    try std.testing.expectEqualStrings(token_uri, pay_val.object.get("aud").?.string);
    try std.testing.expectEqual(now_secs, pay_val.object.get("iat").?.integer);
    try std.testing.expectEqual(now_secs + 3600, pay_val.object.get("exp").?.integer);

    // Mathematically verify RS256 signature: sig^65537 mod n == RFC 8017 PKCS#1 v1.5 EM
    const sig_bytes = try decodeStandardOrUrlBase64(a, sig_b64);
    try std.testing.expectEqual(@as(usize, 256), sig_bytes.len);

    const signing_input = jwt[0 .. hdr_b64.len + 1 + pay_b64.len];
    var expected_digest: [32]u8 = undefined;
    Sha256.hash(signing_input, &expected_digest, .{});

    const digest_info_prefix = [_]u8{
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
        0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
        0x00, 0x04, 0x20,
    };
    var expected_em: [256]u8 = undefined;
    expected_em[0] = 0x00;
    expected_em[1] = 0x01;
    const ps_len = 256 - (digest_info_prefix.len + 32) - 3;
    @memset(expected_em[2 .. 2 + ps_len], 0xFF);
    expected_em[2 + ps_len] = 0x00;
    @memcpy(expected_em[3 + ps_len .. 3 + ps_len + digest_info_prefix.len], &digest_info_prefix);
    @memcpy(expected_em[3 + ps_len + digest_info_prefix.len ..], &expected_digest);

    var sig_int = try bigIntFromBeBytes(a, sig_bytes);
    var n_int = try bigIntFromBeBytes(a, parts.n);
    const pub_exp = [_]u8{ 0x01, 0x00, 0x01 }; // e = 65537
    var recovered_int = try bigIntModExp(a, &sig_int, &pub_exp, &n_int);
    var recovered_em: [256]u8 = undefined;
    try bigIntToBeBytesFixed(&recovered_int, &recovered_em);
    try std.testing.expectEqualSlices(u8, &expected_em, &recovered_em);

    // 3. Malformed PEM inputs MUST fail cleanly with error.GcpAuthFailed
    try std.testing.expectError(error.GcpAuthFailed, parsePkcs8RsaPem(a, ""));
    try std.testing.expectError(error.GcpAuthFailed, parsePkcs8RsaPem(a, "not a pem at all"));
    try std.testing.expectError(error.GcpAuthFailed, parsePkcs8RsaPem(a, "-----BEGIN PRIVATE KEY-----\n!!!invalid-base64!!!\n-----END PRIVATE KEY-----"));
    try std.testing.expectError(error.GcpAuthFailed, parsePkcs8RsaPem(a, "-----BEGIN PRIVATE KEY-----\nAQIDBA==\n-----END PRIVATE KEY-----"));
    // Truncated valid PEM
    try std.testing.expectError(error.GcpAuthFailed, parsePkcs8RsaPem(a, "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEF\n-----END PRIVATE KEY-----"));
}

test "secrets: encrypted vault wrong-passphrase rejection across all operations and AAD/nonce/tag/ciphertext tamper detection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const vault_path = ".zig-cache/test-secrets-vault-tamper.enc";
    std.Io.Dir.cwd().deleteFile(io, vault_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, vault_path) catch {};

    const pass = "correct-horse-battery-staple";
    try vaultSet(io, allocator, vault_path, pass, "API_SECRET", "top-secret-value-123");

    // Wrong passphrase MUST fail every vault operation (get, list, set, delete)
    try std.testing.expectError(error.VaultAuthFailed, vaultGet(io, allocator, vault_path, "wrong-passphrase", "API_SECRET"));
    try std.testing.expectError(error.VaultAuthFailed, vaultList(io, allocator, vault_path, "wrong-passphrase"));
    try std.testing.expectError(error.VaultAuthFailed, vaultSet(io, allocator, vault_path, "wrong-passphrase", "NEW_KEY", "v"));
    try std.testing.expectError(error.VaultAuthFailed, vaultDelete(io, allocator, vault_path, "wrong-passphrase", "API_SECRET"));
    // Empty/null passphrase MUST also fail when vault was encrypted with a passphrase
    try std.testing.expectError(error.VaultAuthFailed, vaultGet(io, allocator, vault_path, null, "API_SECRET"));

    const good_bytes = try std.Io.Dir.cwd().readFileAlloc(io, vault_path, allocator, .limited(64 * 1024));
    defer allocator.free(good_bytes);

    // Flipping 1 byte in salt (AAD), nonce, Poly1305 tag, OR ciphertext MUST fail with VaultAuthFailed
    const tamper_offsets = [_]usize{
        VAULT_MAGIC.len, // salt / AAD byte
        VAULT_MAGIC.len + VAULT_SALT_LEN, // nonce byte
        VAULT_MAGIC.len + VAULT_SALT_LEN + XChaCha20Poly1305.nonce_length, // tag byte
        VAULT_MAGIC.len + VAULT_SALT_LEN + XChaCha20Poly1305.nonce_length + XChaCha20Poly1305.tag_length, // first ciphertext byte
    };
    for (tamper_offsets) |off| {
        const mutated = try allocator.dupe(u8, good_bytes);
        defer allocator.free(mutated);
        mutated[off] ^= 0x80;
        try writeFileAtomic(allocator, io, vault_path, mutated);
        try std.testing.expectError(error.VaultAuthFailed, vaultGet(io, allocator, vault_path, pass, "API_SECRET"));
    }

    // Corrupting magic header or truncating below header size MUST fail with VaultCorrupted
    const bad_magic = try allocator.dupe(u8, good_bytes);
    defer allocator.free(bad_magic);
    bad_magic[0] = 'X';
    try writeFileAtomic(allocator, io, vault_path, bad_magic);
    try std.testing.expectError(error.VaultCorrupted, vaultGet(io, allocator, vault_path, pass, "API_SECRET"));

    try writeFileAtomic(allocator, io, vault_path, good_bytes[0..12]);
    try std.testing.expectError(error.VaultCorrupted, vaultGet(io, allocator, vault_path, pass, "API_SECRET"));
}
