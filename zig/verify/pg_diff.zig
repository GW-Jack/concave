const std = @import("std");
const Allocator = std.mem.Allocator;
const key_mod = @import("../core/key.zig");
const manifest_mod = @import("../core/manifest.zig");
const pg_mod = @import("../core/pg_wire.zig");
const readset_mod = @import("../core/readset.zig");
const storage_mod = @import("../core/storage.zig");
const wal_mod = @import("../core/wal_store.zig");

const PgStore = pg_mod.PgStore;
const WalStore = wal_mod.WalStore;
const WriteOp = storage_mod.WriteOp;

const diff_manifest_json =
    \\{
    \\  "app_name": "pg-diff-verify",
    \\  "tables": [
    \\    {
    \\      "name": "items",
    \\      "document_schema": {"kind": "any"},
    \\      "indexes": [
    \\        {"name": "by_room", "fields": ["room", "score"]},
    \\        {"name": "by_score", "fields": ["score"]}
    \\      ]
    \\    }
    \\  ],
    \\  "components": [
    \\    {
    \\      "namespace": "comp",
    \\      "package": "comp",
    \\      "tables": [
    \\        {
    \\          "name": "items",
    \\          "document_schema": {"kind": "any"},
    \\          "indexes": [
    \\            {"name": "by_room", "fields": ["room"]}
    \\          ]
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "functions": []
    \\}
;

fn docsEqual(a: []const storage_mod.Document, b: []const storage_mod.Document) bool {
    if (a.len != b.len) return false;
    for (a, b) |da, db| {
        if (!std.mem.eql(u8, da.id, db.id)) return false;
        if (da.creation_time_ms != db.creation_time_ms) return false;
        if (!std.mem.eql(u8, da.body_json, db.body_json)) return false;
    }
    return true;
}

fn freeDocs(allocator: Allocator, docs: []storage_mod.Document) void {
    for (docs) |*d| d.deinit(allocator);
    allocator.free(docs);
}

fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |arr| {
            if (arr.items.len != b.array.items.len) return false;
            for (arr.items, b.array.items) |ia, ib| {
                if (!jsonValuesEqual(ia, ib)) return false;
            }
            return true;
        },
        .object => |obj| {
            if (obj.count() != b.object.count()) return false;
            var it = obj.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse return false;
                if (!jsonValuesEqual(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}

fn assertJsonEqual(allocator: Allocator, a: []const u8, b: []const u8) !void {
    const pa = try std.json.parseFromSlice(std.json.Value, allocator, a, .{});
    defer pa.deinit();
    const pb = try std.json.parseFromSlice(std.json.Value, allocator, b, .{});
    defer pb.deinit();
    if (!jsonValuesEqual(pa.value, pb.value)) {
        std.debug.print("JSON mismatch:\n  WAL: {s}\n  PG : {s}\n", .{ a, b });
        return error.DifferentialMismatch;
    }
}

fn assertDocsEqualJson(allocator: Allocator, wal_docs: []const storage_mod.Document, pg_docs: []const storage_mod.Document) !void {
    if (wal_docs.len != pg_docs.len) {
        std.debug.print("Doc count mismatch: WAL={d}, PG={d}\n", .{ wal_docs.len, pg_docs.len });
        return error.DifferentialMismatch;
    }
    for (wal_docs, pg_docs) |wd, pd| {
        if (!std.mem.eql(u8, wd.id, pd.id)) {
            std.debug.print("Doc ID order mismatch: WAL={s}, PG={s}\n", .{ wd.id, pd.id });
            return error.DifferentialMismatch;
        }
        if (wd.creation_time_ms != pd.creation_time_ms) {
            std.debug.print("creation_time_ms mismatch for {s}: WAL={d}, PG={d}\n", .{ wd.id, wd.creation_time_ms, pd.creation_time_ms });
            return error.DifferentialMismatch;
        }
        try assertJsonEqual(allocator, wd.body_json, pd.body_json);
    }
}

pub fn run(init: std.process.Init) !void {
    var gpa_inst = std.heap.DebugAllocator(.{}){};
    defer {
        const leak = gpa_inst.deinit();
        if (leak == .leak) {
            std.debug.print("MEMORY LEAK detected in pg-diff!\n", .{});
            std.process.exit(2);
        }
    }
    const allocator = gpa_inst.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("Usage: pg-diff <postgres-url> [deployment-id]\n", .{});
        return error.MissingDatabaseUrl;
    }
    const db_url = args[1];
    const dep_id = if (args.len >= 3) args[2] else "diff-dep-1";

    var manifest = try manifest_mod.AppManifest.parseJson(allocator, diff_manifest_json);
    defer manifest.deinit();

    var wal = try WalStore.openInMemory(allocator, io);
    defer wal.deinit();
    try wal.initSchema(&manifest);

    var pg = try PgStore.connect(allocator, io, db_url, dep_id);
    defer pg.deinit();
    try pg.initSchema(&manifest);

    // Second deployment sharing the exact same PostgreSQL database to verify tenant isolation.
    const dep_other = try std.fmt.allocPrint(allocator, "{s}-isolated", .{dep_id});
    defer allocator.free(dep_other);
    var pg_other = try PgStore.connect(allocator, io, db_url, dep_other);
    defer pg_other.deinit();
    try pg_other.initSchema(&manifest);

    const rooms = [_][]const u8{
        "general",
        "roc-lang",
        "O'Brien's \\ room",
        "café-émoji",
    };
    const namespaces = [_][]const u8{ "", "comp" };
    const id_pool = [_][]const u8{ "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7" };

    var prng = std.Random.DefaultPrng.init(0x5EED_9601);
    const rng = prng.random();

    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);

    // 1. Differential randomized workload: 60 multi-op ACID transactions on BOTH WalStore & PgStore!
    for (0..60) |step| {
        const wal_ts = try wal.latestCommitTs();
        const pg_ts = try pg.latestCommitTs();
        if (wal_ts != pg_ts) {
            std.debug.print("latestCommitTs diverged at step {d}: WAL={d}, PG={d}\n", .{ step, wal_ts, pg_ts });
            return error.DifferentialMismatch;
        }

        var ops: std.ArrayList(WriteOp) = .empty;
        defer {
            for (ops.items) |*op| op.deinit(allocator);
            ops.deinit(allocator);
        }

        const ns = namespaces[rng.intRangeLessThan(usize, 0, namespaces.len)];
        const id = id_pool[rng.intRangeLessThan(usize, 0, id_pool.len)];
        const room = rooms[rng.intRangeLessThan(usize, 0, rooms.len)];
        const score = rng.intRangeAtMost(i64, -100, 100);

        const existing = try wal.getDoc(allocator, ns, "items", id);
        defer if (existing) |d| d.deinit(allocator);

        if (existing == null) {
            var body_w: std.Io.Writer.Allocating = .init(allocator);
            errdefer body_w.deinit();
            try body_w.writer.writeAll("{\"room\":");
            try storage_mod.writeJsonString(&body_w.writer, room);
            try body_w.writer.print(",\"score\":{d},\"note\":\"step-{d}; 'quoted'\"}}", .{ score, step });
            try ops.append(allocator, .{ .insert = .{
                .namespace = try allocator.dupe(u8, ns),
                .table = try allocator.dupe(u8, "items"),
                .doc_id = try allocator.dupe(u8, id),
                .creation_time_ms = @intCast(10000 + step),
                .body_json = try body_w.toOwnedSlice(),
            } });
            if (rng.boolean()) {
                // Intra-tx `[insert, patch]`
                const pjson = try std.fmt.allocPrint(allocator, "{{\"score\":{d},\"patched\":true}}", .{score + 7});
                try ops.append(allocator, .{ .patch = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                    .patch_json = pjson,
                } });
            }
        } else {
            const kind = rng.intRangeLessThan(u8, 0, 3);
            if (kind == 0) {
                var pw: std.Io.Writer.Allocating = .init(allocator);
                errdefer pw.deinit();
                try pw.writer.writeAll("{\"room\":");
                try storage_mod.writeJsonString(&pw.writer, room);
                try pw.writer.print(",\"score\":{d}}}", .{score});
                try ops.append(allocator, .{ .patch = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                    .patch_json = try pw.toOwnedSlice(),
                } });
            } else if (kind == 1) {
                var rw: std.Io.Writer.Allocating = .init(allocator);
                errdefer rw.deinit();
                try rw.writer.writeAll("{\"room\":");
                try storage_mod.writeJsonString(&rw.writer, room);
                try rw.writer.print(",\"score\":{d},\"replaced\":true}}", .{score});
                try ops.append(allocator, .{ .replace = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                    .body_json = try rw.toOwnedSlice(),
                } });
            } else {
                try ops.append(allocator, .{ .delete = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                } });
            }
        }

        var w_res = try wal.commitTx(allocator, &manifest, wal_ts, &empty_rs, ops.items);
        defer w_res.deinit(allocator);
        var p_res = try pg.commitTx(allocator, &manifest, pg_ts, &empty_rs, ops.items);
        defer p_res.deinit(allocator);

        if (w_res.commit_ts != p_res.commit_ts) {
            std.debug.print("commit_ts mismatch: WAL={d}, PG={d}\n", .{ w_res.commit_ts, p_res.commit_ts });
            return error.DifferentialMismatch;
        }
        try wal.verifyIndexIntegrity(allocator, &manifest);

        // Compare point lookups across every namespace & ID.
        for (namespaces) |check_ns| {
            for (id_pool) |check_id| {
                const wd = try wal.getDoc(allocator, check_ns, "items", check_id);
                defer if (wd) |d| d.deinit(allocator);
                const pd = try pg.getDoc(allocator, check_ns, "items", check_id);
                defer if (pd) |d| d.deinit(allocator);
                if ((wd == null) != (pd == null)) return error.DifferentialMismatch;
                if (wd != null) try assertJsonEqual(allocator, wd.?.body_json, pd.?.body_json);
            }
        }

        // Compare index scans (`by_room` prefix asc/desc + `by_score` range + component namespace).
        const check_room = rooms[step % rooms.len];
        const lo_r = try key_mod.encodeKey(allocator, &.{.{ .str_val = check_room }});
        defer allocator.free(lo_r);
        const hi_r = try key_mod.encodePrefixUpperBound(allocator, &.{.{ .str_val = check_room }});
        defer allocator.free(hi_r);

        for ([_]storage_mod.QueryOrder{ .asc, .desc }) |ord| {
            const iq = storage_mod.IndexQuery{
                .namespace = "",
                .table = "items",
                .index_name = "by_room",
                .start = .{ .included = lo_r },
                .end = .{ .excluded = hi_r },
                .order = ord,
                .limit = 4,
            };
            const w_docs = try wal.scanIndex(allocator, &iq);
            defer freeDocs(allocator, w_docs);
            const p_docs = try pg.scanIndex(allocator, &iq);
            defer freeDocs(allocator, p_docs);
            try assertDocsEqualJson(allocator, w_docs, p_docs);
        }

        const lo_s = try key_mod.encodeKey(allocator, &.{.{ .int_val = -50 }});
        defer allocator.free(lo_s);
        const hi_s = try key_mod.encodeKey(allocator, &.{.{ .int_val = 50 }});
        defer allocator.free(hi_s);
        const score_q = storage_mod.IndexQuery{
            .namespace = "",
            .table = "items",
            .index_name = "by_score",
            .start = .{ .included = lo_s },
            .end = .{ .included = hi_s },
            .order = .asc,
        };
        const ws_docs = try wal.scanIndex(allocator, &score_q);
        defer freeDocs(allocator, ws_docs);
        const ps_docs = try pg.scanIndex(allocator, &score_q);
        defer freeDocs(allocator, ps_docs);
        try assertDocsEqualJson(allocator, ws_docs, ps_docs);

        // Compare `commitsSince(prev_ts)` returns exact commit_ts count.
        const w_log = try wal.commitsSince(allocator, wal_ts);
        defer {
            for (w_log) |*e| e.deinit(allocator);
            allocator.free(w_log);
        }
        const p_log = try pg.commitsSince(allocator, pg_ts);
        defer {
            for (p_log) |*e| e.deinit(allocator);
            allocator.free(p_log);
        }
        if (w_log.len != p_log.len or w_log.len != 1 or w_log[0].commit_ts != p_log[0].commit_ts) {
            return error.DifferentialMismatch;
        }
    }

    // 2. Verify OCC conflict parity (stale phantom index-range read must fail on BOTH WalStore & PgStore!).
    const base_ts = try wal.latestCommitTs();
    const lo_occ = try key_mod.encodeKey(allocator, &.{.{ .str_val = "occ-room" }});
    defer allocator.free(lo_occ);
    const hi_occ = try key_mod.encodePrefixUpperBound(allocator, &.{.{ .str_val = "occ-room" }});
    defer allocator.free(hi_occ);

    var occ_rs: readset_mod.ReadSet = .{};
    defer occ_rs.deinit(allocator);
    try occ_rs.recordIndexRange(allocator, "", "items", "by_room", .{ .included = lo_occ }, .{ .excluded = hi_occ });

    const occ_ins1 = [_]WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("items"),
        .doc_id = @constCast("occ-1"),
        .creation_time_ms = 99999,
        .body_json = @constCast("{\"room\":\"occ-room\",\"score\":1}"),
    } }};
    var wc1 = try wal.commitTx(allocator, &manifest, base_ts, &occ_rs, &occ_ins1);
    wc1.deinit(allocator);
    var pc1 = try pg.commitTx(allocator, &manifest, base_ts, &occ_rs, &occ_ins1);
    pc1.deinit(allocator);

    const occ_ins2 = [_]WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("items"),
        .doc_id = @constCast("occ-2"),
        .creation_time_ms = 99999,
        .body_json = @constCast("{\"room\":\"occ-room\",\"score\":2}"),
    } }};
    const wal_err = wal.commitTx(allocator, &manifest, base_ts, &occ_rs, &occ_ins2);
    const pg_err = pg.commitTx(allocator, &manifest, base_ts, &occ_rs, &occ_ins2);
    if (wal_err != storage_mod.StorageError.Conflict or pg_err != storage_mod.StorageError.Conflict) {
        std.debug.print("OCC conflict parity failed!\n", .{});
        return error.DifferentialMismatch;
    }

    // 3. Verify multi-deployment isolation on shared Postgres DB!
    if ((try pg_other.latestCommitTs()) != 0) {
        std.debug.print("Deployment isolation violated: other deployment saw ts != 0!\n", .{});
        return error.DeploymentIsolationViolation;
    }
    if ((try pg_other.getDoc(allocator, "", "items", "occ-1")) != null) {
        std.debug.print("Deployment isolation violated: other deployment read occ-1!\n", .{});
        return error.DeploymentIsolationViolation;
    }

    std.debug.print("pg-diff PASSED: 60 differential ACID transactions, SQL escaping, OCC conflict parity, commit_log, and multi-deployment isolation matched WalStore 100%% (dep={s})\n", .{dep_id});
}
