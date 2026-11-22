const std = @import("std");
const Allocator = std.mem.Allocator;
const key_mod = @import("../core/key.zig");
const manifest_mod = @import("../core/manifest.zig");
const readset_mod = @import("../core/readset.zig");
const storage_mod = @import("../core/storage.zig");
const wal_mod = @import("../core/wal_store.zig");
const auth_mod = @import("../runtime/auth.zig");
const tx_mod = @import("../runtime/tx.zig");
const engine_mod = @import("../runtime/engine.zig");

const WalStore = wal_mod.WalStore;
const TxContext = tx_mod.TxContext;
const ConcaveEngine = engine_mod.ConcaveEngine;
const AppExecutor = engine_mod.AppExecutor;
const ExecResult = engine_mod.ExecResult;
const ClientSink = engine_mod.ClientSink;

const dst_manifest_json =
    \\{
    \\  "app_name": "dst-sim",
    \\  "tables": [
    \\    {
    \\      "name": "msgs",
    \\      "document_schema": {"kind": "any"},
    \\      "indexes": [
    \\        {"name": "by_room", "fields": ["room", "score"]},
    \\        {"name": "by_score", "fields": ["score"]}
    \\      ]
    \\    },
    \\    {
    \\      "name": "counters",
    \\      "document_schema": {"kind": "any"},
    \\      "indexes": [
    \\        {"name": "by_name", "fields": ["name"]}
    \\      ]
    \\    }
    \\  ],
    \\  "components": [
    \\    {
    \\      "namespace": "comp",
    \\      "package": "comp",
    \\      "tables": [
    \\        {
    \\          "name": "msgs",
    \\          "document_schema": {"kind": "any"},
    \\          "indexes": [
    \\            {"name": "by_room", "fields": ["room"]}
    \\          ]
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "functions": [
    \\    {"name": "msgs.byRoom", "kind": "query", "args_schema": {"kind": "any"}, "return_schema": {"kind": "any"}},
    \\    {"name": "msgs.byScoreRange", "kind": "query", "args_schema": {"kind": "any"}, "return_schema": {"kind": "any"}},
    \\    {"name": "comp.byRoom", "kind": "query", "args_schema": {"kind": "any"}, "return_schema": {"kind": "any"}},
    \\    {"name": "msgs.mutate", "kind": "mutation", "args_schema": {"kind": "any"}, "return_schema": {"kind": "any"}},
    \\    {"name": "counters.inc", "kind": "mutation", "args_schema": {"kind": "any"}, "return_schema": {"kind": "any"}}
    \\  ]
    \\}
;

fn docsEqual(a: []const storage_mod.Document, b: []const storage_mod.Document) bool {
    if (a.len != b.len) return false;
    for (a, b) |da, db| {
        if (!std.mem.eql(u8, da.id, db.id)) return false;
        if (!std.mem.eql(u8, da.body_json, db.body_json)) return false;
    }
    return true;
}

fn freeDocs(allocator: Allocator, docs: []storage_mod.Document) void {
    for (docs) |*d| d.deinit(allocator);
    allocator.free(docs);
}

const ProbeQuery = struct {
    ns: []const u8,
    index_name: []const u8,
    start: readset_mod.KeyBound,
    end: readset_mod.KeyBound,
    order: storage_mod.QueryOrder,
    limit: ?usize,

    fn deinit(self: *const ProbeQuery, allocator: Allocator) void {
        self.start.deinit(allocator);
        self.end.deinit(allocator);
    }

    fn asIndexQuery(self: *const ProbeQuery) storage_mod.IndexQuery {
        return .{
            .namespace = self.ns,
            .table = "msgs",
            .index_name = self.index_name,
            .start = self.start,
            .end = self.end,
            .order = self.order,
            .limit = self.limit,
        };
    }
};

fn randomProbeQuery(allocator: Allocator, rng: std.Random) !ProbeQuery {
    const rooms = [_][]const u8{ "r0", "r1", "r2", "r3" };
    const order: storage_mod.QueryOrder = if (rng.boolean()) .asc else .desc;
    const limit: ?usize = switch (rng.intRangeLessThan(u8, 0, 4)) {
        0 => null,
        1 => 1,
        2 => 3,
        else => 8,
    };

    const mode = rng.intRangeLessThan(u8, 0, 4);
    if (mode == 0) {
        // Room prefix scan in root namespace
        const r = rooms[rng.intRangeLessThan(usize, 0, rooms.len)];
        const lo = try key_mod.encodeKey(allocator, &.{.{ .str_val = r }});
        errdefer allocator.free(lo);
        const hi = try key_mod.encodePrefixUpperBound(allocator, &.{.{ .str_val = r }});
        return .{
            .ns = "",
            .index_name = "by_room",
            .start = .{ .included = lo },
            .end = .{ .excluded = hi },
            .order = order,
            .limit = limit,
        };
    } else if (mode == 1) {
        // Room + score sub-range scan in root namespace
        const r = rooms[rng.intRangeLessThan(usize, 0, rooms.len)];
        const s1 = rng.intRangeAtMost(i64, -10, 10);
        const s2 = rng.intRangeAtMost(i64, s1, 15);
        const lo = try key_mod.encodeKey(allocator, &.{ .{ .str_val = r }, .{ .int_val = s1 } });
        errdefer allocator.free(lo);
        const hi = try key_mod.encodeKey(allocator, &.{ .{ .str_val = r }, .{ .int_val = s2 } });
        return .{
            .ns = "",
            .index_name = "by_room",
            .start = if (rng.boolean()) .{ .included = lo } else .{ .excluded = lo },
            .end = if (rng.boolean()) .{ .included = hi } else .{ .excluded = hi },
            .order = order,
            .limit = limit,
        };
    } else if (mode == 2) {
        // Score range scan in root namespace (including half-unbounded)
        const s1 = rng.intRangeAtMost(i64, -10, 10);
        const s2 = rng.intRangeAtMost(i64, s1, 15);
        const start: readset_mod.KeyBound = if (rng.intRangeLessThan(u8, 0, 3) == 0)
            .unbounded
        else
            .{ .included = try key_mod.encodeKey(allocator, &.{.{ .int_val = s1 }}) };
        errdefer start.deinit(allocator);
        const end: readset_mod.KeyBound = if (rng.intRangeLessThan(u8, 0, 3) == 0)
            .unbounded
        else
            .{ .included = try key_mod.encodeKey(allocator, &.{.{ .int_val = s2 }}) };
        return .{
            .ns = "",
            .index_name = "by_score",
            .start = start,
            .end = end,
            .order = order,
            .limit = limit,
        };
    } else {
        // Component namespace scan
        const r = rooms[rng.intRangeLessThan(usize, 0, rooms.len)];
        const lo = try key_mod.encodeKey(allocator, &.{.{ .str_val = r }});
        errdefer allocator.free(lo);
        const hi = try key_mod.encodePrefixUpperBound(allocator, &.{.{ .str_val = r }});
        return .{
            .ns = "comp",
            .index_name = "by_room",
            .start = .{ .included = lo },
            .end = .{ .excluded = hi },
            .order = order,
            .limit = limit,
        };
    }
}

test "DST: TxContext RYOW overlay refinement & ReadSet/WriteSet soundness (zero missed invalidations)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var manifest = try manifest_mod.AppManifest.parseJson(allocator, dst_manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();
    try store.initSchema(&manifest);

    var prng = std.Random.DefaultPrng.init(0xD570_0001);
    const rng = prng.random();
    const rooms = [_][]const u8{ "r0", "r1", "r2", "r3" };
    const namespaces = [_][]const u8{ "", "comp" };

    var live_root_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (live_root_ids.items) |id| allocator.free(id);
        live_root_ids.deinit(allocator);
    }
    var live_comp_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (live_comp_ids.items) |id| allocator.free(id);
        live_comp_ids.deinit(allocator);
    }

    var total_soundness_checks: usize = 0;
    var total_ryow_checks: usize = 0;

    for (0..80) |round| {
        const snap_ts = try store.latestCommitTs();

        // 1. Evaluate 10 random probe queries BEFORE this mutation and capture (result, ReadSet).
        const num_probes = 10;
        var probes: [num_probes]ProbeQuery = undefined;
        var before_results: [num_probes][]storage_mod.Document = undefined;
        var read_sets: [num_probes]readset_mod.ReadSet = undefined;
        var built_probes: usize = 0;
        defer {
            for (0..built_probes) |pi| {
                probes[pi].deinit(allocator);
                freeDocs(allocator, before_results[pi]);
                read_sets[pi].deinit(allocator);
            }
        }

        for (0..num_probes) |pi| {
            probes[pi] = try randomProbeQuery(allocator, rng);
            var qtx = TxContext.init(allocator, io, .{ .wal = store }, &manifest, snap_ts, true);
            defer qtx.deinit();
            const iq = probes[pi].asIndexQuery();
            before_results[pi] = try qtx.scanIndex(allocator, &iq);
            // Clone ReadSet out of qtx.
            read_sets[pi] = .{};
            for (qtx.read_set.doc_reads.items) |*d| {
                try read_sets[pi].recordDocRead(allocator, d.namespace, d.table, d.doc_id);
            }
            for (qtx.read_set.index_ranges.items) |*r| {
                try read_sets[pi].recordIndexRange(allocator, r.namespace, r.table, r.index_name, r.start, r.end);
            }
            built_probes += 1;
        }

        // 2. Build a multi-op transaction via TxContext (1..4 ops) and check RYOW reads mid-tx!
        var mtx = TxContext.init(allocator, io, .{ .wal = store }, &manifest, snap_ts, false);
        defer mtx.deinit();

        const op_count = rng.intRangeAtMost(usize, 1, 4);
        for (0..op_count) |_| {
            const ns_idx = rng.intRangeLessThan(usize, 0, namespaces.len);
            const ns = namespaces[ns_idx];
            const id_list = if (ns_idx == 0) &live_root_ids else &live_comp_ids;
            const room = rooms[rng.intRangeLessThan(usize, 0, rooms.len)];
            const score = rng.intRangeAtMost(i64, -12, 16);

            const choice = if (id_list.items.len == 0) 0 else rng.intRangeLessThan(u8, 0, 4);
            if (choice == 0) {
                const body = try std.fmt.allocPrint(allocator, "{{\"room\":\"{s}\",\"score\":{d},\"round\":{d}}}", .{ room, score, round });
                defer allocator.free(body);
                const new_id = try mtx.insert(allocator, ns, "msgs", body);
                try id_list.append(allocator, new_id);
            } else if (choice == 1) {
                const idx = rng.intRangeLessThan(usize, 0, id_list.items.len);
                const target_id = id_list.items[idx];
                const patch = try std.fmt.allocPrint(allocator, "{{\"room\":\"{s}\",\"score\":{d}}}", .{ room, score });
                defer allocator.free(patch);
                mtx.patch(ns, "msgs", target_id, patch) catch |err| switch (err) {
                    storage_mod.StorageError.NotFound => {},
                    else => return err,
                };
            } else if (choice == 2) {
                const idx = rng.intRangeLessThan(usize, 0, id_list.items.len);
                const target_id = id_list.items[idx];
                const body = try std.fmt.allocPrint(allocator, "{{\"room\":\"{s}\",\"score\":{d},\"replaced\":true}}", .{ room, score });
                defer allocator.free(body);
                mtx.replace(ns, "msgs", target_id, body) catch |err| switch (err) {
                    storage_mod.StorageError.NotFound => {},
                    else => return err,
                };
            } else {
                const idx = rng.intRangeLessThan(usize, 0, id_list.items.len);
                const target_id = id_list.swapRemove(idx);
                defer allocator.free(target_id);
                try mtx.delete(ns, "msgs", target_id);
            }
        }

        // Capture RYOW scan results BEFORE committing!
        var ryow_results: [num_probes][]storage_mod.Document = undefined;
        var built_ryow: usize = 0;
        defer for (0..built_ryow) |pi| freeDocs(allocator, ryow_results[pi]);

        for (0..num_probes) |pi| {
            const iq = probes[pi].asIndexQuery();
            ryow_results[pi] = try mtx.scanIndex(allocator, &iq);
            built_ryow += 1;
        }

        // 3. Commit the transaction!
        var cres = try store.commitTx(allocator, &manifest, snap_ts, &mtx.read_set, mtx.writes.items);
        defer cres.deinit(allocator);
        try store.verifyIndexIntegrity(allocator, &manifest);

        // 4. Verify BOTH theorems after commit:
        //    (a) RYOW Refinement: every mid-tx scan equals post-commit storage scan identically!
        //    (b) ReadSet Soundness: if before_result != after_result, ReadSet MUST intersect WriteSet!
        for (0..num_probes) |pi| {
            const iq = probes[pi].asIndexQuery();
            const after = try store.scanIndex(allocator, &iq);
            defer freeDocs(allocator, after);

            // Theorem (a): RYOW Refinement
            try std.testing.expect(docsEqual(ryow_results[pi], after));
            total_ryow_checks += 1;

            // Theorem (b): ReadSet/WriteSet Soundness (ZERO false negatives!)
            if (!docsEqual(before_results[pi], after)) {
                try std.testing.expect(read_sets[pi].intersects(&cres.write_set));
            }
            total_soundness_checks += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 800), total_ryow_checks);
    try std.testing.expectEqual(@as(usize, 800), total_soundness_checks);
}

test "DST: 3-replica ConcaveEngine cluster with 6 WS clients, commit_log tailer, surgical isolation, and OCC retry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var manifest = try manifest_mod.AppManifest.parseJson(allocator, dst_manifest_json);
    defer manifest.deinit();

    const SimExec = struct {
        mf: *const manifest_mod.AppManifest,
        inject_conflict_once: bool = false,
        conflict_store: ?*WalStore = null,

        fn getManifest(ptr: *anyopaque) *const manifest_mod.AppManifest {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.mf;
        }

        fn runQuery(
            ptr: *anyopaque,
            alloc: Allocator,
            name: []const u8,
            args_json: []const u8,
            env: *engine_mod.ExecutionEnv,
        ) ExecResult {
            return runQueryImpl(ptr, alloc, env.mode.tx, name, args_json) catch |err|
                .{ .err = alloc.dupe(u8, @errorName(err)) catch @panic("OOM") };
        }

        fn runQueryImpl(
            ptr: *anyopaque,
            alloc: Allocator,
            tx: *TxContext,
            name: []const u8,
            args_json: []const u8,
        ) !ExecResult {
            _ = ptr;
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, args_json, .{});
            defer parsed.deinit();

            var docs: []storage_mod.Document = &.{};
            if (std.mem.eql(u8, name, "msgs.byRoom") or std.mem.eql(u8, name, "comp.byRoom")) {
                const ns: []const u8 = if (std.mem.eql(u8, name, "comp.byRoom")) "comp" else "";
                const room = parsed.value.object.get("room").?.string;
                const lo = try key_mod.encodeKey(alloc, &.{.{ .str_val = room }});
                defer alloc.free(lo);
                const hi = try key_mod.encodePrefixUpperBound(alloc, &.{.{ .str_val = room }});
                defer alloc.free(hi);
                docs = try tx.scanIndex(alloc, &.{
                    .namespace = ns,
                    .table = "msgs",
                    .index_name = "by_room",
                    .start = .{ .included = lo },
                    .end = .{ .excluded = hi },
                    .order = .asc,
                });
            } else if (std.mem.eql(u8, name, "msgs.byScoreRange")) {
                const min_s = parsed.value.object.get("min").?.integer;
                const max_s = parsed.value.object.get("max").?.integer;
                const lo = try key_mod.encodeKey(alloc, &.{.{ .int_val = min_s }});
                defer alloc.free(lo);
                const hi = try key_mod.encodeKey(alloc, &.{.{ .int_val = max_s }});
                defer alloc.free(hi);
                docs = try tx.scanIndex(alloc, &.{
                    .namespace = "",
                    .table = "msgs",
                    .index_name = "by_score",
                    .start = .{ .included = lo },
                    .end = .{ .included = hi },
                    .order = .asc,
                });
            } else {
                return .{ .err = try alloc.dupe(u8, "unknown query") };
            }
            defer freeDocs(alloc, docs);

            // Serialize sorted (id:room:score) array for deterministic equality checks.
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            try out.writer.writeByte('[');
            for (docs, 0..) |d, i| {
                if (i > 0) try out.writer.writeByte(',');
                try out.writer.writeAll("{\"id\":");
                try storage_mod.writeJsonString(&out.writer, d.id);
                try out.writer.writeAll(",\"body\":");
                try out.writer.writeAll(d.body_json);
                try out.writer.writeByte('}');
            }
            try out.writer.writeByte(']');
            return .{ .ok = try out.toOwnedSlice() };
        }

        fn runMutation(
            ptr: *anyopaque,
            alloc: Allocator,
            name: []const u8,
            args_json: []const u8,
            env: *engine_mod.ExecutionEnv,
        ) ExecResult {
            return runMutationImpl(ptr, alloc, env.mode.tx, name, args_json) catch |err|
                .{ .err = alloc.dupe(u8, @errorName(err)) catch @panic("OOM") };
        }

        fn runMutationImpl(
            ptr: *anyopaque,
            alloc: Allocator,
            tx: *TxContext,
            name: []const u8,
            args_json: []const u8,
        ) !ExecResult {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, args_json, .{});
            defer parsed.deinit();

            if (std.mem.eql(u8, name, "msgs.mutate")) {
                const kind = parsed.value.object.get("op").?.string;
                const ns = parsed.value.object.get("ns").?.string;
                if (std.mem.eql(u8, kind, "insert")) {
                    const room = parsed.value.object.get("room").?.string;
                    const score = parsed.value.object.get("score").?.integer;
                    const body = try std.fmt.allocPrint(alloc, "{{\"room\":\"{s}\",\"score\":{d}}}", .{ room, score });
                    defer alloc.free(body);
                    const id = try tx.insert(alloc, ns, "msgs", body);
                    defer alloc.free(id);
                    return .{ .ok = try std.fmt.allocPrint(alloc, "\"{s}\"", .{id}) };
                } else if (std.mem.eql(u8, kind, "patch")) {
                    const id = parsed.value.object.get("id").?.string;
                    const room = parsed.value.object.get("room").?.string;
                    const score = parsed.value.object.get("score").?.integer;
                    const patch = try std.fmt.allocPrint(alloc, "{{\"room\":\"{s}\",\"score\":{d}}}", .{ room, score });
                    defer alloc.free(patch);
                    tx.patch(ns, "msgs", id, patch) catch return .{ .ok = try alloc.dupe(u8, "false") };
                    return .{ .ok = try alloc.dupe(u8, "true") };
                } else if (std.mem.eql(u8, kind, "delete")) {
                    const id = parsed.value.object.get("id").?.string;
                    try tx.delete(ns, "msgs", id);
                    return .{ .ok = try alloc.dupe(u8, "true") };
                }
            } else if (std.mem.eql(u8, name, "counters.inc")) {
                const counter_id = parsed.value.object.get("id").?.string;
                const delta = parsed.value.object.get("delta").?.integer;
                const existing = try tx.get(alloc, "", "counters", counter_id);
                defer if (existing) |d| d.deinit(alloc);

                var cur_val: i64 = 0;
                if (existing) |d| {
                    const dp = try std.json.parseFromSlice(std.json.Value, alloc, d.body_json, .{});
                    defer dp.deinit();
                    cur_val = dp.value.object.get("val").?.integer;
                }

                // Simulate a concurrent rival transaction committing to the same counter mid-flight!
                if (self.inject_conflict_once) {
                    self.inject_conflict_once = false;
                    if (self.conflict_store) |cs| {
                        var empty_rs: readset_mod.ReadSet = .{};
                        defer empty_rs.deinit(alloc);
                        const rival_body = try std.fmt.allocPrint(alloc, "{{\"name\":\"c\",\"val\":{d}}}", .{cur_val + 100});
                        defer alloc.free(rival_body);
                        const snap = try cs.latestCommitTs();
                        const rival_op = [_]storage_mod.WriteOp{.{ .patch = .{
                            .namespace = @constCast(""),
                            .table = @constCast("counters"),
                            .doc_id = @constCast(counter_id),
                            .patch_json = rival_body,
                        } }};
                        var rc = try cs.commitTx(alloc, self.mf, snap, &empty_rs, &rival_op);
                        rc.deinit(alloc);
                    }
                }

                const next_val = cur_val + delta;
                const patch = try std.fmt.allocPrint(alloc, "{{\"val\":{d}}}", .{next_val});
                defer alloc.free(patch);
                try tx.patch("", "counters", counter_id, patch);
                return .{ .ok = try std.fmt.allocPrint(alloc, "{d}", .{next_val}) };
            }
            return .{ .err = try alloc.dupe(u8, "unknown mutation") };
        }

        fn runAction(_: *anyopaque, alloc: Allocator, _: []const u8, _: []const u8, _: *engine_mod.ExecutionEnv) ExecResult {
            return .{ .ok = alloc.dupe(u8, "null") catch @panic("OOM") };
        }

        const vtable = AppExecutor.VTable{
            .manifest = &getManifest,
            .executeQuery = &runQuery,
            .executeMutation = &runMutation,
            .executeAction = &runAction,
        };
    };

    const ClientMirror = struct {
        alloc: Allocator,
        last_ts: i64 = 0,
        transition_count: usize = 0,
        values: std.StringHashMapUnmanaged([]u8) = .empty,

        fn deinit(self: *@This()) void {
            var it = self.values.iterator();
            while (it.next()) |e| {
                self.alloc.free(e.key_ptr.*);
                self.alloc.free(e.value_ptr.*);
            }
            self.values.deinit(self.alloc);
        }

        fn sink(self: *@This()) ClientSink {
            const Self = @This();
            const Helper = struct {
                fn send(ptr: *anyopaque, payload: []const u8) void {
                    const c: *Self = @ptrCast(@alignCast(ptr));
                    var arena = std.heap.ArenaAllocator.init(c.alloc);
                    defer arena.deinit();
                    const a = arena.allocator();
                    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{}) catch return;
                    if (parsed != .object) return;
                    const t = parsed.object.get("type") orelse return;
                    if (t != .string or !std.mem.eql(u8, t.string, "transition")) return;

                    const to_ts = parsed.object.get("to_ts").?.integer;
                    // Monotonic commit_ts invariant!
                    std.debug.assert(to_ts >= c.last_ts);
                    c.last_ts = to_ts;
                    c.transition_count += 1;

                    const updates = parsed.object.get("updates").?.array.items;
                    for (updates) |u| {
                        const sid = u.object.get("sub_id").?.string;
                        const val_str = storage_mod.stringifyJsonValue(c.alloc, u.object.get("value").?) catch return;
                        if (c.values.fetchRemove(sid)) |old| {
                            c.alloc.free(old.key);
                            c.alloc.free(old.value);
                        }
                        const sid_copy = c.alloc.dupe(u8, sid) catch {
                            c.alloc.free(val_str);
                            return;
                        };
                        c.values.put(c.alloc, sid_copy, val_str) catch {
                            c.alloc.free(sid_copy);
                            c.alloc.free(val_str);
                        };
                    }
                }
            };
            return .{ .ptr = @ptrCast(self), .sendFn = &Helper.send };
        }
    };

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();
    try store.initSchema(&manifest);

    var sim = SimExec{ .mf = &manifest, .conflict_store = store };
    const exec = AppExecutor{ .ptr = @ptrCast(&sim), .vtable = &SimExec.vtable };

    // 3 simulated Cloud Run replicas sharing one DB.
    var replicas: [3]*ConcaveEngine = undefined;
    for (0..3) |ri| {
        replicas[ri] = try ConcaveEngine.init(allocator, io, .{ .wal = store }, exec, .{});
    }
    defer for (replicas) |r| r.deinit();

    // 6 simulated clients spread across the 3 replicas.
    var mirrors: [6]ClientMirror = undefined;
    var client_ids: [6]u64 = undefined;
    for (0..6) |ci| {
        mirrors[ci] = .{ .alloc = allocator };
        client_ids[ci] = try replicas[ci % 3].registerClient(mirrors[ci].sink());
    }
    defer {
        for (0..6) |ci| {
            replicas[ci % 3].unregisterClient(client_ids[ci]);
            mirrors[ci].deinit();
        }
    }

    // Subscribe clients to disjoint & overlapping queries across replicas:
    // c0@R0: msgs.byRoom("r0"), msgs.byScoreRange(0..10)
    // c1@R1: msgs.byRoom("r1")
    // c2@R2: msgs.byRoom("r0"), comp.byRoom("r0")
    // c3@R0: msgs.byRoom("r2")  (isolation canary — never written in phase 1!)
    // c4@R1: msgs.byScoreRange(5..15)
    // c5@R2: comp.byRoom("r1")
    const SubSpec = struct { client: usize, sub_id: []const u8, name: []const u8, args: []const u8 };
    const subs = [_]SubSpec{
        .{ .client = 0, .sub_id = "s0", .name = "msgs.byRoom", .args = "{\"room\":\"r0\"}" },
        .{ .client = 0, .sub_id = "s1", .name = "msgs.byScoreRange", .args = "{\"min\":0,\"max\":10}" },
        .{ .client = 1, .sub_id = "s0", .name = "msgs.byRoom", .args = "{\"room\":\"r1\"}" },
        .{ .client = 2, .sub_id = "s0", .name = "msgs.byRoom", .args = "{\"room\":\"r0\"}" },
        .{ .client = 2, .sub_id = "s1", .name = "comp.byRoom", .args = "{\"room\":\"r0\"}" },
        .{ .client = 3, .sub_id = "s0", .name = "msgs.byRoom", .args = "{\"room\":\"r2\"}" },
        .{ .client = 4, .sub_id = "s0", .name = "msgs.byScoreRange", .args = "{\"min\":5,\"max\":15}" },
        .{ .client = 5, .sub_id = "s0", .name = "comp.byRoom", .args = "{\"room\":\"r1\"}" },
    };
    for (subs) |s| {
        try replicas[s.client % 3].subscribe(client_ids[s.client], s.sub_id, s.name, s.args);
    }

    const canary_transitions_initial = mirrors[3].transition_count;

    // Seeded simulation of 60 mutations across random replicas (touching r0, r1, comp:r0, comp:r1 — NOT r2).
    var prng = std.Random.DefaultPrng.init(0xD570_0002);
    const rng = prng.random();
    const active_rooms = [_][]const u8{ "r0", "r1" };
    const namespaces = [_][]const u8{ "", "comp" };

    var root_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (root_ids.items) |id| allocator.free(id);
        root_ids.deinit(allocator);
    }
    var comp_ids: std.ArrayList([]u8) = .empty;
    defer {
        for (comp_ids.items) |id| allocator.free(id);
        comp_ids.deinit(allocator);
    }

    for (0..60) |step| {
        const rep_idx = rng.intRangeLessThan(usize, 0, 3);
        const ns_idx = rng.intRangeLessThan(usize, 0, 2);
        const ns = namespaces[ns_idx];
        const ids = if (ns_idx == 0) &root_ids else &comp_ids;
        const room = active_rooms[rng.intRangeLessThan(usize, 0, 2)];
        const score = rng.intRangeAtMost(i64, -5, 20);

        const op_kind = if (ids.items.len == 0) 0 else rng.intRangeLessThan(u8, 0, 3);
        var args: []u8 = undefined;
        if (op_kind == 0) {
            args = try std.fmt.allocPrint(allocator, "{{\"op\":\"insert\",\"ns\":\"{s}\",\"room\":\"{s}\",\"score\":{d}}}", .{ ns, room, score });
        } else if (op_kind == 1) {
            const id = ids.items[rng.intRangeLessThan(usize, 0, ids.items.len)];
            args = try std.fmt.allocPrint(allocator, "{{\"op\":\"patch\",\"ns\":\"{s}\",\"id\":\"{s}\",\"room\":\"{s}\",\"score\":{d}}}", .{ ns, id, room, score });
        } else {
            const idx = rng.intRangeLessThan(usize, 0, ids.items.len);
            const id = ids.swapRemove(idx);
            defer allocator.free(id);
            args = try std.fmt.allocPrint(allocator, "{{\"op\":\"delete\",\"ns\":\"{s}\",\"id\":\"{s}\"}}", .{ ns, id });
        }
        defer allocator.free(args);

        const mres = try replicas[rep_idx].executeMutation(allocator, "msgs.mutate", args, null);
        defer mres.deinit(allocator);
        try std.testing.expect(mres.result == .ok);
        if (op_kind == 0) {
            // Strip quotes from returned JSON string ID.
            const raw = mres.result.ok;
            try ids.append(allocator, try allocator.dupe(u8, raw[1 .. raw.len - 1]));
        }

        // Interleave delayed commit_log polling on random replicas every few steps.
        if (step % 3 == 0) {
            for (replicas) |r| _ = try r.pollCommitLog();
        }
    }

    // Final sync across all 3 replicas.
    for (replicas) |r| _ = try r.pollCommitLog();

    // 1. Canary client watching room "r2" MUST NOT have received a single spurious transition!
    try std.testing.expectEqual(canary_transitions_initial, mirrors[3].transition_count);

    // 2. EVERY client's mirrored value for EVERY subscription MUST match fresh ground-truth query!
    for (subs) |s| {
        const expected = try replicas[0].executeQuery(allocator, s.name, s.args, null);
        defer expected.deinit(allocator);
        try std.testing.expect(expected == .ok);
        // Normalize expected JSON through parse+stringify so key formatting matches mirror.
        const ep = try std.json.parseFromSlice(std.json.Value, allocator, expected.ok, .{});
        defer ep.deinit();
        const norm_expected = try storage_mod.stringifyJsonValue(allocator, ep.value);
        defer allocator.free(norm_expected);

        const actual = mirrors[s.client].values.get(s.sub_id) orelse return error.MissingClientState;
        try std.testing.expectEqualStrings(norm_expected, actual);
    }

    // 3. OCC Contention & Retry Convergence test:
    //    Seed counter `c1 = 10`, inject a concurrent rival commit `+100` right before `counters.inc(+5)` commits.
    //    Engine MUST detect Conflict, retry on fresh snapshot (110), and commit 115!
    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);
    const seed_counter = [_]storage_mod.WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("counters"),
        .doc_id = @constCast("c1"),
        .creation_time_ms = 1,
        .body_json = @constCast("{\"name\":\"c\",\"val\":10}"),
    } }};
    var sc = try store.commitTx(allocator, &manifest, try store.latestCommitTs(), &empty_rs, &seed_counter);
    sc.deinit(allocator);

    sim.inject_conflict_once = true;
    const inc_res = try replicas[1].executeMutation(allocator, "counters.inc", "{\"id\":\"c1\",\"delta\":5}", null);
    defer inc_res.deinit(allocator);
    try std.testing.expect(inc_res.result == .ok);
    try std.testing.expectEqualStrings("115", inc_res.result.ok);
    try std.testing.expect(!sim.inject_conflict_once);

    const final_doc = (try store.getDoc(allocator, "", "counters", "c1")) orelse return error.MissingCounter;
    defer final_doc.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, final_doc.body_json, "\"val\":115") != null);

    // 4. Idle-replica replay-storm regression check:
    //    Spawn a brand-new idle Replica D after 60+ commits already occurred on replicas[0..2].
    //    Subscribing a client on Replica D must advance `last_broadcast_ts` to its initial snapshot
    //    so `pollCommitLog()` fetches ZERO redundant historical commits!
    var replica_d = try ConcaveEngine.init(allocator, io, .{ .wal = store }, exec, .{});
    defer replica_d.deinit();
    var mirror_d = ClientMirror{ .alloc = allocator };
    defer mirror_d.deinit();
    const cid_d = try replica_d.registerClient(mirror_d.sink());
    defer replica_d.unregisterClient(cid_d);

    try replica_d.subscribe(cid_d, "s0", "msgs.byRoom", "{\"room\":\"r0\"}");
    const transitions_after_sub = mirror_d.transition_count;
    const polled = try replica_d.pollCommitLog();
    try std.testing.expectEqual(@as(usize, 0), polled);
    try std.testing.expectEqual(transitions_after_sub, mirror_d.transition_count);
}

test "DST: concurrent multi-threaded subscribe, mutate, and disconnect (no UAF, no lost updates, monotonic ts)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var manifest = try manifest_mod.AppManifest.parseJson(allocator, dst_manifest_json);
    defer manifest.deinit();

    const ConcExec = struct {
        mf: *const manifest_mod.AppManifest,
        fn getManifest(ptr: *anyopaque) *const manifest_mod.AppManifest {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.mf;
        }
        fn runQuery(_: *anyopaque, alloc: Allocator, _: []const u8, _: []const u8, env: *engine_mod.ExecutionEnv) ExecResult {
            const d = env.dbGet(alloc, "", "counters", "c1") catch return .{ .err = alloc.dupe(u8, "err") catch @panic("OOM") };
            if (d) |doc| {
                defer doc.deinit(alloc);
                return .{ .ok = alloc.dupe(u8, doc.body_json) catch @panic("OOM") };
            }
            return .{ .ok = alloc.dupe(u8, "null") catch @panic("OOM") };
        }
        fn runMutation(_: *anyopaque, alloc: Allocator, _: []const u8, args: []const u8, env: *engine_mod.ExecutionEnv) ExecResult {
            const d = env.dbGet(alloc, "", "counters", "c1") catch return .{ .err = alloc.dupe(u8, "err") catch @panic("OOM") };
            if (d) |doc| {
                doc.deinit(alloc);
                env.dbPatch("", "counters", "c1", args) catch return .{ .err = alloc.dupe(u8, "err") catch @panic("OOM") };
            } else {
                const id = env.dbInsert(alloc, "", "counters", args) catch return .{ .err = alloc.dupe(u8, "err") catch @panic("OOM") };
                alloc.free(id);
            }
            return .{ .ok = alloc.dupe(u8, "true") catch @panic("OOM") };
        }
        fn runAction(_: *anyopaque, alloc: Allocator, _: []const u8, _: []const u8, _: *engine_mod.ExecutionEnv) ExecResult {
            return .{ .ok = alloc.dupe(u8, "null") catch @panic("OOM") };
        }
        const vtable = AppExecutor.VTable{
            .manifest = &getManifest,
            .executeQuery = &runQuery,
            .executeMutation = &runMutation,
            .executeAction = &runAction,
        };
    };

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();
    try store.initSchema(&manifest);

    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);
    const seed = [_]storage_mod.WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("counters"),
        .doc_id = @constCast("c1"),
        .creation_time_ms = 1,
        .body_json = @constCast("{\"name\":\"c\",\"val\":0}"),
    } }};
    var c0 = try store.commitTx(allocator, &manifest, 0, &empty_rs, &seed);
    c0.deinit(allocator);

    var ce = ConcExec{ .mf = &manifest };
    var eng = try ConcaveEngine.init(allocator, io, .{ .wal = store }, .{ .ptr = @ptrCast(&ce), .vtable = &ConcExec.vtable }, .{});
    defer eng.deinit();

    // Thread 1 hammers mutations while Thread 2 repeatedly registers stack-allocated sinks,
    // subscribes, receives concurrent broadcasts, and unregisters/destroys the stack sink!
    // Before our fix, this triggered a dangling stack-pointer UAF or out-of-order `to_ts`!
    const WriterCtx = struct {
        eng: *ConcaveEngine,
        alloc: Allocator,
        done: *std.atomic.Value(bool),
        fn run(ctx: @This()) void {
            for (1..61) |i| {
                const body = std.fmt.allocPrint(ctx.alloc, "{{\"val\":{d}}}", .{i}) catch continue;
                defer ctx.alloc.free(body);
                const mres = ctx.eng.executeMutation(ctx.alloc, "counters.inc", body, null) catch continue;
                mres.deinit(ctx.alloc);
            }
            ctx.done.store(true, .release);
        }
    };

    var done = std.atomic.Value(bool).init(false);
    const writer = try std.Thread.spawn(.{}, WriterCtx.run, .{WriterCtx{
        .eng = eng,
        .alloc = allocator,
        .done = &done,
    }});

    const StackSink = struct {
        magic: u64 = 0xCAFE_BABE_1234_5678,
        last_ts: i64 = 0,
        alloc: Allocator,
        fn send(ptr: *anyopaque, payload: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // Canary catches any dangling stack-pointer UAF immediately!
            std.debug.assert(self.magic == 0xCAFE_BABE_1234_5678);
            const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{}) catch return;
            defer parsed.deinit();
            const to_ts = parsed.value.object.get("to_ts").?.integer;
            // Strict monotonic `to_ts` invariant under concurrent subscribe + broadcast!
            std.debug.assert(to_ts >= self.last_ts);
            self.last_ts = to_ts;
        }
    };

    var cycles: usize = 0;
    while (!done.load(.acquire) or cycles < 30) : (cycles += 1) {
        var local_sink = StackSink{ .alloc = allocator };
        const cid = try eng.registerClient(.{ .ptr = @ptrCast(&local_sink), .sendFn = &StackSink.send });
        try eng.subscribe(cid, "s0", "msgs.byRoom", "{}");
        eng.unregisterClient(cid);
        // Poison the stack slot right after unregister to prove no background thread touches it!
        local_sink.magic = 0xDEAD_DEAD_DEAD_DEAD;
    }

    writer.join();
}
