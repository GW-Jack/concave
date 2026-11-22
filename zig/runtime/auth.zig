const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const rsa = std.crypto.Certificate.rsa;
const storage_mod = @import("../core/storage.zig");
const http_client = @import("http_client.zig");

pub const AuthIdentity = struct {
    subject: []u8,
    issuer: []u8,
    name: ?[]u8 = null,

    pub fn clone(self: *const AuthIdentity, allocator: Allocator) !AuthIdentity {
        const sub = try allocator.dupe(u8, self.subject);
        errdefer allocator.free(sub);
        const iss = try allocator.dupe(u8, self.issuer);
        errdefer allocator.free(iss);
        const nm = if (self.name) |n| try allocator.dupe(u8, n) else null;
        return .{ .subject = sub, .issuer = iss, .name = nm };
    }

    pub fn deinit(self: *const AuthIdentity, allocator: Allocator) void {
        allocator.free(self.subject);
        allocator.free(self.issuer);
        if (self.name) |n| allocator.free(n);
    }

    pub fn toJson(self: *const AuthIdentity, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"subject\":");
        try storage_mod.writeJsonString(w, self.subject);
        try w.writeAll(",\"issuer\":");
        try storage_mod.writeJsonString(w, self.issuer);
        try w.writeAll(",\"name\":");
        try storage_mod.writeJsonString(w, self.name orelse self.subject);
        try w.writeByte('}');
        return try out.toOwnedSlice();
    }
};

pub const JwkKey = union(enum) {
    rsa: struct {
        n: []u8,
        e: []u8,
    },
    ed25519: [32]u8,
    es256: [65]u8, // uncompressed SEC1: 0x04 || x(32) || y(32)

    pub fn clone(self: *const JwkKey, allocator: Allocator) !JwkKey {
        return switch (self.*) {
            .rsa => |r| .{ .rsa = .{
                .n = try allocator.dupe(u8, r.n),
                .e = try allocator.dupe(u8, r.e),
            } },
            .ed25519 => |b| .{ .ed25519 = b },
            .es256 => |b| .{ .es256 = b },
        };
    }

    pub fn deinit(self: *const JwkKey, allocator: Allocator) void {
        switch (self.*) {
            .rsa => |r| {
                allocator.free(r.n);
                allocator.free(r.e);
            },
            .ed25519, .es256 => {},
        }
    }
};

pub const JwkEntry = struct {
    kid: ?[]u8 = null,
    key: JwkKey,

    pub fn deinit(self: *const JwkEntry, allocator: Allocator) void {
        if (self.kid) |k| allocator.free(k);
        self.key.deinit(allocator);
    }
};

/// Thread-safe JWKS cache supporting static JSON (`CONCAVE_JWKS_JSON`) and live HTTPS/HTTP
/// endpoint fetching (`CONCAVE_JWKS_URL`) with automatic `kid`-miss key rotation refresh.
pub const JwksCache = struct {
    allocator: Allocator,
    mutex: std.Io.Mutex = .init,
    jwks_url: ?[]u8 = null,
    keys: std.ArrayList(JwkEntry) = .empty,
    last_fetch_ms: i64 = 0,
    ttl_ms: i64 = 5 * 60 * 1000,
    min_refresh_interval_ms: i64 = 1_000,

    pub fn init(allocator: Allocator, jwks_url: ?[]const u8, static_jwks_json: ?[]const u8) !*JwksCache {
        const self = try allocator.create(JwksCache);
        errdefer allocator.destroy(self);
        const owned_url = if (jwks_url) |u| try allocator.dupe(u8, u) else null;
        errdefer if (owned_url) |u| allocator.free(u);

        self.* = .{
            .allocator = allocator,
            .jwks_url = owned_url,
        };
        if (static_jwks_json) |raw| {
            try self.loadFromJsonLocked(raw);
        }
        return self;
    }

    pub fn deinit(self: *JwksCache) void {
        for (self.keys.items) |*k| k.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        if (self.jwks_url) |u| self.allocator.free(u);
        self.allocator.destroy(self);
    }

    pub fn loadFromJson(self: *JwksCache, io: std.Io, json_bytes: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.loadFromJsonLocked(json_bytes);
        self.last_fetch_ms = storage_mod.nowMillis(io);
    }

    fn loadFromJsonLocked(self: *JwksCache, json_bytes: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json_bytes, .{}) catch return error.InvalidJwks;
        if (parsed != .object) return error.InvalidJwks;
        const keys_v = parsed.object.get("keys") orelse return error.InvalidJwks;
        if (keys_v != .array) return error.InvalidJwks;

        var next_keys: std.ArrayList(JwkEntry) = .empty;
        errdefer {
            for (next_keys.items) |*k| k.deinit(self.allocator);
            next_keys.deinit(self.allocator);
        }

        for (keys_v.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const kty_v = obj.get("kty") orelse continue;
            if (kty_v != .string) continue;
            const kty = kty_v.string;

            const kid: ?[]u8 = if (obj.get("kid")) |kv|
                (if (kv == .string and kv.string.len > 0) try self.allocator.dupe(u8, kv.string) else null)
            else
                null;
            errdefer if (kid) |k| self.allocator.free(k);

            if (std.mem.eql(u8, kty, "RSA")) {
                const n_b64 = getStrField(obj, "n") orelse {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                const e_b64 = getStrField(obj, "e") orelse {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                const n_raw = decodeBase64Url(a, n_b64) catch {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                const e_raw = decodeBase64Url(a, e_b64) catch {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                // Strip leading 0x00 sign byte if present.
                var n_slice = n_raw;
                while (n_slice.len > 1 and n_slice[0] == 0) n_slice = n_slice[1..];
                var e_slice = e_raw;
                while (e_slice.len > 1 and e_slice[0] == 0) e_slice = e_slice[1..];
                try next_keys.append(self.allocator, .{
                    .kid = kid,
                    .key = .{ .rsa = .{
                        .n = try self.allocator.dupe(u8, n_slice),
                        .e = try self.allocator.dupe(u8, e_slice),
                    } },
                });
            } else if (std.mem.eql(u8, kty, "OKP")) {
                const crv = getStrField(obj, "crv") orelse {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                if (!std.mem.eql(u8, crv, "Ed25519")) {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                }
                const x_b64 = getStrField(obj, "x") orelse {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                const x_raw = decodeBase64Url(a, x_b64) catch {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                if (x_raw.len != 32) {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                }
                var pk: [32]u8 = undefined;
                @memcpy(&pk, x_raw);
                try next_keys.append(self.allocator, .{
                    .kid = kid,
                    .key = .{ .ed25519 = pk },
                });
            } else if (std.mem.eql(u8, kty, "EC")) {
                const crv = getStrField(obj, "crv") orelse {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                if (!std.mem.eql(u8, crv, "P-256")) {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                }
                const x_b64 = getStrField(obj, "x") orelse {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                const y_b64 = getStrField(obj, "y") orelse {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                const x_raw = decodeBase64Url(a, x_b64) catch {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                const y_raw = decodeBase64Url(a, y_b64) catch {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                };
                if (x_raw.len != 32 or y_raw.len != 32) {
                    if (kid) |k| self.allocator.free(k);
                    continue;
                }
                var sec1: [65]u8 = undefined;
                sec1[0] = 0x04;
                @memcpy(sec1[1..33], x_raw);
                @memcpy(sec1[33..65], y_raw);
                try next_keys.append(self.allocator, .{
                    .kid = kid,
                    .key = .{ .es256 = sec1 },
                });
            } else {
                if (kid) |k| self.allocator.free(k);
            }
        }

        for (self.keys.items) |*old| old.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.keys = next_keys;
    }

    pub fn lookupKey(
        self: *JwksCache,
        allocator: Allocator,
        io: std.Io,
        kid: ?[]const u8,
        wanted: std.meta.Tag(JwkKey),
    ) !?JwkKey {
        const now = storage_mod.nowMillis(io);

        // Fast path: check cached keys if fresh.
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const is_fresh = self.jwks_url == null or (self.last_fetch_ms > 0 and now - self.last_fetch_ms < self.ttl_ms);
            if (is_fresh) {
                if (self.findMatchingLocked(kid, wanted)) |found| {
                    return try found.clone(allocator);
                }
            }
        }

        // Slow path: refresh from `jwks_url` if configured and not rate-limited.
        const url_copy: ?[]u8 = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const u = self.jwks_url orelse break :blk null;
            if (self.last_fetch_ms > 0 and now - self.last_fetch_ms < self.min_refresh_interval_ms) {
                // Too soon to re-fetch; return cached match if any.
                if (self.findMatchingLocked(kid, wanted)) |found| {
                    return try found.clone(allocator);
                }
                break :blk null;
            }
            break :blk try self.allocator.dupe(u8, u);
        };

        if (url_copy) |url| {
            defer self.allocator.free(url);
            const resp = http_client.fetch(self.allocator, io, .{
                .method = "GET",
                .url = url,
            }) catch null;
            if (resp) |r| {
                defer r.deinit(self.allocator);
                if (r.status >= 200 and r.status < 300) {
                    self.mutex.lockUncancelable(io);
                    defer self.mutex.unlock(io);
                    self.loadFromJsonLocked(r.body) catch {};
                    self.last_fetch_ms = storage_mod.nowMillis(io);
                    if (self.findMatchingLocked(kid, wanted)) |found| {
                        return try found.clone(allocator);
                    }
                    return null;
                }
            }
        }

        // Fallback to cached keys if network refresh failed.
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.findMatchingLocked(kid, wanted)) |found| {
            return try found.clone(allocator);
        }
        return null;
    }

    fn findMatchingLocked(self: *const JwksCache, kid: ?[]const u8, wanted: std.meta.Tag(JwkKey)) ?*const JwkKey {
        if (kid) |want_kid| {
            for (self.keys.items) |*entry| {
                if (std.meta.activeTag(entry.key) != wanted) continue;
                if (entry.kid) |ek| {
                    if (std.mem.eql(u8, ek, want_kid)) return &entry.key;
                }
            }
            return null;
        }
        // No `kid` in JWT header: pick first key of matching type.
        for (self.keys.items) |*entry| {
            if (std.meta.activeTag(entry.key) == wanted) return &entry.key;
        }
        return null;
    }
};

pub const AuthConfig = struct {
    jwt_secret: ?[]const u8 = null,
    jwks_cache: ?*JwksCache = null,
    expected_issuer: ?[]const u8 = null,
    expected_audience: ?[]const u8 = null,
    allow_dev_tokens: bool = true,
};

pub const AuthError = error{
    EmptyToken,
    DevTokensDisabled,
    InvalidDevToken,
    JwtNotConfigured,
    MalformedJwt,
    UnsupportedAlg,
    KeyNotFound,
    InvalidSignature,
    ExpiredToken,
    NotYetValid,
    InvalidIssuer,
    InvalidAudience,
    MissingSubject,
    OutOfMemory,
};

pub fn verifyToken(
    allocator: Allocator,
    io: std.Io,
    config: AuthConfig,
    raw_token: []const u8,
) AuthError!AuthIdentity {
    var tok = std.mem.trim(u8, raw_token, " \t\r\n");
    if (std.mem.startsWith(u8, tok, "Bearer ")) {
        tok = std.mem.trim(u8, tok["Bearer ".len..], " \t\r\n");
    }
    if (tok.len == 0) return error.EmptyToken;

    if (std.mem.startsWith(u8, tok, "dev:")) {
        if (!config.allow_dev_tokens) return error.DevTokensDisabled;
        const rest = tok["dev:".len..];
        var subject: []const u8 = rest;
        var name: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, ':')) |ci| {
            subject = std.mem.trim(u8, rest[0..ci], " \t");
            const n = std.mem.trim(u8, rest[ci + 1 ..], " \t");
            if (n.len > 0) name = n;
        } else {
            subject = std.mem.trim(u8, rest, " \t");
        }
        if (subject.len == 0) return error.InvalidDevToken;
        return .{
            .subject = try allocator.dupe(u8, subject),
            .issuer = try allocator.dupe(u8, "concave:dev"),
            .name = try allocator.dupe(u8, name orelse subject),
        };
    }

    if (config.jwt_secret == null and config.jwks_cache == null) {
        return error.JwtNotConfigured;
    }
    return verifyJwt(allocator, io, config, tok);
}

fn verifyJwt(allocator: Allocator, io: std.Io, config: AuthConfig, token: []const u8) AuthError!AuthIdentity {
    var parts = std.mem.splitScalar(u8, token, '.');
    const p0 = parts.next() orelse return error.MalformedJwt;
    const p1 = parts.next() orelse return error.MalformedJwt;
    const p2 = parts.next() orelse return error.MalformedJwt;
    if (parts.next() != null) return error.MalformedJwt;

    const signing_input = token[0 .. p0.len + 1 + p1.len];

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Decode JWT header
    const hdr_bytes = decodeBase64Url(a, p0) catch return error.MalformedJwt;
    const hdr_val = std.json.parseFromSliceLeaky(std.json.Value, a, hdr_bytes, .{}) catch return error.MalformedJwt;
    if (hdr_val != .object) return error.MalformedJwt;
    const alg_v = hdr_val.object.get("alg") orelse return error.UnsupportedAlg;
    if (alg_v != .string) return error.UnsupportedAlg;
    const alg = alg_v.string;
    const kid: ?[]const u8 = getStrField(hdr_val.object, "kid");

    const sig_bytes = decodeBase64Url(a, p2) catch return error.InvalidSignature;

    if (std.mem.eql(u8, alg, "HS256")) {
        const secret = config.jwt_secret orelse return error.UnsupportedAlg;
        if (sig_bytes.len != 32) return error.InvalidSignature;
        var provided_sig: [32]u8 = undefined;
        @memcpy(&provided_sig, sig_bytes);

        var mac = HmacSha256.init(secret);
        mac.update(signing_input);
        var expected_sig: [32]u8 = undefined;
        mac.final(&expected_sig);

        if (!std.crypto.timing_safe.eql([32]u8, provided_sig, expected_sig)) {
            return error.InvalidSignature;
        }
    } else if (std.mem.eql(u8, alg, "RS256")) {
        const cache = config.jwks_cache orelse return error.UnsupportedAlg;
        const jwk = (cache.lookupKey(a, io, kid, .rsa) catch return error.KeyNotFound) orelse return error.KeyNotFound;
        const r = jwk.rsa;
        if (sig_bytes.len != r.n.len) return error.InvalidSignature;
        switch (r.n.len) {
            inline 128, 256, 384, 512 => |mod_len| {
                const pub_key = rsa.PublicKey.fromBytes(r.e, r.n) catch return error.InvalidSignature;
                rsa.PKCS1v1_5Signature.verify(mod_len, sig_bytes[0..mod_len], signing_input, pub_key, Sha256) catch
                    return error.InvalidSignature;
            },
            else => return error.InvalidSignature,
        }
    } else if (std.mem.eql(u8, alg, "EdDSA")) {
        const cache = config.jwks_cache orelse return error.UnsupportedAlg;
        const jwk = (cache.lookupKey(a, io, kid, .ed25519) catch return error.KeyNotFound) orelse return error.KeyNotFound;
        if (sig_bytes.len != Ed25519.Signature.encoded_length) return error.InvalidSignature;
        var sig_arr: [Ed25519.Signature.encoded_length]u8 = undefined;
        @memcpy(&sig_arr, sig_bytes);
        const sig = Ed25519.Signature.fromBytes(sig_arr);
        const pub_key = Ed25519.PublicKey.fromBytes(jwk.ed25519) catch return error.InvalidSignature;
        sig.verify(signing_input, pub_key) catch return error.InvalidSignature;
    } else if (std.mem.eql(u8, alg, "ES256")) {
        const cache = config.jwks_cache orelse return error.UnsupportedAlg;
        const jwk = (cache.lookupKey(a, io, kid, .es256) catch return error.KeyNotFound) orelse return error.KeyNotFound;
        if (sig_bytes.len != EcdsaP256.Signature.encoded_length) return error.InvalidSignature;
        var sig_arr: [EcdsaP256.Signature.encoded_length]u8 = undefined;
        @memcpy(&sig_arr, sig_bytes);
        const sig = EcdsaP256.Signature.fromBytes(sig_arr);
        const pub_key = EcdsaP256.PublicKey.fromSec1(&jwk.es256) catch return error.InvalidSignature;
        sig.verify(signing_input, pub_key) catch return error.InvalidSignature;
    } else {
        return error.UnsupportedAlg;
    }

    // Decode & validate claims payload
    const pay_bytes = decodeBase64Url(a, p1) catch return error.MalformedJwt;
    const claims = std.json.parseFromSliceLeaky(std.json.Value, a, pay_bytes, .{}) catch return error.MalformedJwt;
    if (claims != .object) return error.MalformedJwt;

    const now_secs = @divTrunc(storage_mod.nowMillis(io), 1000);

    if (claims.object.get("exp")) |exp_v| {
        const exp_secs: i64 = switch (exp_v) {
            .integer => |i| i,
            else => return error.MalformedJwt,
        };
        if (now_secs >= exp_secs) return error.ExpiredToken;
    }

    if (claims.object.get("nbf")) |nbf_v| {
        const nbf_secs: i64 = switch (nbf_v) {
            .integer => |i| i,
            else => return error.MalformedJwt,
        };
        if (now_secs < nbf_secs) return error.NotYetValid;
    }

    const iss_str = if (claims.object.get("iss")) |iv| (if (iv == .string) iv.string else "jwt") else "jwt";
    if (config.expected_issuer) |want_iss| {
        if (!std.mem.eql(u8, iss_str, want_iss)) return error.InvalidIssuer;
    }

    if (config.expected_audience) |want_aud| {
        const aud_v = claims.object.get("aud") orelse return error.InvalidAudience;
        var aud_ok = false;
        switch (aud_v) {
            .string => |s| aud_ok = std.mem.eql(u8, s, want_aud),
            .array => |arr| {
                for (arr.items) |elem| {
                    if (elem == .string and std.mem.eql(u8, elem.string, want_aud)) {
                        aud_ok = true;
                        break;
                    }
                }
            },
            else => {},
        }
        if (!aud_ok) return error.InvalidAudience;
    }

    const sub_v = claims.object.get("sub") orelse return error.MissingSubject;
    if (sub_v != .string or sub_v.string.len == 0) return error.MissingSubject;

    const name_str: ?[]const u8 = if (claims.object.get("name")) |nv| (if (nv == .string) nv.string else null) else null;

    return .{
        .subject = try allocator.dupe(u8, sub_v.string),
        .issuer = try allocator.dupe(u8, iss_str),
        .name = if (name_str) |n| try allocator.dupe(u8, n) else null,
    };
}

fn getStrField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn decodeBase64Url(allocator: Allocator, b64: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, b64, "=");
    const len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try std.base64.url_safe_no_pad.Decoder.decode(out, trimmed);
    return out;
}

test "verifies dev token, HS256, EdDSA (Ed25519), and ES256 (P-256) JWKS JWTs + rejects tampering" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 1. Dev token
    const dev_id = try verifyToken(allocator, io, .{ .allow_dev_tokens = true }, "Bearer dev:alice:Alice Smith");
    defer dev_id.deinit(allocator);
    try std.testing.expectEqualStrings("alice", dev_id.subject);
    try std.testing.expectEqualStrings("Alice Smith", dev_id.name.?);

    // 2. HS256 JWT
    const secret = "super-secret-key";
    const hdr_raw = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const pay_raw = "{\"sub\":\"u123\",\"iss\":\"test-idp\",\"name\":\"Bob\"}";
    var hdr_buf: [64]u8 = undefined;
    var pay_buf: [128]u8 = undefined;
    const hdr_b64 = std.base64.url_safe_no_pad.Encoder.encode(&hdr_buf, hdr_raw);
    const pay_b64 = std.base64.url_safe_no_pad.Encoder.encode(&pay_buf, pay_raw);

    var mac = HmacSha256.init(secret);
    mac.update(hdr_b64);
    mac.update(".");
    mac.update(pay_b64);
    var sig: [32]u8 = undefined;
    mac.final(&sig);
    var sig_buf: [64]u8 = undefined;
    const sig_b64 = std.base64.url_safe_no_pad.Encoder.encode(&sig_buf, &sig);

    const jwt = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ hdr_b64, pay_b64, sig_b64 });
    defer allocator.free(jwt);

    const jwt_id = try verifyToken(allocator, io, .{ .jwt_secret = secret, .allow_dev_tokens = false }, jwt);
    defer jwt_id.deinit(allocator);
    try std.testing.expectEqualStrings("u123", jwt_id.subject);
    try std.testing.expectEqualStrings("test-idp", jwt_id.issuer);
    try std.testing.expectEqualStrings("Bob", jwt_id.name.?);

    // 3. EdDSA (Ed25519) via JWKS + iss/aud checks
    const ed_kp = Ed25519.KeyPair.generate(io);
    var ed_x_buf: [64]u8 = undefined;
    const ed_x_b64 = std.base64.url_safe_no_pad.Encoder.encode(&ed_x_buf, &ed_kp.public_key.bytes);

    // 4. ES256 (P-256) via JWKS
    const ec_kp = EcdsaP256.KeyPair.generate(io);
    const ec_sec1 = ec_kp.public_key.toUncompressedSec1();
    var ec_x_buf: [64]u8 = undefined;
    var ec_y_buf: [64]u8 = undefined;
    const ec_x_b64 = std.base64.url_safe_no_pad.Encoder.encode(&ec_x_buf, ec_sec1[1..33]);
    const ec_y_b64 = std.base64.url_safe_no_pad.Encoder.encode(&ec_y_buf, ec_sec1[33..65]);

    const jwks_json = try std.fmt.allocPrint(
        allocator,
        "{{\"keys\":[{{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"kid\":\"ed-k1\",\"x\":\"{s}\"}},{{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"ec-k1\",\"x\":\"{s}\",\"y\":\"{s}\"}}]}}",
        .{ ed_x_b64, ec_x_b64, ec_y_b64 },
    );
    defer allocator.free(jwks_json);

    const cache = try JwksCache.init(allocator, null, jwks_json);
    defer cache.deinit();

    // Sign & verify EdDSA JWT
    const ed_hdr = "{\"alg\":\"EdDSA\",\"kid\":\"ed-k1\"}";
    const ed_pay = "{\"sub\":\"ed-user\",\"iss\":\"https://auth.concave.dev\",\"aud\":[\"concave-api\"],\"name\":\"Ed\"}";
    var eh_buf: [64]u8 = undefined;
    var ep_buf: [256]u8 = undefined;
    const eh_b64 = std.base64.url_safe_no_pad.Encoder.encode(&eh_buf, ed_hdr);
    const ep_b64 = std.base64.url_safe_no_pad.Encoder.encode(&ep_buf, ed_pay);
    const ed_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ eh_b64, ep_b64 });
    defer allocator.free(ed_input);
    const ed_sig = try ed_kp.sign(ed_input, null);
    var es_buf: [128]u8 = undefined;
    const es_b64 = std.base64.url_safe_no_pad.Encoder.encode(&es_buf, &ed_sig.toBytes());
    const ed_jwt = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ed_input, es_b64 });
    defer allocator.free(ed_jwt);

    const ed_id = try verifyToken(allocator, io, .{
        .jwks_cache = cache,
        .expected_issuer = "https://auth.concave.dev",
        .expected_audience = "concave-api",
        .allow_dev_tokens = false,
    }, ed_jwt);
    defer ed_id.deinit(allocator);
    try std.testing.expectEqualStrings("ed-user", ed_id.subject);

    // Wrong audience MUST fail
    try std.testing.expectError(error.InvalidAudience, verifyToken(allocator, io, .{
        .jwks_cache = cache,
        .expected_audience = "wrong-aud",
        .allow_dev_tokens = false,
    }, ed_jwt));

    // Tampered EdDSA JWT MUST fail
    const bad_ed = try allocator.dupe(u8, ed_jwt);
    defer allocator.free(bad_ed);
    bad_ed[bad_ed.len - 2] = if (bad_ed[bad_ed.len - 2] == 'A') 'B' else 'A';
    try std.testing.expectError(error.InvalidSignature, verifyToken(allocator, io, .{
        .jwks_cache = cache,
        .allow_dev_tokens = false,
    }, bad_ed));

    // Sign & verify ES256 JWT
    const ec_hdr = "{\"alg\":\"ES256\",\"kid\":\"ec-k1\"}";
    const ec_pay = "{\"sub\":\"ec-user\",\"iss\":\"https://clerk.dev\",\"aud\":\"concave-app\"}";
    var ch_buf: [64]u8 = undefined;
    var cp_buf: [256]u8 = undefined;
    const ch_b64 = std.base64.url_safe_no_pad.Encoder.encode(&ch_buf, ec_hdr);
    const cp_b64 = std.base64.url_safe_no_pad.Encoder.encode(&cp_buf, ec_pay);
    const ec_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ch_b64, cp_b64 });
    defer allocator.free(ec_input);
    const ec_sig = try ec_kp.sign(ec_input, null);
    var cs_buf: [128]u8 = undefined;
    const cs_b64 = std.base64.url_safe_no_pad.Encoder.encode(&cs_buf, &ec_sig.toBytes());
    const ec_jwt = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ec_input, cs_b64 });
    defer allocator.free(ec_jwt);

    const ec_id = try verifyToken(allocator, io, .{
        .jwks_cache = cache,
        .expected_issuer = "https://clerk.dev",
        .expected_audience = "concave-app",
        .allow_dev_tokens = false,
    }, ec_jwt);
    defer ec_id.deinit(allocator);
    try std.testing.expectEqualStrings("ec-user", ec_id.subject);
}
