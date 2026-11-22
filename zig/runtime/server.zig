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

pub const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 3210,
    static_dir: ?[]const u8 = null,
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
        const stream = listener.accept(io) catch |err| {
            std.debug.print("accept error: {s}\n", .{@errorName(err)});
            continue;
        };

        const ConnCtx = struct {
            allocator: Allocator,
            io: std.Io,
            engine: *engine_mod.ConcaveEngine,
            static_dir: ?[]const u8,
            stream: std.Io.net.Stream,

            fn run(ctx: @This()) void {
                handleConnection(ctx.allocator, ctx.io, ctx.engine, ctx.static_dir, ctx.stream);
            }
        };

        const thread = std.Thread.spawn(.{}, ConnCtx.run, .{ConnCtx{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .static_dir = config.static_dir,
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
    authorization: ?[]u8 = null,
    upgrade_ws: bool = false,
    ws_key: ?[]u8 = null,
    body: []u8,

    pub fn deinit(self: *const HttpRequest, allocator: Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
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

    var content_length: usize = 0;
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
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" ++
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

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}
