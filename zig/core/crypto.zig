const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Ed25519 = std.crypto.sign.Ed25519;
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const argon2 = std.crypto.pwhash.argon2;
const storage_mod = @import("storage.zig");

pub const CryptoError = error{
    InvalidJson,
    MissingField,
    InvalidField,
    UnsupportedOp,
    InvalidKey,
    InvalidLength,
    InvalidCiphertext,
    AuthenticationFailed,
    PasswordHashFailed,
    SigningFailed,
    OutOfMemory,
};

/// Execute a JSON-encoded host crypto request and return a JSON-encoded response value.
pub fn executeOpJson(allocator: Allocator, io: std.Io, req_json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, req_json, .{}) catch return error.InvalidJson;
    if (parsed != .object) return error.InvalidJson;
    const obj = parsed.object;

    const op = try getReqStr(obj, "op");

    if (std.mem.eql(u8, op, "random_bytes")) {
        return try opRandomBytes(allocator, io, obj);
    }
    if (std.mem.eql(u8, op, "sha256")) {
        return try opSha256(allocator, obj);
    }
    if (std.mem.eql(u8, op, "hmac_sha256")) {
        return try opHmacSha256(allocator, obj);
    }
    if (std.mem.eql(u8, op, "ct_eq")) {
        return try opCtEq(allocator, obj);
    }
    if (std.mem.eql(u8, op, "hash_password")) {
        return try opHashPassword(allocator, io, obj);
    }
    if (std.mem.eql(u8, op, "verify_password")) {
        return try opVerifyPassword(allocator, io, obj);
    }
    if (std.mem.eql(u8, op, "ed25519_jwk")) {
        return try opEd25519Jwk(allocator, obj);
    }
    if (std.mem.eql(u8, op, "jwt_sign_ed25519")) {
        return try opJwtSignEd25519(allocator, a, obj);
    }
    if (std.mem.eql(u8, op, "aead_encrypt")) {
        return try opAeadEncrypt(allocator, io, obj);
    }
    if (std.mem.eql(u8, op, "aead_decrypt")) {
        return try opAeadDecrypt(allocator, a, obj);
    }
    return error.UnsupportedOp;
}

fn opRandomBytes(allocator: Allocator, io: std.Io, obj: std.json.ObjectMap) ![]u8 {
    const len_v = obj.get("len") orelse return error.MissingField;
    if (len_v != .integer) return error.InvalidField;
    if (len_v.integer < 1 or len_v.integer > 1024) return error.InvalidLength;
    const len: usize = @intCast(len_v.integer);

    var raw_buf: [1024]u8 = undefined;
    const raw = raw_buf[0..len];
    defer std.crypto.secureZero(u8, raw);
    io.random(raw);

    const enc_len = std.base64.url_safe_no_pad.Encoder.calcSize(len);
    const enc_buf = try allocator.alloc(u8, enc_len);
    defer {
        std.crypto.secureZero(u8, enc_buf);
        allocator.free(enc_buf);
    }
    const b64 = std.base64.url_safe_no_pad.Encoder.encode(enc_buf, raw);
    return try encodeJsonString(allocator, b64);
}

fn opSha256(allocator: Allocator, obj: std.json.ObjectMap) ![]u8 {
    const data = try getReqStr(obj, "data");
    const enc = getOptStr(obj, "encoding") orelse "hex";

    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});

    return try encodeDigestJson(allocator, &digest, enc);
}

fn opHmacSha256(allocator: Allocator, obj: std.json.ObjectMap) ![]u8 {
    const key = try getReqStr(obj, "key");
    const data = try getReqStr(obj, "data");
    const enc = getOptStr(obj, "encoding") orelse "hex";

    var mac = HmacSha256.init(key);
    mac.update(data);
    var digest: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    mac.final(&digest);

    return try encodeDigestJson(allocator, &digest, enc);
}

fn encodeDigestJson(allocator: Allocator, digest: *const [32]u8, encoding: []const u8) ![]u8 {
    if (std.mem.eql(u8, encoding, "hex")) {
        const hex = std.fmt.bytesToHex(digest.*, .lower);
        return try encodeJsonString(allocator, &hex);
    }
    if (std.mem.eql(u8, encoding, "base64url")) {
        var b64_buf: [64]u8 = undefined;
        const b64 = std.base64.url_safe_no_pad.Encoder.encode(&b64_buf, digest);
        return try encodeJsonString(allocator, b64);
    }
    return error.InvalidField;
}

fn opCtEq(allocator: Allocator, obj: std.json.ObjectMap) ![]u8 {
    const a_str = try getReqStr(obj, "a");
    const b_str = try getReqStr(obj, "b");
    const equal = constantTimeSliceEql(a_str, b_str);
    return try allocator.dupe(u8, if (equal) "true" else "false");
}

pub fn constantTimeSliceEql(a: []const u8, b: []const u8) bool {
    var ha: [32]u8 = undefined;
    var hb: [32]u8 = undefined;
    Sha256.hash(a, &ha, .{});
    Sha256.hash(b, &hb, .{});
    const hash_eq = std.crypto.timing_safe.eql([32]u8, ha, hb);
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |ca, cb| {
        diff |= ca ^ cb;
    }
    const byte_eq = std.crypto.timing_safe.eql([1]u8, .{diff}, .{0});
    return hash_eq and byte_eq;
}

fn opHashPassword(allocator: Allocator, io: std.Io, obj: std.json.ObjectMap) ![]u8 {
    const password = try getReqStr(obj, "password");
    if (password.len > 4096) return error.InvalidLength;

    var hash_buf: [256]u8 = undefined;
    const phc = argon2.strHash(password, .{
        .allocator = allocator,
        .params = .{ .t = 2, .m = 19456, .p = 1 },
        .mode = .argon2id,
    }, &hash_buf, io) catch return error.PasswordHashFailed;
    return try encodeJsonString(allocator, phc);
}

fn opVerifyPassword(allocator: Allocator, io: std.Io, obj: std.json.ObjectMap) ![]u8 {
    const password = try getReqStr(obj, "password");
    const hash = try getReqStr(obj, "hash");
    if (password.len > 4096 or hash.len > 512) return error.InvalidLength;

    const ok = blk: {
        argon2.strVerify(hash, password, .{ .allocator = allocator }, io) catch break :blk false;
        break :blk true;
    };
    return try allocator.dupe(u8, if (ok) "true" else "false");
}

fn opEd25519Jwk(allocator: Allocator, obj: std.json.ObjectMap) ![]u8 {
    const seed_str = try getReqStr(obj, "seed");
    const kid = getOptStr(obj, "kid") orelse "";

    var seed = try decodeKey32(seed_str);
    defer std.crypto.secureZero(u8, &seed);

    var kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidKey;
    defer std.crypto.secureZero(u8, &kp.secret_key.bytes);

    var x_buf: [64]u8 = undefined;
    const x_b64 = std.base64.url_safe_no_pad.Encoder.encode(&x_buf, &kp.public_key.bytes);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"kty\":\"OKP\",\"crv\":\"Ed25519\",\"alg\":\"EdDSA\",\"use\":\"sig\",\"kid\":");
    try storage_mod.writeJsonString(w, kid);
    try w.writeAll(",\"x\":");
    try storage_mod.writeJsonString(w, x_b64);
    try w.writeByte('}');
    return try out.toOwnedSlice();
}

fn opJwtSignEd25519(allocator: Allocator, arena_alloc: Allocator, obj: std.json.ObjectMap) ![]u8 {
    const seed_str = try getReqStr(obj, "seed");
    const kid = getOptStr(obj, "kid") orelse "";
    const claims_v = obj.get("claims") orelse return error.MissingField;

    var seed = try decodeKey32(seed_str);
    defer std.crypto.secureZero(u8, &seed);

    var kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidKey;
    defer std.crypto.secureZero(u8, &kp.secret_key.bytes);

    // Encode header JSON: {"alg":"EdDSA","typ":"JWT","kid":"..."}
    var hdr_out: std.Io.Writer.Allocating = .init(arena_alloc);
    try hdr_out.writer.writeAll("{\"alg\":\"EdDSA\",\"typ\":\"JWT\"");
    if (kid.len > 0) {
        try hdr_out.writer.writeAll(",\"kid\":");
        try storage_mod.writeJsonString(&hdr_out.writer, kid);
    }
    try hdr_out.writer.writeByte('}');
    const hdr_json = hdr_out.written();

    // Encode claims JSON (accept JSON object or JSON object string)
    var pay_out: std.Io.Writer.Allocating = .init(arena_alloc);
    switch (claims_v) {
        .object => try writeJsonValue(&pay_out.writer, claims_v),
        .string => |s| {
            const parsed_claims = std.json.parseFromSliceLeaky(std.json.Value, arena_alloc, s, .{}) catch return error.InvalidField;
            if (parsed_claims != .object) return error.InvalidField;
            try writeJsonValue(&pay_out.writer, parsed_claims);
        },
        else => return error.InvalidField,
    }
    const pay_json = pay_out.written();

    const hdr_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(hdr_json.len);
    const pay_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(pay_json.len);
    const signing_input = try arena_alloc.alloc(u8, hdr_b64_len + 1 + pay_b64_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(signing_input[0..hdr_b64_len], hdr_json);
    signing_input[hdr_b64_len] = '.';
    _ = std.base64.url_safe_no_pad.Encoder.encode(signing_input[hdr_b64_len + 1 ..], pay_json);

    const sig = kp.sign(signing_input, null) catch return error.SigningFailed;
    var sig_b64_buf: [128]u8 = undefined;
    const sig_b64 = std.base64.url_safe_no_pad.Encoder.encode(&sig_b64_buf, &sig.toBytes());

    const jwt = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ signing_input, sig_b64 });
    return try encodeJsonString(allocator, jwt);
}

fn opAeadEncrypt(allocator: Allocator, io: std.Io, obj: std.json.ObjectMap) ![]u8 {
    const key_str = try getReqStr(obj, "key");
    const plaintext = try getReqStr(obj, "plaintext");
    const aad = getOptStr(obj, "aad") orelse "";

    var key = try decodeKey32(key_str);
    defer std.crypto.secureZero(u8, &key);

    var nonce: [XChaCha20Poly1305.nonce_length]u8 = undefined;
    io.random(&nonce);

    const ct_and_tag = try allocator.alloc(u8, plaintext.len + XChaCha20Poly1305.tag_length);
    defer allocator.free(ct_and_tag);

    var tag: [XChaCha20Poly1305.tag_length]u8 = undefined;
    XChaCha20Poly1305.encrypt(ct_and_tag[0..plaintext.len], &tag, plaintext, aad, nonce, key);
    @memcpy(ct_and_tag[plaintext.len..], &tag);

    var nonce_b64_buf: [64]u8 = undefined;
    const nonce_b64 = std.base64.url_safe_no_pad.Encoder.encode(&nonce_b64_buf, &nonce);

    const ct_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(ct_and_tag.len);
    const ct_b64_buf = try allocator.alloc(u8, ct_b64_len);
    defer allocator.free(ct_b64_buf);
    const ct_b64 = std.base64.url_safe_no_pad.Encoder.encode(ct_b64_buf, ct_and_tag);

    const token = try std.fmt.allocPrint(allocator, "v1.{s}.{s}", .{ nonce_b64, ct_b64 });
    defer allocator.free(token);
    return try encodeJsonString(allocator, token);
}

fn opAeadDecrypt(allocator: Allocator, arena_alloc: Allocator, obj: std.json.ObjectMap) ![]u8 {
    const key_str = try getReqStr(obj, "key");
    const ciphertext = try getReqStr(obj, "ciphertext");
    const aad = getOptStr(obj, "aad") orelse "";

    var key = try decodeKey32(key_str);
    defer std.crypto.secureZero(u8, &key);

    var parts = std.mem.splitScalar(u8, ciphertext, '.');
    const ver = parts.next() orelse return error.InvalidCiphertext;
    const nonce_b64 = parts.next() orelse return error.InvalidCiphertext;
    const ct_tag_b64 = parts.next() orelse return error.InvalidCiphertext;
    if (parts.next() != null or !std.mem.eql(u8, ver, "v1")) return error.InvalidCiphertext;

    const nonce_raw = decodeBase64UrlAlloc(arena_alloc, nonce_b64) catch return error.InvalidCiphertext;
    if (nonce_raw.len != XChaCha20Poly1305.nonce_length) return error.InvalidCiphertext;
    var nonce: [XChaCha20Poly1305.nonce_length]u8 = undefined;
    @memcpy(&nonce, nonce_raw);

    const ct_tag = decodeBase64UrlAlloc(arena_alloc, ct_tag_b64) catch return error.InvalidCiphertext;
    if (ct_tag.len < XChaCha20Poly1305.tag_length) return error.InvalidCiphertext;
    const ct_len = ct_tag.len - XChaCha20Poly1305.tag_length;

    var tag: [XChaCha20Poly1305.tag_length]u8 = undefined;
    @memcpy(&tag, ct_tag[ct_len..]);

    const plaintext = try arena_alloc.alloc(u8, ct_len);
    defer std.crypto.secureZero(u8, plaintext);
    XChaCha20Poly1305.decrypt(plaintext, ct_tag[0..ct_len], tag, aad, nonce, key) catch return error.AuthenticationFailed;

    return try encodeJsonString(allocator, plaintext);
}

pub fn decodeKey32(raw: []const u8) ![32]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 64) {
        var hex_out: [32]u8 = undefined;
        if (std.fmt.hexToBytes(&hex_out, trimmed)) |slice| {
            if (slice.len == 32) return hex_out;
        } else |_| {}
    }
    const no_pad = std.mem.trimEnd(u8, trimmed, "=");
    if (std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(no_pad)) |sz| {
        if (sz == 32) {
            var b64_out: [32]u8 = undefined;
            if (std.base64.url_safe_no_pad.Decoder.decode(&b64_out, no_pad)) |_| {
                return b64_out;
            } else |_| {}
        }
    } else |_| {}
    // Standard base64 fallback
    if (std.base64.standard.Decoder.calcSizeForSlice(trimmed)) |sz| {
        if (sz == 32) {
            var std_out: [32]u8 = undefined;
            if (std.base64.standard.Decoder.decode(&std_out, trimmed)) |_| {
                return std_out;
            } else |_| {}
        }
    } else |_| {}
    return error.InvalidKey;
}

fn decodeBase64UrlAlloc(allocator: Allocator, b64: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, b64, "=");
    const len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed);
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    try std.base64.url_safe_no_pad.Decoder.decode(out, trimmed);
    return out;
}

fn getReqStr(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .string) return error.InvalidField;
    return v.string;
}

fn getOptStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn encodeJsonString(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try storage_mod.writeJsonString(&out.writer, s);
    return try out.toOwnedSlice();
}

fn writeJsonValue(w: *std.Io.Writer, val: std.json.Value) !void {
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try storage_mod.writeJsonString(w, s),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| {
                if (idx > 0) try w.writeByte(',');
                try storage_mod.writeJsonString(w, entry.key_ptr.*);
                try w.writeByte(':');
                try writeJsonValue(w, entry.value_ptr.*);
                idx += 1;
            }
            try w.writeByte('}');
        },
    }
}

test "crypto: random_bytes, sha256, hmac_sha256, ct_eq, argon2id, aead, ed25519_jwk + jwt_sign_ed25519 verified by auth" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const auth_mod = @import("../runtime/auth.zig");

    // 1. random_bytes
    const r1 = try executeOpJson(allocator, io, "{\"op\":\"random_bytes\",\"len\":32}");
    defer allocator.free(r1);
    const r2 = try executeOpJson(allocator, io, "{\"op\":\"random_bytes\",\"len\":32}");
    defer allocator.free(r2);
    try std.testing.expect(!std.mem.eql(u8, r1, r2));
    try std.testing.expect(r1[0] == '"' and r1[r1.len - 1] == '"');
    try std.testing.expectError(error.InvalidLength, executeOpJson(allocator, io, "{\"op\":\"random_bytes\",\"len\":0}"));
    try std.testing.expectError(error.InvalidLength, executeOpJson(allocator, io, "{\"op\":\"random_bytes\",\"len\":2048}"));

    // 2. sha256 (hex & base64url)
    const s_hex = try executeOpJson(allocator, io, "{\"op\":\"sha256\",\"data\":\"abc\"}");
    defer allocator.free(s_hex);
    try std.testing.expectEqualStrings(
        "\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"",
        s_hex,
    );
    const s_b64 = try executeOpJson(allocator, io, "{\"op\":\"sha256\",\"data\":\"abc\",\"encoding\":\"base64url\"}");
    defer allocator.free(s_b64);
    try std.testing.expectEqualStrings("\"ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0\"", s_b64);

    // 3. hmac_sha256
    const hm = try executeOpJson(allocator, io, "{\"op\":\"hmac_sha256\",\"key\":\"key\",\"data\":\"The quick brown fox jumps over the lazy dog\"}");
    defer allocator.free(hm);
    try std.testing.expectEqualStrings(
        "\"f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8\"",
        hm,
    );

    // 4. ct_eq
    const eq_true = try executeOpJson(allocator, io, "{\"op\":\"ct_eq\",\"a\":\"secret-123\",\"b\":\"secret-123\"}");
    defer allocator.free(eq_true);
    try std.testing.expectEqualStrings("true", eq_true);
    const eq_false = try executeOpJson(allocator, io, "{\"op\":\"ct_eq\",\"a\":\"secret-123\",\"b\":\"secret-124\"}");
    defer allocator.free(eq_false);
    try std.testing.expectEqualStrings("false", eq_false);
    const eq_len_false = try executeOpJson(allocator, io, "{\"op\":\"ct_eq\",\"a\":\"short\",\"b\":\"much-longer\"}");
    defer allocator.free(eq_len_false);
    try std.testing.expectEqualStrings("false", eq_len_false);

    // 5. hash_password & verify_password (Argon2id)
    const phc_json = try executeOpJson(allocator, io, "{\"op\":\"hash_password\",\"password\":\"correct horse battery staple\"}");
    defer allocator.free(phc_json);
    try std.testing.expect(std.mem.startsWith(u8, phc_json, "\"$argon2id$"));

    const verify_ok_req = try std.fmt.allocPrint(allocator, "{{\"op\":\"verify_password\",\"password\":\"correct horse battery staple\",\"hash\":{s}}}", .{phc_json});
    defer allocator.free(verify_ok_req);
    const verify_ok = try executeOpJson(allocator, io, verify_ok_req);
    defer allocator.free(verify_ok);
    try std.testing.expectEqualStrings("true", verify_ok);

    const verify_bad_req = try std.fmt.allocPrint(allocator, "{{\"op\":\"verify_password\",\"password\":\"wrong password\",\"hash\":{s}}}", .{phc_json});
    defer allocator.free(verify_bad_req);
    const verify_bad = try executeOpJson(allocator, io, verify_bad_req);
    defer allocator.free(verify_bad);
    try std.testing.expectEqualStrings("false", verify_bad);

    // 6. aead_encrypt & aead_decrypt (XChaCha20-Poly1305)
    const key_hex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
    const enc_req = try std.fmt.allocPrint(
        allocator,
        "{{\"op\":\"aead_encrypt\",\"key\":\"{s}\",\"plaintext\":\"top secret payload\",\"aad\":\"tenant-1\"}}",
        .{key_hex},
    );
    defer allocator.free(enc_req);
    const ct_json = try executeOpJson(allocator, io, enc_req);
    defer allocator.free(ct_json);
    try std.testing.expect(std.mem.startsWith(u8, ct_json, "\"v1."));

    const dec_req = try std.fmt.allocPrint(
        allocator,
        "{{\"op\":\"aead_decrypt\",\"key\":\"{s}\",\"ciphertext\":{s},\"aad\":\"tenant-1\"}}",
        .{ key_hex, ct_json },
    );
    defer allocator.free(dec_req);
    const pt_json = try executeOpJson(allocator, io, dec_req);
    defer allocator.free(pt_json);
    try std.testing.expectEqualStrings("\"top secret payload\"", pt_json);

    // Wrong AAD must fail authentication
    const bad_aad_req = try std.fmt.allocPrint(
        allocator,
        "{{\"op\":\"aead_decrypt\",\"key\":\"{s}\",\"ciphertext\":{s},\"aad\":\"tenant-2\"}}",
        .{ key_hex, ct_json },
    );
    defer allocator.free(bad_aad_req);
    try std.testing.expectError(error.AuthenticationFailed, executeOpJson(allocator, io, bad_aad_req));

    // 7. ed25519_jwk + jwt_sign_ed25519 verified end-to-end by auth.verifyToken!
    const seed_hex = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
    const jwk_req = try std.fmt.allocPrint(allocator, "{{\"op\":\"ed25519_jwk\",\"seed\":\"{s}\",\"kid\":\"auth-k1\"}}", .{seed_hex});
    defer allocator.free(jwk_req);
    const jwk_json = try executeOpJson(allocator, io, jwk_req);
    defer allocator.free(jwk_json);

    const jwks_json = try std.fmt.allocPrint(allocator, "{{\"keys\":[{s}]}}", .{jwk_json});
    defer allocator.free(jwks_json);
    const jwks_cache = try auth_mod.JwksCache.init(allocator, null, jwks_json);
    defer jwks_cache.deinit();

    const future_exp = @divTrunc(storage_mod.nowMillis(io), 1000) + 3600;
    const sign_req = try std.fmt.allocPrint(
        allocator,
        "{{\"op\":\"jwt_sign_ed25519\",\"seed\":\"{s}\",\"kid\":\"auth-k1\",\"claims\":{{\"sub\":\"usr_99\",\"iss\":\"concave-auth\",\"name\":\"Ada\",\"email\":\"ada@example.com\",\"email_verified\":true,\"sid\":\"s_777\",\"roles\":[\"member\"],\"exp\":{d}}}}}",
        .{ seed_hex, future_exp },
    );
    defer allocator.free(sign_req);
    const jwt_json_str = try executeOpJson(allocator, io, sign_req);
    defer allocator.free(jwt_json_str);
    // Unwrap JSON string quotes
    const jwt_raw = jwt_json_str[1 .. jwt_json_str.len - 1];

    const id = try auth_mod.verifyToken(allocator, io, .{
        .jwks_cache = jwks_cache,
        .expected_issuer = "concave-auth",
        .allow_dev_tokens = false,
    }, jwt_raw);
    defer id.deinit(allocator);
    try std.testing.expectEqualStrings("usr_99", id.subject);
    try std.testing.expectEqualStrings("ada@example.com", id.email);
    try std.testing.expect(id.email_verified);
    try std.testing.expectEqualStrings("s_777", id.session_id);
    try std.testing.expectEqual(@as(usize, 1), id.roles.len);
    try std.testing.expectEqualStrings("member", id.roles[0]);
}
