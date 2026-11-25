const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const key_mod = @import("../core/key.zig");
const manifest_mod = @import("../core/manifest.zig");
const pg_mod = @import("../core/pg_wire.zig");
const wal_mod = @import("../core/wal_store.zig");
const auth_mod = @import("../runtime/auth.zig");
const server_mod = @import("../runtime/server.zig");
const ws_mod = @import("../runtime/ws.zig");

// ============================================================================
// 1. HS256 JWT & Dev-Token Security Suite (RFC 7515 / 7519 + Attack Vectors)
// ============================================================================

fn signJwt(allocator: Allocator, secret: []const u8, hdr_json: []const u8, pay_json: []const u8) ![]u8 {
    const hdr_len = std.base64.url_safe_no_pad.Encoder.calcSize(hdr_json.len);
    const pay_len = std.base64.url_safe_no_pad.Encoder.calcSize(pay_json.len);
    const hdr_b64 = try allocator.alloc(u8, hdr_len);
    defer allocator.free(hdr_b64);
    const pay_b64 = try allocator.alloc(u8, pay_len);
    defer allocator.free(pay_b64);
    _ = std.base64.url_safe_no_pad.Encoder.encode(hdr_b64, hdr_json);
    _ = std.base64.url_safe_no_pad.Encoder.encode(pay_b64, pay_json);

    var mac = HmacSha256.init(secret);
    mac.update(hdr_b64);
    mac.update(".");
    mac.update(pay_b64);
    var sig: [32]u8 = undefined;
    mac.final(&sig);
    var sig_buf: [64]u8 = undefined;
    const sig_b64 = std.base64.url_safe_no_pad.Encoder.encode(&sig_buf, &sig);

    return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ hdr_b64, pay_b64, sig_b64 });
}

test "auth security: rejects alg:none, RS256, tampered sig, expired exp, future nbf, and disabled dev tokens" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const secret = "production-secret-256-bits";
    const cfg = auth_mod.AuthConfig{ .jwt_secret = secret, .allow_dev_tokens = false };

    // Dev tokens rejected when disabled; empty/malformed dev tokens rejected even when enabled.
    try std.testing.expectError(error.DevTokensDisabled, auth_mod.verifyToken(allocator, io, cfg, "dev:alice:Alice"));
    try std.testing.expectError(error.EmptyToken, auth_mod.verifyToken(allocator, io, .{ .allow_dev_tokens = true }, "   "));
    try std.testing.expectError(error.InvalidDevToken, auth_mod.verifyToken(allocator, io, .{ .allow_dev_tokens = true }, "dev:"));
    try std.testing.expectError(error.InvalidDevToken, auth_mod.verifyToken(allocator, io, .{ .allow_dev_tokens = true }, "dev:  :Name"));

    // alg:none attack
    const alg_none = try signJwt(allocator, secret, "{\"alg\":\"none\",\"typ\":\"JWT\"}", "{\"sub\":\"admin\"}");
    defer allocator.free(alg_none);
    try std.testing.expectError(error.UnsupportedAlg, auth_mod.verifyToken(allocator, io, cfg, alg_none));

    // alg:RS256 confusion attack
    const alg_rs = try signJwt(allocator, secret, "{\"alg\":\"RS256\"}", "{\"sub\":\"admin\"}");
    defer allocator.free(alg_rs);
    try std.testing.expectError(error.UnsupportedAlg, auth_mod.verifyToken(allocator, io, cfg, alg_rs));

    // Wrong signing secret
    const wrong_secret = try signJwt(allocator, "attacker-secret", "{\"alg\":\"HS256\"}", "{\"sub\":\"admin\"}");
    defer allocator.free(wrong_secret);
    try std.testing.expectError(error.InvalidSignature, auth_mod.verifyToken(allocator, io, cfg, wrong_secret));

    // Tampered payload byte after signing
    const valid = try signJwt(allocator, secret, "{\"alg\":\"HS256\"}", "{\"sub\":\"alice\",\"exp\":4102444800,\"nbf\":1000}");
    defer allocator.free(valid);
    const id = try auth_mod.verifyToken(allocator, io, cfg, valid);
    defer id.deinit(allocator);
    try std.testing.expectEqualStrings("alice", id.subject);

    const tampered = try allocator.dupe(u8, valid);
    defer allocator.free(tampered);
    const dot = std.mem.indexOfScalar(u8, tampered, '.').?;
    tampered[dot + 2] = if (tampered[dot + 2] == 'A') 'B' else 'A';
    try std.testing.expectError(error.InvalidSignature, auth_mod.verifyToken(allocator, io, cfg, tampered));

    // Expired token (`exp: 1`)
    const expired = try signJwt(allocator, secret, "{\"alg\":\"HS256\"}", "{\"sub\":\"alice\",\"exp\":1}");
    defer allocator.free(expired);
    try std.testing.expectError(error.ExpiredToken, auth_mod.verifyToken(allocator, io, cfg, expired));

    // Missing `exp` must be rejected when `require_exp` is enabled (default).
    const no_exp = try signJwt(allocator, secret, "{\"alg\":\"HS256\"}", "{\"sub\":\"alice\"}");
    defer allocator.free(no_exp);
    try std.testing.expectError(error.MissingExpiration, auth_mod.verifyToken(allocator, io, cfg, no_exp));

    // Future `nbf` token (`nbf: 4102444800`, year 2100) with valid `exp`
    const future = try signJwt(allocator, secret, "{\"alg\":\"HS256\"}", "{\"sub\":\"alice\",\"exp\":4200000000,\"nbf\":4102444800}");
    defer allocator.free(future);
    try std.testing.expectError(error.NotYetValid, auth_mod.verifyToken(allocator, io, cfg, future));

    // Non-integer `exp` must be rejected as MalformedJwt
    const bad_exp = try signJwt(allocator, secret, "{\"alg\":\"HS256\"}", "{\"sub\":\"alice\",\"exp\":\"never\"}");
    defer allocator.free(bad_exp);
    try std.testing.expectError(error.MalformedJwt, auth_mod.verifyToken(allocator, io, cfg, bad_exp));

    // Missing/empty `sub` (with valid `exp`)
    const no_sub = try signJwt(allocator, secret, "{\"alg\":\"HS256\"}", "{\"name\":\"ghost\",\"exp\":4102444800}");
    defer allocator.free(no_sub);
    try std.testing.expectError(error.MissingSubject, auth_mod.verifyToken(allocator, io, cfg, no_sub));
}

// ============================================================================
// 2. RFC 6455 WebSocket Framing, Fragmentation & Protocol Violation Suite
// ============================================================================

fn appendWsFrame(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    fin: bool,
    opcode: u4,
    masked: bool,
    mask_key: [4]u8,
    payload: []const u8,
) !void {
    const b0: u8 = (@as(u8, if (fin) 0x80 else 0x00)) | @as(u8, opcode);
    try out.append(allocator, b0);
    const mbit: u8 = if (masked) 0x80 else 0x00;
    if (payload.len < 126) {
        try out.append(allocator, mbit | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 65535) {
        try out.append(allocator, mbit | 126);
        var ext: [2]u8 = undefined;
        std.mem.writeInt(u16, &ext, @intCast(payload.len), .big);
        try out.appendSlice(allocator, &ext);
    } else {
        try out.append(allocator, mbit | 127);
        var ext: [8]u8 = undefined;
        std.mem.writeInt(u64, &ext, payload.len, .big);
        try out.appendSlice(allocator, &ext);
    }
    if (masked) {
        try out.appendSlice(allocator, &mask_key);
        for (payload, 0..) |b, i| {
            try out.append(allocator, b ^ mask_key[i & 3]);
        }
    } else {
        try out.appendSlice(allocator, payload);
    }
}

test "ws framing: masked 16-bit & 64-bit lengths, fragmented messages with interleaved ping, and protocol errors" {
    const allocator = std.testing.allocator;
    const mask = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };

    // 1. Multi-frame fragmented message with an interleaved Ping frame inside!
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(allocator);
    try appendWsFrame(allocator, &wire, false, 0x1, true, mask, "Hello, ");
    try appendWsFrame(allocator, &wire, true, 0x9, true, mask, "ping!");
    try appendWsFrame(allocator, &wire, false, 0x0, true, mask, "fragmented ");
    try appendWsFrame(allocator, &wire, true, 0x0, true, mask, "Concave!");
    try appendWsFrame(allocator, &wire, true, 0x8, true, mask, "");

    var r = std.Io.Reader.fixed(wire.items);
    const f1 = try ws_mod.readFrame(allocator, &r);
    defer f1.deinit(allocator);
    try std.testing.expectEqualStrings("Hello, fragmented Concave!", f1.text);
    const f2 = try ws_mod.readFrame(allocator, &r);
    defer f2.deinit(allocator);
    try std.testing.expect(f2 == .close);

    // 2. Medium (16-bit length, 300 bytes) & large (64-bit length, 70000 bytes) masked frames.
    const medium_payload = try allocator.alloc(u8, 300);
    defer allocator.free(medium_payload);
    @memset(medium_payload, 'M');
    const large_payload = try allocator.alloc(u8, 70000);
    defer allocator.free(large_payload);
    @memset(large_payload, 'L');

    var wire2: std.ArrayList(u8) = .empty;
    defer wire2.deinit(allocator);
    try appendWsFrame(allocator, &wire2, true, 0x1, true, mask, medium_payload);
    try appendWsFrame(allocator, &wire2, true, 0x1, true, mask, large_payload);
    var r2 = std.Io.Reader.fixed(wire2.items);
    const fm = try ws_mod.readFrame(allocator, &r2);
    defer fm.deinit(allocator);
    try std.testing.expectEqualSlices(u8, medium_payload, fm.text);
    const fl = try ws_mod.readFrame(allocator, &r2);
    defer fl.deinit(allocator);
    try std.testing.expectEqualSlices(u8, large_payload, fl.text);

    // 3. Truncated mid-payload EOF must return .close with ZERO leaked bytes!
    var r_trunc = std.Io.Reader.fixed(wire2.items[0..50]);
    const ft = try ws_mod.readFrame(allocator, &r_trunc);
    defer ft.deinit(allocator);
    try std.testing.expect(ft == .close);

    // 4. Protocol errors (RFC 6455 §5.2 & §5.5):
    // Non-zero RSV1 bit
    var r_rsv = std.Io.Reader.fixed(&[_]u8{ 0xC1, 0x00 });
    try std.testing.expectError(error.ProtocolError, ws_mod.readFrame(allocator, &r_rsv));
    // Fragmented Ping control frame (FIN=0, opcode=9)
    var r_fping = std.Io.Reader.fixed(&[_]u8{ 0x09, 0x00 });
    try std.testing.expectError(error.ProtocolError, ws_mod.readFrame(allocator, &r_fping));
    // Control frame with extended length 126
    var r_bigping = std.Io.Reader.fixed(&[_]u8{ 0x89, 126, 0x00, 126 });
    try std.testing.expectError(error.ProtocolError, ws_mod.readFrame(allocator, &r_bigping));
    // Unexpected continuation frame when not fragmented
    var r_cont = std.Io.Reader.fixed(&[_]u8{ 0x80, 0x00 });
    try std.testing.expectError(error.ProtocolError, ws_mod.readFrame(allocator, &r_cont));
    // Unmasked client-to-server frame MUST be rejected (RFC 6455 §5.1)
    var r_unmasked = std.Io.Reader.fixed(&[_]u8{ 0x81, 0x02, 'h', 'i' });
    try std.testing.expectError(error.ProtocolError, ws_mod.readFrame(allocator, &r_unmasked));
    // Oversized masked frame > 16 MiB (mask bit 0x80 | 127 = 0xFF)
    var r_huge = std.Io.Reader.fixed(&[_]u8{ 0x81, 0xFF, 0, 0, 0, 0, 0x02, 0, 0, 0 });
    try std.testing.expectError(error.FrameTooLarge, ws_mod.readFrame(allocator, &r_huge));
}

// ============================================================================
// 3. PostgreSQL Wire v3 & RFC 7677 SCRAM-SHA-256 Official Test Vectors
// ============================================================================

test "pg_wire: RFC 7677 Section 3 official SCRAM-SHA-256 client proof and mutual server signature verification" {
    const allocator = std.testing.allocator;

    // Exact test vector from RFC 7677 Section 3:
    const client_first_bare = "n=user,r=rOprNGfwEbeRWgbNEkqO";
    const client_nonce = "rOprNGfwEbeRWgbNEkqO";
    const server_first = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";

    const res = try pg_mod.buildScramClientFinal(
        allocator,
        "pencil",
        client_first_bare,
        client_nonce,
        server_first,
    );
    defer allocator.free(res.client_final);

    try std.testing.expectEqualStrings(
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=",
        res.client_final,
    );

    // Verify official RFC 7677 server-final signature!
    try pg_mod.verifyScramServerFinal("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", res.expected_server_sig);

    // Tampered server signature MUST fail mutual authentication!
    try std.testing.expectError(
        error.PostgresAuthFailed,
        pg_mod.verifyScramServerFinal("v=7rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", res.expected_server_sig),
    );
    try std.testing.expectError(
        error.PostgresAuthFailed,
        pg_mod.verifyScramServerFinal("e=invalid-proof", res.expected_server_sig),
    );

    // Hostile server-first parameters: nonce prefix mismatch, i=0, i=2_000_000.
    try std.testing.expectError(
        error.PostgresAuthFailed,
        pg_mod.buildScramClientFinal(allocator, "pencil", client_first_bare, client_nonce, "r=WRONGNONCE,s=AAAA,i=4096"),
    );
    try std.testing.expectError(
        error.PostgresAuthFailed,
        pg_mod.buildScramClientFinal(allocator, "pencil", client_first_bare, client_nonce, "r=rOprNGfwEbeRWgbNEkqOabc,s=AAAA,i=0"),
    );
    try std.testing.expectError(
        error.PostgresAuthFailed,
        pg_mod.buildScramClientFinal(allocator, "pencil", client_first_bare, client_nonce, "r=rOprNGfwEbeRWgbNEkqOabc,s=AAAA,i=2000000"),
    );
}

test "pg_wire: DataRow parsing, NULL columns, truncated frames, and URL edge cases" {
    const allocator = std.testing.allocator;

    // Valid 3-column DataRow: ["hi", NULL (-1), "world"]
    const valid_row = [_]u8{
        0x00, 0x03, // 3 cols
        0x00, 0x00, 0x00, 0x02, 'h', 'i',
        0xFF, 0xFF, 0xFF, 0xFF, // SQL NULL
        0x00, 0x00, 0x00, 0x05, 'w', 'o', 'r', 'l', 'd',
    };
    const row = try pg_mod.parseDataRow(allocator, &valid_row);
    defer row.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), row.cols.len);
    try std.testing.expectEqualStrings("hi", row.cols[0]);
    try std.testing.expectEqualStrings("", row.cols[1]);
    try std.testing.expectEqualStrings("world", row.cols[2]);

    // Truncated & hostile DataRow payloads must return error.MalformedDataRow with zero leaks.
    try std.testing.expectError(error.MalformedDataRow, pg_mod.parseDataRow(allocator, &[_]u8{0x00}));
    try std.testing.expectError(error.MalformedDataRow, pg_mod.parseDataRow(allocator, &[_]u8{ 0xFF, 0xFF, 0x00, 0x00 }));
    try std.testing.expectError(error.MalformedDataRow, pg_mod.parseDataRow(allocator, &[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x10, 'a' }));

    // URL edge cases
    try std.testing.expectError(error.InvalidDatabaseUrl, pg_mod.PgUrl.parse(allocator, "http://example.com"));
    try std.testing.expectError(error.InvalidDatabaseUrl, pg_mod.PgUrl.parse(allocator, "postgres://user:pass@/db"));
    try std.testing.expectError(error.InvalidDatabaseUrl, pg_mod.PgUrl.parse(allocator, "postgres://localhost:notaport/db"));

    const local = try pg_mod.PgUrl.parse(allocator, "postgres://127.0.0.1:5433/app");
    defer local.deinit(allocator);
    try std.testing.expect(!local.use_tls);
    try std.testing.expectEqual(@as(u16, 5433), local.port);
}

// ============================================================================
// 4. HTTP/1.1 Parser & Static Path Traversal Security Suite
// ============================================================================

test "server security: static path traversal rejection and HTTP/1.1 request parser edge cases" {
    const allocator = std.testing.allocator;

    // Safe paths
    const p_root = try server_mod.sanitizeStaticPath(allocator, "/");
    defer allocator.free(p_root);
    try std.testing.expectEqualStrings("index.html", p_root);

    const p_js = try server_mod.sanitizeStaticPath(allocator, "/src/_generated/api.js");
    defer allocator.free(p_js);
    try std.testing.expectEqualStrings("src/_generated/api.js", p_js);

    // Traversal & smuggling attempts MUST be forbidden!
    const attacks = [_][]const u8{
        "/../etc/passwd",
        "/src/../../secret",
        "/%2e%2e/etc/passwd",
        "/%2E%2E/%2e%2e/secret",
        "/src\\..\\secret",
        "/src/main.js%00.png",
        "/./src/main.js",
        "/%ZZinvalid",
        "/src/foo%0aBar",
    };
    for (attacks) |bad| {
        try std.testing.expectError(error.ForbiddenPath, server_mod.sanitizeStaticPath(allocator, bad));
    }

    // HTTP/1.1 parsing: valid POST + duplicate headers (no leak!) + WS upgrade
    const raw_post =
        "POST /api/mutation/messages.send?foo=1 HTTP/1.1\r\n" ++
        "Authorization: dev:a:A\r\n" ++
        "Authorization: dev:b:B\r\n" ++
        "Content-Length: 11\r\n\r\n" ++
        "{\"ok\":true}";
    var r_post = std.Io.Reader.fixed(raw_post);
    const req = (try server_mod.readHttpRequest(allocator, &r_post)).?;
    defer req.deinit(allocator);
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/api/mutation/messages.send", req.path);
    try std.testing.expectEqualStrings("dev:b:B", req.authorization.?);
    try std.testing.expectEqualStrings("{\"ok\":true}", req.body);

    // Unterminated 64 KiB header without `\r\n\r\n` must return HeadersTooLarge.
    const giant_hdr = try allocator.alloc(u8, 65 * 1024);
    defer allocator.free(giant_hdr);
    @memset(giant_hdr, 'A');
    var r_giant = std.Io.Reader.fixed(giant_hdr);
    try std.testing.expectError(error.HeadersTooLarge, server_mod.readHttpRequest(allocator, &r_giant));
}

// ============================================================================
// 5. Coverage-Guided Fuzz Targets (`zig build test --fuzz`)
// ============================================================================

test "fuzz: key codec order & bracketing on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const allocator = std.testing.allocator;
            var b1: [64]u8 = undefined;
            var b2: [64]u8 = undefined;
            const s1 = b1[0..smith.slice(&b1)];
            const s2 = b2[0..smith.slice(&b2)];

            const k1 = try key_mod.encodeKey(allocator, &.{.{ .str_val = s1 }});
            defer allocator.free(k1);
            const k2 = try key_mod.encodeKey(allocator, &.{.{ .str_val = s2 }});
            defer allocator.free(k2);
            try std.testing.expectEqual(std.mem.order(u8, s1, s2), std.mem.order(u8, k1, k2));

            const hi = try key_mod.encodePrefixUpperBound(allocator, &.{.{ .str_val = s1 }});
            defer allocator.free(hi);
            const ext = try key_mod.encodeKey(allocator, &.{ .{ .str_val = s1 }, .{ .str_val = s2 } });
            defer allocator.free(ext);
            try std.testing.expect(std.mem.order(u8, k1, ext) == .lt);
            try std.testing.expect(std.mem.order(u8, ext, hi) == .lt);
        }
    }.testOne, .{
        .corpus = &.{ "", "\x00", "\x00\xFF", "hello\x00world" },
    });
}

test "fuzz: WalStore WAL replay never panics or leaks on arbitrary corrupted bytes" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            const mf_json =
                \\{"app_name":"fz","tables":[{"name":"t","document_schema":{"kind":"any"},"indexes":[{"name":"by_a","fields":["a"]}]}],"components":[],"functions":[]}
            ;
            var mf = try manifest_mod.AppManifest.parseJson(allocator, mf_json);
            defer mf.deinit();

            var store = try wal_mod.WalStore.openInMemory(allocator, io);
            defer store.deinit();
            try store.replayWalBytes(input, &mf);
            try store.verifyIndexIntegrity(allocator, &mf);
        }
    }.testOne, .{
        .corpus = &.{
            "",
            "{}\n",
            "00000000|{\"ts\":1,\"ops\":[{\"op\":123}]}\n",
            "{\"ts\":1,\"ops\":[{\"op\":\"insert\",\"ns\":\"\",\"table\":\"t\",\"id\":\"1\",\"ct\":1,\"body\":\"{}\"}]}\n",
        },
    });
}

test "fuzz: WebSocket RFC 6455 frame reader never panics or leaks on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const allocator = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            var r = std.Io.Reader.fixed(input);
            const frame = ws_mod.readFrame(allocator, &r) catch return;
            frame.deinit(allocator);
        }
    }.testOne, .{
        .corpus = &.{
            &[_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' },
            &[_]u8{ 0x81, 0x85, 1, 2, 3, 4, 'a', 'b', 'c', 'd', 'e' },
            &[_]u8{ 0x01, 0x02, 'a', 'b', 0x80, 0x02, 'c', 'd' },
            &[_]u8{ 0x89, 0x7E, 0x00, 0x80 },
        },
    });
}

test "fuzz: auth.verifyToken never panics or leaks on arbitrary tokens" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const allocator = std.testing.allocator;
            const io = std.testing.io;
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            const id = auth_mod.verifyToken(allocator, io, .{
                .jwt_secret = "fuzz-secret",
                .allow_dev_tokens = true,
            }, input) catch return;
            id.deinit(allocator);
        }
    }.testOne, .{
        .corpus = &.{
            "",
            "dev:alice:Alice",
            "Bearer a.b.c",
            "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhIn0.",
        },
    });
}

test "fuzz: pg_wire DataRow, WriteSet JSON, and URL parsers never panic or leak" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const allocator = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            if (pg_mod.parseDataRow(allocator, input)) |row| {
                row.deinit(allocator);
            } else |_| {}

            if (pg_mod.parseWriteSetJson(allocator, input)) |*ws_val| {
                var ws = ws_val.*;
                ws.deinit(allocator);
            } else |_| {}

            if (pg_mod.PgUrl.parse(allocator, input)) |url| {
                url.deinit(allocator);
            } else |_| {}
        }
    }.testOne, .{
        .corpus = &.{
            "postgres://u:p@host:5432/db?sslmode=require",
            "{\"docs\":[{\"ns\":123,\"t\":\"a\",\"id\":\"1\"}],\"keys\":[{\"k\":\"!!!\"}]}",
            &[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 'o', 'k' },
        },
    });
}

test "fuzz: HTTP request parser and static path sanitizer never panic or leak" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) !void {
            const allocator = std.testing.allocator;
            var buf: [512]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];

            var r = std.Io.Reader.fixed(input);
            if (server_mod.readHttpRequest(allocator, &r)) |maybe_req| {
                if (maybe_req) |req| req.deinit(allocator);
            } else |_| {}

            if (server_mod.sanitizeStaticPath(allocator, input)) |p| {
                allocator.free(p);
            } else |_| {}
        }
    }.testOne, .{
        .corpus = &.{
            "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "POST /api/query/x HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",
            "/%2e%2e/etc/passwd",
        },
    });
}
