const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("embedded_assets");
const storage_mod = @import("../core/storage.zig");
const auth_mod = @import("auth.zig");
const compress = @import("compress.zig");
const engine_mod = @import("engine.zig");
const http2 = @import("http2.zig");
const ws_mod = @import("ws.zig");

const DYNAMIC_GZIP_MIN_BYTES: usize = 512;

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3210,
    static_dir: ?[]const u8 = null,
    live_reload: bool = false,
    admin_key: ?[]const u8 = null,
    operator_token: ?[]const u8 = null,
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

pub fn serve(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    config: ServerConfig,
) !void {
    const addr = try std.Io.net.IpAddress.parse(config.host, config.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

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

        enableTcpNoDelay(stream);

        const ConnCtx = struct {
            allocator: Allocator,
            io: std.Io,
            engine: *engine_mod.ConcaveEngine,
            static_dir: ?[]const u8,
            live_reload: bool,
            admin_key: ?[]const u8,
            operator_token: ?[]const u8,
            shutdown_flag: ?*std.atomic.Value(bool),
            stream: std.Io.net.Stream,

            fn run(ctx: @This()) void {
                handleConnection(
                    ctx.allocator,
                    ctx.io,
                    ctx.engine,
                    ctx.static_dir,
                    ctx.live_reload,
                    ctx.admin_key,
                    ctx.operator_token,
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
            .shutdown_flag = config.shutdown_flag,
            .stream = stream,
        }}) catch {
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
    content_type: ?[]u8 = null,
    authorization: ?[]u8 = null,
    accept_encoding: ?[]u8 = null,
    if_none_match: ?[]u8 = null,
    keep_alive: bool = true,
    upgrade_ws: bool = false,
    ws_key: ?[]u8 = null,
    is_h2_preface: bool = false,
    body: []u8,

    pub fn deinit(self: *const HttpRequest, allocator: Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.query);
        if (self.content_type) |ct| allocator.free(ct);
        if (self.authorization) |a| allocator.free(a);
        if (self.accept_encoding) |ae| allocator.free(ae);
        if (self.if_none_match) |inm| allocator.free(inm);
        if (self.ws_key) |k| allocator.free(k);
        allocator.free(self.body);
    }

    pub fn asH2View(self: *const HttpRequest) http2.H2Request {
        return .{
            .method = self.method,
            .path = self.path,
            .query = self.query,
            .content_type = self.content_type,
            .authorization = self.authorization,
            .accept_encoding = self.accept_encoding,
            .if_none_match = self.if_none_match,
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
    const method_raw = req_parts.next() orelse return null;
    const target_raw = req_parts.next() orelse return null;
    const version_raw = req_parts.next() orelse "HTTP/1.1";

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

    const path_raw = if (std.mem.indexOfScalar(u8, target_raw, '?')) |qi| target_raw[0..qi] else target_raw;
    const query_raw = if (std.mem.indexOfScalar(u8, target_raw, '?')) |qi| target_raw[qi + 1 ..] else "";

    var content_length: usize = 0;
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

    while (lines.next()) |line| {
        const ci = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hname = std.mem.trim(u8, line[0..ci], " \t");
        const hval = std.mem.trim(u8, line[ci + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(hname, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, hval, 10) catch 0;
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
        .content_type = content_type,
        .authorization = auth_header,
        .accept_encoding = accept_encoding,
        .if_none_match = if_none_match,
        .keep_alive = keep_alive,
        .upgrade_ws = upgrade_ws,
        .ws_key = ws_key,
        .body = body,
    };
}

const DispatchCtx = struct {
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    static_dir: ?[]const u8,
    live_reload: bool,
    admin_key: ?[]const u8,
    operator_token: ?[]const u8,

    fn h2Dispatch(ptr: *anyopaque, allocator: Allocator, req: *const http2.H2Request) http2.H2Response {
        const self: *DispatchCtx = @ptrCast(@alignCast(ptr));
        return dispatchHttpRequest(allocator, self.io, self.engine, self.static_dir, self.live_reload, self.admin_key, self.operator_token, req);
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
    shutdown_flag: ?*std.atomic.Value(bool),
    stream: std.Io.net.Stream,
) void {
    defer stream.close(io);

    var rbuf: [8192]u8 = undefined;
    var sr = stream.reader(io, &rbuf);

    var dctx = DispatchCtx{
        .io = io,
        .engine = engine,
        .static_dir = static_dir,
        .live_reload = live_reload,
        .admin_key = admin_key,
        .operator_token = operator_token,
    };

    var req_arena = std.heap.ArenaAllocator.init(allocator);
    defer req_arena.deinit();

    var first_req = true;
    while (true) {
        if (shutdown_flag) |sf| {
            if (sf.load(.acquire)) break;
        }
        defer _ = req_arena.reset(.retain_capacity);
        const ra = req_arena.allocator();

        const maybe_req = readHttpRequest(ra, &sr.interface) catch return;
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

            const initial_binary = std.mem.indexOf(u8, req.query, "proto=bin") != null;
            handleWebSocket(allocator, io, engine, stream, &sr.interface, initial_binary);
            return;
        }

        const h2_view = req.asH2View();
        const resp = dispatchHttpRequest(ra, io, engine, static_dir, live_reload, admin_key, operator_token, &h2_view);

        const shutting_down = if (shutdown_flag) |sf| sf.load(.acquire) else false;
        const keep_conn = req.keep_alive and !shutting_down and resp.status < 400;
        writeHttp1Response(io, stream, &resp, keep_conn);
        if (!keep_conn) break;
    }
}

/// Unified HTTP/1.1 + HTTP/2 request router with zero-cost pre-compressed embedded assets,
/// ETag/304 caching, and automatic gzip compression for dynamic & static payloads.
fn dispatchHttpRequest(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    static_dir: ?[]const u8,
    live_reload: bool,
    admin_key: ?[]const u8,
    operator_token: ?[]const u8,
    req: *const http2.H2Request,
) http2.H2Response {
    const resp = dispatchHttpRequestInner(allocator, io, engine, static_dir, live_reload, admin_key, operator_token, req);
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

    // Embedded Live Dev Dashboard (`/_dashboard`) — minified, pre-gzipped, ETag-cached
    if (std.mem.eql(u8, req.method, "GET")) {
        if (std.mem.eql(u8, req.path, "/_dashboard") or std.mem.eql(u8, req.path, "/_dashboard/")) {
            return serveEmbeddedAsset(allocator, &assets.dashboard_index_html, want_gzip, req.if_none_match);
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
        if (!isOperatorAuthorized(engine, expected_tok, req.authorization, req.query)) {
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
        if (!isAdminAuthorized(engine, admin_key, req.authorization, req.query)) {
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
        const storage_id = bs.verifyUploadToken(allocator, token) catch
            return makeResponse(allocator, 403, "application/json", "{\"error\":\"invalid or expired upload token\"}", false);
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
        // Copy content_type-safe slice? Wait: `blob.content_type` is freed at defer; pick static mime or dupe?
        // Return static common MIME or octet-stream to avoid lifetime issue on `H2Response.content_type`:
        const ct_static = internCommonMime(blob.content_type);
        return makeResponse(allocator, 200, ct_static, blob.bytes, want_gzip);
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
        rw.writeByte('}') catch return makeEmptyResponse(500, "application/json");

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
                    return makeResponse(allocator, status, internCommonMime(ct_raw), resp_body, want_gzip);
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
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) {
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

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(16 * 1024 * 1024)) catch
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
            "Vary: Accept-Encoding\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
            "Connection: {s}\r\n",
        .{
            resp.status,
            httpStatusReason(resp.status),
            resp.content_type,
            resp.body.len,
            if (keep_alive) "keep-alive" else "close",
        },
    ) catch return;
    if (resp.content_encoding) |ce| {
        w.print("Content-Encoding: {s}\r\n", .{ce}) catch return;
    }
    if (resp.etag) |et| {
        w.print("ETag: {s}\r\n", .{et}) catch return;
    }
    if (resp.cache_control) |cc| {
        w.print("Cache-Control: {s}\r\n", .{cc}) catch return;
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
    var sender = ws_mod.WsSender.init(io, stream);
    const client_id = engine.registerClient(engine_mod.ClientSink.fromWsSender(&sender)) catch return;
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
        defer _ = ws_arena.reset(.retain_capacity);
        const wa = ws_arena.allocator();
        const frame = ws_mod.readFrame(wa, reader) catch break;

        switch (frame) {
            .close => break,
            .ping => |p| {
                sender.sendPong(p) catch break;
            },
            .pong => {},
            .text => |text| {
                handleWsText(wa, engine, client_id, &sender, text);
            },
            .binary => |bin| {
                if (!binary_enabled) {
                    binary_enabled = true;
                    engine.setClientBinaryProtocol(client_id, true);
                }
                handleWsBinary(wa, engine, client_id, &sender, bin);
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
    query: []const u8,
) bool {
    if (expected_token) |expected| {
        if (auth_header) |ah| {
            var tok = std.mem.trim(u8, ah, " \t");
            if (std.mem.startsWith(u8, tok, "Bearer ")) {
                tok = std.mem.trim(u8, tok["Bearer ".len..], " \t");
            }
            if (timingSafeStrEql(tok, expected)) return true;
        }
        var pairs = std.mem.splitScalar(u8, query, '&');
        while (pairs.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "token=")) {
                if (timingSafeStrEql(pair["token=".len..], expected)) return true;
            } else if (std.mem.startsWith(u8, pair, "key=")) {
                if (timingSafeStrEql(pair["key=".len..], expected)) return true;
            }
        }
        return false;
    }
    return engine.auth_config.allow_dev_tokens;
}

fn isAdminAuthorized(
    engine: *const engine_mod.ConcaveEngine,
    admin_key: ?[]const u8,
    auth_header: ?[]const u8,
    query: []const u8,
) bool {
    if (admin_key) |expected| {
        if (auth_header) |ah| {
            var tok = std.mem.trim(u8, ah, " \t");
            if (std.mem.startsWith(u8, tok, "Bearer ")) {
                tok = std.mem.trim(u8, tok["Bearer ".len..], " \t");
            }
            if (timingSafeStrEql(tok, expected)) return true;
        }
        var pairs = std.mem.splitScalar(u8, query, '&');
        while (pairs.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "key=")) {
                if (timingSafeStrEql(pair["key=".len..], expected)) return true;
            }
        }
        return false;
    }
    return engine.auth_config.allow_dev_tokens;
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
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "OK",
    };
}

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}
