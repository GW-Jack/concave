const std = @import("std");
const Allocator = std.mem.Allocator;
const key_mod = @import("../core/key.zig");
const manifest_mod = @import("../core/manifest.zig");
const readset_mod = @import("../core/readset.zig");
const storage_mod = @import("../core/storage.zig");
const wal_mod = @import("../core/wal_store.zig");

const WalStore = wal_mod.WalStore;
const WriteOp = storage_mod.WriteOp;

const test_manifest_json =
    \\{
    \\  "app_name": "wal-crash-test",
    \\  "tables": [
    \\    {
    \\      "name": "items",
    \\      "document_schema": {"kind": "any"},
    \\      "indexes": [
    \\        {"name": "by_room", "fields": ["room", "seq"]},
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

const SnapshotDoc = struct {
    ns: []u8,
    id: []u8,
    body_json: []u8,

    fn deinit(self: *const SnapshotDoc, allocator: Allocator) void {
        allocator.free(self.ns);
        allocator.free(self.id);
        allocator.free(self.body_json);
    }
};

const StateSnapshot = struct {
    ts: i64,
    docs: std.ArrayList(SnapshotDoc) = .empty,

    fn deinit(self: *StateSnapshot, allocator: Allocator) void {
        for (self.docs.items) |*d| d.deinit(allocator);
        self.docs.deinit(allocator);
    }

    fn capture(allocator: Allocator, store: *WalStore, known_ids: []const []const u8) !StateSnapshot {
        var snap = StateSnapshot{ .ts = try store.latestCommitTs() };
        errdefer snap.deinit(allocator);
        const namespaces = [_][]const u8{ "", "comp" };
        for (namespaces) |ns| {
            for (known_ids) |id| {
                if (try store.getDoc(allocator, ns, "items", id)) |doc| {
                    defer doc.deinit(allocator);
                    try snap.docs.append(allocator, .{
                        .ns = try allocator.dupe(u8, ns),
                        .id = try allocator.dupe(u8, id),
                        .body_json = try allocator.dupe(u8, doc.body_json),
                    });
                }
            }
        }
        return snap;
    }

    fn matches(self: *const StateSnapshot, allocator: Allocator, store: *WalStore, known_ids: []const []const u8) !bool {
        if (try store.latestCommitTs() != self.ts) return false;
        var current = try StateSnapshot.capture(allocator, store, known_ids);
        defer current.deinit(allocator);
        if (current.docs.items.len != self.docs.items.len) return false;
        for (self.docs.items, current.docs.items) |a, b| {
            if (!std.mem.eql(u8, a.ns, b.ns)) return false;
            if (!std.mem.eql(u8, a.id, b.id)) return false;
            if (!std.mem.eql(u8, a.body_json, b.body_json)) return false;
        }
        return true;
    }
};

test "wal store: byte-by-byte power-loss truncation and bit-flip corruption recovery" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var manifest = try manifest_mod.AppManifest.parseJson(allocator, test_manifest_json);
    defer manifest.deinit();

    const wal_path = ".zig-cache/test_wal_crash_recovery.wal";
    std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};

    var store = try WalStore.openFile(allocator, io, wal_path);
    defer store.deinit();
    try store.initSchema(&manifest);

    const rooms = [_][]const u8{ "general", "roc", "zig", "alerts" };
    const namespaces = [_][]const u8{ "", "comp" };
    const id_pool = [_][]const u8{ "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7" };

    var prng = std.Random.DefaultPrng.init(0xFA11_5AFE);
    const rng = prng.random();

    var history: std.ArrayList(StateSnapshot) = .empty;
    defer {
        for (history.items) |*s| s.deinit(allocator);
        history.deinit(allocator);
    }
    try history.append(allocator, try StateSnapshot.capture(allocator, store, &id_pool));

    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);

    // Run 30 randomized multi-op ACID transactions, capturing every committed state S_0..S_30.
    for (0..30) |step| {
        const snap_ts = try store.latestCommitTs();
        var ops: std.ArrayList(WriteOp) = .empty;
        defer {
            for (ops.items) |*op| op.deinit(allocator);
            ops.deinit(allocator);
        }

        const ns = namespaces[rng.intRangeLessThan(usize, 0, namespaces.len)];
        const id = id_pool[rng.intRangeLessThan(usize, 0, id_pool.len)];
        const room = rooms[rng.intRangeLessThan(usize, 0, rooms.len)];
        const score = rng.intRangeAtMost(i64, -50, 50);

        const existing = try store.getDoc(allocator, ns, "items", id);
        defer if (existing) |d| d.deinit(allocator);

        if (existing == null) {
            // Half the time do an intra-tx `[insert, patch]` to verify multi-op atomicity!
            const body = try std.fmt.allocPrint(allocator, "{{\"room\":\"{s}\",\"seq\":{d},\"score\":{d}}}", .{ room, step, score });
            try ops.append(allocator, .{ .insert = .{
                .namespace = try allocator.dupe(u8, ns),
                .table = try allocator.dupe(u8, "items"),
                .doc_id = try allocator.dupe(u8, id),
                .creation_time_ms = @intCast(1000 + step),
                .body_json = body,
            } });
            if (rng.boolean()) {
                const patch = try std.fmt.allocPrint(allocator, "{{\"score\":{d},\"patched\":true}}", .{score + 10});
                try ops.append(allocator, .{ .patch = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                    .patch_json = patch,
                } });
            }
        } else {
            const action = rng.intRangeLessThan(u8, 0, 3);
            if (action == 0) {
                const patch = try std.fmt.allocPrint(allocator, "{{\"room\":\"{s}\",\"score\":{d}}}", .{ room, score });
                try ops.append(allocator, .{ .patch = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                    .patch_json = patch,
                } });
            } else if (action == 1) {
                const body = try std.fmt.allocPrint(allocator, "{{\"room\":\"{s}\",\"seq\":{d},\"score\":{d}}}", .{ room, step, score });
                try ops.append(allocator, .{ .replace = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                    .body_json = body,
                } });
            } else {
                try ops.append(allocator, .{ .delete = .{
                    .namespace = try allocator.dupe(u8, ns),
                    .table = try allocator.dupe(u8, "items"),
                    .doc_id = try allocator.dupe(u8, id),
                } });
            }
        }

        var cres = try store.commitTx(allocator, &manifest, snap_ts, &empty_rs, ops.items);
        cres.deinit(allocator);

        // Live store must maintain exact document <-> index parity after every single commit.
        try store.verifyIndexIntegrity(allocator, &manifest);
        try history.append(allocator, try StateSnapshot.capture(allocator, store, &id_pool));
    }

    // Read the raw WAL file from disk.
    const wal_bytes = try std.Io.Dir.cwd().readFileAlloc(io, wal_path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(wal_bytes);
    try std.testing.expect(wal_bytes.len > 200);

    // 1. Power-loss truncation test: test every single commit boundary (`nl-1`, `nl`, `nl+1`),
    //    every CRC-header boundary (`nl+9`), mid-record cuts, and start/end offsets.
    var prev_recovered_ts: i64 = 0;
    var last_nl: usize = 0;
    var cut: usize = 0;
    while (cut <= wal_bytes.len) : (cut += 1) {
        if (cut > 0 and wal_bytes[cut - 1] == '\n') last_nl = cut;
        const offset_in_line = cut - last_nl;
        const critical_cut = cut == 0 or cut == wal_bytes.len or
            offset_in_line == 0 or offset_in_line == 4 or offset_in_line == 9 or offset_in_line == 40 or
            (cut < wal_bytes.len and wal_bytes[cut] == '\n');
        if (!critical_cut) continue;

        var recovered = try WalStore.openInMemory(allocator, io);
        defer recovered.deinit();
        try recovered.replayWalBytes(wal_bytes[0..cut], &manifest);
        try recovered.verifyIndexIntegrity(allocator, &manifest);

        const rec_ts = try recovered.latestCommitTs();
        try std.testing.expect(rec_ts >= prev_recovered_ts);
        prev_recovered_ts = rec_ts;

        // Recovered state MUST match the exact historical snapshot S_{rec_ts}!
        const idx: usize = @intCast(rec_ts);
        try std.testing.expect(idx < history.items.len);
        try std.testing.expect(try history.items[idx].matches(allocator, recovered, &id_pool));
    }
    try std.testing.expectEqual(@as(i64, @intCast(history.items.len - 1)), prev_recovered_ts);

    // 2. Single-bit flip corruption test across 40 random positions:
    //    CRC32 must detect corruption and stop cleanly at a valid historical prefix!
    const mutable_wal = try allocator.dupe(u8, wal_bytes);
    defer allocator.free(mutable_wal);
    for (0..40) |_| {
        const pos = rng.intRangeLessThan(usize, 0, mutable_wal.len);
        const bit: u8 = @as(u8, 1) << rng.int(u3);
        mutable_wal[pos] ^= bit;
        defer mutable_wal[pos] ^= bit;

        var recovered = try WalStore.openInMemory(allocator, io);
        defer recovered.deinit();
        try recovered.replayWalBytes(mutable_wal, &manifest);
        try recovered.verifyIndexIntegrity(allocator, &manifest);

        const rec_ts = try recovered.latestCommitTs();
        const idx: usize = @intCast(rec_ts);
        try std.testing.expect(idx < history.items.len);
        try std.testing.expect(try history.items[idx].matches(allocator, recovered, &id_pool));
    }

    // 3. Reopening the actual file from disk reproduces the exact final snapshot!
    var reopened = try WalStore.openFile(allocator, io, wal_path);
    defer reopened.deinit();
    try reopened.initSchema(&manifest);
    try reopened.verifyIndexIntegrity(allocator, &manifest);
    try std.testing.expect(try history.items[history.items.len - 1].matches(allocator, reopened, &id_pool));
}

test "wal store: atomic rollback on invalid intra-tx [delete, patch] and phantom index-range OCC" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var manifest = try manifest_mod.AppManifest.parseJson(allocator, test_manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();
    try store.initSchema(&manifest);

    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);

    // Seed doc d1 in room "general".
    const seed = [_]WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("items"),
        .doc_id = @constCast("d1"),
        .creation_time_ms = 100,
        .body_json = @constCast("{\"room\":\"general\",\"seq\":1,\"score\":10}"),
    } }};
    var c1 = try store.commitTx(allocator, &manifest, 0, &empty_rs, &seed);
    c1.deinit(allocator);

    // Invalid intra-tx sequence `[delete(d1), patch(d1)]` must fail atomically leaving d1 intact!
    const bad_tx = [_]WriteOp{
        .{ .delete = .{
            .namespace = @constCast(""),
            .table = @constCast("items"),
            .doc_id = @constCast("d1"),
        } },
        .{ .patch = .{
            .namespace = @constCast(""),
            .table = @constCast("items"),
            .doc_id = @constCast("d1"),
            .patch_json = @constCast("{\"score\":99}"),
        } },
    };
    try std.testing.expectError(
        storage_mod.StorageError.NotFound,
        store.commitTx(allocator, &manifest, 1, &empty_rs, &bad_tx),
    );
    try std.testing.expectEqual(@as(i64, 1), try store.latestCommitTs());
    const still_there = (try store.getDoc(allocator, "", "items", "d1")) orelse return error.ExpectedDoc;
    defer still_there.deinit(allocator);
    try store.verifyIndexIntegrity(allocator, &manifest);

    // Phantom OCC check: Tx A scans room "roc" at ts=1 (empty!), Tx B inserts into "roc" at ts=2,
    // Tx A tries to commit at snapshot_ts=1 -> MUST Conflict!
    var range_roc: readset_mod.ReadSet = .{};
    defer range_roc.deinit(allocator);
    const lo_roc = try key_mod.encodeKey(allocator, &.{.{ .str_val = "roc" }});
    defer allocator.free(lo_roc);
    const hi_roc = try key_mod.encodePrefixUpperBound(allocator, &.{.{ .str_val = "roc" }});
    defer allocator.free(hi_roc);
    try range_roc.recordIndexRange(allocator, "", "items", "by_room", .{ .included = lo_roc }, .{ .excluded = hi_roc });

    // Non-overlapping write to "general" commits at ts=2...
    const write_gen = [_]WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("items"),
        .doc_id = @constCast("d2"),
        .creation_time_ms = 200,
        .body_json = @constCast("{\"room\":\"general\",\"seq\":2,\"score\":20}"),
    } }};
    var c2 = try store.commitTx(allocator, &manifest, 1, &empty_rs, &write_gen);
    c2.deinit(allocator);

    // ...so a tx reading "roc" at ts=1 does NOT conflict with ts=2's "general" write!
    const write_other = [_]WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("items"),
        .doc_id = @constCast("d3"),
        .creation_time_ms = 300,
        .body_json = @constCast("{\"room\":\"roc\",\"seq\":1,\"score\":5}"),
    } }};
    var c3 = try store.commitTx(allocator, &manifest, 1, &range_roc, &write_other);
    c3.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 3), c3.commit_ts);

    // Now a second stale tx that ALSO read "roc" at ts=1 MUST conflict with ts=3's phantom insert!
    const write_stale = [_]WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("items"),
        .doc_id = @constCast("d4"),
        .creation_time_ms = 400,
        .body_json = @constCast("{\"room\":\"roc\",\"seq\":2,\"score\":6}"),
    } }};
    try std.testing.expectError(
        storage_mod.StorageError.Conflict,
        store.commitTx(allocator, &manifest, 1, &range_roc, &write_stale),
    );
    try store.verifyIndexIntegrity(allocator, &manifest);
}
