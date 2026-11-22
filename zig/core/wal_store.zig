const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest_mod = @import("manifest.zig");
const readset_mod = @import("readset.zig");
const storage_mod = @import("storage.zig");

const Document = storage_mod.Document;
const IndexQuery = storage_mod.IndexQuery;
const WriteOp = storage_mod.WriteOp;
const CommitEntry = storage_mod.CommitEntry;
const CommitResult = storage_mod.CommitResult;

const IndexRow = struct {
    namespace: []u8,
    table: []u8,
    index_name: []u8,
    encoded_key: []u8,
    doc_id: []u8,

    fn deinit(self: *const IndexRow, allocator: Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.table);
        allocator.free(self.index_name);
        allocator.free(self.encoded_key);
        allocator.free(self.doc_id);
    }
};

/// Zero-dependency embedded ACID WAL + ordered index store (replaces SQLite for local dev & tests).
///
/// - Persists every committed mutation as an append-only newline-delimited JSON record in `wal_path`
///   and replays it cleanly on startup.
/// - Enforces serializable OCC conflict checks against `commit_log` and maintains both pre-image
///   and post-image index keys in every `WriteSet`.
pub const WalStore = struct {
    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    wal_path: ?[]u8,
    latest_ts: i64 = 0,
    /// Keyed by `"<namespace>\x1f<table>\x1f<doc_id>"` -> owned Document.
    docs: std.StringHashMapUnmanaged(Document) = .empty,
    /// Secondary index entries (kept sorted by encoded_key + doc_id on scan).
    indexes: std.ArrayList(IndexRow) = .empty,
    /// Monotonic commit log for OCC conflict checks and cross-instance tailing.
    commit_log: std.ArrayList(CommitEntry) = .empty,
    /// Number of WAL records appended since the last atomic compaction.
    wal_records_since_compact: usize = 0,
    /// Automatically compact the WAL after this many commits (0 disables auto-compaction).
    compact_threshold: usize = 1000,

    pub fn openInMemory(allocator: Allocator, io: std.Io) !*WalStore {
        const self = try allocator.create(WalStore);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .wal_path = null,
        };
        return self;
    }

    pub fn openFile(allocator: Allocator, io: std.Io, path: []const u8) !*WalStore {
        const self = try allocator.create(WalStore);
        errdefer allocator.destroy(self);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .wal_path = path_copy,
        };

        // Ensure parent directory exists if a relative/nested path was given.
        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) {
                std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            }
        }
        return self;
    }

    pub fn deinit(self: *WalStore) void {
        if (self.wal_path) |p| self.allocator.free(p);
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.docs.deinit(self.allocator);
        for (self.indexes.items) |*row| row.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
        for (self.commit_log.items) |*ce| ce.deinit(self.allocator);
        self.commit_log.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn initSchema(self: *WalStore, manifest: *const manifest_mod.AppManifest) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Replay durable WAL if present and not yet loaded.
        if (self.wal_path) |path| {
            if (self.latest_ts == 0 and self.docs.count() == 0) {
                try self.replayWalLocked(path, manifest);
            }
        }

        // Rebuild all secondary indexes for existing documents so new manifest indexes are synced.
        try self.rebuildIndexesLocked(manifest);
    }

    pub fn latestCommitTs(self: *WalStore) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.latest_ts;
    }

    pub fn getDoc(self: *WalStore, allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) !?Document {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const k = try makeDocKey(self.allocator, ns, table, doc_id);
        defer self.allocator.free(k);
        if (self.docs.get(k)) |doc| {
            return try doc.clone(allocator);
        }
        return null;
    }

    pub fn scanIndex(self: *WalStore, allocator: Allocator, query: *const IndexQuery) ![]Document {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const range = readset_mod.IndexRangeRead{
            .namespace = @constCast(query.namespace),
            .table = @constCast(query.table),
            .index_name = @constCast(query.index_name),
            .start = query.start,
            .end = query.end,
        };

        const Match = struct {
            encoded_key: []const u8,
            doc_id: []const u8,
            doc: *const Document,
        };

        var matches: std.ArrayList(Match) = .empty;
        defer matches.deinit(self.allocator);

        for (self.indexes.items) |*row| {
            if (!std.mem.eql(u8, row.namespace, query.namespace)) continue;
            if (!std.mem.eql(u8, row.table, query.table)) continue;
            if (!std.mem.eql(u8, row.index_name, query.index_name)) continue;
            if (!range.containsKey(row.encoded_key)) continue;

            const dk = try makeDocKey(self.allocator, row.namespace, row.table, row.doc_id);
            defer self.allocator.free(dk);
            if (self.docs.getPtr(dk)) |doc_ptr| {
                try matches.append(self.allocator, .{
                    .encoded_key = row.encoded_key,
                    .doc_id = row.doc_id,
                    .doc = doc_ptr,
                });
            }
        }

        const SortCtx = struct {
            order: storage_mod.QueryOrder,
            fn lessThan(ctx: @This(), a: Match, b: Match) bool {
                const cmp = std.mem.order(u8, a.encoded_key, b.encoded_key);
                const ord = if (cmp != .eq) cmp else std.mem.order(u8, a.doc_id, b.doc_id);
                return switch (ctx.order) {
                    .asc => ord == .lt,
                    .desc => ord == .gt,
                };
            }
        };
        std.mem.sort(Match, matches.items, SortCtx{ .order = query.order }, SortCtx.lessThan);

        const count = if (query.limit) |lim| @min(lim, matches.items.len) else matches.items.len;
        var out = try allocator.alloc(Document, count);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*d| d.deinit(allocator);
            allocator.free(out);
        }
        for (matches.items[0..count], 0..) |m, i| {
            out[i] = try m.doc.clone(allocator);
            built += 1;
        }
        return out;
    }

    pub fn commitTx(
        self: *WalStore,
        allocator: Allocator,
        manifest: *const manifest_mod.AppManifest,
        snapshot_ts: i64,
        read_set: *const readset_mod.ReadSet,
        writes: []const WriteOp,
    ) !CommitResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // 1. OCC conflict check against every commit strictly after `snapshot_ts`.
        if (self.latest_ts > snapshot_ts) {
            for (self.commit_log.items) |*entry| {
                if (entry.commit_ts > snapshot_ts) {
                    if (read_set.intersects(&entry.write_set)) {
                        return storage_mod.StorageError.Conflict;
                    }
                }
            }
        }

        if (writes.len == 0) {
            return .{
                .commit_ts = self.latest_ts,
                .write_set = .{},
            };
        }

        // 2. Validate that target docs exist for Replace/Patch against intra-tx virtual existence state
        //    so `[insert(x), patch(x)]` succeeds and `[delete(x), patch(x)]` fails atomically.
        {
            var v_exists: std.StringHashMapUnmanaged(bool) = .empty;
            defer {
                var vit = v_exists.keyIterator();
                while (vit.next()) |kp| self.allocator.free(kp.*);
                v_exists.deinit(self.allocator);
            }
            for (writes) |op| {
                switch (op) {
                    .insert => |ins| {
                        const k = try makeDocKey(self.allocator, ins.namespace, ins.table, ins.doc_id);
                        if (v_exists.getPtr(k)) |ptr| {
                            self.allocator.free(k);
                            ptr.* = true;
                        } else {
                            try v_exists.put(self.allocator, k, true);
                        }
                    },
                    .replace => |r| {
                        const k = try makeDocKey(self.allocator, r.namespace, r.table, r.doc_id);
                        defer self.allocator.free(k);
                        const exists = v_exists.get(k) orelse self.docs.contains(k);
                        if (!exists) return storage_mod.StorageError.NotFound;
                    },
                    .patch => |p| {
                        const k = try makeDocKey(self.allocator, p.namespace, p.table, p.doc_id);
                        defer self.allocator.free(k);
                        const exists = v_exists.get(k) orelse self.docs.contains(k);
                        if (!exists) return storage_mod.StorageError.NotFound;
                    },
                    .delete => |d| {
                        const k = try makeDocKey(self.allocator, d.namespace, d.table, d.doc_id);
                        if (v_exists.getPtr(k)) |ptr| {
                            self.allocator.free(k);
                            ptr.* = false;
                        } else {
                            try v_exists.put(self.allocator, k, false);
                        }
                    },
                }
            }
        }

        // 3. Apply writes and collect full pre-image + post-image WriteSet.
        var write_set: readset_mod.WriteSet = .{};
        errdefer write_set.deinit(self.allocator);

        for (writes) |op| {
            try self.applyOpLocked(manifest, op, &write_set);
        }

        const next_ts = self.latest_ts + 1;

        // 4. Persist to append-only WAL file before acknowledging commit.
        if (self.wal_path) |path| {
            try self.appendWalLocked(path, next_ts, writes);
        }

        self.latest_ts = next_ts;

        // Store a copy in commit_log and return a copy to caller.
        const caller_ws = try write_set.clone(allocator);
        try self.commit_log.append(self.allocator, .{
            .commit_ts = next_ts,
            .write_set = write_set,
        });

        // Bound in-memory commit_log size while keeping a generous sliding window for OCC/tailers.
        if (self.commit_log.items.len > 4096) {
            const drop = self.commit_log.items.len - 2048;
            for (self.commit_log.items[0..drop]) |*old| old.deinit(self.allocator);
            std.mem.copyForwards(CommitEntry, self.commit_log.items[0..2048], self.commit_log.items[drop..]);
            self.commit_log.shrinkRetainingCapacity(2048);
        }

        // Trigger atomic WAL compaction when threshold is reached.
        if (self.wal_path) |path| {
            self.wal_records_since_compact += 1;
            if (self.compact_threshold > 0 and self.wal_records_since_compact >= self.compact_threshold) {
                self.compactLocked(path) catch {};
            }
        }

        return .{
            .commit_ts = next_ts,
            .write_set = caller_ws,
        };
    }

    /// Atomically compact the on-disk WAL into a minimal CRC32-protected snapshot of live documents.
    pub fn compact(self: *WalStore) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const path = self.wal_path orelse return;
        try self.compactLocked(path);
    }

    fn compactLocked(self: *WalStore, path: []const u8) !void {
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();
        const w = &payload.writer;

        try w.print("{{\"ts\":{d},\"ops\":[", .{self.latest_ts});
        var first = true;
        var dit = self.docs.iterator();
        while (dit.next()) |entry| {
            var parts = std.mem.splitScalar(u8, entry.key_ptr.*, 0x1F);
            const ns = parts.next() orelse continue;
            const tbl = parts.next() orelse continue;
            const doc = entry.value_ptr;

            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"op\":\"insert\",\"ns\":");
            try storage_mod.writeJsonString(w, ns);
            try w.writeAll(",\"table\":");
            try storage_mod.writeJsonString(w, tbl);
            try w.writeAll(",\"id\":");
            try storage_mod.writeJsonString(w, doc.id);
            try w.print(",\"ct\":{d},\"body\":", .{doc.creation_time_ms});
            try storage_mod.writeJsonString(w, doc.body_json);
            try w.writeByte('}');
        }
        try w.writeAll("]}");

        const crc = std.hash.Crc32.hash(payload.written());
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        try line.writer.print("{x:0>8}|{s}\n", .{ crc, payload.written() });

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.compact.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            const file = std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .truncate = true }) catch
                return storage_mod.StorageError.StorageFailure;
            defer file.close(self.io);
            file.writePositionalAll(self.io, line.written(), 0) catch
                return storage_mod.StorageError.StorageFailure;
            file.sync(self.io) catch {};
        }

        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, self.io) catch
            return storage_mod.StorageError.StorageFailure;
        self.wal_records_since_compact = 0;
    }

    pub fn commitsSince(self: *WalStore, allocator: Allocator, since_ts: i64) ![]CommitEntry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(CommitEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }

        for (self.commit_log.items) |*entry| {
            if (entry.commit_ts > since_ts) {
                try out.append(allocator, .{
                    .commit_ts = entry.commit_ts,
                    .write_set = try entry.write_set.clone(allocator),
                });
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    fn applyOpLocked(
        self: *WalStore,
        manifest: *const manifest_mod.AppManifest,
        op: WriteOp,
        write_set: *readset_mod.WriteSet,
    ) !void {
        switch (op) {
            .insert => |ins| {
                const dk = try makeDocKey(self.allocator, ins.namespace, ins.table, ins.doc_id);
                errdefer self.allocator.free(dk);
                const doc = Document{
                    .id = try self.allocator.dupe(u8, ins.doc_id),
                    .creation_time_ms = ins.creation_time_ms,
                    .body_json = try self.allocator.dupe(u8, ins.body_json),
                };
                if (self.docs.fetchRemove(dk)) |old| {
                    self.allocator.free(old.key);
                    old.value.deinit(self.allocator);
                }
                try self.docs.put(self.allocator, dk, doc);
                try write_set.recordDoc(self.allocator, ins.namespace, ins.table, ins.doc_id);
                try self.insertIndexRowsLocked(manifest, ins.namespace, ins.table, &doc, write_set);
            },
            .replace => |rep| {
                const dk = try makeDocKey(self.allocator, rep.namespace, rep.table, rep.doc_id);
                defer self.allocator.free(dk);
                const existing = self.docs.getPtr(dk) orelse return storage_mod.StorageError.NotFound;

                try self.recordAndRemoveIndexRowsLocked(manifest, rep.namespace, rep.table, existing, write_set);
                const new_body = try self.allocator.dupe(u8, rep.body_json);
                self.allocator.free(existing.body_json);
                existing.body_json = new_body;

                try write_set.recordDoc(self.allocator, rep.namespace, rep.table, rep.doc_id);
                try self.insertIndexRowsLocked(manifest, rep.namespace, rep.table, existing, write_set);
            },
            .patch => |pat| {
                const dk = try makeDocKey(self.allocator, pat.namespace, pat.table, pat.doc_id);
                defer self.allocator.free(dk);
                const existing = self.docs.getPtr(dk) orelse return storage_mod.StorageError.NotFound;

                try self.recordAndRemoveIndexRowsLocked(manifest, pat.namespace, pat.table, existing, write_set);
                const merged = try storage_mod.applyPatchJson(self.allocator, existing.body_json, pat.patch_json);
                self.allocator.free(existing.body_json);
                existing.body_json = merged;

                try write_set.recordDoc(self.allocator, pat.namespace, pat.table, pat.doc_id);
                try self.insertIndexRowsLocked(manifest, pat.namespace, pat.table, existing, write_set);
            },
            .delete => |del| {
                const dk = try makeDocKey(self.allocator, del.namespace, del.table, del.doc_id);
                defer self.allocator.free(dk);
                if (self.docs.fetchRemove(dk)) |removed| {
                    defer self.allocator.free(removed.key);
                    defer removed.value.deinit(self.allocator);
                    try self.recordAndRemoveIndexRowsLocked(manifest, del.namespace, del.table, &removed.value, write_set);
                    try write_set.recordDoc(self.allocator, del.namespace, del.table, del.doc_id);
                }
            },
        }
    }

    fn insertIndexRowsLocked(
        self: *WalStore,
        manifest: *const manifest_mod.AppManifest,
        ns: []const u8,
        table: []const u8,
        doc: *const Document,
        write_set: ?*readset_mod.WriteSet,
    ) !void {
        const entries = try storage_mod.computeIndexEntries(self.allocator, manifest, ns, table, doc);
        defer {
            for (entries) |*e| e.deinit(self.allocator);
            self.allocator.free(entries);
        }
        for (entries) |e| {
            try self.indexes.append(self.allocator, .{
                .namespace = try self.allocator.dupe(u8, ns),
                .table = try self.allocator.dupe(u8, table),
                .index_name = try self.allocator.dupe(u8, e.index_name),
                .encoded_key = try self.allocator.dupe(u8, e.encoded_key),
                .doc_id = try self.allocator.dupe(u8, doc.id),
            });
            if (write_set) |ws| {
                try ws.recordIndexKey(self.allocator, ns, table, e.index_name, e.encoded_key);
            }
        }
    }

    fn recordAndRemoveIndexRowsLocked(
        self: *WalStore,
        manifest: *const manifest_mod.AppManifest,
        ns: []const u8,
        table: []const u8,
        doc: *const Document,
        write_set: *readset_mod.WriteSet,
    ) !void {
        const old_entries = try storage_mod.computeIndexEntries(self.allocator, manifest, ns, table, doc);
        defer {
            for (old_entries) |*e| e.deinit(self.allocator);
            self.allocator.free(old_entries);
        }
        for (old_entries) |e| {
            try write_set.recordIndexKey(self.allocator, ns, table, e.index_name, e.encoded_key);
        }

        var i: usize = 0;
        while (i < self.indexes.items.len) {
            const row = &self.indexes.items[i];
            if (std.mem.eql(u8, row.namespace, ns) and
                std.mem.eql(u8, row.table, table) and
                std.mem.eql(u8, row.doc_id, doc.id))
            {
                row.deinit(self.allocator);
                _ = self.indexes.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn rebuildIndexesLocked(self: *WalStore, manifest: *const manifest_mod.AppManifest) !void {
        for (self.indexes.items) |*row| row.deinit(self.allocator);
        self.indexes.clearRetainingCapacity();

        var it = self.docs.iterator();
        while (it.next()) |entry| {
            var parts = std.mem.splitScalar(u8, entry.key_ptr.*, 0x1F);
            const ns = parts.next() orelse continue;
            const tbl = parts.next() orelse continue;
            try self.insertIndexRowsLocked(manifest, ns, tbl, entry.value_ptr, null);
        }
    }

    fn appendWalLocked(self: *WalStore, path: []const u8, commit_ts: i64, writes: []const WriteOp) !void {
        var payload: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload.deinit();
        const w = &payload.writer;

        try w.print("{{\"ts\":{d},\"ops\":[", .{commit_ts});
        for (writes, 0..) |op, idx| {
            if (idx > 0) try w.writeByte(',');
            switch (op) {
                .insert => |ins| {
                    try w.writeAll("{\"op\":\"insert\",\"ns\":");
                    try storage_mod.writeJsonString(w, ins.namespace);
                    try w.writeAll(",\"table\":");
                    try storage_mod.writeJsonString(w, ins.table);
                    try w.writeAll(",\"id\":");
                    try storage_mod.writeJsonString(w, ins.doc_id);
                    try w.print(",\"ct\":{d},\"body\":", .{ins.creation_time_ms});
                    try storage_mod.writeJsonString(w, ins.body_json);
                    try w.writeByte('}');
                },
                .replace => |rep| {
                    try w.writeAll("{\"op\":\"replace\",\"ns\":");
                    try storage_mod.writeJsonString(w, rep.namespace);
                    try w.writeAll(",\"table\":");
                    try storage_mod.writeJsonString(w, rep.table);
                    try w.writeAll(",\"id\":");
                    try storage_mod.writeJsonString(w, rep.doc_id);
                    try w.writeAll(",\"body\":");
                    try storage_mod.writeJsonString(w, rep.body_json);
                    try w.writeByte('}');
                },
                .patch => |pat| {
                    try w.writeAll("{\"op\":\"patch\",\"ns\":");
                    try storage_mod.writeJsonString(w, pat.namespace);
                    try w.writeAll(",\"table\":");
                    try storage_mod.writeJsonString(w, pat.table);
                    try w.writeAll(",\"id\":");
                    try storage_mod.writeJsonString(w, pat.doc_id);
                    try w.writeAll(",\"patch\":");
                    try storage_mod.writeJsonString(w, pat.patch_json);
                    try w.writeByte('}');
                },
                .delete => |del| {
                    try w.writeAll("{\"op\":\"delete\",\"ns\":");
                    try storage_mod.writeJsonString(w, del.namespace);
                    try w.writeAll(",\"table\":");
                    try storage_mod.writeJsonString(w, del.table);
                    try w.writeAll(",\"id\":");
                    try storage_mod.writeJsonString(w, del.doc_id);
                    try w.writeByte('}');
                },
            }
        }
        try w.writeAll("]}");

        const crc = std.hash.Crc32.hash(payload.written());
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        try line.writer.print("{x:0>8}|{s}\n", .{ crc, payload.written() });

        const file = std.Io.Dir.cwd().createFile(self.io, path, .{
            .truncate = false,
            .read = true,
        }) catch return storage_mod.StorageError.StorageFailure;
        defer file.close(self.io);

        const stat = file.stat(self.io) catch return storage_mod.StorageError.StorageFailure;
        file.writePositionalAll(self.io, line.written(), stat.size) catch
            return storage_mod.StorageError.StorageFailure;
        file.sync(self.io) catch {};
    }

    fn replayWalLocked(self: *WalStore, path: []const u8, manifest: *const manifest_mod.AppManifest) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024 * 1024)) catch
            return;
        defer self.allocator.free(bytes);
        try self.replayWalBytesLocked(bytes, manifest);
    }

    /// Replay a WAL byte buffer into this store (also used directly by crash-recovery & fuzz tests).
    /// - Only newline-terminated frames are considered committed (trailing partial frames are torn writes).
    /// - CRC32-framed lines (`<8-hex-crc>|<json>`) reject any bit-flip corruption atomically.
    /// - Every op in a line is fully validated before any state is mutated.
    pub fn replayWalBytes(self: *WalStore, bytes: []const u8, manifest: *const manifest_mod.AppManifest) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replayWalBytesLocked(bytes, manifest);
        try self.rebuildIndexesLocked(manifest);
    }

    fn replayWalBytesLocked(self: *WalStore, bytes: []const u8, manifest: *const manifest_mod.AppManifest) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse {
                // Unterminated trailing line => torn write from crash; stop replay cleanly.
                break;
            };
            const raw_line = std.mem.trim(u8, bytes[pos..nl], " \t\r");
            pos = nl + 1;
            if (raw_line.len == 0) continue;

            // Verify CRC32 framing if present (`<8-hex-crc>|<json>`).
            var json_slice = raw_line;
            if (raw_line.len >= 9 and raw_line[8] == '|') {
                const expected_crc = std.fmt.parseInt(u32, raw_line[0..8], 16) catch break;
                const payload = raw_line[9..];
                if (std.hash.Crc32.hash(payload) != expected_crc) {
                    // Corrupted WAL record => stop replay at the last valid committed prefix.
                    break;
                }
                json_slice = payload;
            } else if (raw_line[0] != '{') {
                break;
            }

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json_slice, .{}) catch break;
            if (parsed != .object) break;
            const ts_v = parsed.object.get("ts") orelse break;
            if (ts_v != .integer or ts_v.integer <= 0) break;
            const ops_v = parsed.object.get("ops") orelse break;
            if (ops_v != .array) break;

            // Validate and decode all ops in this transaction before applying any of them.
            var decoded_ops: std.ArrayList(WriteOp) = .empty;
            var valid_line = true;
            for (ops_v.array.items) |op_v| {
                if (op_v != .object) {
                    valid_line = false;
                    break;
                }
                const kind = jsonStrField(op_v.object, "op") orelse {
                    valid_line = false;
                    break;
                };
                const ns = jsonStrField(op_v.object, "ns") orelse {
                    valid_line = false;
                    break;
                };
                const tbl = jsonStrField(op_v.object, "table") orelse {
                    valid_line = false;
                    break;
                };
                const id = jsonStrField(op_v.object, "id") orelse {
                    valid_line = false;
                    break;
                };

                if (std.mem.eql(u8, kind, "insert")) {
                    const ct = jsonIntField(op_v.object, "ct") orelse {
                        valid_line = false;
                        break;
                    };
                    const body = jsonStrField(op_v.object, "body") orelse {
                        valid_line = false;
                        break;
                    };
                    try decoded_ops.append(a, .{ .insert = .{
                        .namespace = @constCast(ns),
                        .table = @constCast(tbl),
                        .doc_id = @constCast(id),
                        .creation_time_ms = ct,
                        .body_json = @constCast(body),
                    } });
                } else if (std.mem.eql(u8, kind, "replace")) {
                    const body = jsonStrField(op_v.object, "body") orelse {
                        valid_line = false;
                        break;
                    };
                    try decoded_ops.append(a, .{ .replace = .{
                        .namespace = @constCast(ns),
                        .table = @constCast(tbl),
                        .doc_id = @constCast(id),
                        .body_json = @constCast(body),
                    } });
                } else if (std.mem.eql(u8, kind, "patch")) {
                    const patch = jsonStrField(op_v.object, "patch") orelse {
                        valid_line = false;
                        break;
                    };
                    try decoded_ops.append(a, .{ .patch = .{
                        .namespace = @constCast(ns),
                        .table = @constCast(tbl),
                        .doc_id = @constCast(id),
                        .patch_json = @constCast(patch),
                    } });
                } else if (std.mem.eql(u8, kind, "delete")) {
                    try decoded_ops.append(a, .{ .delete = .{
                        .namespace = @constCast(ns),
                        .table = @constCast(tbl),
                        .doc_id = @constCast(id),
                    } });
                } else {
                    valid_line = false;
                    break;
                }
            }
            if (!valid_line) break;

            // Validate doc existence for replace/patch before mutating state.
            var v_exists: std.StringHashMapUnmanaged(bool) = .empty;
            var ops_applicable = true;
            for (decoded_ops.items) |op| {
                switch (op) {
                    .insert => |ins| {
                        const k = try makeDocKey(a, ins.namespace, ins.table, ins.doc_id);
                        try v_exists.put(a, k, true);
                    },
                    .replace => |r| {
                        const k = try makeDocKey(a, r.namespace, r.table, r.doc_id);
                        if (!(v_exists.get(k) orelse self.docs.contains(k))) {
                            ops_applicable = false;
                            break;
                        }
                    },
                    .patch => |p| {
                        const k = try makeDocKey(a, p.namespace, p.table, p.doc_id);
                        if (!(v_exists.get(k) orelse self.docs.contains(k))) {
                            ops_applicable = false;
                            break;
                        }
                    },
                    .delete => |d| {
                        const k = try makeDocKey(a, d.namespace, d.table, d.doc_id);
                        try v_exists.put(a, k, false);
                    },
                }
            }
            if (!ops_applicable) break;

            var ws: readset_mod.WriteSet = .{};
            defer ws.deinit(self.allocator);
            for (decoded_ops.items) |op| {
                self.applyOpLocked(manifest, op, &ws) catch break;
            }
            if (ts_v.integer > self.latest_ts) {
                self.latest_ts = ts_v.integer;
            }
        }
    }

    /// Assert that `self.indexes` matches `computeIndexEntries` across every live document (no orphan or missing rows).
    pub fn verifyIndexIntegrity(self: *WalStore, allocator: Allocator, manifest: *const manifest_mod.AppManifest) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var expected: std.StringHashMapUnmanaged(usize) = .empty;
        defer {
            var it = expected.keyIterator();
            while (it.next()) |kp| allocator.free(kp.*);
            expected.deinit(allocator);
        }

        var dit = self.docs.iterator();
        while (dit.next()) |entry| {
            var parts = std.mem.splitScalar(u8, entry.key_ptr.*, 0x1F);
            const ns = parts.next() orelse continue;
            const tbl = parts.next() orelse continue;
            const rows = try storage_mod.computeIndexEntries(allocator, manifest, ns, tbl, entry.value_ptr);
            defer {
                for (rows) |*r| r.deinit(allocator);
                allocator.free(rows);
            }
            for (rows) |r| {
                const sig = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{x}", .{
                    ns, tbl, r.index_name, entry.value_ptr.id, r.encoded_key,
                });
                const gop = try expected.getOrPut(allocator, sig);
                if (gop.found_existing) {
                    allocator.free(sig);
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
        }

        for (self.indexes.items) |row| {
            const sig = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{x}", .{
                row.namespace, row.table, row.index_name, row.doc_id, row.encoded_key,
            });
            defer allocator.free(sig);
            const cnt = expected.getPtr(sig) orelse return error.IndexIntegrityViolation;
            if (cnt.* == 0) return error.IndexIntegrityViolation;
            cnt.* -= 1;
        }

        var eit = expected.valueIterator();
        while (eit.next()) |rem| {
            if (rem.* != 0) return error.IndexIntegrityViolation;
        }
    }
};

fn jsonStrField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonIntField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = obj.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn makeDocKey(allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ ns, table, doc_id });
}

test "wal store insert, index scan, patch moving out of index range, delete, and OCC" {
    const key_mod = @import("key.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const manifest_json =
        \\{"app_name":"test","tables":[{"name":"messages","document_schema":{"kind":"any"},"indexes":[{"name":"by_room","fields":["room_id"]}]}],"components":[],"functions":[]}
    ;
    var manifest = try manifest_mod.AppManifest.parseJson(allocator, manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();
    try store.initSchema(&manifest);

    try std.testing.expectEqual(@as(i64, 0), try store.latestCommitTs());

    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);

    const w1 = [_]WriteOp{
        .{ .insert = .{
            .namespace = @constCast(""),
            .table = @constCast("messages"),
            .doc_id = @constCast("m1"),
            .creation_time_ms = 1000,
            .body_json = @constCast("{\"room_id\":\"general\",\"body\":\"hello\"}"),
        } },
        .{ .insert = .{
            .namespace = @constCast(""),
            .table = @constCast("messages"),
            .doc_id = @constCast("m2"),
            .creation_time_ms = 2000,
            .body_json = @constCast("{\"room_id\":\"roc\",\"body\":\"functional\"}"),
        } },
        .{ .insert = .{
            .namespace = @constCast(""),
            .table = @constCast("messages"),
            .doc_id = @constCast("m3"),
            .creation_time_ms = 3000,
            .body_json = @constCast("{\"room_id\":\"general\",\"body\":\"world\"}"),
        } },
    };
    var c1 = try store.commitTx(allocator, &manifest, 0, &empty_rs, &w1);
    defer c1.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1), c1.commit_ts);

    const start_gen = try key_mod.encodeKey(allocator, &.{.{ .str_val = "general" }});
    defer allocator.free(start_gen);
    const end_gen = try key_mod.encodePrefixUpperBound(allocator, &.{.{ .str_val = "general" }});
    defer allocator.free(end_gen);

    const docs = try store.scanIndex(allocator, &.{
        .namespace = "",
        .table = "messages",
        .index_name = "by_room",
        .start = .{ .included = start_gen },
        .end = .{ .excluded = end_gen },
        .order = .desc,
        .limit = 10,
    });
    defer {
        for (docs) |*d| d.deinit(allocator);
        allocator.free(docs);
    }
    try std.testing.expectEqual(@as(usize, 2), docs.len);
    try std.testing.expectEqualStrings("m3", docs[0].id);
    try std.testing.expectEqualStrings("m1", docs[1].id);

    // OCC: stale read of m1 at snapshot_ts=0 must conflict!
    var stale_rs: readset_mod.ReadSet = .{};
    defer stale_rs.deinit(allocator);
    try stale_rs.recordDocRead(allocator, "", "messages", "m1");

    const w_conflict = [_]WriteOp{.{ .patch = .{
        .namespace = @constCast(""),
        .table = @constCast("messages"),
        .doc_id = @constCast("m1"),
        .patch_json = @constCast("{\"body\":\"edited\"}"),
    } }};
    try std.testing.expectError(
        storage_mod.StorageError.Conflict,
        store.commitTx(allocator, &manifest, 0, &stale_rs, &w_conflict),
    );

    // Patch moving m1 from "general" to "roc" MUST invalidate "general" watcher via pre-image key!
    const w_move = [_]WriteOp{.{ .patch = .{
        .namespace = @constCast(""),
        .table = @constCast("messages"),
        .doc_id = @constCast("m1"),
        .patch_json = @constCast("{\"room_id\":\"roc\",\"body\":\"moved\"}"),
    } }};
    var c2 = try store.commitTx(allocator, &manifest, c1.commit_ts, &empty_rs, &w_move);
    defer c2.deinit(allocator);

    var gen_watcher: readset_mod.ReadSet = .{};
    defer gen_watcher.deinit(allocator);
    try gen_watcher.recordIndexRange(allocator, "", "messages", "by_room", .{ .included = start_gen }, .{ .excluded = end_gen });
    try std.testing.expect(gen_watcher.intersects(&c2.write_set));
}

test "wal store atomic compaction shrinks log and recovers exact live state + commit_ts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const wal_path = ".zig-cache/test-compact.wal";
    std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};

    const manifest_json =
        \\{"app_name":"compact","tables":[{"name":"items","document_schema":{"kind":"any"},"indexes":[{"name":"by_val","fields":["val"]}]}],"components":[],"functions":[]}
    ;
    var manifest = try manifest_mod.AppManifest.parseJson(allocator, manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openFile(allocator, io, wal_path);
    store.compact_threshold = 0; // test manual compaction + size drop
    try store.initSchema(&manifest);

    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);

    // Insert 2 docs, patch doc1 60 times, delete doc2.
    {
        const w_ins = [_]WriteOp{
            .{ .insert = .{ .namespace = @constCast(""), .table = @constCast("items"), .doc_id = @constCast("d1"), .creation_time_ms = 100, .body_json = @constCast("{\"val\":0}") } },
            .{ .insert = .{ .namespace = @constCast(""), .table = @constCast("items"), .doc_id = @constCast("d2"), .creation_time_ms = 101, .body_json = @constCast("{\"val\":999}") } },
        };
        var c = try store.commitTx(allocator, &manifest, 0, &empty_rs, &w_ins);
        c.deinit(allocator);
    }
    for (1..61) |i| {
        const patch_json = try std.fmt.allocPrint(allocator, "{{\"val\":{d}}}", .{i});
        defer allocator.free(patch_json);
        const w_pat = [_]WriteOp{.{ .patch = .{ .namespace = @constCast(""), .table = @constCast("items"), .doc_id = @constCast("d1"), .patch_json = patch_json } }};
        var c = try store.commitTx(allocator, &manifest, try store.latestCommitTs(), &empty_rs, &w_pat);
        c.deinit(allocator);
    }
    {
        const w_del = [_]WriteOp{.{ .delete = .{ .namespace = @constCast(""), .table = @constCast("items"), .doc_id = @constCast("d2") } }};
        var c = try store.commitTx(allocator, &manifest, try store.latestCommitTs(), &empty_rs, &w_del);
        c.deinit(allocator);
    }

    const before_bytes = try std.Io.Dir.cwd().readFileAlloc(io, wal_path, allocator, .limited(10 * 1024 * 1024));
    const before_len = before_bytes.len;
    allocator.free(before_bytes);

    try store.compact();
    const expected_ts = try store.latestCommitTs();
    store.deinit();

    const after_bytes = try std.Io.Dir.cwd().readFileAlloc(io, wal_path, allocator, .limited(10 * 1024 * 1024));
    const after_len = after_bytes.len;
    allocator.free(after_bytes);
    try std.testing.expect(after_len * 5 < before_len);

    // Reopen from compacted WAL and verify exact state + monotonic commit_ts + index integrity!
    var reopened = try WalStore.openFile(allocator, io, wal_path);
    defer reopened.deinit();
    try reopened.initSchema(&manifest);
    try std.testing.expectEqual(expected_ts, try reopened.latestCommitTs());
    const d1 = (try reopened.getDoc(allocator, "", "items", "d1")).?;
    defer d1.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, d1.body_json, "60") != null);
    try std.testing.expect((try reopened.getDoc(allocator, "", "items", "d2")) == null);
    try reopened.verifyIndexIntegrity(allocator, &manifest);
}
