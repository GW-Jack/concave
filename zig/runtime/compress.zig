const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const CompressionLevel = enum {
    fast,
    best,
};

/// Compress `input` into a standard RFC 1952 gzip byte slice using Zig's stdlib flate compressor.
pub fn gzipCompress(allocator: Allocator, input: []const u8, level: CompressionLevel) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, @max(@as(usize, 128), input.len / 2 + 64));
    errdefer out.deinit();

    var window_buf: [flate.max_window_len]u8 = undefined;
    const opts: flate.Compress.Options = switch (level) {
        .fast => .fastest,
        .best => .best,
    };
    var comp = try flate.Compress.init(&out.writer, &window_buf, .gzip, opts);
    try comp.writer.writeAll(input);
    try comp.finish();
    return try out.toOwnedSlice();
}

/// Returns true if an `Accept-Encoding` header value permits `gzip`.
pub fn acceptsGzip(accept_encoding: ?[]const u8) bool {
    const raw = accept_encoding orelse return false;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        var semi = std.mem.splitScalar(u8, trimmed, ';');
        const coding = std.mem.trim(u8, semi.next() orelse continue, " \t");
        if (!std.ascii.eqlIgnoreCase(coding, "gzip")) continue;
        // Reject explicit q=0
        while (semi.next()) |param| {
            const p = std.mem.trim(u8, param, " \t");
            if (std.mem.startsWith(u8, p, "q=") or std.mem.startsWith(u8, p, "Q=")) {
                const qval = std.mem.trim(u8, p[2..], " \t");
                if (std.mem.eql(u8, qval, "0") or std.mem.eql(u8, qval, "0.0") or std.mem.eql(u8, qval, "0.00") or std.mem.eql(u8, qval, "0.000")) {
                    return false;
                }
            }
        }
        return true;
    }
    return false;
}

/// Returns true if the MIME type benefits from gzip compression.
pub fn isCompressibleMime(content_type: []const u8) bool {
    return std.mem.startsWith(u8, content_type, "text/") or
        std.mem.startsWith(u8, content_type, "application/json") or
        std.mem.startsWith(u8, content_type, "application/javascript") or
        std.mem.startsWith(u8, content_type, "image/svg+xml");
}

/// Compute a strong quoted SHA-256 ETag (`"<16-hex>"`, 18 bytes total).
pub fn computeEtag(data: []const u8, out_buf: *[18]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    out_buf[0] = '"';
    @memcpy(out_buf[1..17], &hex);
    out_buf[17] = '"';
    return out_buf[0..18];
}

/// Check if an `If-None-Match` header matches `etag` (handles `*`, weak `W/` prefixes, and comma lists).
pub fn etagMatches(if_none_match: ?[]const u8, etag: []const u8) bool {
    const raw = if_none_match orelse return false;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        var tok = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, tok, "*")) return true;
        if (std.mem.startsWith(u8, tok, "W/")) tok = tok[2..];
        if (std.mem.eql(u8, tok, etag)) return true;
    }
    return false;
}

test "compress: gzip round-trip, acceptsGzip, and ETag matching" {
    const allocator = std.testing.allocator;
    const chunk = "export function signal(x){return x;} ";
    const sample = chunk ++ chunk ++ chunk ++ chunk ++ chunk ++ chunk ++ chunk ++ chunk ++
        chunk ++ chunk ++ chunk ++ chunk ++ chunk ++ chunk ++ chunk ++ chunk;
    const gz = try gzipCompress(allocator, sample, .best);
    defer allocator.free(gz);
    try std.testing.expect(gz.len < sample.len / 4);
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);

    // Round-trip decompress via std.compress.flate.Decompress
    var in_r = std.Io.Reader.fixed(gz);
    var dec_buf: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in_r, .gzip, &dec_buf);
    const plain = try dec.reader.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(plain);
    try std.testing.expectEqualStrings(sample, plain);

    try std.testing.expect(acceptsGzip("br, gzip, deflate"));
    try std.testing.expect(!acceptsGzip("gzip;q=0, br"));
    try std.testing.expect(!acceptsGzip(null));

    var etag_buf: [18]u8 = undefined;
    const etag = computeEtag(sample, &etag_buf);
    try std.testing.expect(etagMatches(etag, etag));
    try std.testing.expect(etagMatches("*", etag));
    try std.testing.expect(!etagMatches("\"0000000000000000\"", etag));
}
