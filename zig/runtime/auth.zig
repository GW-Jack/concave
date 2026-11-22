const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const storage_mod = @import("../core/storage.zig");

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

pub const AuthConfig = struct {
    jwt_secret: ?[]const u8 = null,
    allow_dev_tokens: bool = true,
};

pub const AuthError = error{
    EmptyToken,
    DevTokensDisabled,
    InvalidDevToken,
    JwtNotConfigured,
    MalformedJwt,
    UnsupportedAlg,
    InvalidSignature,
    ExpiredToken,
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

    const secret = config.jwt_secret orelse return error.JwtNotConfigured;
    return verifyHs256Jwt(allocator, io, secret, tok);
}

fn verifyHs256Jwt(allocator: Allocator, io: std.Io, secret: []const u8, token: []const u8) AuthError!AuthIdentity {
    var parts = std.mem.splitScalar(u8, token, '.');
    const p0 = parts.next() orelse return error.MalformedJwt;
    const p1 = parts.next() orelse return error.MalformedJwt;
    const p2 = parts.next() orelse return error.MalformedJwt;
    if (parts.next() != null) return error.MalformedJwt;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Decode header
    const hdr_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(p0) catch return error.MalformedJwt;
    const hdr_bytes = try a.alloc(u8, hdr_len);
    std.base64.url_safe_no_pad.Decoder.decode(hdr_bytes, p0) catch return error.MalformedJwt;
    const hdr_val = std.json.parseFromSliceLeaky(std.json.Value, a, hdr_bytes, .{}) catch return error.MalformedJwt;
    if (hdr_val != .object) return error.MalformedJwt;
    const alg_v = hdr_val.object.get("alg") orelse return error.UnsupportedAlg;
    if (alg_v != .string or !std.mem.eql(u8, alg_v.string, "HS256")) return error.UnsupportedAlg;

    // Verify HMAC-SHA256 signature in constant time.
    const sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(p2) catch return error.InvalidSignature;
    if (sig_len != 32) return error.InvalidSignature;
    var provided_sig: [32]u8 = undefined;
    std.base64.url_safe_no_pad.Decoder.decode(&provided_sig, p2) catch return error.InvalidSignature;

    var mac = HmacSha256.init(secret);
    mac.update(p0);
    mac.update(".");
    mac.update(p1);
    var expected_sig: [32]u8 = undefined;
    mac.final(&expected_sig);

    if (!std.crypto.timing_safe.eql([32]u8, provided_sig, expected_sig)) {
        return error.InvalidSignature;
    }

    // Decode claims payload
    const pay_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(p1) catch return error.MalformedJwt;
    const pay_bytes = try a.alloc(u8, pay_len);
    std.base64.url_safe_no_pad.Decoder.decode(pay_bytes, p1) catch return error.MalformedJwt;
    const claims = std.json.parseFromSliceLeaky(std.json.Value, a, pay_bytes, .{}) catch return error.MalformedJwt;
    if (claims != .object) return error.MalformedJwt;

    if (claims.object.get("exp")) |exp_v| {
        if (exp_v == .integer) {
            const now_secs = @divTrunc(storage_mod.nowMillis(io), 1000);
            if (now_secs >= exp_v.integer) return error.ExpiredToken;
        }
    }

    const sub_v = claims.object.get("sub") orelse return error.MissingSubject;
    if (sub_v != .string or sub_v.string.len == 0) return error.MissingSubject;

    const iss_str = if (claims.object.get("iss")) |iv| (if (iv == .string) iv.string else "jwt") else "jwt";
    const name_str: ?[]const u8 = if (claims.object.get("name")) |nv| (if (nv == .string) nv.string else null) else null;

    return .{
        .subject = try allocator.dupe(u8, sub_v.string),
        .issuer = try allocator.dupe(u8, iss_str),
        .name = if (name_str) |n| try allocator.dupe(u8, n) else null,
    };
}

test "verifies dev token and HS256 JWT" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const dev_id = try verifyToken(allocator, io, .{ .allow_dev_tokens = true }, "Bearer dev:alice:Alice Smith");
    defer dev_id.deinit(allocator);
    try std.testing.expectEqualStrings("alice", dev_id.subject);
    try std.testing.expectEqualStrings("Alice Smith", dev_id.name.?);

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
}
