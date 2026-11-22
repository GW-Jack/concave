const std = @import("std");
const Allocator = std.mem.Allocator;
const storage_mod = @import("../core/storage.zig");
const auth_mod = @import("auth.zig");
const engine_mod = @import("engine.zig");
const ws_mod = @import("ws.zig");

const CLIENT_INDEX_JS = @embedFile("concave_client_index_js");
const CLIENT_SIGNALS_JS = @embedFile("concave_client_signals_js");
const CLIENT_CLIENT_JS = @embedFile("concave_client_client_js");
const CLIENT_DOM_JS = @embedFile("concave_client_dom_js");
const ANALYTICS_CLIENT_JS = @embedFile("concave_analytics_client_js");
const DASHBOARD_INDEX_HTML = @embedFile("concave_dashboard_index_html");
const DASHBOARD_STYLES_CSS = @embedFile("concave_dashboard_styles_css");
const DASHBOARD_APP_JS = @embedFile("concave_dashboard_app_js");

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3210,
    static_dir: ?[]const u8 = null,
    admin_key: ?[]const u8 = null,
    shutdown_flag: ?*std.atomic.Value(bool) = null,
};

pub fn serve(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    config: ServerConfig,
) !void {
    const addr = try std.Io.net.IpAddress.parse(config.host, config.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.debug.print("Concave server listening on http://{s}:{d}\n", .{ config.host, config.port });

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

        const ConnCtx = struct {
            allocator: Allocator,
            io: std.Io,
            engine: *engine_mod.ConcaveEngine,
            static_dir: ?[]const u8,
            admin_key: ?[]const u8,
            stream: std.Io.net.Stream,

            fn run(ctx: @This()) void {
                handleConnection(ctx.allocator, ctx.io, ctx.engine, ctx.static_dir, ctx.admin_key, ctx.stream);
            }
        };

        const thread = std.Thread.spawn(.{}, ConnCtx.run, .{ConnCtx{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .static_dir = config.static_dir,
            .admin_key = config.admin_key,
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
    upgrade_ws: bool = false,
    ws_key: ?[]u8 = null,
    body: []u8,

    pub fn deinit(self: *const HttpRequest, allocator: Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.query);
        if (self.content_type) |ct| allocator.free(ct);
        if (self.authorization) |a| allocator.free(a);
        if (self.ws_key) |k| allocator.free(k);
        allocator.free(self.body);
    }
};

pub fn readHttpRequest(allocator: Allocator, reader: *std.Io.Reader) !?HttpRequest {
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(allocator);

    var found_end = false;
    while (head.items.len < 64 * 1024) {
        const b = reader.takeByte() catch return null;
        try head.append(allocator, b);
        if (head.items.len >= 4 and std.mem.eql(u8, head.items[head.items.len - 4 ..], "\r\n\r\n")) {
            found_end = true;
            break;
        }
    }
    if (!found_end) return error.HeadersTooLarge;

    var lines = std.mem.splitSequence(u8, head.items[0 .. head.items.len - 4], "\r\n");
    const req_line = lines.next() orelse return null;
    var req_parts = std.mem.splitScalar(u8, req_line, ' ');
    const method_raw = req_parts.next() orelse return null;
    const target_raw = req_parts.next() orelse return null;
    const path_raw = if (std.mem.indexOfScalar(u8, target_raw, '?')) |qi| target_raw[0..qi] else target_raw;
    const query_raw = if (std.mem.indexOfScalar(u8, target_raw, '?')) |qi| target_raw[qi + 1 ..] else "";

    var content_length: usize = 0;
    var content_type: ?[]u8 = null;
    errdefer if (content_type) |ct| allocator.free(ct);
    var auth_header: ?[]u8 = null;
    errdefer if (auth_header) |a| allocator.free(a);
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
        .upgrade_ws = upgrade_ws,
        .ws_key = ws_key,
        .body = body,
    };
}

fn handleConnection(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    static_dir: ?[]const u8,
    admin_key: ?[]const u8,
    stream: std.Io.net.Stream,
) void {
    defer stream.close(io);

    var rbuf: [8192]u8 = undefined;
    var sr = stream.reader(io, &rbuf);

    const maybe_req = readHttpRequest(allocator, &sr.interface) catch return;
    const req = maybe_req orelse return;
    defer req.deinit(allocator);

    // WebSocket upgrade on `/ws`
    if (req.upgrade_ws and std.mem.eql(u8, req.path, "/ws")) {
        const key = req.ws_key orelse {
            writeHttpResponse(io, stream, 400, "Bad Request", "text/plain", "missing Sec-WebSocket-Key");
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

        handleWebSocket(allocator, io, engine, stream, &sr.interface);
        return;
    }

    // CORS preflight
    if (std.mem.eql(u8, req.method, "OPTIONS")) {
        writeHttpResponse(io, stream, 204, "No Content", "text/plain", "");
        return;
    }

    // Health & Readiness probes
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/health")) {
        writeHttpResponse(io, stream, 200, "OK", "application/json", "{\"status\":\"ok\"}");
        return;
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/ready")) {
        const ts = engine.readyCheck() catch {
            writeHttpResponse(io, stream, 503, "Service Unavailable", "application/json", "{\"status\":\"unavailable\"}");
            return;
        };
        const body = std.fmt.allocPrint(allocator, "{{\"status\":\"ready\",\"commit_ts\":{d}}}", .{ts}) catch return;
        defer allocator.free(body);
        writeHttpResponse(io, stream, 200, "OK", "application/json", body);
        return;
    }

    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/api/manifest")) {
        writeHttpResponse(io, stream, 200, "OK", "application/json", engine.manifest.raw_json);
        return;
    }

    // Embedded Live Dev Dashboard (`/_dashboard`)
    if (std.mem.eql(u8, req.method, "GET") and
        (std.mem.eql(u8, req.path, "/_dashboard") or std.mem.eql(u8, req.path, "/_dashboard/")))
    {
        writeHttpResponse(io, stream, 200, "OK", "text/html; charset=utf-8", DASHBOARD_INDEX_HTML);
        return;
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/_dashboard/styles.css")) {
        writeHttpResponse(io, stream, 200, "OK", "text/css; charset=utf-8", DASHBOARD_STYLES_CSS);
        return;
    }
    if (std.mem.eql(u8, req.method, "GET") and std.mem.eql(u8, req.path, "/_dashboard/app.js")) {
        writeHttpResponse(io, stream, 200, "OK", "text/javascript; charset=utf-8", DASHBOARD_APP_JS);
        return;
    }

    // Admin inspection endpoints (`/_admin/stats`, `/_admin/table`, `/_admin/jobs`)
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/_admin/")) {
        if (!isAdminAuthorized(engine, admin_key, req.authorization, req.query)) {
            const status: u16 = if (admin_key != null) 401 else 403;
            const reason = if (admin_key != null) "Unauthorized" else "Forbidden";
            writeHttpResponse(io, stream, status, reason, "application/json", "{\"error\":\"admin access denied\"}");
            return;
        }
        if (std.mem.eql(u8, req.path, "/_admin/stats")) {
            const stats = engine.getStats();
            const raw = engine.manifest.raw_json;
            // Splice live runtime metrics into the manifest JSON object.
            const inner = if (raw.len >= 2 and raw[0] == '{' and raw[raw.len - 1] == '}') raw[1 .. raw.len - 1] else "";
            const body = std.fmt.allocPrint(
                allocator,
                "{{\"commit_ts\":{d},\"active_clients\":{d},\"active_subscriptions\":{d},{s}}}",
                .{ stats.commit_ts, stats.active_clients, stats.active_subscriptions, inner },
            ) catch return;
            defer allocator.free(body);
            writeHttpResponse(io, stream, 200, "OK", "application/json", body);
            return;
        }
        if (std.mem.eql(u8, req.path, "/_admin/jobs")) {
            const docs = engine.adminScanTable(allocator, "_system", "_scheduled_jobs", 100) catch {
                writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", "{\"error\":\"failed to list jobs\"}");
                return;
            };
            defer {
                for (docs) |*d| d.deinit(allocator);
                allocator.free(docs);
            }
            sendDocsJsonArray(allocator, io, stream, docs);
            return;
        }
        if (std.mem.eql(u8, req.path, "/_admin/table")) {
            const ns = getQueryParamDecoded(allocator, req.query, "ns") catch null;
            defer if (ns) |v| allocator.free(v);
            const tbl = getQueryParamDecoded(allocator, req.query, "table") catch null;
            defer if (tbl) |v| allocator.free(v);
            if (tbl == null or tbl.?.len == 0) {
                writeHttpResponse(io, stream, 400, "Bad Request", "application/json", "{\"error\":\"missing table parameter\"}");
                return;
            }
            const lim_str = getQueryParamDecoded(allocator, req.query, "limit") catch null;
            defer if (lim_str) |v| allocator.free(v);
            const limit: usize = if (lim_str) |ls| std.fmt.parseInt(usize, ls, 10) catch 100 else 100;

            const docs = engine.adminScanTable(allocator, ns orelse "", tbl.?, limit) catch {
                writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", "{\"error\":\"failed to scan table\"}");
                return;
            };
            defer {
                for (docs) |*d| d.deinit(allocator);
                allocator.free(docs);
            }
            sendDocsJsonArray(allocator, io, stream, docs);
            return;
        }
        writeHttpResponse(io, stream, 404, "Not Found", "application/json", "{\"error\":\"unknown admin endpoint\"}");
        return;
    }

    // Embedded zero-dependency browser ESM client at `/_concave/{index,signals,client,dom}.js`
    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/_concave/")) {
        const file = req.path["/_concave/".len..];
        const js: ?[]const u8 = if (std.mem.eql(u8, file, "index.js"))
            CLIENT_INDEX_JS
        else if (std.mem.eql(u8, file, "signals.js"))
            CLIENT_SIGNALS_JS
        else if (std.mem.eql(u8, file, "client.js"))
            CLIENT_CLIENT_JS
        else if (std.mem.eql(u8, file, "dom.js"))
            CLIENT_DOM_JS
        else if (std.mem.eql(u8, file, "analytics.js"))
            ANALYTICS_CLIENT_JS
        else
            null;
        if (js) |content| {
            writeHttpResponse(io, stream, 200, "OK", "text/javascript; charset=utf-8", content);
        } else {
            writeHttpResponse(io, stream, 404, "Not Found", "text/plain", "not found");
        }
        return;
    }

    // HTTP RPC endpoints: `/api/query/<name>`, `/api/mutation/<name>`, `/api/action/<name>`
    if (std.mem.eql(u8, req.method, "POST") and std.mem.startsWith(u8, req.path, "/api/")) {
        var auth_id: ?auth_mod.AuthIdentity = null;
        defer if (auth_id) |*a| a.deinit(allocator);
        if (req.authorization) |raw_auth| {
            auth_id = engine.verifyAuthToken(allocator, raw_auth) catch {
                writeHttpResponse(io, stream, 401, "Unauthorized", "application/json", "{\"ok\":false,\"error\":\"unauthorized\"}");
                return;
            };
        }
        const args_json = if (req.body.len > 0) req.body else "{}";

        if (std.mem.startsWith(u8, req.path, "/api/query/")) {
            const name = req.path["/api/query/".len..];
            const res = engine.executeQuery(allocator, name, args_json, if (auth_id) |*a| a else null) catch {
                writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", "{\"ok\":false,\"error\":\"internal error\"}");
                return;
            };
            defer res.deinit(allocator);
            sendHttpRpcResult(allocator, io, stream, res, null);
            return;
        }
        if (std.mem.startsWith(u8, req.path, "/api/mutation/")) {
            const name = req.path["/api/mutation/".len..];
            const mres = engine.executeMutation(allocator, name, args_json, if (auth_id) |*a| a else null) catch {
                writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", "{\"ok\":false,\"error\":\"internal error\"}");
                return;
            };
            defer mres.deinit(allocator);
            sendHttpRpcResult(allocator, io, stream, mres.result, if (mres.result == .ok) mres.commit_ts else null);
            return;
        }
        if (std.mem.startsWith(u8, req.path, "/api/action/")) {
            const name = req.path["/api/action/".len..];
            const res = engine.executeAction(allocator, name, args_json, if (auth_id) |*a| a else null) catch {
                writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", "{\"ok\":false,\"error\":\"internal error\"}");
                return;
            };
            defer res.deinit(allocator);
            sendHttpRpcResult(allocator, io, stream, res, null);
            return;
        }
    }

    // Built-in local blob storage upload & download endpoints (`/_storage/...`)
    if (std.mem.startsWith(u8, req.path, "/_storage/upload/") and
        (std.mem.eql(u8, req.method, "POST") or std.mem.eql(u8, req.method, "PUT")))
    {
        const bs = engine.blob_store orelse {
            writeHttpResponse(io, stream, 503, "Service Unavailable", "application/json", "{\"error\":\"storage not configured\"}");
            return;
        };
        const token = req.path["/_storage/upload/".len..];
        const storage_id = bs.verifyUploadToken(allocator, token) catch {
            writeHttpResponse(io, stream, 403, "Forbidden", "application/json", "{\"error\":\"invalid or expired upload token\"}");
            return;
        };
        defer allocator.free(storage_id);
        const ct = req.content_type orelse "application/octet-stream";
        bs.putLocalBlob(storage_id, ct, req.body) catch {
            writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", "{\"error\":\"failed to store blob\"}");
            return;
        };
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        out.writer.writeAll("{\"storage_id\":") catch return;
        storage_mod.writeJsonString(&out.writer, storage_id) catch return;
        out.writer.writeByte('}') catch return;
        writeHttpResponse(io, stream, 200, "OK", "application/json", out.written());
        return;
    }

    if (std.mem.eql(u8, req.method, "GET") and std.mem.startsWith(u8, req.path, "/_storage/")) {
        const bs = engine.blob_store orelse {
            writeHttpResponse(io, stream, 503, "Service Unavailable", "text/plain", "storage not configured");
            return;
        };
        const storage_id = req.path["/_storage/".len..];
        const blob = bs.getLocalBlob(allocator, storage_id) catch {
            writeHttpResponse(io, stream, 404, "Not Found", "text/plain", "blob not found");
            return;
        };
        defer blob.deinit(allocator);
        writeHttpResponse(io, stream, 200, "OK", blob.content_type, blob.bytes);
        return;
    }

    // Custom application HTTP routes / webhooks (`App.http_route`)
    if (engine.manifest.matchHttpRoute(req.method, req.path) != null) {
        var auth_id: ?auth_mod.AuthIdentity = null;
        defer if (auth_id) |*a| a.deinit(allocator);
        if (req.authorization) |raw_auth| {
            auth_id = engine.verifyAuthToken(allocator, raw_auth) catch {
                writeHttpResponse(io, stream, 401, "Unauthorized", "application/json", "{\"error\":\"unauthorized\"}");
                return;
            };
        }

        var req_out: std.Io.Writer.Allocating = .init(allocator);
        defer req_out.deinit();
        const rw = &req_out.writer;
        rw.writeAll("{\"method\":") catch return;
        storage_mod.writeJsonString(rw, req.method) catch return;
        rw.writeAll(",\"path\":") catch return;
        storage_mod.writeJsonString(rw, req.path) catch return;
        rw.writeAll(",\"query\":") catch return;
        storage_mod.writeJsonString(rw, req.query) catch return;
        rw.writeAll(",\"body\":") catch return;
        storage_mod.writeJsonString(rw, req.body) catch return;
        rw.writeAll(",\"content_type\":") catch return;
        storage_mod.writeJsonString(rw, req.content_type orelse "") catch return;
        rw.writeByte('}') catch return;

        const res = engine.executeHttpRoute(
            allocator,
            req.method,
            req.path,
            req_out.written(),
            if (auth_id) |*a| a else null,
        ) catch {
            writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", "{\"error\":\"internal error\"}");
            return;
        };
        defer res.deinit(allocator);

        switch (res) {
            .ok => |val| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), val, .{}) catch {
                    writeHttpResponse(io, stream, 200, "OK", "application/json", val);
                    return;
                };
                if (parsed == .object) {
                    const status: u16 = if (parsed.object.get("status")) |sv|
                        (if (sv == .integer and sv.integer >= 100 and sv.integer <= 599) @intCast(sv.integer) else 200)
                    else
                        200;
                    const ct = if (parsed.object.get("content_type")) |cv|
                        (if (cv == .string and cv.string.len > 0) cv.string else "application/json")
                    else
                        "application/json";
                    const resp_body = if (parsed.object.get("body")) |bv|
                        (if (bv == .string) bv.string else "")
                    else
                        "";
                    writeHttpResponse(io, stream, status, httpStatusReason(status), ct, resp_body);
                    return;
                }
                writeHttpResponse(io, stream, 200, "OK", "application/json", val);
                return;
            },
            .err => |msg| {
                var eout: std.Io.Writer.Allocating = .init(allocator);
                defer eout.deinit();
                eout.writer.writeAll("{\"error\":") catch return;
                storage_mod.writeJsonString(&eout.writer, msg) catch return;
                eout.writer.writeByte('}') catch return;
                writeHttpResponse(io, stream, 500, "Internal Server Error", "application/json", eout.written());
                return;
            },
        }
    }

    // Static frontend serving from `--static-dir`
    if (std.mem.eql(u8, req.method, "GET")) {
        if (static_dir) |root| {
            serveStaticFile(allocator, io, stream, root, req.path);
            return;
        }
    }

    writeHttpResponse(io, stream, 404, "Not Found", "text/plain", "not found");
}

fn sendHttpRpcResult(allocator: Allocator, io: std.Io, stream: std.Io.net.Stream, res: engine_mod.ExecResult, commit_ts: ?i64) void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    switch (res) {
        .ok => |val| {
            w.writeAll("{\"ok\":true,\"value\":") catch return;
            w.writeAll(val) catch return;
            if (commit_ts) |ts| {
                w.print(",\"commit_ts\":{d}", .{ts}) catch return;
            }
            w.writeByte('}') catch return;
            writeHttpResponse(io, stream, 200, "OK", "application/json", out.written());
        },
        .err => |msg| {
            w.writeAll("{\"ok\":false,\"error\":") catch return;
            storage_mod.writeJsonString(w, msg) catch return;
            w.writeByte('}') catch return;
            writeHttpResponse(io, stream, 400, "Bad Request", "application/json", out.written());
        },
    }
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

fn serveStaticFile(allocator: Allocator, io: std.Io, stream: std.Io.net.Stream, root: []const u8, raw_path: []const u8) void {
    const rel = sanitizeStaticPath(allocator, raw_path) catch {
        writeHttpResponse(io, stream, 403, "Forbidden", "text/plain", "forbidden");
        return;
    };
    defer allocator.free(rel);

    const full_path = std.fs.path.join(allocator, &.{ root, rel }) catch return;
    defer allocator.free(full_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(16 * 1024 * 1024)) catch {
        writeHttpResponse(io, stream, 404, "Not Found", "text/plain", "not found");
        return;
    };
    defer allocator.free(bytes);

    const mime = mimeType(full_path);
    writeHttpResponse(io, stream, 200, "OK", mime, bytes);
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

fn writeHttpResponse(
    io: std.Io,
    stream: std.Io.net.Stream,
    status: u16,
    reason: []const u8,
    content_type: []const u8,
    body: []const u8,
) void {
    var wbuf: [4096]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    sw.interface.print(
        "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
            "Connection: close\r\n\r\n",
        .{ status, reason, content_type, body.len },
    ) catch return;
    if (body.len > 0) {
        sw.interface.writeAll(body) catch return;
    }
    sw.interface.flush() catch {};
}

fn handleWebSocket(
    allocator: Allocator,
    io: std.Io,
    engine: *engine_mod.ConcaveEngine,
    stream: std.Io.net.Stream,
    reader: *std.Io.Reader,
) void {
    var sender = ws_mod.WsSender.init(io, stream);
    const client_id = engine.registerClient(engine_mod.ClientSink.fromWsSender(&sender)) catch return;
    defer {
        sender.markClosed();
        engine.unregisterClient(client_id);
    }

    while (true) {
        const frame = ws_mod.readFrame(allocator, reader) catch break;
        defer frame.deinit(allocator);

        switch (frame) {
            .close => break,
            .ping => |p| {
                sender.sendPong(p) catch break;
            },
            .pong => {},
            .text => |text| {
                handleWsText(allocator, engine, client_id, &sender, text);
            },
        }
    }
}

fn handleWsText(
    allocator: Allocator,
    engine: *engine_mod.ConcaveEngine,
    client_id: u64,
    sender: *ws_mod.WsSender,
    text: []const u8,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
        defer allocator.free(resp);
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

        var auth_copy = engine.cloneClientAuth(allocator, client_id);
        defer if (auth_copy) |*ac| ac.deinit(allocator);

        const mres = engine.executeMutation(allocator, name, args_json, if (auth_copy) |*ac| ac else null) catch return;
        defer mres.deinit(allocator);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
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

        var auth_copy = engine.cloneClientAuth(allocator, client_id);
        defer if (auth_copy) |*ac| ac.deinit(allocator);

        const res = engine.executeAction(allocator, name, args_json, if (auth_copy) |*ac| ac else null) catch return;
        defer res.deinit(allocator);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
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
    } else if (std.mem.eql(u8, msg_type, "ping")) {
        const ts: i64 = if (parsed.object.get("ts")) |tv| (if (tv == .integer) tv.integer else 0) else 0;
        const pong = std.fmt.allocPrint(allocator, "{{\"type\":\"pong\",\"ts\":{d}}}", .{ts}) catch return;
        defer allocator.free(pong);
        sender.sendText(pong) catch {};
    }
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

fn sendDocsJsonArray(allocator: Allocator, io: std.Io, stream: std.Io.net.Stream, docs: []const storage_mod.Document) void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    out.writer.writeByte('[') catch return;
    for (docs, 0..) |*d, i| {
        if (i > 0) out.writer.writeByte(',') catch return;
        const wj = d.toWireJson(allocator) catch return;
        defer allocator.free(wj);
        out.writer.writeAll(wj) catch return;
    }
    out.writer.writeByte(']') catch return;
    writeHttpResponse(io, stream, 200, "OK", "application/json", out.written());
}

fn httpStatusReason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
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
