const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("roc_platform_abi.zig");
const key_mod = @import("../core/key.zig");
const manifest_mod = @import("../core/manifest.zig");
const readset_mod = @import("../core/readset.zig");
const storage_mod = @import("../core/storage.zig");
const BlobStore = @import("../core/blob_store.zig").BlobStore;
const S3Config = @import("../core/sigv4.zig").S3Config;
const WalStore = @import("../core/wal_store.zig").WalStore;
const PgStore = @import("../core/pg_wire.zig").PgStore;
const auth_mod = @import("../runtime/auth.zig");
const engine_mod = @import("../runtime/engine.zig");
const server_mod = @import("../runtime/server.zig");

const RocStr = abi.RocStr;
const RocHost = abi.RocHost;

const g_alloc: Allocator = std.heap.smp_allocator;
var g_io_threaded: std.Io.Threaded = undefined;
var g_io_ready: bool = false;

var g_roc_env: abi.RocEnv = undefined;
var g_roc_host: RocHost = undefined;

fn getIo() std.Io {
    return g_io_threaded.io();
}

fn initRocRuntime() void {
    if (!g_io_ready) {
        g_io_threaded = std.Io.Threaded.init(g_alloc, .{});
        g_io_ready = true;
    }
    g_roc_env = .{
        .allocator = g_alloc,
        .roc_io = abi.RocIo.default(),
    };
    g_roc_host = abi.makeRocHost(&g_roc_env);
}

// =============================================================================
// Runtime Symbols required by compiled Roc 0.1.0_RC1 code
// =============================================================================

export fn roc_alloc(length: usize, alignment: usize) callconv(.c) *anyopaque {
    return abi.DefaultAllocators.rocAlloc(&g_roc_host, length, alignment);
}

export fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    abi.DefaultAllocators.rocDealloc(&g_roc_host, ptr, alignment);
}

export fn roc_realloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) *anyopaque {
    return abi.DefaultAllocators.rocRealloc(&g_roc_host, ptr, new_length, alignment);
}

export fn roc_dbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocDbg(&g_roc_host, bytes, len);
}

export fn roc_expect_failed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocExpectFailed(&g_roc_host, bytes, len);
}

export fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocCrashed(&g_roc_host, bytes, len);
}

// =============================================================================
// Thread-Safe + Re-Entrant Roc Execution Stack
// =============================================================================

var g_roc_mutex: std.Io.Mutex = .init;
threadlocal var t_roc_lock_depth: usize = 0;
threadlocal var t_env_stack: [16]*engine_mod.ExecutionEnv = undefined;
threadlocal var t_env_depth: usize = 0;

fn currentEnv() ?*engine_mod.ExecutionEnv {
    if (t_env_depth == 0) return null;
    return t_env_stack[t_env_depth - 1];
}

fn takeRocStr(alloc: Allocator, s: RocStr) ![]u8 {
    const owned = try alloc.dupe(u8, s.asSlice());
    s.decref(&g_roc_host);
    return owned;
}

fn wireOk(payload: []const u8) RocStr {
    const full = std.fmt.allocPrint(g_alloc, "OK:{s}", .{payload}) catch return RocStr.fromSlice("ERR:oom", &g_roc_host);
    defer g_alloc.free(full);
    return RocStr.fromSlice(full, &g_roc_host);
}

fn wireErr(msg: []const u8) RocStr {
    const full = std.fmt.allocPrint(g_alloc, "ERR:{s}", .{msg}) catch return RocStr.fromSlice("ERR:oom", &g_roc_host);
    defer g_alloc.free(full);
    return RocStr.fromSlice(full, &g_roc_host);
}

fn unwrapRocWire(allocator: Allocator, raw: []const u8) engine_mod.ExecResult {
    if (std.mem.startsWith(u8, raw, "OK:")) {
        return .{ .ok = allocator.dupe(u8, raw["OK:".len..]) catch &.{} };
    }
    if (std.mem.startsWith(u8, raw, "ERR:")) {
        return .{ .err = allocator.dupe(u8, raw["ERR:".len..]) catch &.{} };
    }
    return .{ .err = std.fmt.allocPrint(allocator, "malformed Roc wire response: {s}", .{raw}) catch &.{} };
}

// =============================================================================
// Hosted C-ABI Functions (called by compiled Roc 0.1.0_RC1 code)
// =============================================================================

export fn roc_host_db_get(ns_raw: RocStr, table_raw: RocStr, id_raw: RocStr) callconv(.c) RocStr {
    const ns = takeRocStr(g_alloc, ns_raw) catch return wireErr("oom");
    defer g_alloc.free(ns);
    const table = takeRocStr(g_alloc, table_raw) catch return wireErr("oom");
    defer g_alloc.free(table);
    const doc_id = takeRocStr(g_alloc, id_raw) catch return wireErr("oom");
    defer g_alloc.free(doc_id);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const maybe_doc = env.dbGet(g_alloc, ns, table, doc_id) catch |err| return wireErr(@errorName(err));
    if (maybe_doc) |doc| {
        defer doc.deinit(g_alloc);
        const wire = doc.toWireJson(g_alloc) catch return wireErr("serialization failed");
        defer g_alloc.free(wire);
        return wireOk(wire);
    }
    return wireOk("null");
}

fn parseWireBound(alloc: Allocator, val: std.json.Value) !readset_mod.KeyBound {
    if (val != .object) return error.InvalidKey;
    const kind_v = val.object.get("kind") orelse return error.InvalidKey;
    if (kind_v != .string) return error.InvalidKey;
    const kind = kind_v.string;
    if (std.mem.eql(u8, kind, "unbounded")) return .unbounded;

    const vals_v = val.object.get("values") orelse return error.InvalidKey;
    if (vals_v != .array) return error.InvalidKey;
    var vals: std.ArrayList(key_mod.IndexValue) = .empty;
    defer vals.deinit(alloc);
    for (vals_v.array.items) |item| {
        try vals.append(alloc, try key_mod.IndexValue.fromWireJson(item));
    }

    if (std.mem.eql(u8, kind, "included")) {
        return .{ .included = try key_mod.encodeKey(alloc, vals.items) };
    }
    if (std.mem.eql(u8, kind, "excluded")) {
        return .{ .excluded = try key_mod.encodeKey(alloc, vals.items) };
    }
    if (std.mem.eql(u8, kind, "prefix")) {
        return .{ .excluded = try key_mod.encodePrefixUpperBound(alloc, vals.items) };
    }
    return error.InvalidKey;
}

export fn roc_host_db_query(req_raw: RocStr) callconv(.c) RocStr {
    const req_json = takeRocStr(g_alloc, req_raw) catch return wireErr("oom");
    defer g_alloc.free(req_json);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");

    var arena = std.heap.ArenaAllocator.init(g_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, req_json, .{}) catch
        return wireErr("invalid query JSON");
    if (parsed != .object) return wireErr("invalid query JSON object");
    const obj = parsed.object;

    const ns_v = obj.get("namespace") orelse return wireErr("missing namespace");
    const table_v = obj.get("table") orelse return wireErr("missing table");
    const index_v = obj.get("index_name") orelse return wireErr("missing index_name");
    if (ns_v != .string or table_v != .string or index_v != .string) return wireErr("invalid string field");
    const ns = ns_v.string;
    const table = table_v.string;
    const index_name = index_v.string;
    const start = parseWireBound(a, obj.get("start") orelse return wireErr("missing start")) catch
        return wireErr("invalid start bound");
    const end = parseWireBound(a, obj.get("end") orelse return wireErr("missing end")) catch
        return wireErr("invalid end bound");

    var order: storage_mod.QueryOrder = .asc;
    if (obj.get("order")) |ov| {
        if (ov == .string and std.mem.eql(u8, ov.string, "desc")) order = .desc;
    }
    var limit: ?usize = null;
    if (obj.get("limit")) |lv| {
        if (lv == .integer and lv.integer >= 0) limit = @intCast(lv.integer);
    }

    const docs = env.dbQuery(g_alloc, &.{
        .namespace = ns,
        .table = table,
        .index_name = index_name,
        .start = start,
        .end = end,
        .order = order,
        .limit = limit,
    }) catch |err| return wireErr(@errorName(err));
    defer {
        for (docs) |*d| d.deinit(g_alloc);
        g_alloc.free(docs);
    }

    var out: std.Io.Writer.Allocating = .init(g_alloc);
    defer out.deinit();
    out.writer.writeByte('[') catch return wireErr("oom");
    for (docs, 0..) |*d, i| {
        if (i > 0) out.writer.writeByte(',') catch return wireErr("oom");
        const wj = d.toWireJson(g_alloc) catch return wireErr("oom");
        defer g_alloc.free(wj);
        out.writer.writeAll(wj) catch return wireErr("oom");
    }
    out.writer.writeByte(']') catch return wireErr("oom");
    return wireOk(out.written());
}

export fn roc_host_db_paginate(req_raw: RocStr) callconv(.c) RocStr {
    const req_json = takeRocStr(g_alloc, req_raw) catch return wireErr("oom");
    defer g_alloc.free(req_json);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");

    var arena = std.heap.ArenaAllocator.init(g_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, req_json, .{}) catch
        return wireErr("invalid paginate JSON");
    if (parsed != .object) return wireErr("invalid paginate JSON object");
    const obj = parsed.object;

    const ns_v = obj.get("namespace") orelse return wireErr("missing namespace");
    const table_v = obj.get("table") orelse return wireErr("missing table");
    const index_v = obj.get("index_name") orelse return wireErr("missing index_name");
    if (ns_v != .string or table_v != .string or index_v != .string) return wireErr("invalid string field");
    const start = parseWireBound(a, obj.get("start") orelse return wireErr("missing start")) catch
        return wireErr("invalid start bound");
    const end = parseWireBound(a, obj.get("end") orelse return wireErr("missing end")) catch
        return wireErr("invalid end bound");

    var order: storage_mod.QueryOrder = .asc;
    if (obj.get("order")) |ov| {
        if (ov == .string and std.mem.eql(u8, ov.string, "desc")) order = .desc;
    }
    const cursor: []const u8 = if (obj.get("cursor")) |cv| (if (cv == .string) cv.string else "") else "";
    const page_size: usize = if (obj.get("page_size")) |pv|
        (if (pv == .integer and pv.integer > 0) @intCast(pv.integer) else 25)
    else
        25;

    const page_res = env.dbPaginate(g_alloc, &.{
        .namespace = ns_v.string,
        .table = table_v.string,
        .index_name = index_v.string,
        .start = start,
        .end = end,
        .order = order,
        .limit = null,
    }, cursor, page_size) catch |err| return wireErr(@errorName(err));
    defer page_res.deinit(g_alloc);

    var out: std.Io.Writer.Allocating = .init(g_alloc);
    defer out.deinit();
    out.writer.writeAll("{\"page\":[") catch return wireErr("oom");
    for (page_res.docs, 0..) |*d, i| {
        if (i > 0) out.writer.writeByte(',') catch return wireErr("oom");
        const wj = d.toWireJson(g_alloc) catch return wireErr("oom");
        defer g_alloc.free(wj);
        out.writer.writeAll(wj) catch return wireErr("oom");
    }
    out.writer.writeAll("],\"next_cursor\":") catch return wireErr("oom");
    storage_mod.writeJsonString(&out.writer, page_res.next_cursor) catch return wireErr("oom");
    out.writer.print(",\"is_done\":{s}}}", .{if (page_res.is_done) "true" else "false"}) catch return wireErr("oom");
    return wireOk(out.written());
}

export fn roc_host_db_search(req_raw: RocStr) callconv(.c) RocStr {
    const req_json = takeRocStr(g_alloc, req_raw) catch return wireErr("oom");
    defer g_alloc.free(req_json);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");

    var arena = std.heap.ArenaAllocator.init(g_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, req_json, .{}) catch
        return wireErr("invalid search JSON");
    if (parsed != .object) return wireErr("invalid search JSON object");
    const obj = parsed.object;

    const ns_v = obj.get("namespace") orelse return wireErr("missing namespace");
    const table_v = obj.get("table") orelse return wireErr("missing table");
    const field_v = obj.get("field") orelse return wireErr("missing field");
    const query_v = obj.get("query") orelse return wireErr("missing query");
    if (ns_v != .string or table_v != .string or field_v != .string or query_v != .string) {
        return wireErr("invalid search string field");
    }
    const limit: usize = if (obj.get("limit")) |lv|
        (if (lv == .integer and lv.integer > 0) @intCast(lv.integer) else 50)
    else
        50;

    const docs = env.dbSearch(g_alloc, ns_v.string, table_v.string, field_v.string, query_v.string, limit) catch |err|
        return wireErr(@errorName(err));
    defer {
        for (docs) |*d| d.deinit(g_alloc);
        g_alloc.free(docs);
    }

    var out: std.Io.Writer.Allocating = .init(g_alloc);
    defer out.deinit();
    out.writer.writeByte('[') catch return wireErr("oom");
    for (docs, 0..) |*d, i| {
        if (i > 0) out.writer.writeByte(',') catch return wireErr("oom");
        const wj = d.toWireJson(g_alloc) catch return wireErr("oom");
        defer g_alloc.free(wj);
        out.writer.writeAll(wj) catch return wireErr("oom");
    }
    out.writer.writeByte(']') catch return wireErr("oom");
    return wireOk(out.written());
}

export fn roc_host_db_insert(ns_raw: RocStr, table_raw: RocStr, body_raw: RocStr) callconv(.c) RocStr {
    const ns = takeRocStr(g_alloc, ns_raw) catch return wireErr("oom");
    defer g_alloc.free(ns);
    const table = takeRocStr(g_alloc, table_raw) catch return wireErr("oom");
    defer g_alloc.free(table);
    const body = takeRocStr(g_alloc, body_raw) catch return wireErr("oom");
    defer g_alloc.free(body);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const id = env.dbInsert(g_alloc, ns, table, body) catch |err| return wireErr(@errorName(err));
    defer g_alloc.free(id);
    return wireOk(id);
}

export fn roc_host_db_patch(ns_raw: RocStr, table_raw: RocStr, id_raw: RocStr, patch_raw: RocStr) callconv(.c) RocStr {
    const ns = takeRocStr(g_alloc, ns_raw) catch return wireErr("oom");
    defer g_alloc.free(ns);
    const table = takeRocStr(g_alloc, table_raw) catch return wireErr("oom");
    defer g_alloc.free(table);
    const doc_id = takeRocStr(g_alloc, id_raw) catch return wireErr("oom");
    defer g_alloc.free(doc_id);
    const patch = takeRocStr(g_alloc, patch_raw) catch return wireErr("oom");
    defer g_alloc.free(patch);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    env.dbPatch(ns, table, doc_id, patch) catch |err| return wireErr(@errorName(err));
    return wireOk("ok");
}

export fn roc_host_db_replace(ns_raw: RocStr, table_raw: RocStr, id_raw: RocStr, body_raw: RocStr) callconv(.c) RocStr {
    const ns = takeRocStr(g_alloc, ns_raw) catch return wireErr("oom");
    defer g_alloc.free(ns);
    const table = takeRocStr(g_alloc, table_raw) catch return wireErr("oom");
    defer g_alloc.free(table);
    const doc_id = takeRocStr(g_alloc, id_raw) catch return wireErr("oom");
    defer g_alloc.free(doc_id);
    const body = takeRocStr(g_alloc, body_raw) catch return wireErr("oom");
    defer g_alloc.free(body);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    env.dbReplace(ns, table, doc_id, body) catch |err| return wireErr(@errorName(err));
    return wireOk("ok");
}

export fn roc_host_db_delete(ns_raw: RocStr, table_raw: RocStr, id_raw: RocStr) callconv(.c) RocStr {
    const ns = takeRocStr(g_alloc, ns_raw) catch return wireErr("oom");
    defer g_alloc.free(ns);
    const table = takeRocStr(g_alloc, table_raw) catch return wireErr("oom");
    defer g_alloc.free(table);
    const doc_id = takeRocStr(g_alloc, id_raw) catch return wireErr("oom");
    defer g_alloc.free(doc_id);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    env.dbDelete(ns, table, doc_id) catch |err| return wireErr(@errorName(err));
    return wireOk("ok");
}

export fn roc_host_schedule_job(run_at_ms: i64, fn_raw: RocStr, args_raw: RocStr) callconv(.c) RocStr {
    const fn_name = takeRocStr(g_alloc, fn_raw) catch return wireErr("oom");
    defer g_alloc.free(fn_name);
    const args_json = takeRocStr(g_alloc, args_raw) catch return wireErr("oom");
    defer g_alloc.free(args_json);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const job_id = env.scheduleJob(g_alloc, run_at_ms, fn_name, args_json) catch |err| return wireErr(@errorName(err));
    defer g_alloc.free(job_id);
    return wireOk(job_id);
}

export fn roc_host_cancel_job(id_raw: RocStr) callconv(.c) RocStr {
    const job_id = takeRocStr(g_alloc, id_raw) catch return wireErr("oom");
    defer g_alloc.free(job_id);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    env.cancelJob(job_id) catch |err| return wireErr(@errorName(err));
    return wireOk("ok");
}

export fn roc_host_storage_upload_url() callconv(.c) RocStr {
    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const url = env.storageUploadUrl(g_alloc) catch |err| return wireErr(@errorName(err));
    defer g_alloc.free(url);
    return wireOk(url);
}

export fn roc_host_storage_get_url(id_raw: RocStr) callconv(.c) RocStr {
    const storage_id = takeRocStr(g_alloc, id_raw) catch return wireErr("oom");
    defer g_alloc.free(storage_id);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const url = env.storageGetUrl(g_alloc, storage_id) catch |err| return wireErr(@errorName(err));
    defer g_alloc.free(url);
    return wireOk(url);
}

export fn roc_host_storage_delete(id_raw: RocStr) callconv(.c) RocStr {
    const storage_id = takeRocStr(g_alloc, id_raw) catch return wireErr("oom");
    defer g_alloc.free(storage_id);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    env.storageDelete(storage_id) catch |err| return wireErr(@errorName(err));
    return wireOk("ok");
}

export fn roc_host_auth_identity() callconv(.c) RocStr {
    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    if (env.auth) |*id| {
        const json_str = id.toJson(g_alloc) catch return wireErr("oom");
        defer g_alloc.free(json_str);
        return wireOk(json_str);
    }
    return wireErr("unauthenticated");
}

/// Temporarily release `g_roc_mutex` across blocking I/O (`http_fetch`) or engine re-entry
/// (`run_query`/`run_mutation`) so we never hold `g_roc_mutex` while acquiring `sync_mutex`
/// (preventing AB-BA deadlock with `subscribe`/`broadcastInvalidation`) and HTTP Actions never
/// stall other queries/mutations.
fn releaseRocLockForHostCall() usize {
    const saved = t_roc_lock_depth;
    if (saved > 0) {
        t_roc_lock_depth = 0;
        g_roc_mutex.unlock(getIo());
    }
    return saved;
}

fn reacquireRocLockAfterHostCall(saved: usize) void {
    if (saved > 0) {
        g_roc_mutex.lockUncancelable(getIo());
        t_roc_lock_depth = saved;
    }
}

export fn roc_host_http_fetch(method_raw: RocStr, url_raw: RocStr, body_raw: RocStr) callconv(.c) RocStr {
    const method = takeRocStr(g_alloc, method_raw) catch return wireErr("oom");
    defer g_alloc.free(method);
    const url = takeRocStr(g_alloc, url_raw) catch return wireErr("oom");
    defer g_alloc.free(url);
    const body = takeRocStr(g_alloc, body_raw) catch return wireErr("oom");
    defer g_alloc.free(body);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const fetch_res = blk: {
        const saved = releaseRocLockForHostCall();
        defer reacquireRocLockAfterHostCall(saved);
        break :blk env.httpFetch(g_alloc, .{
            .method = method,
            .url = url,
            .body = if (body.len > 0) body else null,
        });
    };
    const resp = fetch_res catch |err| return wireErr(@errorName(err));
    defer resp.deinit(g_alloc);

    var out: std.Io.Writer.Allocating = .init(g_alloc);
    defer out.deinit();
    out.writer.print("{{\"status\":{d},\"body\":", .{resp.status}) catch return wireErr("oom");
    storage_mod.writeJsonString(&out.writer, resp.body) catch return wireErr("oom");
    out.writer.writeByte('}') catch return wireErr("oom");
    return wireOk(out.written());
}

export fn roc_host_run_query(name_raw: RocStr, args_raw: RocStr) callconv(.c) RocStr {
    const name = takeRocStr(g_alloc, name_raw) catch return wireErr("oom");
    defer g_alloc.free(name);
    const args_json = takeRocStr(g_alloc, args_raw) catch return wireErr("oom");
    defer g_alloc.free(args_json);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const qres = blk: {
        const saved = releaseRocLockForHostCall();
        defer reacquireRocLockAfterHostCall(saved);
        break :blk env.runQuery(g_alloc, name, args_json);
    };
    const res = qres catch |err| return wireErr(@errorName(err));
    defer res.deinit(g_alloc);
    return switch (res) {
        .ok => |v| wireOk(v),
        .err => |e| wireErr(e),
    };
}

export fn roc_host_run_mutation(name_raw: RocStr, args_raw: RocStr) callconv(.c) RocStr {
    const name = takeRocStr(g_alloc, name_raw) catch return wireErr("oom");
    defer g_alloc.free(name);
    const args_json = takeRocStr(g_alloc, args_raw) catch return wireErr("oom");
    defer g_alloc.free(args_json);

    const env = currentEnv() orelse return wireErr("no active ExecutionEnv");
    const mut_res = blk: {
        const saved = releaseRocLockForHostCall();
        defer reacquireRocLockAfterHostCall(saved);
        break :blk env.runMutation(g_alloc, name, args_json);
    };
    const mres = mut_res catch |err| return wireErr(@errorName(err));
    defer mres.deinit(g_alloc);
    return switch (mres.result) {
        .ok => |v| wireOk(v),
        .err => |e| wireErr(e),
    };
}

export fn roc_host_now_ms() callconv(.c) i64 {
    return storage_mod.nowMillis(getIo());
}

// =============================================================================
// RocAppExecutor bridging ConcaveEngine <-> compiled Roc entrypoints
// =============================================================================

const DispatchKind = enum { query, mutation, action };

const RocAppExecutor = struct {
    manifest: manifest_mod.AppManifest,

    fn init() !RocAppExecutor {
        const raw_str = abi.roc_introspect();
        defer raw_str.decref(&g_roc_host);
        const manifest = try manifest_mod.AppManifest.parseJson(g_alloc, raw_str.asSlice());
        return .{ .manifest = manifest };
    }

    fn deinit(self: *RocAppExecutor) void {
        self.manifest.deinit();
    }

    fn dispatch(
        kind: DispatchKind,
        allocator: Allocator,
        name: []const u8,
        args_json: []const u8,
        env: *engine_mod.ExecutionEnv,
    ) engine_mod.ExecResult {
        const io = getIo();
        if (t_roc_lock_depth == 0) {
            g_roc_mutex.lockUncancelable(io);
        }
        t_roc_lock_depth += 1;
        defer {
            t_roc_lock_depth -= 1;
            if (t_roc_lock_depth == 0) {
                g_roc_mutex.unlock(io);
            }
        }

        if (t_env_depth >= t_env_stack.len) {
            return .{ .err = allocator.dupe(u8, "max re-entrant Roc call depth exceeded") catch &.{} };
        }
        t_env_stack[t_env_depth] = env;
        t_env_depth += 1;
        defer t_env_depth -= 1;

        const roc_name = RocStr.fromSlice(name, &g_roc_host);
        const roc_args = RocStr.fromSlice(args_json, &g_roc_host);

        const raw_res = switch (kind) {
            .query => abi.roc_dispatch_query(roc_name, roc_args),
            .mutation => abi.roc_dispatch_mutation(roc_name, roc_args),
            .action => abi.roc_dispatch_action(roc_name, roc_args),
        };
        defer raw_res.decref(&g_roc_host);

        return unwrapRocWire(allocator, raw_res.asSlice());
    }

    fn getManifest(ptr: *anyopaque) *const manifest_mod.AppManifest {
        const self: *RocAppExecutor = @ptrCast(@alignCast(ptr));
        return &self.manifest;
    }

    fn runQuery(_: *anyopaque, allocator: Allocator, name: []const u8, args_json: []const u8, env: *engine_mod.ExecutionEnv) engine_mod.ExecResult {
        return dispatch(.query, allocator, name, args_json, env);
    }

    fn runMutation(_: *anyopaque, allocator: Allocator, name: []const u8, args_json: []const u8, env: *engine_mod.ExecutionEnv) engine_mod.ExecResult {
        return dispatch(.mutation, allocator, name, args_json, env);
    }

    fn runAction(_: *anyopaque, allocator: Allocator, name: []const u8, args_json: []const u8, env: *engine_mod.ExecutionEnv) engine_mod.ExecResult {
        return dispatch(.action, allocator, name, args_json, env);
    }

    fn runHttpRoute(_: *anyopaque, allocator: Allocator, method: []const u8, path: []const u8, req_json: []const u8, env: *engine_mod.ExecutionEnv) engine_mod.ExecResult {
        const io = getIo();
        if (t_roc_lock_depth == 0) {
            g_roc_mutex.lockUncancelable(io);
        }
        t_roc_lock_depth += 1;
        defer {
            t_roc_lock_depth -= 1;
            if (t_roc_lock_depth == 0) {
                g_roc_mutex.unlock(io);
            }
        }

        if (t_env_depth >= t_env_stack.len) {
            return .{ .err = allocator.dupe(u8, "max re-entrant Roc call depth exceeded") catch &.{} };
        }
        t_env_stack[t_env_depth] = env;
        t_env_depth += 1;
        defer t_env_depth -= 1;

        const roc_method = RocStr.fromSlice(method, &g_roc_host);
        const roc_path = RocStr.fromSlice(path, &g_roc_host);
        const roc_req = RocStr.fromSlice(req_json, &g_roc_host);
        const raw_res = abi.roc_dispatch_http(roc_method, roc_path, roc_req);
        defer raw_res.decref(&g_roc_host);
        return unwrapRocWire(allocator, raw_res.asSlice());
    }

    const vtable = engine_mod.AppExecutor.VTable{
        .manifest = &getManifest,
        .executeQuery = &runQuery,
        .executeMutation = &runMutation,
        .executeAction = &runAction,
        .executeHttpRoute = &runHttpRoute,
    };

    fn asExecutor(self: *RocAppExecutor) engine_mod.AppExecutor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// =============================================================================
// C Entrypoint (`--introspect` / `--serve`)
// =============================================================================

var g_envp: ?[*:null]const ?[*:0]const u8 = null;

// Provide weak Linux fallbacks so `libhost.a` links cleanly against musl 1.2.3/1.2.4 (Ubuntu 24.04 / Debian bookworm)
// as well as musl 1.2.5 (Debian trixie / Alpine).
fn linuxGetAuxValFallback(_: c_ulong) callconv(.c) c_ulong {
    return 0;
}

fn linuxStatxFallback(
    dirfd: i32,
    pathname: [*:0]const u8,
    flags: u32,
    mask: u32,
    statxbuf: *std.os.linux.Statx,
) callconv(.c) i32 {
    const rc = std.os.linux.statx(dirfd, pathname, flags, @bitCast(mask), statxbuf);
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed > -4096) return -1;
    return @intCast(signed);
}

comptime {
    if (@import("builtin").os.tag == .linux) {
        @export(&linuxGetAuxValFallback, .{ .name = "getauxval", .linkage = .weak });
        @export(&linuxStatxFallback, .{ .name = "statx", .linkage = .weak });
    }
}

fn getEnvSlice(name: []const u8) ?[]const u8 {
    const envp = g_envp orelse return null;
    var idx: usize = 0;
    while (envp[idx]) |entry_ptr| : (idx += 1) {
        const entry = std.mem.span(entry_ptr);
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.startsWith(u8, entry, name)) {
            const val = entry[name.len + 1 ..];
            return if (val.len > 0) val else null;
        }
    }
    return null;
}

export fn main(argc: c_int, argv: [*]const [*:0]const u8, envp: [*:null]const ?[*:0]const u8) callconv(.c) c_int {
    g_envp = envp;
    initRocRuntime();

    var introspect = false;
    const env_port_str = getEnvSlice("PORT");
    var port: u16 = if (env_port_str) |ps| std.fmt.parseInt(u16, ps, 10) catch 3210 else 3210;
    var host: []const u8 = getEnvSlice("CONCAVE_HOST") orelse
        (if (env_port_str != null) "0.0.0.0" else "127.0.0.1");
    var db_path: []const u8 = getEnvSlice("CONCAVE_DB_PATH") orelse ".concave/dev.wal";
    var database_url: ?[]const u8 = getEnvSlice("DATABASE_URL");
    var deployment_id: []const u8 = getEnvSlice("CONCAVE_DEPLOYMENT_ID") orelse "default";
    var static_dir: ?[]const u8 = getEnvSlice("CONCAVE_STATIC_DIR");
    var commit_poll_ms: u64 = if (getEnvSlice("CONCAVE_COMMIT_POLL_MS")) |s|
        std.fmt.parseInt(u64, s, 10) catch 100
    else
        100;

    const count: usize = @intCast(@max(0, argc));
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--introspect")) {
            introspect = true;
        } else if (std.mem.eql(u8, arg, "--serve")) {
            // default mode
        } else if (std.mem.eql(u8, arg, "--host") and i + 1 < count) {
            i += 1;
            host = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--port") and i + 1 < count) {
            i += 1;
            port = std.fmt.parseInt(u16, std.mem.span(argv[i]), 10) catch {
                std.debug.print("invalid --port value\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--db") and i + 1 < count) {
            i += 1;
            db_path = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--database-url") and i + 1 < count) {
            i += 1;
            database_url = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--deployment-id") and i + 1 < count) {
            i += 1;
            deployment_id = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--static-dir") and i + 1 < count) {
            i += 1;
            static_dir = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--commit-poll-ms") and i + 1 < count) {
            i += 1;
            commit_poll_ms = std.fmt.parseInt(u64, std.mem.span(argv[i]), 10) catch 100;
        }
    }

    if (introspect) {
        const raw_str = abi.roc_introspect();
        defer raw_str.decref(&g_roc_host);
        const io = getIo();
        var buf: [4096]u8 = undefined;
        var out_w = std.Io.File.stdout().writer(io, &buf);
        out_w.interface.writeAll(raw_str.asSlice()) catch return 1;
        out_w.interface.writeByte('\n') catch return 1;
        out_w.interface.flush() catch return 1;
        return 0;
    }

    runServer(host, port, db_path, database_url, deployment_id, static_dir, commit_poll_ms) catch |err| {
        std.debug.print("concave host error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

var g_shutdown: std.atomic.Value(bool) = .init(false);

fn handleShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    g_shutdown.store(true, .release);
}

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn runServer(
    host: []const u8,
    port: u16,
    db_path: []const u8,
    database_url: ?[]const u8,
    deployment_id: []const u8,
    static_dir: ?[]const u8,
    commit_poll_ms: u64,
) !void {
    installSignalHandlers();

    const io = getIo();
    var exec = try RocAppExecutor.init();
    defer exec.deinit();

    var wal_store: ?*WalStore = null;
    var pg_store: ?*PgStore = null;
    defer if (wal_store) |w| w.deinit();
    defer if (pg_store) |p| p.deinit();

    const storage: storage_mod.Storage = if (database_url) |url| blk: {
        const max_conns: usize = if (getEnvSlice("CONCAVE_PG_MAX_CONNECTIONS")) |s|
            std.fmt.parseInt(usize, s, 10) catch 8
        else
            8;
        pg_store = try PgStore.connectWithPoolSize(g_alloc, io, url, deployment_id, max_conns);
        break :blk .{ .pg = pg_store.? };
    } else blk: {
        wal_store = try WalStore.openFile(g_alloc, io, db_path);
        if (getEnvSlice("CONCAVE_WAL_COMPACT_THRESHOLD")) |s| {
            wal_store.?.compact_threshold = std.fmt.parseInt(usize, s, 10) catch 1000;
        }
        break :blk .{ .wal = wal_store.? };
    };

    const allow_dev = if (getEnvSlice("CONCAVE_ALLOW_DEV_TOKENS")) |v|
        !std.mem.eql(u8, v, "false") and !std.mem.eql(u8, v, "0")
    else
        true;

    const jwks_url = getEnvSlice("CONCAVE_JWKS_URL");
    const jwks_json = getEnvSlice("CONCAVE_JWKS_JSON");
    var jwks_cache: ?*auth_mod.JwksCache = null;
    if (jwks_url != null or jwks_json != null) {
        jwks_cache = try auth_mod.JwksCache.init(g_alloc, jwks_url, jwks_json);
    }
    defer if (jwks_cache) |jc| jc.deinit();

    var engine = try engine_mod.ConcaveEngine.init(g_alloc, io, storage, exec.asExecutor(), .{
        .jwt_secret = getEnvSlice("CONCAVE_JWT_SECRET"),
        .jwks_cache = jwks_cache,
        .expected_issuer = getEnvSlice("CONCAVE_JWT_ISSUER"),
        .expected_audience = getEnvSlice("CONCAVE_JWT_AUDIENCE"),
        .allow_dev_tokens = allow_dev,
    });
    defer engine.deinit();

    if (getEnvSlice("CONCAVE_LOG_FORMAT")) |fmt| {
        if (std.ascii.eqlIgnoreCase(fmt, "json")) {
            engine.metrics.log_json = true;
        }
    }

    // Configure built-in local / S3-SigV4 blob storage.
    const storage_dir = getEnvSlice("CONCAVE_STORAGE_DIR") orelse ".concave/storage";
    const default_host = if (std.mem.eql(u8, host, "0.0.0.0")) "127.0.0.1" else host;
    const default_base_url = try std.fmt.allocPrint(g_alloc, "http://{s}:{d}", .{ default_host, port });
    defer g_alloc.free(default_base_url);
    const public_url = getEnvSlice("CONCAVE_PUBLIC_URL") orelse default_base_url;

    const s3_opt: ?S3Config = blk: {
        const ep = getEnvSlice("CONCAVE_S3_ENDPOINT") orelse break :blk null;
        const bucket = getEnvSlice("CONCAVE_S3_BUCKET") orelse break :blk null;
        const ak = getEnvSlice("CONCAVE_S3_ACCESS_KEY") orelse break :blk null;
        const sk = getEnvSlice("CONCAVE_S3_SECRET_KEY") orelse break :blk null;
        const region = getEnvSlice("CONCAVE_S3_REGION") orelse "auto";
        break :blk .{
            .endpoint = ep,
            .bucket = bucket,
            .region = region,
            .access_key = ak,
            .secret_key = sk,
        };
    };

    const blob_store = try BlobStore.init(g_alloc, io, storage_dir, public_url, s3_opt);
    defer blob_store.deinit();
    engine.blob_store = blob_store;

    var tailer_thread: ?std.Thread = null;
    if (commit_poll_ms > 0) {
        tailer_thread = try engine.spawnCommitTailer(commit_poll_ms);
    }

    const sched_poll_ms: u64 = if (getEnvSlice("CONCAVE_SCHEDULER_POLL_MS")) |s|
        std.fmt.parseInt(u64, s, 10) catch 200
    else
        200;
    var sched_thread: ?std.Thread = null;
    if (sched_poll_ms > 0) {
        sched_thread = try engine.spawnSchedulerWorker(sched_poll_ms);
    }

    // Spawn a lightweight graceful-shutdown coordinator that drains WS clients and unblocks accept().
    const ShutdownWatcher = struct {
        io: std.Io,
        engine: *engine_mod.ConcaveEngine,
        connect_host: []const u8,
        port: u16,
        fn run(ctx: @This()) void {
            while (!g_shutdown.load(.acquire)) {
                ctx.io.sleep(.fromMilliseconds(40), .awake) catch break;
            }
            ctx.engine.stop_tailer.store(true, .release);
            ctx.engine.closeAllClients();
            // Wake the blocking accept() call via a loopback poke.
            if (std.Io.net.IpAddress.parse(ctx.connect_host, ctx.port)) |addr| {
                if (addr.connect(ctx.io, .{ .mode = .stream })) |s| {
                    s.close(ctx.io);
                } else |_| {}
            } else |_| {}
        }
    };
    const watcher = try std.Thread.spawn(.{}, ShutdownWatcher.run, .{ShutdownWatcher{
        .io = io,
        .engine = engine,
        .connect_host = default_host,
        .port = port,
    }});
    watcher.detach();

    try server_mod.serve(g_alloc, io, engine, .{
        .host = host,
        .port = port,
        .static_dir = static_dir,
        .admin_key = getEnvSlice("CONCAVE_ADMIN_KEY"),
        .operator_token = getEnvSlice("CONCAVE_OPERATOR_TOKEN"),
        .shutdown_flag = &g_shutdown,
    });

    // Cleanly stop & join background workers before tearing down storage/engine.
    engine.stop_tailer.store(true, .release);
    if (tailer_thread) |t| t.join();
    if (sched_thread) |t| t.join();
}
