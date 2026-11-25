const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("embedded_assets");
const storage_mod = @import("../core/storage.zig");
const auth_mod = @import("auth.zig");
const compress = @import("compress.zig");
const engine_mod = @import("engine.zig");
const http2 = @import("http2.zig");
const rate_limit = @import("rate_limit.zig");
const ws_mod = @import("ws.zig");

const DYNAMIC_GZIP_MIN_BYTES: usize = 512;
const HTTP_SOCKET_TIMEOUT_SECS: i64 = 30;
const MAX_HTTP_HEADERS: usize = 128;

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3210,
    static_dir: ?[]const u8 = null,
    live_reload: bool = false,
    admin_key: ?[]const u8 = null,
    operator_token: ?[]const u8 = null,
    cors_origins: []const []const u8 = &.{},
    max_connections: usize = 512,
    rate_limit_rps: u32 = 200,
    rate_limit_burst: u32 = 400,
    trust_proxy: bool = false,
    shutdown_flag: ?*std.atomic.Value(bool) = null,
};

fn enableTcpNoDelay(stream: std.Io.net.Stream) void {
    const one: i32 = 1;
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&one),
    ) catch {};
}

fn setSocketTimeouts(stream: std.Io.net.Stream, rcv_secs: i64, snd_secs: i64) void {
    const rtv = std.posix.timeval{ .sec = @intCast(rcv_secs), .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&rtv)) catch {};
    const stv = std.posix.timeval{ .sec = @intCast(snd_secs), .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&stv)) catch {};
}

pub fn serve(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    config: ServerConfig,
) !void {
    const addr = try std.Io.net.IpAddress.parse(config.host, config.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var active_conns = std.atomic.Value(usize).init(0);
    var limiter = rate_limit.RateLimiter.init(allocator, io, config.rate_limit_rps, config.rate_limit_burst);
    defer limiter.deinit();

    std.debug.print("Concave server listening on http://{s}:{d} (HTTP/1.1 + HTTP/2 h2c + WS)\n", .{ config.host, config.port });

    while (true) {
        if (config.shutdown_flag) |sf| {
            if (sf.load(.acquire)) break;
        }
        const stream = listener.accept(io) catch |err| {
            if (config.shutdown_flag) |sf| {
                if (sf.load(.acquire)) break;
            }
            std.debug.print("accept error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (config.shutdown_flag) |sf| {
            if (sf.load(.acquire)) {
                stream.close(io);
                break;
            }
        }

        const prev_conns = active_conns.fetchAdd(1, .acq_rel);
        if (prev_conns >= config.max_connections) {
            _ = active_conns.fetchSub(1, .acq_rel);
            const busy = makeEmptyResponse(503, "text/plain");
            writeHttp1Response(io, stream, &busy, false);
            stream.close(io);
            continue;
        }

        enableTcpNoDelay(stream);
        setSocketTimeouts(stream, HTTP_SOCKET_TIMEOUT_SECS, HTTP_SOCKET_TIMEOUT_SECS);

        const ConnCtx = struct {
            allocator: Allocator,
            io: std.Io,
            engine: *engine_mod.ConcaveEngine,
            static_dir: ?[]const u8,
            live_reload: bool,
            admin_key: ?[]const u8,
            operator_token: ?[]const u8,
            cors_origins: []const []const u8,
            limiter: *rate_limit.RateLimiter,
            trust_proxy: bool,
            shutdown_flag: ?*std.atomic.Value(bool),
            active_conns: *std.atomic.Value(usize),
            stream: std.Io.net.Stream,

            fn run(ctx: @This()) void {
                defer _ = ctx.active_conns.fetchSub(1, .acq_rel);
                handleConnection(
                    ctx.allocator,
                    ctx.io,
                    ctx.engine,
                    ctx.static_dir,
                    ctx.live_reload,
                    ctx.admin_key,
                    ctx.operator_token,
                    ctx.cors_origins,
                    ctx.limiter,
                    ctx.trust_proxy,
                    ctx.shutdown_flag,
                    ctx.stream,
                );
            }
        };

        const thread = std.Thread.spawn(.{}, ConnCtx.run, .{ConnCtx{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .static_dir = config.static_dir,
            .live_reload = config.live_reload,
            .admin_key = config.admin_key,
            .operator_token = config.operator_token,
            .cors_origins = config.cors_origins,
            .limiter = &limiter,
            .trust_proxy = config.trust_proxy,
            .shutdown_flag = config.shutdown_flag,
            .active_conns = &active_conns,
            .stream = stream,
        }}) catch {
            _ = active_conns.fetchSub(1, .acq_rel);
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

pub const HttpRequest = struct {
    method: []u8,
    path: []u8,
    query: []u8,
    host: ?[]u8 = null,
    origin: ?[]u8 = null,
    content_type: ?[]u8 = null,
    authorization: ?[]u8 = null,
    accept_encoding: ?[]u8 = null,
    if_none_match: ?[]u8 = null,
    headers: []http2.HttpHeader = &.{},
    keep_alive: bool = true,
    upgrade_ws: bool = false,
    ws_key: ?[]u8 = null,
    is_h2_preface: bool = false,
    body: []u8,

    pub fn deinit(self: *const HttpRequest, allocator: Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.query);
        if (self.host) |h| allocator.free(h);
        if (self.origin) |o| allocator.free(o);
        if (self.content_type) |ct| allocator.free(ct);
        if (self.authorization) |a| allocator.free(a);
        if (self.accept_encoding) |ae| allocator.free(ae);
        if (self.if_none_match) |inm| allocator.free(inm);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        if (self.headers.len > 0) allocator.free(self.headers);
        if (self.ws_key) |k| allocator.free(k);
        allocator.free(self.body);
    }

    pub fn asH2View(self: *const HttpRequest) http2.H2Request {
        return .{
            .method = self.method,
            .path = self.path,
            .query = self.query,
            .host = self.host,
            .origin = self.origin,
            .content_type = self.content_type,
            .authorization = self.authorization,
            .accept_encoding = self.accept_encoding,
            .if_none_match = self.if_none_match,
            .headers = self.headers,
            .body = self.body,
        };
    }
};

pub fn readHttpRequest(allocator: Allocator, reader: *std.Io.Reader) !?HttpRequest {
    var stack_head: [8192]u8 = undefined;
    var stack_len: usize = 0;
    var heap_head: std.ArrayList(u8) = .empty;
    defer heap_head.deinit(allocator);
    var use_heap = false;

    var found_end = false;
    while (true) {
        const cur_len = if (use_heap) heap_head.items.len else stack_len;
        if (cur_len >= 64 * 1024) break;
        const b = reader.takeByte() catch return null;
        if (!use_heap) {
            if (stack_len < stack_head.len) {
                stack_head[stack_len] = b;
                stack_len += 1;
                if (stack_len >= 4 and std.mem.eql(u8, stack_head[stack_len - 4 .. stack_len], "\r\n\r\n")) {
                    found_end = true;
                    break;
                }
                continue;
            }
            use_heap = true;
            try heap_head.appendSlice(allocator, stack_head[0..stack_len]);
        }
        try heap_head.append(allocator, b);
        if (heap_head.items.len >= 4 and std.mem.eql(u8, heap_head.items[heap_head.items.len - 4 ..], "\r\n\r\n")) {
            found_end = true;
            break;
        }
    }
    if (!found_end) return error.HeadersTooLarge;

    const head_bytes = if (use_heap) heap_head.items[0 .. heap_head.items.len - 4] else stack_head[0 .. stack_len - 4];
    var lines = std.mem.splitSequence(u8, head_bytes, "\r\n");
    const req_line = lines.next() orelse return null;
    var req_parts = std.mem.splitScalar(u8, req_line, ' ');
    const method_raw = req_parts.next() orelse return error.BadRequest;
    const target_raw = req_parts.next() orelse return error.BadRequest;
    const version_raw = req_parts.next() orelse return error.BadRequest;
    if (req_parts.next() != null) return error.BadRequest;
    if (method_raw.len == 0 or target_raw.len == 0) return error.BadRequest;

    // RFC 9113 HTTP/2 prior-knowledge connection preface begins with `"PRI * HTTP/2.0\r\n\r\n"`.
    if (std.mem.eql(u8, method_raw, "PRI") and std.mem.eql(u8, target_raw, "*") and std.mem.eql(u8, version_raw, "HTTP/2.0")) {
        return .{
            .method = try allocator.dupe(u8, "PRI"),
            .path = try allocator.dupe(u8, "*"),
            .query = try allocator.dupe(u8, ""),
            .is_h2_preface = true,
            .body = try allocator.alloc(u8, 0),
        };
    }

    if (!std.mem.eql(u8, version_raw, "HTTP/1.1") and !std.mem.eql(u8, version_raw, "HTTP/1.0")) {
        return error.BadRequest;
    }

    const path_raw = if (std.mem.indexOfScalar(u8, target_raw, '?')) |qi| target_raw[0..qi] else target_raw;
    const query_raw = if (std.mem.indexOfScalar(u8, target_raw, '?')) |qi| target_raw[qi + 1 ..] else "";

    var content_length: usize = 0;
    var saw_content_length = false;
    var host: ?[]u8 = null;
    errdefer if (host) |h| allocator.free(h);
    var origin: ?[]u8 = null;
    errdefer if (origin) |o| allocator.free(o);
    var content_type: ?[]u8 = null;
    errdefer if (content_type) |ct| allocator.free(ct);
    var auth_header: ?[]u8 = null;
    errdefer if (auth_header) |a| allocator.free(a);
    var accept_encoding: ?[]u8 = null;
    errdefer if (accept_encoding) |ae| allocator.free(ae);
    var if_none_match: ?[]u8 = null;
    errdefer if (if_none_match) |inm| allocator.free(inm);
    var keep_alive = !std.mem.eql(u8, version_raw, "HTTP/1.0");
    var upgrade_ws = false;
    var ws_key: ?[]u8 = null;
    errdefer if (ws_key) |k| allocator.free(k);

    var header_list: std.ArrayList(http2.HttpHeader) = .empty;
    errdefer {
        for (header_list.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        header_list.deinit(allocator);
    }

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Reject obs-fold (RFC 9112 §5.2) and malformed lines without ':'.
        if (line[0] == ' ' or line[0] == '\t') return error.BadRequest;
        const ci = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const hname_raw = line[0..ci];
        // RFC 9112 §5.1: No whitespace allowed between field name and colon.
        if (hname_raw.len == 0 or hname_raw[hname_raw.len - 1] == ' ' or hname_raw[hname_raw.len - 1] == '\t') {
            return error.BadRequest;
        }
        const hname = hname_raw;
        const hval = std.mem.trim(u8, line[ci + 1 ..], " \t");

        if (header_list.items.len >= MAX_HTTP_HEADERS) return error.HeadersTooLarge;
        try header_list.append(allocator, .{
            .name = try allocator.dupe(u8, hname),
            .value = try allocator.dupe(u8, hval),
        });

        // RFC 9112 §6.1 / Request Smuggling defense: reject Transfer-Encoding (unsupported by HTTP/1.1 reader).
        if (std.ascii.eqlIgnoreCase(hname, "Transfer-Encoding")) {
            return error.UnsupportedTransferEncoding;
        } else if (std.ascii.eqlIgnoreCase(hname, "Content-Length")) {
            if (hval.len == 0) return error.BadRequest;
            for (hval) |ch| {
                if (ch < '0' or ch > '9') return error.BadRequest;
            }
            const parsed_len = std.fmt.parseInt(usize, hval, 10) catch return error.BadRequest;
            if (saw_content_length and parsed_len != content_length) {
                return error.BadRequest;
            }
            saw_content_length = true;
            content_length = parsed_len;
        } else if (std.ascii.eqlIgnoreCase(hname, "Host")) {
            if (host) |old| allocator.free(old);
            host = try allocator.dupe(u8, hval);
        } else if (std.ascii.eqlIgnoreCase(hname, "Origin")) {
            if (origin) |old| allocator.free(old);
            origin = try allocator.dupe(u8, hval);
        } else if (std.ascii.eqlIgnoreCase(hname, "Content-Type")) {
            if (content_type) |old| allocator.free(old);
            content_type = try allocator.dupe(u8, hval);
        } else if (std.ascii.eqlIgnoreCase(hname, "Authorization")) {
            if (auth_header) |old| allocator.free(old);
            auth_header = try allocator.dupe(u8, hval);
        } else if (std.ascii.eqlIgnoreCase(hname, "Accept-Encoding")) {
            if (accept_encoding) |old| allocator.free(old);
            accept_encoding = try allocator.dupe(u8, hval);
        } else if (std.ascii.eqlIgnoreCase(hname, "If-None-Match")) {
            if (if_none_match) |old| allocator.free(old);
            if_none_match = try allocator.dupe(u8, hval);
        } else if (std.ascii.eqlIgnoreCase(hname, "Connection")) {
            if (containsAsciiIgnoreCase(hval, "close")) {
                keep_alive = false;
            } else if (containsAsciiIgnoreCase(hval, "keep-alive")) {
                keep_alive = true;
            }
        } else if (std.ascii.eqlIgnoreCase(hname, "Upgrade") and std.ascii.eqlIgnoreCase(hval, "websocket")) {
            upgrade_ws = true;
        } else if (std.ascii.eqlIgnoreCase(hname, "Sec-WebSocket-Key")) {
            if (ws_key) |old| allocator.free(old);
            ws_key = try allocator.dupe(u8, hval);
        }
    }

    if (content_length > 16 * 1024 * 1024) return error.PayloadTooLarge;
    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    if (content_length > 0) {
        try reader.readSliceAll(body);
    }

    return .{
        .method = try allocator.dupe(u8, method_raw),
        .path = try allocator.dupe(u8, path_raw),
        .query = try allocator.dupe(u8, query_raw),
        .host = host,
        .origin = origin,
        .content_type = content_type,
        .authorization = auth_header,
        .accept_encoding = accept_encoding,
        .if_none_match = if_none_match,
        .headers = try header_list.toOwnedSlice(allocator),
        .keep_alive = keep_alive,
        .upgrade_ws = upgrade_ws,
        .ws_key = ws_key,
        .body = body,
    };
}

fn formatPeerIp(addr: std.Io.net.IpAddress, buf: *[64]u8) []const u8 {
    return switch (addr) {
        .ip4 => |v4| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
            v4.bytes[0], v4.bytes[1], v4.bytes[2], v4.bytes[3],
        }) catch "unknown",
        .ip6 => |v6| std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}", .{
            v6.bytes[0], v6.bytes[1], v6.bytes[2], v6.bytes[3],
            v6.bytes[4], v6.bytes[5], v6.bytes[6], v6.bytes[7],
        }) catch "unknown",
    };
}

fn findHeaderValue(headers: []const http2.HttpHeader, name: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

const DispatchCtx = struct {
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    static_dir: ?[]const u8,
    live_reload: bool,
    admin_key: ?[]const u8,
    operator_token: ?[]const u8,
    cors_origins: []const []const u8,
    limiter: ?*rate_limit.RateLimiter = null,
    trust_proxy: bool = false,
    peer_ip: []const u8 = "unknown",

    fn h2Dispatch(ptr: *anyopaque, allocator: Allocator, req: *const http2.H2Request) http2.H2Response {
        const self: *DispatchCtx = @ptrCast(@alignCast(ptr));
        return dispatchHttpRequest(
            allocator,
            self.io,
            self.engine,
            self.static_dir,
            self.live_reload,
            self.admin_key,
            self.operator_token,
            self.cors_origins,
            self.limiter,
            self.trust_proxy,
            self.peer_ip,
            req,
        );
    }
};

fn handleConnection(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    static_dir: ?[]const u8,
    live_reload: bool,
    admin_key: ?[]const u8,
    operator_token: ?[]const u8,
    cors_origins: []const []const u8,
    limiter: *rate_limit.RateLimiter,
    trust_proxy: bool,
    shutdown_flag: ?*std.atomic.Value(bool),
    stream: std.Io.net.Stream,
) void {
    var stream_handed_off = false;
    defer if (!stream_handed_off) stream.close(io);

    var peer_ip_buf: [64]u8 = undefined;
    const peer_ip = formatPeerIp(stream.socket.address, &peer_ip_buf);

    var rbuf: [8192]u8 = undefined;
    var sr = stream.reader(io, &rbuf);

    var dctx = DispatchCtx{
        .io = io,
        .engine = engine,
        .static_dir = static_dir,
        .live_reload = live_reload,
        .admin_key = admin_key,
        .operator_token = operator_token,
        .cors_origins = cors_origins,
        .limiter = limiter,
        .trust_proxy = trust_proxy,
        .peer_ip = peer_ip,
    };

    var req_arena = std.heap.ArenaAllocator.init(allocator);
    defer req_arena.deinit();

    var first_req = true;
    while (true) {
        if (shutdown_flag) |sf| {
            if (sf.load(.acquire)) break;
        }
        defer _ = req_arena.reset(.{ .retain_with_limit = 64 * 1024 });
        const ra = req_arena.allocator();

        const maybe_req = readHttpRequest(ra, &sr.interface) catch |err| {
            const err_status: u16 = switch (err) {
                error.HeadersTooLarge => 431,
                error.PayloadTooLarge => 413,
                error.UnsupportedTransferEncoding => 501,
                error.BadRequest => 400,
                else => return,
            };
            const err_resp = makeEmptyResponse(err_status, "text/plain");
            engine.metrics.recordHttpStatus(err_status);
            writeHttp1Response(io, stream, &err_resp, false);
            return;
        };
        const req = maybe_req orelse return;

        // Seamless HTTP/2 (`h2c` prior knowledge) upgrade on first request preface
        if (first_req and req.is_h2_preface) {
            var tail: [6]u8 = undefined;
            sr.interface.readSliceAll(&tail) catch return;
            if (!std.mem.eql(u8, &tail, "SM\r\n\r\n")) return;
            http2.serveConnection(allocator, io, stream, &sr.interface, @ptrCast(&dctx), &DispatchCtx.h2Dispatch);
            return;
        }
        first_req = false;

        // WebSocket upgrade on `/ws`
        if (req.upgrade_ws and std.mem.eql(u8, req.path, "/ws")) {
            if (!isWsOriginAllowed(req.origin, req.host, cors_origins, engine.auth_config.allow_dev_tokens)) {
                const err_resp = makePlainResponse(ra, 403, "text/plain", "forbidden origin") catch return;
                engine.metrics.recordHttpStatus(403);
                writeHttp1Response(io, stream, &err_resp, false);
                return;
            }
            const key = req.ws_key orelse {
                const err_resp = makePlainResponse(ra, 400, "text/plain", "missing Sec-WebSocket-Key") catch return;
                engine.metrics.recordHttpStatus(400);
                writeHttp1Response(io, stream, &err_resp, false);
                return;
            };
            var accept_buf: [28]u8 = undefined;
            const accept = ws_mod.computeAcceptKey(key, &accept_buf);

            var wbuf: [512]u8 = undefined;
            var sw = stream.writer(io, &wbuf);
            sw.interface.print(
                "HTTP/1.1 101 Switching Protocols\r\n" ++
                    "Upgrade: websocket\r\n" ++
                    "Connection: Upgrade\r\n" ++
                    "Sec-WebSocket-Accept: {s}\r\n\r\n",
                .{accept},
            ) catch return;
            sw.interface.flush() catch return;

            // Clear HTTP read timeout so idle WebSocket subscribers stay connected;
            // WsSender applies its own 5s write timeout.
            setSocketTimeouts(stream, 0, 5);
            const initial_binary = std.mem.indexOf(u8, req.query, "proto=bin") != null;
            stream_handed_off = true;
            handleWebSocket(allocator, io, engine, stream, &sr.interface, initial_binary);
            return;
        }

        const h2_view = req.asH2View();
        const resp = dispatchHttpRequest(
            ra,
            io,
            engine,
            static_dir,
            live_reload,
            admin_key,
            operator_token,
            cors_origins,
            limiter,
            trust_proxy,
            peer_ip,
            &h2_view,
        );

        const shutting_down = if (shutdown_flag) |sf| sf.load(.acquire) else false;
        const keep_conn = req.keep_alive and !shutting_down and resp.status < 400;
        writeHttp1Response(io, stream, &resp, keep_conn);
        if (!keep_conn) break;
    }
}

/// Unified HTTP/1.1 + HTTP/2 request router with zero-cost pre-compressed embedded assets,
/// ETag/304 caching, security headers, edge rate limiting, CORS policy, and automatic gzip compression.
fn dispatchHttpRequest(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    static_dir: ?[]const u8,
    live_reload: bool,
    admin_key: ?[]const u8,
    operator_token: ?[]const u8,
    cors_origins: []const []const u8,
    limiter: ?*rate_limit.RateLimiter,
    trust_proxy: bool,
    peer_ip: []const u8,
    req: *const http2.H2Request,
) http2.H2Response {
    if (limiter) |rl| {
        if (!std.mem.eql(u8, req.path, "/health") and !std.mem.eql(u8, req.path, "/ready")) {
            const xff = findHeaderValue(req.headers, "x-forwarded-for");
            const client_ip = rate_limit.extractClientIp(peer_ip, xff, trust_proxy);
            const decision = rl.check(client_ip);
            if (!decision.allowed) {
                var r429 = makeResponse(allocator, 429, "application/json", "{\"error\":\"rate limit exceeded\"}", false);
                r429.retry_after_secs = decision.retry_after_secs;
                r429.cors_allow_origin = resolveCorsOrigin(req.path, req.origin, cors_origins, engine.auth_config.allow_dev_tokens);
                engine.metrics.recordHttpStatus(429);
                return r429;
            }
        }
    }
    var resp = dispatchHttpRequestInner(allocator, io, engine, static_dir, live_reload, admin_key, operator_token, req);
    resp.cors_allow_origin = resolveCorsOrigin(req.path, req.origin, cors_origins, engine.auth_config.allow_dev_tokens);
    engine.metrics.recordHttpStatus(resp.status);
    return resp;
}

fn dispatchHttpRequestInner(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    static_dir: ?[]const u8,
    live_reload: bool,
    admin_key: ?[]const u8,
    operator_token: ?[]const u8,
    req: *const http2.H2Request,
) http2.H2Response {
    const want_gzip = compress.acceptsGzip(req.accept_encoding);

    // CORS preflight
    if (std.mem.eql(u8, req.method, "OPTIONS")) {
        return makeEmptyResponse(204, "text/plain");
    }

    // Health & Readiness probes
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/health")) {
        return makeResponse(allocator, 200, "application/json", "{\"status\":\"ok\"}", false);
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/ready")) {
        const ts = engine.readyCheck() catch {
            return makeResponse(allocator, 503, "application/json", "{\"status\":\"unavailable\"}", false);
        };
        const body = std.fmt.allocPrint(allocator, "{{\"status\":\"ready\",\"commit_ts\":{d}}}", .{ts}) catch
            return makeEmptyResponse(500, "application/json");
        defer allocator.free(body);
        return makeResponse(allocator, 200, "application/json", body, false);
    }

    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/api/manifest")) {
        return makeResponse(allocator, 200, "application/json", engine.manifest.raw_json, want_gzip);
    }

    // Embedded Live Dev Dashboard (`/_dashboard`) — minified, pre-gzipped, ETag-cached + strict CSP
    if (std.mem.eql(u8, req.method, "GET")) {
        if (std.mem.eql(u8, req.path, "/_dashboard") or std.mem.eql(u8, req.path, "/_dashboard/")) {
            var resp = serveEmbeddedAsset(allocator, &assets.dashboard_index_html, want_gzip, req.if_none_match);
            resp.content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; img-src 'self' data:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'";
            resp.x_frame_options = "DENY";
            return resp;
        }
        if (std.mem.eql(u8, req.path, "/_dashboard/styles.css")) {
            return serveEmbeddedAsset(allocator, &assets.dashboard_styles_css, want_gzip, req.if_none_match);
        }
        if (std.mem.eql(u8, req.path, "/_dashboard/app.js")) {
            return serveEmbeddedAsset(allocator, &assets.dashboard_app_js, want_gzip, req.if_none_match);
        }
    }

    // Platform Operator Reliability Endpoints (`/_internal/metrics`, `/_internal/status`)
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/_internal/")) {
        const expected_tok = operator_token orelse admin_key;
        if (!isOperatorAuthorized(engine, expected_tok, req.authorization)) {
            const status: u16 = if (expected_tok != null) 401 else 403;
            return makeResponse(allocator, status, "application/json", "{\"error\":\"operator access denied\"}", false);
        }
        if (std.mem.eql(u8, req.path, "/_internal/metrics")) {
            const body = engine.formatPrometheusMetrics(allocator) catch
                return makeResponse(allocator, 500, "text/plain", "metrics unavailable", false);
            defer allocator.free(body);
            return makeResponse(allocator, 200, "text/plain; version=0.0.4; charset=utf-8", body, want_gzip);
        }
        if (std.mem.eql(u8, req.path, "/_internal/status")) {
            const body = engine.formatInternalStatusJson(allocator) catch
                return makeResponse(allocator, 500, "application/json", "{\"error\":\"status unavailable\"}", false);
            defer allocator.free(body);
            return makeResponse(allocator, 200, "application/json", body, want_gzip);
        }
        return makeResponse(allocator, 404, "application/json", "{\"error\":\"unknown internal endpoint\"}", false);
    }

    // Admin inspection endpoints (`/_admin/stats`, `/_admin/table`, `/_admin/jobs`)
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/_admin/")) {
        if (!isAdminAuthorized(engine, admin_key, req.authorization)) {
            const status: u16 = if (admin_key != null) 401 else 403;
            return makeResponse(allocator, status, "application/json", "{\"error\":\"admin access denied\"}", false);
        }
        if (std.mem.eql(u8, req.path, "/_admin/stats")) {
            const stats = engine.getStats();
            const raw = engine.manifest.raw_json;
            const inner = if (raw.len >= 2 and raw[0] == '{' and raw[raw.len - 1] == '}') raw[1 .. raw.len - 1] else "";
            const body = std.fmt.allocPrint(
                allocator,
                "{{\"commit_ts\":{d},\"active_clients\":{d},\"active_subscriptions\":{d},{s}}}",
                .{ stats.commit_ts, stats.active_clients, stats.active_subscriptions, inner },
            ) catch return makeEmptyResponse(500, "application/json");
            defer allocator.free(body);
            return makeResponse(allocator, 200, "application/json", body, want_gzip);
        }
        if (std.mem.eql(u8, req.path, "/_admin/jobs")) {
            const docs = engine.adminScanTable(allocator, "_system", "_scheduled_jobs", 100) catch
                return makeResponse(allocator, 500, "application/json", "{\"error\":\"failed to list jobs\"}", false);
            defer {
                for (docs) |*d| d.deinit(allocator);
                allocator.free(docs);
            }
            return buildDocsJsonResponse(allocator, docs, want_gzip);
        }
        if (std.mem.eql(u8, req.path, "/_admin/table")) {
            const ns = getQueryParamDecoded(allocator, req.query, "ns") catch null;
            defer if (ns) |v| allocator.free(v);
            const tbl = getQueryParamDecoded(allocator, req.query, "table") catch null;
            defer if (tbl) |v| allocator.free(v);
            if (tbl == null or tbl.?.len == 0) {
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing table parameter\"}", false);
            }
            const lim_str = getQueryParamDecoded(allocator, req.query, "limit") catch null;
            defer if (lim_str) |v| allocator.free(v);
            const limit: usize = if (lim_str) |ls| std.fmt.parseInt(usize, ls, 10) catch 100 else 100;

            const docs = engine.adminScanTable(allocator, ns orelse "", tbl.?, limit) catch
                return makeResponse(allocator, 500, "application/json", "{\"error\":\"failed to scan table\"}", false);
            defer {
                for (docs) |*d| d.deinit(allocator);
                allocator.free(docs);
            }
            return buildDocsJsonResponse(allocator, docs, want_gzip);
        }
        return makeResponse(allocator, 404, "application/json", "{\"error\":\"unknown admin endpoint\"}", false);
    }

    // Admin mutation endpoints (`/_admin/doc/patch`, `/_admin/doc/delete`, `/_admin/jobs/retry`, `/_admin/jobs/cancel`)
    if (std.mem.eql(u8, req.method, "POST") and std.mem.startsWith(u8, req.path, "/_admin/")) {
        if (!isAdminAuthorized(engine, admin_key, req.authorization)) {
            const status: u16 = if (admin_key != null) 401 else 403;
            return makeResponse(allocator, status, "application/json", "{\"error\":\"admin access denied\"}", false);
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, if (req.body.len > 0) req.body else "{}", .{}) catch
            return makeResponse(allocator, 400, "application/json", "{\"error\":\"invalid JSON body\"}", false);
        if (parsed != .object) {
            return makeResponse(allocator, 400, "application/json", "{\"error\":\"expected JSON object\"}", false);
        }

        if (std.mem.eql(u8, req.path, "/_admin/doc/patch")) {
            const ns = jsonStringField(parsed.object, "ns") orelse "";
            const tbl = jsonStringField(parsed.object, "table") orelse
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing table\"}", false);
            const id = jsonStringField(parsed.object, "id") orelse
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing id\"}", false);
            const patch_val = parsed.object.get("patch") orelse
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing patch\"}", false);
            const patch_json = storage_mod.stringifyJsonValue(a, patch_val) catch
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"invalid patch\"}", false);
            engine.adminPatchDoc(ns, tbl, id, patch_json) catch |err| {
                const st: u16 = switch (err) {
                    storage_mod.StorageError.AccessDenied => 403,
                    storage_mod.StorageError.NotFound => 404,
                    storage_mod.StorageError.SchemaViolation, storage_mod.StorageError.InvalidJson, storage_mod.StorageError.UnknownTable => 400,
                    else => 500,
                };
                const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"patch failed\"}";
                defer if (!std.mem.eql(u8, msg, "{\"error\":\"patch failed\"}")) allocator.free(msg);
                return makeResponse(allocator, st, "application/json", msg, false);
            };
            return makeResponse(allocator, 200, "application/json", "{\"ok\":true}", false);
        }
        if (std.mem.eql(u8, req.path, "/_admin/doc/delete")) {
            const ns = jsonStringField(parsed.object, "ns") orelse "";
            const tbl = jsonStringField(parsed.object, "table") orelse
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing table\"}", false);
            const id = jsonStringField(parsed.object, "id") orelse
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing id\"}", false);
            engine.adminDeleteDoc(ns, tbl, id) catch |err| {
                const st: u16 = switch (err) {
                    storage_mod.StorageError.AccessDenied => 403,
                    storage_mod.StorageError.NotFound => 404,
                    else => 500,
                };
                const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"delete failed\"}";
                defer if (!std.mem.eql(u8, msg, "{\"error\":\"delete failed\"}")) allocator.free(msg);
                return makeResponse(allocator, st, "application/json", msg, false);
            };
            return makeResponse(allocator, 200, "application/json", "{\"ok\":true}", false);
        }
        if (std.mem.eql(u8, req.path, "/_admin/jobs/retry")) {
            const job_id = jsonStringField(parsed.object, "job_id") orelse
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing job_id\"}", false);
            const ok = engine.adminRetryJob(job_id) catch
                return makeResponse(allocator, 500, "application/json", "{\"error\":\"retry failed\"}", false);
            if (!ok) return makeResponse(allocator, 404, "application/json", "{\"error\":\"job not found\"}", false);
            return makeResponse(allocator, 200, "application/json", "{\"ok\":true}", false);
        }
        if (std.mem.eql(u8, req.path, "/_admin/jobs/cancel")) {
            const job_id = jsonStringField(parsed.object, "job_id") orelse
                return makeResponse(allocator, 400, "application/json", "{\"error\":\"missing job_id\"}", false);
            const ok = engine.adminCancelJob(job_id) catch
                return makeResponse(allocator, 500, "application/json", "{\"error\":\"cancel failed\"}", false);
            if (!ok) return makeResponse(allocator, 404, "application/json", "{\"error\":\"job not found\"}", false);
            return makeResponse(allocator, 200, "application/json", "{\"ok\":true}", false);
        }
        return makeResponse(allocator, 404, "application/json", "{\"error\":\"unknown admin endpoint\"}", false);
    }

    // Embedded zero-dependency browser ESM client at `/_concave/*` — bundled, minified, pre-gzipped, ETag-cached
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/_concave/")) {
        const file = req.path["/_concave/".len..];
        const maybe_asset: ?*const assets.Asset = if (std.mem.eql(u8, file, "index.js"))
            &assets.client_index_js
        else if (std.mem.eql(u8, file, "signals.js"))
            &assets.client_signals_js
        else if (std.mem.eql(u8, file, "client.js"))
            &assets.client_client_js
        else if (std.mem.eql(u8, file, "dom.js"))
            &assets.client_dom_js
        else if (std.mem.eql(u8, file, "router.js"))
            &assets.client_router_js
        else if (std.mem.eql(u8, file, "auth.js"))
            &assets.auth_client_js
        else if (std.mem.eql(u8, file, "analytics.js"))
            &assets.analytics_client_js
        else if (std.mem.eql(u8, file, "monitor.js"))
            &assets.monitor_client_js
        else
            null;
        if (maybe_asset) |a| {
            return serveEmbeddedAsset(allocator, a, want_gzip, req.if_none_match);
        }
        return makeResponse(allocator, 404, "text/plain", "not found", false);
    }

    // HTTP RPC endpoints: `/api/query/<name>`, `/api/mutation/<name>`, `/api/action/<name>`
    if (std.mem.eql(u8, req.method, "POST") and std.mem.startsWith(u8, req.path, "/api/")) {
        var auth_id: ?auth_mod.AuthIdentity = null;
        defer if (auth_id) |*a| a.deinit(allocator);
        if (req.authorization) |raw_auth| {
            auth_id = engine.verifyAuthToken(allocator, raw_auth) catch {
                return makeResponse(allocator, 401, "application/json", "{\"ok\":false,\"error\":\"unauthorized\"}", false);
            };
        }
        const args_json = if (req.body.len > 0) req.body else "{}";

        if (std.mem.startsWith(u8, req.path, "/api/query/")) {
            const name = req.path["/api/query/".len..];
            const res = engine.executeQuery(allocator, name, args_json, if (auth_id) |*a| a else null) catch
                return makeResponse(allocator, 500, "application/json", "{\"ok\":false,\"error\":\"internal error\"}", false);
            defer res.deinit(allocator);
            return buildRpcResultResponse(allocator, res, null, want_gzip);
        }
        if (std.mem.startsWith(u8, req.path, "/api/mutation/")) {
            const name = req.path["/api/mutation/".len..];
            const mres = engine.executeMutation(allocator, name, args_json, if (auth_id) |*a| a else null) catch
                return makeResponse(allocator, 500, "application/json", "{\"ok\":false,\"error\":\"internal error\"}", false);
            defer mres.deinit(allocator);
            return buildRpcResultResponse(allocator, mres.result, if (mres.result == .ok) mres.commit_ts else null, want_gzip);
        }
        if (std.mem.startsWith(u8, req.path, "/api/action/")) {
            const name = req.path["/api/action/".len..];
            const res = engine.executeAction(allocator, name, args_json, if (auth_id) |*a| a else null) catch
                return makeResponse(allocator, 500, "application/json", "{\"ok\":false,\"error\":\"internal error\"}", false);
            defer res.deinit(allocator);
            return buildRpcResultResponse(allocator, res, null, want_gzip);
        }
    }

    // Built-in local blob storage upload & download endpoints (`/_storage/...`)
    if (std.mem.startsWith(u8, req.path, "/_storage/upload/") and
        (std.mem.eql(u8, req.method, "POST") or std.mem.eql(u8, req.method, "PUT")))
    {
        const bs = engine.blob_store orelse
            return makeResponse(allocator, 503, "application/json", "{\"error\":\"storage not configured\"}", false);
        const token = req.path["/_storage/upload/".len..];
        const storage_id = bs.consumeUploadToken(allocator, token) catch
            return makeResponse(allocator, 403, "application/json", "{\"error\":\"invalid, expired, or already-used upload token\"}", false);
        defer allocator.free(storage_id);
        const ct = req.content_type orelse "application/octet-stream";
        bs.putLocalBlob(storage_id, ct, req.body) catch
            return makeResponse(allocator, 500, "application/json", "{\"error\":\"failed to store blob\"}", false);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        out.writer.writeAll("{\"storage_id\":") catch return makeEmptyResponse(500, "application/json");
        storage_mod.writeJsonString(&out.writer, storage_id) catch return makeEmptyResponse(500, "application/json");
        out.writer.writeByte('}') catch return makeEmptyResponse(500, "application/json");
        return makeResponse(allocator, 200, "application/json", out.written(), false);
    }

    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/_storage/")) {
        const bs = engine.blob_store orelse
            return makeResponse(allocator, 503, "text/plain", "storage not configured", false);
        const storage_id = req.path["/_storage/".len..];
        const blob = bs.getLocalBlob(allocator, storage_id) catch
            return makeResponse(allocator, 404, "text/plain", "blob not found", false);
        defer blob.deinit(allocator);
        // Never serve untrusted user uploads as active web documents (HTML/SVG/JS/XML) on the app origin.
        const ct_static = safeStorageMime(blob.content_type);
        var resp = makeResponse(allocator, 200, ct_static, blob.bytes, want_gzip);
        resp.content_disposition = "attachment";
        resp.content_security_policy = "default-src 'none'; sandbox";
        resp.x_frame_options = "DENY";
        return resp;
    }

    // Custom application HTTP routes / webhooks (`App.http_route`)
    if (engine.manifest.matchHttpRoute(req.method, req.path) != null) {
        var auth_id: ?auth_mod.AuthIdentity = null;
        defer if (auth_id) |*a| a.deinit(allocator);
        if (req.authorization) |raw_auth| {
            auth_id = engine.verifyAuthToken(allocator, raw_auth) catch {
                return makeResponse(allocator, 401, "application/json", "{\"error\":\"unauthorized\"}", false);
            };
        }

        var req_out: std.Io.Writer.Allocating = .init(allocator);
        defer req_out.deinit();
        const rw = &req_out.writer;
        rw.writeAll("{\"method\":") catch return makeEmptyResponse(500, "application/json");
        storage_mod.writeJsonString(rw, req.method) catch return makeEmptyResponse(500, "application/json");
        rw.writeAll(",\"path\":") catch return makeEmptyResponse(500, "application/json");
        storage_mod.writeJsonString(rw, req.path) catch return makeEmptyResponse(500, "application/json");
        rw.writeAll(",\"query\":") catch return makeEmptyResponse(500, "application/json");
        storage_mod.writeJsonString(rw, req.query) catch return makeEmptyResponse(500, "application/json");
        rw.writeAll(",\"body\":") catch return makeEmptyResponse(500, "application/json");
        storage_mod.writeJsonString(rw, req.body) catch return makeEmptyResponse(500, "application/json");
        rw.writeAll(",\"content_type\":") catch return makeEmptyResponse(500, "application/json");
        storage_mod.writeJsonString(rw, req.content_type orelse "") catch return makeEmptyResponse(500, "application/json");
        rw.writeAll(",\"headers\":[") catch return makeEmptyResponse(500, "application/json");
        for (req.headers, 0..) |hdr, hi| {
            if (hi > 0) rw.writeByte(',') catch return makeEmptyResponse(500, "application/json");
            rw.writeAll("{\"name\":") catch return makeEmptyResponse(500, "application/json");
            storage_mod.writeJsonString(rw, hdr.name) catch return makeEmptyResponse(500, "application/json");
            rw.writeAll(",\"value\":") catch return makeEmptyResponse(500, "application/json");
            storage_mod.writeJsonString(rw, hdr.value) catch return makeEmptyResponse(500, "application/json");
            rw.writeByte('}') catch return makeEmptyResponse(500, "application/json");
        }
        rw.writeAll("]}") catch return makeEmptyResponse(500, "application/json");

        const res = engine.executeHttpRoute(
            allocator,
            req.method,
            req.path,
            req_out.written(),
            if (auth_id) |*a| a else null,
        ) catch return makeResponse(allocator, 500, "application/json", "{\"error\":\"internal error\"}", false);
        defer res.deinit(allocator);

        switch (res) {
            .ok => |val| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), val, .{}) catch {
                    return makeResponse(allocator, 200, "application/json", val, want_gzip);
                };
                if (parsed == .object) {
                    const status: u16 = if (parsed.object.get("status")) |sv|
                        (if (sv == .integer and sv.integer >= 100 and sv.integer <= 599) @intCast(sv.integer) else 200)
                    else
                        200;
                    const ct_raw = if (parsed.object.get("content_type")) |cv|
                        (if (cv == .string and cv.string.len > 0) cv.string else "application/json")
                    else
                        "application/json";
                    const resp_body = if (parsed.object.get("body")) |bv|
                        (if (bv == .string) bv.string else "")
                    else
                        "";
                    var route_resp = makeResponse(allocator, status, internCommonMime(ct_raw), resp_body, want_gzip);
                    if (parsed.object.get("headers")) |hv| {
                        if (hv == .array and hv.array.items.len > 0) {
                            var extra: std.ArrayList(http2.HttpHeader) = .empty;
                            for (hv.array.items) |item| {
                                if (item != .object) continue;
                                const hn = jsonStringField(item.object, "name") orelse continue;
                                const hval = jsonStringField(item.object, "value") orelse continue;
                                if (!isValidResponseHeader(hn, hval)) continue;
                                if (std.ascii.eqlIgnoreCase(hn, "cache-control")) {
                                    // Preserve custom Cache-Control cleanly without duplicating.
                                }
                                const dn = allocator.dupe(u8, hn) catch continue;
                                const dv = allocator.dupe(u8, hval) catch {
                                    allocator.free(dn);
                                    continue;
                                };
                                extra.append(allocator, .{ .name = dn, .value = dv }) catch {
                                    allocator.free(dn);
                                    allocator.free(dv);
                                };
                            }
                            if (extra.items.len > 0) {
                                route_resp.extra_headers = extra.toOwnedSlice(allocator) catch &.{};
                                route_resp.extra_headers_owned = route_resp.extra_headers.len > 0;
                            } else {
                                extra.deinit(allocator);
                            }
                        }
                    }
                    return route_resp;
                }
                return makeResponse(allocator, 200, "application/json", val, want_gzip);
            },
            .err => |msg| {
                var eout: std.Io.Writer.Allocating = .init(allocator);
                defer eout.deinit();
                eout.writer.writeAll("{\"error\":") catch return makeEmptyResponse(500, "application/json");
                storage_mod.writeJsonString(&eout.writer, msg) catch return makeEmptyResponse(500, "application/json");
                eout.writer.writeByte('}') catch return makeEmptyResponse(500, "application/json");
                return makeResponse(allocator, 500, "application/json", eout.written(), false);
            },
        }
    }

    // Static frontend serving from `--static-dir` (with ETag/304 + gzip compression)
    if (std.mem.eql(u8, req.method, "GET")) {
        if (static_dir) |root| {
            return serveStaticFileResponse(allocator, io, root, req.path, want_gzip, req.if_none_match, live_reload);
        }
    }

    return makeResponse(allocator, 404, "text/plain", "not found", false);
}

fn serveEmbeddedAsset(
    _: Allocator,
    asset: *const assets.Asset,
    want_gzip: bool,
    if_none_match: ?[]const u8,
) http2.H2Response {
    if (compress.etagMatches(if_none_match, asset.etag)) {
        return .{
            .status = 304,
            .content_type = asset.content_type,
            .body = &.{},
            .body_owned = false,
            .etag = @constCast(asset.etag),
            .etag_owned = false,
            .cache_control = "public, max-age=3600",
        };
    }
    const use_gz = want_gzip and asset.gzip.len < asset.raw.len;
    const payload = if (use_gz) asset.gzip else asset.raw;
    return .{
        .status = 200,
        .content_type = asset.content_type,
        .body = @constCast(payload),
        .body_owned = false,
        .content_encoding = if (use_gz) "gzip" else null,
        .etag = @constCast(asset.etag),
        .etag_owned = false,
        .cache_control = "public, max-age=3600",
    };
}

fn makeEmptyResponse(status: u16, content_type: []const u8) http2.H2Response {
    return .{
        .status = status,
        .content_type = content_type,
        .body = &.{},
        .body_owned = false,
    };
}

fn makePlainResponse(allocator: Allocator, status: u16, content_type: []const u8, body: []const u8) !http2.H2Response {
    return .{
        .status = status,
        .content_type = content_type,
        .body = try allocator.dupe(u8, body),
    };
}

fn makeResponse(
    allocator: Allocator,
    status: u16,
    content_type: []const u8,
    raw_body: []const u8,
    want_gzip: bool,
) http2.H2Response {
    if (want_gzip and raw_body.len >= DYNAMIC_GZIP_MIN_BYTES and compress.isCompressibleMime(content_type)) {
        if (compress.gzipCompress(allocator, raw_body, .fast)) |gz| {
            if (gz.len < raw_body.len) {
                return .{
                    .status = status,
                    .content_type = content_type,
                    .body = gz,
                    .content_encoding = "gzip",
                };
            }
            allocator.free(gz);
        } else |_| {}
    }
    return .{
        .status = status,
        .content_type = content_type,
        .body = allocator.dupe(u8, raw_body) catch &.{},
    };
}

fn buildRpcResultResponse(allocator: Allocator, res: engine_mod.ExecResult, commit_ts: ?i64, want_gzip: bool) http2.H2Response {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    switch (res) {
        .ok => |val| {
            w.writeAll("{\"ok\":true,\"value\":") catch return makeEmptyResponse(500, "application/json");
            w.writeAll(val) catch return makeEmptyResponse(500, "application/json");
            if (commit_ts) |ts| {
                w.print(",\"commit_ts\":{d}", .{ts}) catch return makeEmptyResponse(500, "application/json");
            }
            w.writeByte('}') catch return makeEmptyResponse(500, "application/json");
            return makeResponse(allocator, 200, "application/json", out.written(), want_gzip);
        },
        .err => |msg| {
            w.writeAll("{\"ok\":false,\"error\":") catch return makeEmptyResponse(500, "application/json");
            storage_mod.writeJsonString(w, msg) catch return makeEmptyResponse(500, "application/json");
            w.writeByte('}') catch return makeEmptyResponse(500, "application/json");
            return makeResponse(allocator, 400, "application/json", out.written(), false);
        },
    }
}

fn buildDocsJsonResponse(allocator: Allocator, docs: []const storage_mod.Document, want_gzip: bool) http2.H2Response {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    out.writer.writeByte('[') catch return makeEmptyResponse(500, "application/json");
    for (docs, 0..) |*d, i| {
        if (i > 0) out.writer.writeByte(',') catch return makeEmptyResponse(500, "application/json");
        d.writeWireJson(&out.writer) catch return makeEmptyResponse(500, "application/json");
    }
    out.writer.writeByte(']') catch return makeEmptyResponse(500, "application/json");
    return makeResponse(allocator, 200, "application/json", out.written(), want_gzip);
}

/// Decode percent-encoding and reject path traversal (`..`, `\`, NUL bytes, control chars).
pub fn sanitizeStaticPath(allocator: Allocator, raw_path: []const u8) ![]u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);

    var i: usize = 0;
    while (i < raw_path.len) {
        if (raw_path[i] == '%') {
            if (i + 2 >= raw_path.len) return error.ForbiddenPath;
            const byte = std.fmt.parseInt(u8, raw_path[i + 1 .. i + 3], 16) catch return error.ForbiddenPath;
            try decoded.append(allocator, byte);
            i += 3;
        } else {
            try decoded.append(allocator, raw_path[i]);
            i += 1;
        }
    }

    for (decoded.items) |b| {
        if (b == 0 or b == '\\' or b < 0x20) return error.ForbiddenPath;
    }

    const trimmed = std.mem.trimStart(u8, decoded.items, "/");
    const rel = if (trimmed.len == 0) "index.html" else trimmed;

    var segs = std.mem.splitScalar(u8, rel, '/');
    while (segs.next()) |seg| {
        if (seg.len == 0) continue;
        // Reject `.`, `..`, and any dotfiles/hidden directories (`.env`, `.git`, `.htaccess`, etc.).
        if (seg[0] == '.') {
            return error.ForbiddenPath;
        }
    }

    return try allocator.dupe(u8, rel);
}

fn serveStaticFileResponse(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    raw_path: []const u8,
    want_gzip: bool,
    if_none_match: ?[]const u8,
    live_reload: bool,
) http2.H2Response {
    const rel = sanitizeStaticPath(allocator, raw_path) catch
        return makeResponse(allocator, 403, "text/plain", "forbidden", false);
    defer allocator.free(rel);

    const full_path = std.fs.path.join(allocator, &.{ root, rel }) catch
        return makeEmptyResponse(500, "text/plain");
    defer allocator.free(full_path);

    // Resolve symlinks and verify canonical containment inside `root` (prevents symlink escape).
    const real_root = std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator) catch
        return makeResponse(allocator, 404, "text/plain", "not found", false);
    defer allocator.free(real_root);
    const real_file = std.Io.Dir.cwd().realPathFileAlloc(io, full_path, allocator) catch
        return makeResponse(allocator, 404, "text/plain", "not found", false);
    defer allocator.free(real_file);
    const root_trimmed = std.mem.trimEnd(u8, real_root, "/");
    if (!std.mem.startsWith(u8, real_file, root_trimmed) or
        real_file.len <= root_trimmed.len or
        real_file[root_trimmed.len] != '/')
    {
        return makeResponse(allocator, 403, "text/plain", "forbidden", false);
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, real_file, allocator, .limited(16 * 1024 * 1024)) catch
        return makeResponse(allocator, 404, "text/plain", "not found", false);
    defer allocator.free(bytes);

    const mime = mimeType(full_path);
    var etag_buf: [18]u8 = undefined;
    const etag = compress.computeEtag(bytes, &etag_buf);
    const etag_copy = allocator.dupe(u8, etag) catch null;
    const cache_control: []const u8 = if (live_reload) "no-cache" else "public, max-age=60";

    if (compress.etagMatches(if_none_match, etag)) {
        return .{
            .status = 304,
            .content_type = mime,
            .body = allocator.alloc(u8, 0) catch &.{},
            .etag = etag_copy,
            .cache_control = cache_control,
        };
    }

    var resp = makeResponse(allocator, 200, mime, bytes, want_gzip);
    resp.etag = etag_copy;
    resp.cache_control = cache_control;
    return resp;
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

fn internCommonMime(ct: []const u8) []const u8 {
    if (std.mem.eql(u8, ct, "application/json")) return "application/json";
    if (std.mem.eql(u8, ct, "application/json; charset=utf-8")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ct, "text/plain")) return "text/plain";
    if (std.mem.eql(u8, ct, "text/plain; charset=utf-8")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ct, "text/html")) return "text/html";
    if (std.mem.eql(u8, ct, "text/html; charset=utf-8")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ct, "text/css; charset=utf-8")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ct, "text/javascript; charset=utf-8")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ct, "image/png")) return "image/png";
    if (std.mem.eql(u8, ct, "image/jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ct, "image/svg+xml")) return "image/svg+xml";
    if (std.mem.eql(u8, ct, "image/webp")) return "image/webp";
    if (std.mem.eql(u8, ct, "application/pdf")) return "application/pdf";
    return "application/octet-stream";
}

/// Restrict untrusted user-uploaded blob MIME types so active documents (HTML, SVG, JS, XML)
/// are never served inline under the application origin (prevents stored XSS).
fn safeStorageMime(ct: []const u8) []const u8 {
    const base = if (std.mem.indexOfScalar(u8, ct, ';')) |semi|
        std.mem.trim(u8, ct[0..semi], " \t")
    else
        std.mem.trim(u8, ct, " \t");
    if (std.ascii.eqlIgnoreCase(base, "image/png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(base, "image/jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(base, "image/webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(base, "image/gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(base, "application/pdf")) return "application/pdf";
    if (std.ascii.eqlIgnoreCase(base, "text/plain")) return "text/plain; charset=utf-8";
    if (std.ascii.eqlIgnoreCase(base, "application/json")) return "application/json; charset=utf-8";
    return "application/octet-stream";
}

fn writeHttp1Response(
    io: std.Io,
    stream: std.Io.net.Stream,
    resp: *const http2.H2Response,
    keep_alive: bool,
) void {
    var wbuf: [16384]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    const w = &sw.interface;
    w.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Vary: Accept-Encoding, Origin\r\n" ++
            "X-Content-Type-Options: nosniff\r\n" ++
            "Referrer-Policy: no-referrer\r\n" ++
            "Connection: {s}\r\n",
        .{
            resp.status,
            httpStatusReason(resp.status),
            resp.content_type,
            resp.body.len,
            if (keep_alive) "keep-alive" else "close",
        },
    ) catch return;
    if (resp.cors_allow_origin) |acao| {
        w.print(
            "Access-Control-Allow-Origin: {s}\r\n" ++
                "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
                "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n",
            .{acao},
        ) catch return;
    }
    if (resp.content_security_policy) |csp| {
        w.print("Content-Security-Policy: {s}\r\n", .{csp}) catch return;
    }
    if (resp.content_disposition) |cd| {
        w.print("Content-Disposition: {s}\r\n", .{cd}) catch return;
    }
    if (resp.x_frame_options) |xfo| {
        w.print("X-Frame-Options: {s}\r\n", .{xfo}) catch return;
    }
    if (resp.content_encoding) |ce| {
        w.print("Content-Encoding: {s}\r\n", .{ce}) catch return;
    }
    if (resp.etag) |et| {
        w.print("ETag: {s}\r\n", .{et}) catch return;
    }
    if (resp.cache_control) |cc| {
        w.print("Cache-Control: {s}\r\n", .{cc}) catch return;
    }
    if (resp.retry_after_secs) |ra| {
        w.print("Retry-After: {d}\r\n", .{ra}) catch return;
    }
    for (resp.extra_headers) |eh| {
        if (!isValidResponseHeader(eh.name, eh.value)) continue;
        if (std.ascii.eqlIgnoreCase(eh.name, "content-length") or
            std.ascii.eqlIgnoreCase(eh.name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(eh.name, "connection")) continue;
        w.print("{s}: {s}\r\n", .{ eh.name, eh.value }) catch return;
    }
    w.writeAll("\r\n") catch return;
    if (resp.body.len > 0) {
        w.writeAll(resp.body) catch return;
    }
    w.flush() catch {};
}

fn handleWebSocket(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    stream: std.Io.net.Stream,
    reader: *std.Io.Reader,
    initial_binary: bool,
) void {
    const sender = ws_mod.WsSender.createShared(allocator, io, stream, true) catch {
        stream.close(io);
        return;
    };
    defer sender.release();

    const client_id = engine.registerClient(engine_mod.ClientSink.fromWsSender(sender)) catch return;
    var binary_enabled = initial_binary;
    if (binary_enabled) {
        engine.setClientBinaryProtocol(client_id, true);
    }
    defer {
        sender.markClosed();
        engine.unregisterClient(client_id);
    }

    var ws_arena = std.heap.ArenaAllocator.init(allocator);
    defer ws_arena.deinit();

    while (true) {
        defer _ = ws_arena.reset(.{ .retain_with_limit = 64 * 1024 });
        const wa = ws_arena.allocator();
        const frame = ws_mod.readFrame(wa, reader) catch break;

        switch (frame) {
            .close => break,
            .ping => |p| {
                sender.sendPong(p) catch break;
            },
            .pong => {},
            .text => |text| {
                handleWsText(wa, engine, client_id, sender, text);
            },
            .binary => |bin| {
                if (!binary_enabled) {
                    binary_enabled = true;
                    engine.setClientBinaryProtocol(client_id, true);
                }
                handleWsBinary(wa, engine, client_id, sender, bin);
            },
        }
    }
}

const BinReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readU8(self: *BinReader) !u8 {
        if (self.pos + 1 > self.data.len) return error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn readU16(self: *BinReader) !u16 {
        if (self.pos + 2 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    fn readU32(self: *BinReader) !u32 {
        if (self.pos + 4 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn readI64(self: *BinReader) !i64 {
        if (self.pos + 8 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    fn readStr16(self: *BinReader) ![]const u8 {
        const len: usize = try self.readU16();
        if (self.pos + len > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }

    fn readStr32(self: *BinReader) ![]const u8 {
        const len: usize = try self.readU32();
        if (self.pos + len > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }
};

fn sendWsBinaryResult(
    a: Allocator,
    sender: *ws_mod.WsSender,
    tag: u8,
    req_id: []const u8,
    res: engine_mod.ExecResult,
    commit_ts: ?i64,
) void {
    const payload = switch (res) {
        .ok => |v| v,
        .err => |e| e,
    };
    const ok_byte: u8 = if (res == .ok) 1 else 0;
    const ts_bytes: usize = if (commit_ts != null) 8 else 0;
    const total = 1 + 2 + req_id.len + 1 + ts_bytes + 4 + payload.len;

    var stack_buf: [8192]u8 = undefined;
    const buf = if (total <= stack_buf.len) stack_buf[0..total] else (a.alloc(u8, total) catch return);

    var p: usize = 0;
    buf[p] = tag;
    p += 1;
    std.mem.writeInt(u16, buf[p..][0..2], @intCast(req_id.len), .big);
    p += 2;
    @memcpy(buf[p .. p + req_id.len], req_id);
    p += req_id.len;
    buf[p] = ok_byte;
    p += 1;
    if (commit_ts) |ts| {
        std.mem.writeInt(i64, buf[p..][0..8], ts, .big);
        p += 8;
    }
    std.mem.writeInt(u32, buf[p..][0..4], @intCast(payload.len), .big);
    p += 4;
    if (payload.len > 0) @memcpy(buf[p .. p + payload.len], payload);

    sender.sendBinary(buf) catch {};
}

/// Zero-JSON-envelope binary WebSocket dispatcher (CBIN v1, RFC 6455 opcode 0x02).
fn handleWsBinary(
    a: Allocator,
    engine: *engine_mod.ConcaveEngine,
    client_id: u64,
    sender: *ws_mod.WsSender,
    data: []const u8,
) void {
    var r = BinReader{ .data = data };
    const tag = r.readU8() catch return;

    switch (tag) {
        0x01 => { // authenticate: [u8 has_token]([u16 len][token])?
            const has_tok = r.readU8() catch return;
            const tok: ?[]const u8 = if (has_tok != 0) (r.readStr16() catch return) else null;
            const resp = engine.authenticateClientBinary(client_id, tok) catch return;
            defer engine.allocator.free(resp);
            sender.sendBinary(resp) catch {};
        },
        0x02 => { // subscribe: [u16 sub_id][u16 name][u32 args_json]
            const sub_id = r.readStr16() catch return;
            const name = r.readStr16() catch return;
            const args_raw = r.readStr32() catch return;
            const args_json = if (args_raw.len > 0) args_raw else "{}";
            engine.subscribe(client_id, sub_id, name, args_json) catch {};
        },
        0x03 => { // unsubscribe: [u16 sub_id]
            const sub_id = r.readStr16() catch return;
            engine.unsubscribe(client_id, sub_id);
        },
        0x04 => { // mutation: [u16 req_id][u16 name][u32 args_json] -> 0x84
            const req_id = r.readStr16() catch return;
            const name = r.readStr16() catch return;
            const args_raw = r.readStr32() catch return;
            const args_json = if (args_raw.len > 0) args_raw else "{}";

            var auth_copy = engine.cloneClientAuth(a, client_id);
            const mres = engine.executeMutation(a, name, args_json, if (auth_copy) |*ac| ac else null) catch return;
            sendWsBinaryResult(a, sender, 0x84, req_id, mres.result, mres.commit_ts);
        },
        0x05 => { // action: [u16 req_id][u16 name][u32 args_json] -> 0x85
            const req_id = r.readStr16() catch return;
            const name = r.readStr16() catch return;
            const args_raw = r.readStr32() catch return;
            const args_json = if (args_raw.len > 0) args_raw else "{}";

            var auth_copy = engine.cloneClientAuth(a, client_id);
            const res = engine.executeAction(a, name, args_json, if (auth_copy) |*ac| ac else null) catch return;
            sendWsBinaryResult(a, sender, 0x85, req_id, res, null);
        },
        0x06 => { // ping: [i64 ts] -> 0x86 [i64 ts]
            const ts = r.readI64() catch return;
            var pong: [9]u8 = undefined;
            pong[0] = 0x86;
            std.mem.writeInt(i64, pong[1..9], ts, .big);
            sender.sendBinary(&pong) catch {};
        },
        0x07 => { // one-shot query: [u16 req_id][u16 name][u32 args_json] -> 0x87
            const req_id = r.readStr16() catch return;
            const name = r.readStr16() catch return;
            const args_raw = r.readStr32() catch return;
            const args_json = if (args_raw.len > 0) args_raw else "{}";

            var auth_copy = engine.cloneClientAuth(a, client_id);
            const res = engine.executeQuery(a, name, args_json, if (auth_copy) |*ac| ac else null) catch return;
            sendWsBinaryResult(a, sender, 0x87, req_id, res, null);
        },
        else => {
            const msg = "unknown binary opcode";
            var err_buf: [5 + msg.len]u8 = undefined;
            err_buf[0] = 0x8F;
            std.mem.writeInt(u32, err_buf[1..5], msg.len, .big);
            @memcpy(err_buf[5..], msg);
            sender.sendBinary(&err_buf) catch {};
        },
    }
}

fn handleWsText(
    a: Allocator,
    engine: *engine_mod.ConcaveEngine,
    client_id: u64,
    sender: *ws_mod.WsSender,
    text: []const u8,
) void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch {
        sender.sendText("{\"type\":\"error\",\"message\":\"invalid JSON frame\"}") catch {};
        return;
    };
    if (parsed != .object) return;
    const type_v = parsed.object.get("type") orelse return;
    if (type_v != .string) return;
    const msg_type = type_v.string;

    if (std.mem.eql(u8, msg_type, "authenticate")) {
        const tok: ?[]const u8 = if (parsed.object.get("token")) |tv| (if (tv == .string) tv.string else null) else null;
        const resp = engine.authenticateClient(client_id, tok) catch return;
        defer engine.allocator.free(resp);
        sender.sendText(resp) catch {};
    } else if (std.mem.eql(u8, msg_type, "subscribe")) {
        const sub_id = jsonStringField(parsed.object, "sub_id") orelse return;
        const name = jsonStringField(parsed.object, "name") orelse return;
        const args_json = if (parsed.object.get("args")) |av|
            storage_mod.stringifyJsonValue(a, av) catch "{}"
        else
            "{}";
        engine.subscribe(client_id, sub_id, name, args_json) catch {};
    } else if (std.mem.eql(u8, msg_type, "unsubscribe")) {
        const sub_id = jsonStringField(parsed.object, "sub_id") orelse return;
        engine.unsubscribe(client_id, sub_id);
    } else if (std.mem.eql(u8, msg_type, "mutation")) {
        const req_id = jsonStringField(parsed.object, "req_id") orelse return;
        const name = jsonStringField(parsed.object, "name") orelse return;
        const args_json = if (parsed.object.get("args")) |av|
            storage_mod.stringifyJsonValue(a, av) catch "{}"
        else
            "{}";

        var auth_copy = engine.cloneClientAuth(a, client_id);
        const mres = engine.executeMutation(a, name, args_json, if (auth_copy) |*ac| ac else null) catch return;

        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        w.writeAll("{\"type\":\"mutation_result\",\"req_id\":") catch return;
        storage_mod.writeJsonString(w, req_id) catch return;
        switch (mres.result) {
            .ok => |val| {
                w.writeAll(",\"ok\":true,\"value\":") catch return;
                w.writeAll(val) catch return;
                w.print(",\"commit_ts\":{d}}}", .{mres.commit_ts}) catch return;
            },
            .err => |msg| {
                w.writeAll(",\"ok\":false,\"error\":") catch return;
                storage_mod.writeJsonString(w, msg) catch return;
                w.writeByte('}') catch return;
            },
        }
        sender.sendText(out.written()) catch {};
    } else if (std.mem.eql(u8, msg_type, "action")) {
        const req_id = jsonStringField(parsed.object, "req_id") orelse return;
        const name = jsonStringField(parsed.object, "name") orelse return;
        const args_json = if (parsed.object.get("args")) |av|
            storage_mod.stringifyJsonValue(a, av) catch "{}"
        else
            "{}";

        var auth_copy = engine.cloneClientAuth(a, client_id);
        const res = engine.executeAction(a, name, args_json, if (auth_copy) |*ac| ac else null) catch return;

        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        w.writeAll("{\"type\":\"action_result\",\"req_id\":") catch return;
        storage_mod.writeJsonString(w, req_id) catch return;
        switch (res) {
            .ok => |val| {
                w.writeAll(",\"ok\":true,\"value\":") catch return;
                w.writeAll(val) catch return;
                w.writeByte('}') catch return;
            },
            .err => |msg| {
                w.writeAll(",\"ok\":false,\"error\":") catch return;
                storage_mod.writeJsonString(w, msg) catch return;
                w.writeByte('}') catch return;
            },
        }
        sender.sendText(out.written()) catch {};
    } else if (std.mem.eql(u8, msg_type, "query")) {
        const req_id = jsonStringField(parsed.object, "req_id") orelse return;
        const name = jsonStringField(parsed.object, "name") orelse return;
        const args_json = if (parsed.object.get("args")) |av|
            storage_mod.stringifyJsonValue(a, av) catch "{}"
        else
            "{}";

        var auth_copy = engine.cloneClientAuth(a, client_id);
        const res = engine.executeQuery(a, name, args_json, if (auth_copy) |*ac| ac else null) catch return;

        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        w.writeAll("{\"type\":\"query_result\",\"req_id\":") catch return;
        storage_mod.writeJsonString(w, req_id) catch return;
        switch (res) {
            .ok => |val| {
                w.writeAll(",\"ok\":true,\"value\":") catch return;
                w.writeAll(val) catch return;
                w.writeByte('}') catch return;
            },
            .err => |msg| {
                w.writeAll(",\"ok\":false,\"error\":") catch return;
                storage_mod.writeJsonString(w, msg) catch return;
                w.writeByte('}') catch return;
            },
        }
        sender.sendText(out.written()) catch {};
    } else if (std.mem.eql(u8, msg_type, "ping")) {
        const ts: i64 = if (parsed.object.get("ts")) |tv| (if (tv == .integer) tv.integer else 0) else 0;
        const pong = std.fmt.allocPrint(a, "{{\"type\":\"pong\",\"ts\":{d}}}", .{ts}) catch return;
        sender.sendText(pong) catch {};
    }
}

fn isOperatorAuthorized(
    engine: *const engine_mod.ConcaveEngine,
    expected_token: ?[]const u8,
    auth_header: ?[]const u8,
) bool {
    if (expected_token) |expected| {
        if (auth_header) |ah| {
            var tok = std.mem.trim(u8, ah, " \t");
            if (std.mem.startsWith(u8, tok, "Bearer ")) {
                tok = std.mem.trim(u8, tok["Bearer ".len..], " \t");
            }
            if (timingSafeStrEql(tok, expected)) return true;
        }
        return false;
    }
    return engine.auth_config.allow_dev_tokens;
}

fn isAdminAuthorized(
    engine: *const engine_mod.ConcaveEngine,
    admin_key: ?[]const u8,
    auth_header: ?[]const u8,
) bool {
    if (admin_key) |expected| {
        if (auth_header) |ah| {
            var tok = std.mem.trim(u8, ah, " \t");
            if (std.mem.startsWith(u8, tok, "Bearer ")) {
                tok = std.mem.trim(u8, tok["Bearer ".len..], " \t");
            }
            if (timingSafeStrEql(tok, expected)) return true;
        }
        return false;
    }
    return engine.auth_config.allow_dev_tokens;
}

fn isLoopbackOrigin(origin: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else
        return false;
    const host = if (std.mem.indexOfScalar(u8, rest, ':')) |ci| rest[0..ci] else rest;
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]");
}

fn originMatchesAllowlist(origin: []const u8, cors_origins: []const []const u8) bool {
    for (cors_origins) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) return true;
        if (std.ascii.eqlIgnoreCase(origin, allowed)) return true;
    }
    return false;
}

/// Resolve `Access-Control-Allow-Origin` safely:
/// - Admin, internal, and dashboard endpoints NEVER emit `*` and only allow explicit `CONCAVE_CORS_ORIGINS`.
/// - Public API endpoints respect `CONCAVE_CORS_ORIGINS` (or loopback origins in local dev mode).
fn resolveCorsOrigin(
    path: []const u8,
    origin: ?[]const u8,
    cors_origins: []const []const u8,
    allow_dev_tokens: bool,
) ?[]const u8 {
    const is_privileged = std.mem.startsWith(u8, path, "/_admin/") or
        std.mem.startsWith(u8, path, "/_internal/") or
        std.mem.startsWith(u8, path, "/_dashboard");

    if (is_privileged) {
        const orig = origin orelse return null;
        for (cors_origins) |allowed| {
            if (!std.mem.eql(u8, allowed, "*") and std.ascii.eqlIgnoreCase(orig, allowed)) {
                return orig;
            }
        }
        return null;
    }

    if (cors_origins.len > 0) {
        const orig = origin orelse {
            for (cors_origins) |allowed| {
                if (std.mem.eql(u8, allowed, "*")) return "*";
            }
            return null;
        };
        if (originMatchesAllowlist(orig, cors_origins)) {
            for (cors_origins) |allowed| {
                if (std.ascii.eqlIgnoreCase(orig, allowed)) return orig;
            }
            return "*";
        }
        return null;
    }

    if (allow_dev_tokens) {
        if (origin) |orig| {
            if (isLoopbackOrigin(orig)) return orig;
        }
    }
    return null;
}

/// Validate WebSocket `Origin` header (prevents Cross-Site WebSocket Hijacking).
/// Non-browser clients without an `Origin` header are allowed; browser `Origin` headers must
/// match `Host` (same-origin), `CONCAVE_CORS_ORIGINS`, or loopback in dev mode.
pub fn isWsOriginAllowed(
    origin: ?[]const u8,
    host: ?[]const u8,
    cors_origins: []const []const u8,
    allow_dev_tokens: bool,
) bool {
    const orig = origin orelse return true;
    if (orig.len == 0) return false;
    if (cors_origins.len > 0 and originMatchesAllowlist(orig, cors_origins)) return true;

    // Extract authority (`host[:port]`) from `scheme://authority`
    const rest = if (std.mem.startsWith(u8, orig, "https://"))
        orig["https://".len..]
    else if (std.mem.startsWith(u8, orig, "http://"))
        orig["http://".len..]
    else
        return false;
    const orig_authority = if (std.mem.indexOfScalar(u8, rest, '/')) |si| rest[0..si] else rest;

    if (host) |h| {
        if (std.ascii.eqlIgnoreCase(orig_authority, std.mem.trim(u8, h, " \t"))) return true;
    }
    if (allow_dev_tokens and isLoopbackOrigin(orig)) return true;
    return false;
}

fn isValidResponseHeader(name: []const u8, value: []const u8) bool {
    if (name.len == 0 or name.len > 128 or value.len > 8192) return false;
    for (name) |c| {
        if (c <= 0x20 or c >= 0x7f or c == ':' or c == '\r' or c == '\n') return false;
    }
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
    }
    return true;
}

fn timingSafeStrEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn getQueryParamDecoded(allocator: Allocator, query: []const u8, key: []const u8) !?[]u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        const raw = pair[eq + 1 ..];
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '+') {
                try out.append(allocator, ' ');
                i += 1;
            } else if (raw[i] == '%' and i + 2 < raw.len) {
                const byte = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch {
                    try out.append(allocator, raw[i]);
                    i += 1;
                    continue;
                };
                try out.append(allocator, byte);
                i += 3;
            } else {
                try out.append(allocator, raw[i]);
                i += 1;
            }
        }
        return try out.toOwnedSlice(allocator);
    }
    return null;
}

fn httpStatusReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "OK",
    };
}

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

test "http1: rejects Transfer-Encoding, conflicting Content-Length, invalid Content-Length, and dotfiles" {
    const alloc = std.testing.allocator;

    // Transfer-Encoding must return UnsupportedTransferEncoding (prevents CL.TE / TE.CL smuggling).
    {
        const raw = "POST /api/mutation/x HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\ntest";
        var r = std.Io.Reader.fixed(raw);
        try std.testing.expectError(error.UnsupportedTransferEncoding, readHttpRequest(alloc, &r));
    }
    // Conflicting duplicate Content-Length headers must fail with BadRequest.
    {
        const raw = "POST /api/mutation/x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nContent-Length: 4\r\n\r\ntest";
        var r = std.Io.Reader.fixed(raw);
        try std.testing.expectError(error.BadRequest, readHttpRequest(alloc, &r));
    }
    // Non-numeric Content-Length must fail with BadRequest (never silently 0).
    {
        const raw = "POST /api/mutation/x HTTP/1.1\r\nHost: localhost\r\nContent-Length: abc\r\n\r\n";
        var r = std.Io.Reader.fixed(raw);
        try std.testing.expectError(error.BadRequest, readHttpRequest(alloc, &r));
    }
    // Dotfiles and traversal rejected by sanitizeStaticPath.
    try std.testing.expectError(error.ForbiddenPath, sanitizeStaticPath(alloc, "/.env"));
    try std.testing.expectError(error.ForbiddenPath, sanitizeStaticPath(alloc, "/.git/config"));
    try std.testing.expectError(error.ForbiddenPath, sanitizeStaticPath(alloc, "/%2e%2e/secret"));

    // Active storage MIME types coerced to octet-stream.
    try std.testing.expectEqualStrings("application/octet-stream", safeStorageMime("text/html; charset=utf-8"));
    try std.testing.expectEqualStrings("application/octet-stream", safeStorageMime("image/svg+xml"));
    try std.testing.expectEqualStrings("image/png", safeStorageMime("image/png"));

    // WebSocket Origin checks.
    try std.testing.expect(isWsOriginAllowed(null, "example.com", &.{}, false));
    try std.testing.expect(isWsOriginAllowed("https://example.com", "example.com", &.{}, false));
    try std.testing.expect(!isWsOriginAllowed("https://evil.example", "example.com", &.{}, false));
    try std.testing.expect(isWsOriginAllowed("https://app.example", "api.example", &.{"https://app.example"}, false));
}
