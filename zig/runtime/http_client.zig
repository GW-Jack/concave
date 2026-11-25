const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DEFAULT_MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const DEFAULT_MAX_REDIRECTS: u8 = 5;
pub const DEFAULT_TIMEOUT_SECS: u32 = 15;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpFetchRequest = struct {
    method: []const u8,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    allow_private_ips: bool = false,
    allow_http: bool = false,
    max_response_bytes: usize = DEFAULT_MAX_RESPONSE_BYTES,
    max_redirects: u8 = DEFAULT_MAX_REDIRECTS,
    timeout_secs: u32 = DEFAULT_TIMEOUT_SECS,
};

pub const HttpFetchResponse = struct {
    status: u16,
    headers: []Header = &.{},
    body: []u8,

    pub fn deinit(self: *const HttpFetchResponse, allocator: Allocator) void {
        allocator.free(self.body);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
    }
};

pub fn validateHeaders(headers: []const Header) !void {
    for (headers) |h| {
        if (h.name.len == 0 or h.name.len > 256 or h.value.len > 16384) return error.InvalidHeader;
        for (h.name) |c| {
            if (c <= 0x20 or c >= 0x7f or c == ':' or c == '\r' or c == '\n') return error.InvalidHeader;
        }
        for (h.value) |c| {
            if (c == '\r' or c == '\n' or c == 0) return error.InvalidHeader;
        }
    }
}

fn isHopByHopOrAutoHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "connection");
}

fn isSameOrigin(a: std.Uri, b: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    var abuf: [std.Io.net.HostName.max_len + 4]u8 = undefined;
    var bbuf: [std.Io.net.HostName.max_len + 4]u8 = undefined;
    const ah = if (a.host) |h| (h.toRaw(&abuf) catch return false) else return false;
    const bh = if (b.host) |h| (h.toRaw(&bbuf) catch return false) else return false;
    if (!std.ascii.eqlIgnoreCase(ah, bh)) return false;
    const ap: u16 = a.port orelse if (std.ascii.eqlIgnoreCase(a.scheme, "https")) 443 else 80;
    const bp: u16 = b.port orelse if (std.ascii.eqlIgnoreCase(b.scheme, "https")) 443 else 80;
    return ap == bp;
}

/// Returns true if `addr` is loopback, RFC 1918 private, link-local (including 169.254.169.254
/// cloud metadata), CGNAT, multicast, unspecified, reserved, IPv6 ULA, or IPv4-mapped private.
pub fn isForbiddenIp(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |ip4| isForbiddenIp4(ip4.bytes),
        .ip6 => |ip6| isForbiddenIp6(ip6.bytes),
    };
}

fn isForbiddenIp4(b: [4]u8) bool {
    // 0.0.0.0/8 (unspecified / "this network")
    if (b[0] == 0) return true;
    // 10.0.0.0/8 (RFC 1918)
    if (b[0] == 10) return true;
    // 100.64.0.0/10 (RFC 6598 CGNAT / Tailscale / internal cloud)
    if (b[0] == 100 and (b[1] & 0xC0) == 64) return true;
    // 127.0.0.0/8 (loopback)
    if (b[0] == 127) return true;
    // 169.254.0.0/16 (link-local & cloud metadata 169.254.169.254)
    if (b[0] == 169 and b[1] == 254) return true;
    // 172.16.0.0/12 (RFC 1918)
    if (b[0] == 172 and (b[1] & 0xF0) == 16) return true;
    // 192.0.0.0/24 (IETF protocol assignments) & 192.0.2.0/24 (TEST-NET-1)
    if (b[0] == 192 and b[1] == 0 and (b[2] == 0 or b[2] == 2)) return true;
    // 192.168.0.0/16 (RFC 1918)
    if (b[0] == 192 and b[1] == 168) return true;
    // 198.18.0.0/15 (benchmarking) & 198.51.100.0/24 (TEST-NET-2)
    if (b[0] == 198 and ((b[1] & 0xFE) == 18 or (b[1] == 51 and b[2] == 100))) return true;
    // 203.0.113.0/24 (TEST-NET-3)
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return true;
    // 224.0.0.0/4 (multicast) & 240.0.0.0/4 (reserved / broadcast 255.255.255.255)
    if (b[0] >= 224) return true;
    return false;
}

fn isForbiddenIp6(b: [16]u8) bool {
    var all_zero = true;
    for (b) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    // :: (unspecified)
    if (all_zero) return true;

    // ::1 (loopback)
    var loopback = true;
    for (b[0..15]) |byte| {
        if (byte != 0) {
            loopback = false;
            break;
        }
    }
    if (loopback and b[15] == 1) return true;

    // ::ffff:0:0/96 (IPv4-mapped IPv6)
    var ipv4_mapped = true;
    for (b[0..10]) |byte| {
        if (byte != 0) {
            ipv4_mapped = false;
            break;
        }
    }
    if (ipv4_mapped and b[10] == 0xFF and b[11] == 0xFF) {
        return isForbiddenIp4(.{ b[12], b[13], b[14], b[15] });
    }

    // 64:ff9b::/96 (NAT64 well-known prefix)
    if (b[0] == 0x00 and b[1] == 0x64 and b[2] == 0xFF and b[3] == 0x9B and
        b[4] == 0 and b[5] == 0 and b[6] == 0 and b[7] == 0 and
        b[8] == 0 and b[9] == 0 and b[10] == 0 and b[11] == 0)
    {
        return isForbiddenIp4(.{ b[12], b[13], b[14], b[15] });
    }

    // fc00::/7 (Unique Local Address)
    if ((b[0] & 0xFE) == 0xFC) return true;
    // fe80::/10 (Link-local)
    if (b[0] == 0xFE and (b[1] & 0xC0) == 0x80) return true;
    // fec0::/10 (deprecated site-local)
    if (b[0] == 0xFE and (b[1] & 0xC0) == 0xC0) return true;
    // ff00::/8 (multicast)
    if (b[0] == 0xFF) return true;
    return false;
}

fn isForbiddenHostname(host: []const u8) bool {
    if (host.len == 0) return true;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".local")) return true;
    if (std.ascii.endsWithIgnoreCase(host, ".internal")) return true;
    if (std.ascii.eqlIgnoreCase(host, "metadata.google.internal")) return true;
    return false;
}

/// Validate scheme, hostname, and resolved IP addresses against SSRF policy.
pub fn validateTargetUri(
    allocator: Allocator,
    io: std.Io,
    uri: std.Uri,
    allow_private_ips: bool,
    allow_http: bool,
) !void {
    const is_https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    const is_http = std.ascii.eqlIgnoreCase(uri.scheme, "http");
    if (!is_https and !is_http) return error.ForbiddenUrlScheme;
    if (is_http and !allow_http and !allow_private_ips) return error.InsecureHttpBlocked;

    const host_comp = uri.host orelse return error.MissingHost;
    var host_buf: [std.Io.net.HostName.max_len + 4]u8 = undefined;
    const host_raw = host_comp.toRaw(&host_buf) catch return error.InvalidHost;
    if (host_raw.len == 0) return error.MissingHost;

    if (allow_private_ips) return;

    // Strip IPv6 brackets if present.
    const host = if (host_raw.len >= 2 and host_raw[0] == '[' and host_raw[host_raw.len - 1] == ']')
        host_raw[1 .. host_raw.len - 1]
    else
        host_raw;

    if (isForbiddenHostname(host)) return error.SsrfBlocked;

    const port: u16 = uri.port orelse if (is_https) 443 else 80;

    // Direct IP literal check (IPv4 or IPv6).
    if (std.Io.net.IpAddress.parse(host, port)) |ip| {
        if (isForbiddenIp(ip)) return error.SsrfBlocked;
        return;
    } else |_| {}

    // Reject numeric/octal/hex IPv4 obfuscations (e.g. 2130706433, 0x7f000001).
    if (std.fmt.parseInt(u32, host, 0)) |_| {
        return error.SsrfBlocked;
    } else |_| {}

    // Resolve DNS and verify EVERY returned address is public.
    const host_name = std.Io.net.HostName.init(host) catch return error.InvalidHost;
    var lookup_buf: [32]std.Io.net.HostName.LookupResult = undefined;
    var resolved: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buf);
    try host_name.lookup(io, &resolved, .{ .port = port });

    var saw_addr = false;
    while (resolved.getOne(io)) |item| {
        switch (item) {
            .address => |addr| {
                saw_addr = true;
                if (isForbiddenIp(addr)) return error.SsrfBlocked;
            },
            .canonical_name => {},
        }
    } else |_| {}

    if (!saw_addr) return error.DnsResolutionFailed;
    _ = allocator;
}

fn applySocketTimeout(stream: std.Io.net.Stream, timeout_secs: u32) void {
    if (timeout_secs == 0) return;
    const tv = std.posix.timeval{
        .sec = @intCast(timeout_secs),
        .usec = 0,
    };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// Zero-dependency SSRF-hardened HTTP & HTTPS client powered by Zig's built-in `std.http.Client` + `std.crypto.tls`.
pub fn fetch(allocator: Allocator, io: std.Io, req: HttpFetchRequest) !HttpFetchResponse {
    try validateHeaders(req.headers);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var current_url = try allocator.dupe(u8, req.url);
    defer allocator.free(current_url);
    const initial_uri = try std.Uri.parse(current_url);
    var method = parseMethod(req.method);
    var payload = if (req.body) |b| (if (b.len > 0) b else null) else null;

    var extra_headers_list: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers_list.deinit(allocator);

    var hops: u8 = 0;
    while (true) {
        const uri = try std.Uri.parse(current_url);
        try validateTargetUri(allocator, io, uri, req.allow_private_ips, req.allow_http);

        const same_origin = (hops == 0) or isSameOrigin(initial_uri, uri);
        extra_headers_list.clearRetainingCapacity();
        for (req.headers) |h| {
            if (isHopByHopOrAutoHeader(h.name)) continue;
            if (!same_origin and (std.ascii.eqlIgnoreCase(h.name, "authorization") or std.ascii.eqlIgnoreCase(h.name, "cookie"))) {
                continue;
            }
            try extra_headers_list.append(allocator, .{ .name = h.name, .value = h.value });
        }

        var http_req = try client.request(method, uri, .{
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
            .extra_headers = extra_headers_list.items,
        });
        defer http_req.deinit();

        if (http_req.connection) |conn| {
            applySocketTimeout(conn.stream_reader.stream, req.timeout_secs);
        }

        if (payload) |p| {
            http_req.transfer_encoding = .{ .content_length = p.len };
            var body_w = try http_req.sendBodyUnflushed(&.{});
            try body_w.writer.writeAll(p);
            try body_w.end();
            if (http_req.connection) |conn| try conn.flush();
        } else {
            try http_req.sendBodiless();
        }

        var head_buf: [8192]u8 = undefined;
        var response = try http_req.receiveHead(&head_buf);
        const status_code: u16 = @intFromEnum(response.head.status);

        // Manually follow HTTP redirects, re-validating every hop against SSRF rules.
        if (response.head.location) |loc| {
            const is_redirect = status_code == 301 or status_code == 302 or status_code == 303 or status_code == 307 or status_code == 308;
            if (is_redirect and hops < req.max_redirects) {
                hops += 1;
                const next_url = try resolveRedirectUrl(allocator, uri, loc);
                allocator.free(current_url);
                current_url = next_url;
                if (status_code == 303 or ((status_code == 301 or status_code == 302) and method == .POST)) {
                    method = .GET;
                    payload = null;
                }
                continue;
            }
        }

        var resp_headers: std.ArrayList(Header) = .empty;
        errdefer {
            for (resp_headers.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            resp_headers.deinit(allocator);
        }
        var hit = response.head.iterateHeaders();
        while (hit.next()) |h| {
            if (resp_headers.items.len >= 128) break;
            const n = try allocator.dupe(u8, h.name);
            errdefer allocator.free(n);
            const v = try allocator.dupe(u8, h.value);
            errdefer allocator.free(v);
            try resp_headers.append(allocator, .{ .name = n, .value = v });
        }

        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(allocator, .limited(req.max_response_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => return err,
        };
        return .{
            .status = status_code,
            .headers = try resp_headers.toOwnedSlice(allocator),
            .body = body,
        };
    }
}

fn resolveRedirectUrl(allocator: Allocator, base: std.Uri, location: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, location, "://") != null) {
        return try allocator.dupe(u8, location);
    }
    var host_buf: [std.Io.net.HostName.max_len + 4]u8 = undefined;
    const host = if (base.host) |h| (h.toRaw(&host_buf) catch return error.InvalidRedirect) else return error.InvalidRedirect;
    if (std.mem.startsWith(u8, location, "//")) {
        return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ base.scheme, location });
    }
    if (base.port) |p| {
        if (std.mem.startsWith(u8, location, "/")) {
            return try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}", .{ base.scheme, host, p, location });
        }
        return try std.fmt.allocPrint(allocator, "{s}://{s}:{d}/{s}", .{ base.scheme, host, p, location });
    }
    if (std.mem.startsWith(u8, location, "/")) {
        return try std.fmt.allocPrint(allocator, "{s}://{s}{s}", .{ base.scheme, host, location });
    }
    return try std.fmt.allocPrint(allocator, "{s}://{s}/{s}", .{ base.scheme, host, location });
}

fn parseMethod(s: []const u8) std.http.Method {
    if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(s, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(s, "OPTIONS")) return .OPTIONS;
    return .GET;
}

test "http_client: blocks SSRF private/loopback/metadata IPs and insecure schemes by default" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Forbidden IPv4/IPv6 ranges
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("127.0.0.1", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("169.254.169.254", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("10.0.0.1", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("172.16.5.4", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("192.168.1.1", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("100.64.0.1", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("0.0.0.0", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("::1", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("fe80::1", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("fc00::1", 80)));
    try std.testing.expect(isForbiddenIp(try std.Io.net.IpAddress.parse("::ffff:169.254.169.254", 80)));
    // Public IP allowed
    try std.testing.expect(!isForbiddenIp(try std.Io.net.IpAddress.parse("93.184.216.34", 443)));

    // Scheme & URL validation
    try std.testing.expectError(error.ForbiddenUrlScheme, validateTargetUri(allocator, io, try std.Uri.parse("file:///etc/passwd"), false, false));
    try std.testing.expectError(error.InsecureHttpBlocked, validateTargetUri(allocator, io, try std.Uri.parse("http://93.184.216.34/"), false, false));
    try std.testing.expectError(error.SsrfBlocked, validateTargetUri(allocator, io, try std.Uri.parse("https://169.254.169.254/latest/meta-data/"), false, false));
    try std.testing.expectError(error.SsrfBlocked, validateTargetUri(allocator, io, try std.Uri.parse("https://localhost:3210/_admin/stats"), false, false));
    try std.testing.expectError(error.SsrfBlocked, validateTargetUri(allocator, io, try std.Uri.parse("https://metadata.google.internal/"), false, false));
    try std.testing.expectError(error.SsrfBlocked, validateTargetUri(allocator, io, try std.Uri.parse("https://2130706433/"), false, false));
    // Public HTTPS IP passes
    try validateTargetUri(allocator, io, try std.Uri.parse("https://93.184.216.34/"), false, false);
    // Explicit private opt-in passes for local test servers
    try validateTargetUri(allocator, io, try std.Uri.parse("http://127.0.0.1:8080/test"), true, true);

    // Header validation rejects CRLF injection and invalid names
    try validateHeaders(&.{
        .{ .name = "Authorization", .value = "Bearer tok_123" },
        .{ .name = "Content-Type", .value = "application/json" },
    });
    try std.testing.expectError(error.InvalidHeader, validateHeaders(&.{
        .{ .name = "X-Bad", .value = "ok\r\nInjected: yes" },
    }));
    try std.testing.expectError(error.InvalidHeader, validateHeaders(&.{
        .{ .name = "Bad Name", .value = "val" },
    }));
    try std.testing.expectError(error.InvalidHeader, validateHeaders(&.{
        .{ .name = "", .value = "val" },
    }));
}
