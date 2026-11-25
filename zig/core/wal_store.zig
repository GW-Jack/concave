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

const SortedIndexRow = struct {
    encoded_key: []u8,
    doc_id: []u8,

    fn deinit(self: *const SortedIndexRow, allocator: Allocator) void {
        allocator.free(self.encoded_key);
        allocator.free(self.doc_id);
    }
};

fn cmpRow(a_key: []const u8, a_id: []const u8, b_key: []const u8, b_id: []const u8) std.math.Order {
    const c = std.mem.order(u8, a_key, b_key);
    return if (c != .eq) c else std.mem.order(u8, a_id, b_id);
}

fn lowerBoundKeyDoc(items: []const SortedIndexRow, key: []const u8, doc_id: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cmpRow(items[mid].encoded_key, items[mid].doc_id, key, doc_id) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn lowerBoundKeyOnly(items: []const SortedIndexRow, key: []const u8, inclusive: bool) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const ord = std.mem.order(u8, items[mid].encoded_key, key);
        const go_right = if (inclusive) ord == .lt else (ord == .lt or ord == .eq);
        if (go_right) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn upperBoundKeyOnly(items: []const SortedIndexRow, key: []const u8, inclusive: bool) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const ord = std.mem.order(u8, items[mid].encoded_key, key);
        const go_right = if (inclusive) (ord == .lt or ord == .eq) else ord == .lt;
        if (go_right) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

const CommitWaiter = struct {
    allocator: Allocator,
    manifest: *const manifest_mod.AppManifest,
    snapshot_ts: i64,
    read_set: *const readset_mod.ReadSet,
    writes: []const WriteOp,
    done: bool = false,
    result: anyerror!CommitResult = undefined,
    next: ?*CommitWaiter = null,
};

/// Zero-dependency embedded ACID WAL + partitioned $O(\log N)$ ordered index store with Leader-Follower Group Commit.
///
/// - Uses an `RwLock` for parallel concurrent reads (`getDoc`, `scanIndex`, `scanIndexToWireJson`).
/// - Batches concurrent durable commits into a single `write()` + `fsync()` call via Leader-Follower
///   Group Commit while preserving strict OCC serializability, linearizability, and zero dirty reads.
/// - Persists every committed mutation as an append-only CRC32-framed JSON record in `wal_path`
///   using a persistent open file handle, with atomic snapshot compaction.
pub const WalStore = struct {
    allocator: Allocator,
    io: std.Io,
    rwlock: std.Io.RwLock = .init,
    /// Protects `wal_file` I/O (`writePositionalAll`, `sync`, and `compactLocked` close/rename)
    /// so `file.sync()` runs outside `rwlock` without blocking concurrent readers or Roc mutations.
    /// Strict lock order: `rwlock` -> `wal_io_mutex` (never reversed).
    wal_io_mutex: std.Io.Mutex = .init,
    /// Group-commit waiter queue (separate lock so arriving writers enqueue while leader fsyncs).
    queue_mutex: std.Io.Mutex = .init,
    queue_cond: std.Io.Condition = .init,
    queue_head: ?*CommitWaiter = null,
    queue_tail: ?*CommitWaiter = null,
    leader_active: bool = false,
    wal_path: ?[]u8,
    wal_file: ?std.Io.File = null,
    wal_file_size: u64 = 0,
    /// Reusable batch buffer for zero-alloc WAL serialization & in-place CRC32 framing.
    wal_batch: std.Io.Writer.Allocating,
    wal_fsync_count: std.atomic.Value(u64) = .init(0),
    wal_group_batches: std.atomic.Value(u64) = .init(0),
    latest_ts: i64 = 0,
    latest_ts_atomic: std.atomic.Value(i64) = .init(0),
    /// Keyed by `"<namespace>\x1f<table>\x1f<doc_id>"` -> owned Document.
    docs: std.StringHashMapUnmanaged(Document) = .empty,
    /// Partitioned secondary indexes keyed by `"<ns>\x1f<table>\x1f<index_name>"` -> sorted rows.
    index_buckets: std.StringHashMapUnmanaged(std.ArrayList(SortedIndexRow)) = .empty,
    /// Monotonic commit log for OCC conflict checks and cross-instance tailing.
    commit_log: std.ArrayList(CommitEntry) = .empty,
    /// Lowest commit_ts whose successor commits are all still retained in `commit_log`.
    /// Any transaction whose `snapshot_ts < min_retained_commit_ts` cannot be safely validated
    /// against missed commits and must conservatively abort with `StorageError.Conflict`.
    min_retained_commit_ts: i64 = 0,
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
            .wal_batch = .init(allocator),
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
            .wal_batch = .init(allocator),
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
        if (self.wal_file) |f| f.close(self.io);
        self.wal_batch.deinit();
        if (self.wal_path) |p| self.allocator.free(p);
        var it = self.docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.docs.deinit(self.allocator);
        var bit = self.index_buckets.iterator();
        while (bit.next()) |b| {
            self.allocator.free(b.key_ptr.*);
            for (b.value_ptr.items) |*row| row.deinit(self.allocator);
            b.value_ptr.deinit(self.allocator);
        }
        self.index_buckets.deinit(self.allocator);
        for (self.commit_log.items) |*ce| ce.deinit(self.allocator);
        self.commit_log.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn initSchema(self: *WalStore, manifest: *const manifest_mod.AppManifest) !void {
        self.rwlock.lockUncancelable(self.io);
        defer self.rwlock.unlock(self.io);

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
        return self.latest_ts_atomic.load(.acquire);
    }

    pub fn getDoc(self: *WalStore, allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) !?Document {
        self.rwlock.lockSharedUncancelable(self.io);
        defer self.rwlock.unlockShared(self.io);

        var stack_buf: [256]u8 = undefined;
        const k = try formatKey3Buf(&stack_buf, self.allocator, ns, table, doc_id);
        defer if (k.owned) self.allocator.free(k.slice);
        if (self.docs.get(k.slice)) |doc| {
            return try doc.clone(allocator);
        }
        return null;
    }

    pub fn scanIndex(self: *WalStore, allocator: Allocator, query: *const IndexQuery) ![]Document {
        self.rwlock.lockSharedUncancelable(self.io);
        defer self.rwlock.unlockShared(self.io);

        var bucket_buf: [256]u8 = undefined;
        const bk = try formatKey3Buf(&bucket_buf, self.allocator, query.namespace, query.table, query.index_name);
        defer if (bk.owned) self.allocator.free(bk.slice);

        const bucket = self.index_buckets.getPtr(bk.slice) orelse return try allocator.alloc(Document, 0);
        const rows = bucket.items;
        if (rows.len == 0) return try allocator.alloc(Document, 0);

        const lo: usize = switch (query.start) {
            .unbounded => 0,
            .included => |k| lowerBoundKeyOnly(rows, k, true),
            .excluded => |k| lowerBoundKeyOnly(rows, k, false),
        };
        const hi: usize = switch (query.end) {
            .unbounded => rows.len,
            .included => |k| upperBoundKeyOnly(rows, k, true),
            .excluded => |k| upperBoundKeyOnly(rows, k, false),
        };
        if (lo >= hi) return try allocator.alloc(Document, 0);

        const span = rows[lo..hi];
        const count = if (query.limit) |lim| @min(lim, span.len) else span.len;
        var out = try allocator.alloc(Document, count);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*d| d.deinit(allocator);
            allocator.free(out);
        }

        var doc_buf: [256]u8 = undefined;
        for (0..count) |i| {
            const row = switch (query.order) {
                .asc => &span[i],
                .desc => &span[span.len - 1 - i],
            };
            const dk = try formatKey3Buf(&doc_buf, self.allocator, query.namespace, query.table, row.doc_id);
            defer if (dk.owned) self.allocator.free(dk.slice);
            if (self.docs.getPtr(dk.slice)) |doc_ptr| {
                out[built] = try doc_ptr.clone(allocator);
                built += 1;
            }
        }
        if (built < count) {
            return try allocator.realloc(out, built);
        }
        return out;
    }

    /// Zero-clone fast path: streams matching documents directly as a JSON array into `w` under a shared lock.
    pub fn scanIndexToWireJson(self: *WalStore, query: *const IndexQuery, w: *std.Io.Writer) !void {
        self.rwlock.lockSharedUncancelable(self.io);
        defer self.rwlock.unlockShared(self.io);

        try w.writeByte('[');

        var bucket_buf: [256]u8 = undefined;
        const bk = try formatKey3Buf(&bucket_buf, self.allocator, query.namespace, query.table, query.index_name);
        defer if (bk.owned) self.allocator.free(bk.slice);

        if (self.index_buckets.getPtr(bk.slice)) |bucket| {
            const rows = bucket.items;
            if (rows.len > 0) {
                const lo: usize = switch (query.start) {
                    .unbounded => 0,
                    .included => |k| lowerBoundKeyOnly(rows, k, true),
                    .excluded => |k| lowerBoundKeyOnly(rows, k, false),
                };
                const hi: usize = switch (query.end) {
                    .unbounded => rows.len,
                    .included => |k| upperBoundKeyOnly(rows, k, true),
                    .excluded => |k| upperBoundKeyOnly(rows, k, false),
                };
                if (lo < hi) {
                    const span = rows[lo..hi];
                    const count = if (query.limit) |lim| @min(lim, span.len) else span.len;
                    var doc_buf: [256]u8 = undefined;
                    var written: usize = 0;
                    for (0..count) |i| {
                        const row = switch (query.order) {
                            .asc => &span[i],
                            .desc => &span[span.len - 1 - i],
                        };
                        const dk = try formatKey3Buf(&doc_buf, self.allocator, query.namespace, query.table, row.doc_id);
                        defer if (dk.owned) self.allocator.free(dk.slice);
                        if (self.docs.getPtr(dk.slice)) |doc_ptr| {
                            if (written > 0) try w.writeByte(',');
                            try doc_ptr.writeWireJson(w);
                            written += 1;
                        }
                    }
                }
            }
        }

        try w.writeByte(']');
    }

    pub fn commitTx(
        self: *WalStore,
        allocator: Allocator,
        manifest: *const manifest_mod.AppManifest,
        snapshot_ts: i64,
        read_set: *const readset_mod.ReadSet,
        writes: []const WriteOp,
    ) !CommitResult {
        // Fast path 1: read-only commits validate OCC under a shared lock with zero disk I/O.
        if (writes.len == 0) {
            self.rwlock.lockSharedUncancelable(self.io);
            defer self.rwlock.unlockShared(self.io);
            if (self.latest_ts > snapshot_ts) {
                if (snapshot_ts < self.min_retained_commit_ts) {
                    return storage_mod.StorageError.Conflict;
                }
                for (self.commit_log.items) |*entry| {
                    if (entry.commit_ts > snapshot_ts and read_set.intersects(&entry.write_set)) {
                        return storage_mod.StorageError.Conflict;
                    }
                }
            }
            return .{ .commit_ts = self.latest_ts, .write_set = .{} };
        }

        // Fast path 2: in-memory store needs no fsync batching.
        if (self.wal_path == null) {
            self.rwlock.lockUncancelable(self.io);
            defer self.rwlock.unlock(self.io);
            return self.commitSingleLocked(allocator, manifest, snapshot_ts, read_set, writes, false);
        }

        // Durable WAL path: Leader-Follower Group Commit.
        // Stack-allocated waiter avoids per-commit heap allocation; callers arriving while a leader
        // is inside `fsync()` batch together and commit in a single `write()` + `fsync()`.
        var waiter = CommitWaiter{
            .allocator = allocator,
            .manifest = manifest,
            .snapshot_ts = snapshot_ts,
            .read_set = read_set,
            .writes = writes,
        };

        self.queue_mutex.lockUncancelable(self.io);
        if (self.queue_tail) |tail| {
            tail.next = &waiter;
            self.queue_tail = &waiter;
        } else {
            self.queue_head = &waiter;
            self.queue_tail = &waiter;
        }

        while (self.leader_active and !waiter.done) {
            self.queue_cond.waitUncancelable(self.io, &self.queue_mutex);
        }

        if (waiter.done) {
            self.queue_mutex.unlock(self.io);
            return waiter.result;
        }

        // We are now the Group Leader: drain all currently queued commits and flush in one batch.
        self.leader_active = true;
        const batch_head = self.queue_head;
        self.queue_head = null;
        self.queue_tail = null;
        self.queue_mutex.unlock(self.io);

        var wal_file_to_sync: ?std.Io.File = null;
        var should_compact = false;
        var batch_commits: usize = 0;

        {
            self.rwlock.lockUncancelable(self.io);
            defer self.rwlock.unlock(self.io);

            self.wal_batch.writer.end = 0;
            var cur = batch_head;
            while (cur) |w| : (cur = w.next) {
                w.result = self.commitSingleLocked(w.allocator, w.manifest, w.snapshot_ts, w.read_set, w.writes, true);
                if (w.result) |_| {
                    batch_commits += 1;
                } else |_| {}
            }

            const batch_bytes = self.wal_batch.written();
            if (batch_commits > 0 and batch_bytes.len > 0) {
                self.wal_io_mutex.lockUncancelable(self.io);
                const write_res = self.writeWalBatchLocked(self.wal_path.?, batch_bytes);
                if (write_res) |f| {
                    wal_file_to_sync = f;
                    self.wal_records_since_compact += batch_commits;
                    if (self.compact_threshold > 0 and self.wal_records_since_compact >= self.compact_threshold) {
                        should_compact = true;
                    }
                    // Keep `wal_io_mutex` held across `file.sync()` after `rwlock` is released!
                } else |err| {
                    self.wal_io_mutex.unlock(self.io);
                    var ec = batch_head;
                    while (ec) |w| : (ec = w.next) {
                        if (w.result) |*ok_res| {
                            ok_res.deinit(w.allocator);
                            w.result = err;
                        } else |_| {}
                    }
                }
            }
        }

        // Perform the durable SSD `fsync()` OUTSIDE `rwlock` so concurrent readers and arriving
        // mutations run at full speed and batch together into the next group commit!
        if (wal_file_to_sync) |file| {
            defer self.wal_io_mutex.unlock(self.io);
            if (file.sync(self.io)) |_| {
                _ = self.wal_fsync_count.fetchAdd(1, .monotonic);
                _ = self.wal_group_batches.fetchAdd(1, .monotonic);
            } else |_| {
                // Propagate fsync failure so callers never believe an unsynced commit is durable.
                var ec = batch_head;
                while (ec) |w| : (ec = w.next) {
                    if (w.result) |*ok_res| {
                        ok_res.deinit(w.allocator);
                        w.result = storage_mod.StorageError.StorageFailure;
                    } else |_| {}
                }
            }
        }

        if (should_compact) {
            self.rwlock.lockUncancelable(self.io);
            defer self.rwlock.unlock(self.io);
            self.wal_io_mutex.lockUncancelable(self.io);
            defer self.wal_io_mutex.unlock(self.io);
            self.compactLocked(self.wal_path.?) catch {};
        }

        self.queue_mutex.lockUncancelable(self.io);
        var done_cur = batch_head;
        while (done_cur) |w| {
            const nxt = w.next;
            w.done = true;
            done_cur = nxt;
        }
        self.leader_active = false;
        self.queue_cond.broadcast(self.io);
        self.queue_mutex.unlock(self.io);

        return waiter.result;
    }

    fn commitSingleLocked(
        self: *WalStore,
        allocator: Allocator,
        manifest: *const manifest_mod.AppManifest,
        snapshot_ts: i64,
        read_set: *const readset_mod.ReadSet,
        writes: []const WriteOp,
        encode_wal: bool,
    ) !CommitResult {
        // 1. OCC conflict check against every commit strictly after `snapshot_ts`.
        if (self.latest_ts > snapshot_ts) {
            if (snapshot_ts < self.min_retained_commit_ts) {
                return storage_mod.StorageError.Conflict;
            }
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

        // 2. Validate target doc existence only if any Replace/Patch ops exist in `writes`.
        var needs_existence_check = false;
        for (writes) |op| {
            if (op == .replace or op == .patch) {
                needs_existence_check = true;
                break;
            }
        }
        if (needs_existence_check) {
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
                        var kbuf: [256]u8 = undefined;
                        const k = try formatKey3Buf(&kbuf, self.allocator, r.namespace, r.table, r.doc_id);
                        defer if (k.owned) self.allocator.free(k.slice);
                        const exists = v_exists.get(k.slice) orelse self.docs.contains(k.slice);
                        if (!exists) return storage_mod.StorageError.NotFound;
                    },
                    .patch => |p| {
                        var kbuf: [256]u8 = undefined;
                        const k = try formatKey3Buf(&kbuf, self.allocator, p.namespace, p.table, p.doc_id);
                        defer if (k.owned) self.allocator.free(k.slice);
                        const exists = v_exists.get(k.slice) orelse self.docs.contains(k.slice);
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

        // 4. Append CRC32-framed WAL record directly into reusable batch buffer.
        if (encode_wal) {
            try self.encodeWalRecordToBatchLocked(next_ts, writes);
        }

        self.latest_ts = next_ts;
        self.latest_ts_atomic.store(next_ts, .release);

        // Store a copy in commit_log and return a copy to caller.
        const caller_ws = try write_set.clone(allocator);
        try self.commit_log.append(self.allocator, .{
            .commit_ts = next_ts,
            .write_set = write_set,
        });

        // Bound in-memory commit_log size while tracking `min_retained_commit_ts` so older
        // snapshots conservatively abort with `Conflict` instead of silently bypassing OCC.
        if (self.commit_log.items.len > 4096) {
            const drop = self.commit_log.items.len - 2048;
            for (self.commit_log.items[0..drop]) |*old| old.deinit(self.allocator);
            std.mem.copyForwards(CommitEntry, self.commit_log.items[0..2048], self.commit_log.items[drop..]);
            self.commit_log.shrinkRetainingCapacity(2048);
            if (self.commit_log.items.len > 0) {
                self.min_retained_commit_ts = self.commit_log.items[0].commit_ts - 1;
            }
        }

        return .{
            .commit_ts = next_ts,
            .write_set = caller_ws,
        };
    }

    /// Atomically compact the on-disk WAL into a minimal CRC32-protected snapshot of live documents.
    pub fn compact(self: *WalStore) !void {
        self.rwlock.lockUncancelable(self.io);
        defer self.rwlock.unlock(self.io);
        self.wal_io_mutex.lockUncancelable(self.io);
        defer self.wal_io_mutex.unlock(self.io);
        const path = self.wal_path orelse return;
        try self.compactLocked(path);
    }

    fn formatCompactSnapshotLocked(self: *const WalStore, allocator: Allocator) ![]u8 {
        if (self.latest_ts == 0 and self.docs.count() == 0) {
            return try allocator.alloc(u8, 0);
        }

        var payload: std.Io.Writer.Allocating = .init(allocator);
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
        var line: std.Io.Writer.Allocating = .init(allocator);
        errdefer line.deinit();
        try line.writer.print("{x:0>8}|{s}\n", .{ crc, payload.written() });
        return try line.toOwnedSlice();
    }

    fn compactLocked(self: *WalStore, path: []const u8) !void {
        const snapshot = try self.formatCompactSnapshotLocked(self.allocator);
        defer self.allocator.free(snapshot);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.compact.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            const file = std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .truncate = true }) catch
                return storage_mod.StorageError.StorageFailure;
            defer file.close(self.io);
            file.writePositionalAll(self.io, snapshot, 0) catch
                return storage_mod.StorageError.StorageFailure;
            file.sync(self.io) catch
                return storage_mod.StorageError.StorageFailure;
        }

        if (self.wal_file) |f| {
            f.close(self.io);
            self.wal_file = null;
            self.wal_file_size = 0;
        }
        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, self.io) catch
            return storage_mod.StorageError.StorageFailure;
        self.wal_records_since_compact = 0;
    }

    pub fn commitsSince(self: *WalStore, allocator: Allocator, since_ts: i64) ![]CommitEntry {
        self.rwlock.lockSharedUncancelable(self.io);
        defer self.rwlock.unlockShared(self.io);

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
            var kbuf: [256]u8 = undefined;
            const bk = try formatKey3Buf(&kbuf, self.allocator, ns, table, e.index_name);
            defer if (bk.owned) self.allocator.free(bk.slice);

            const bucket = blk: {
                if (self.index_buckets.getPtr(bk.slice)) |ptr| break :blk ptr;
                const owned_bk = try self.allocator.dupe(u8, bk.slice);
                errdefer self.allocator.free(owned_bk);
                try self.index_buckets.put(self.allocator, owned_bk, .empty);
                break :blk self.index_buckets.getPtr(owned_bk).?;
            };

            const pos = lowerBoundKeyDoc(bucket.items, e.encoded_key, doc.id);
            const row = SortedIndexRow{
                .encoded_key = try self.allocator.dupe(u8, e.encoded_key),
                .doc_id = try self.allocator.dupe(u8, doc.id),
            };
            try bucket.insert(self.allocator, pos, row);
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
        var kbuf: [256]u8 = undefined;
        for (old_entries) |e| {
            try write_set.recordIndexKey(self.allocator, ns, table, e.index_name, e.encoded_key);
            const bk = try formatKey3Buf(&kbuf, self.allocator, ns, table, e.index_name);
            defer if (bk.owned) self.allocator.free(bk.slice);
            if (self.index_buckets.getPtr(bk.slice)) |bucket| {
                const pos = lowerBoundKeyDoc(bucket.items, e.encoded_key, doc.id);
                if (pos < bucket.items.len and
                    std.mem.eql(u8, bucket.items[pos].encoded_key, e.encoded_key) and
                    std.mem.eql(u8, bucket.items[pos].doc_id, doc.id))
                {
                    bucket.items[pos].deinit(self.allocator);
                    _ = bucket.orderedRemove(pos);
                }
            }
        }
    }

    fn rebuildIndexesLocked(self: *WalStore, manifest: *const manifest_mod.AppManifest) !void {
        var bit = self.index_buckets.iterator();
        while (bit.next()) |b| {
            self.allocator.free(b.key_ptr.*);
            for (b.value_ptr.items) |*row| row.deinit(self.allocator);
            b.value_ptr.deinit(self.allocator);
        }
        self.index_buckets.clearRetainingCapacity();

        var it = self.docs.iterator();
        while (it.next()) |entry| {
            var parts = std.mem.splitScalar(u8, entry.key_ptr.*, 0x1F);
            const ns = parts.next() orelse continue;
            const tbl = parts.next() orelse continue;
            try self.insertIndexRowsLocked(manifest, ns, tbl, entry.value_ptr, null);
        }
    }

    fn encodeWalRecordToBatchLocked(self: *WalStore, commit_ts: i64, writes: []const WriteOp) !void {
        const w = &self.wal_batch.writer;
        const header_start = w.end;
        // Reserve 9 bytes for `<8-hex-crc>|` and patch the CRC32 in-place after writing payload.
        try w.writeAll("00000000|");
        const payload_start = w.end;

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

        const payload_end = w.end;
        const crc = std.hash.Crc32.hash(w.buffer[payload_start..payload_end]);
        const hex = "0123456789abcdef";
        inline for (0..8) |i| {
            const shift: u5 = @intCast(28 - i * 4);
            w.buffer[header_start + i] = hex[@as(usize, @intCast((crc >> shift) & 0xF))];
        }
        try w.writeByte('\n');
    }

    fn writeWalBatchLocked(self: *WalStore, path: []const u8, batch_bytes: []const u8) !std.Io.File {
        if (self.wal_file == null) {
            const f = std.Io.Dir.cwd().createFile(self.io, path, .{
                .truncate = false,
                .read = true,
            }) catch return storage_mod.StorageError.StorageFailure;
            const st = f.stat(self.io) catch {
                f.close(self.io);
                return storage_mod.StorageError.StorageFailure;
            };
            self.wal_file = f;
            self.wal_file_size = st.size;
        }
        const file = self.wal_file.?;
        file.writePositionalAll(self.io, batch_bytes, self.wal_file_size) catch
            return storage_mod.StorageError.StorageFailure;
        self.wal_file_size += batch_bytes.len;
        return file;
    }

    /// Stream-replay the WAL file line-by-line with no total file size limit.
    /// Only `error.FileNotFound` is treated as a fresh empty store; any other I/O error
    /// fails startup explicitly rather than silently discarding durable data.
    fn replayWalLocked(self: *WalStore, path: []const u8, manifest: *const manifest_mod.AppManifest) !void {
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return storage_mod.StorageError.StorageFailure,
        };
        defer file.close(self.io);

        var chunk: [64 * 1024]u8 = undefined;
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);
        var offset: u64 = 0;

        while (true) {
            const n = file.readPositionalAll(self.io, &chunk, offset) catch
                return storage_mod.StorageError.StorageFailure;
            if (n == 0) break;
            offset += n;

            var start: usize = 0;
            while (start < n) {
                if (std.mem.indexOfScalarPos(u8, chunk[0..n], start, '\n')) |nl| {
                    try line_buf.appendSlice(self.allocator, chunk[start..nl]);
                    const raw_line = std.mem.trim(u8, line_buf.items, " \t\r");
                    if (raw_line.len > 0) {
                        const ok = try self.replayWalLineLocked(raw_line, manifest);
                        if (!ok) return;
                    }
                    line_buf.clearRetainingCapacity();
                    start = nl + 1;
                } else {
                    try line_buf.appendSlice(self.allocator, chunk[start..n]);
                    // Cap a single WAL line to 64 MiB to guard against unbounded malformed records.
                    if (line_buf.items.len > 64 * 1024 * 1024) {
                        return storage_mod.StorageError.StorageFailure;
                    }
                    break;
                }
            }
        }
    }

    const StrictReplayInfo = struct {
        bytes: usize,
        crc32: u32,
    };

    /// Strictly validate and replay every record in a WAL file.
    /// Rejects missing CRC32 frames, checksum mismatches, truncated trailing lines,
    /// malformed JSON, or invalid operations with `error.CorruptBackup`.
    fn replayWalStrictLocked(self: *WalStore, path: []const u8, manifest: *const manifest_mod.AppManifest) !StrictReplayInfo {
        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only });
        defer file.close(self.io);

        var chunk: [64 * 1024]u8 = undefined;
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);
        var offset: u64 = 0;
        var hasher = std.hash.Crc32.init();

        while (true) {
            const n = file.readPositionalAll(self.io, &chunk, offset) catch
                return storage_mod.StorageError.StorageFailure;
            if (n == 0) break;
            offset += n;
            hasher.update(chunk[0..n]);

            var start: usize = 0;
            while (start < n) {
                if (std.mem.indexOfScalarPos(u8, chunk[0..n], start, '\n')) |nl| {
                    try line_buf.appendSlice(self.allocator, chunk[start..nl]);
                    const raw_line = std.mem.trim(u8, line_buf.items, " \t\r");
                    if (raw_line.len > 0) {
                        if (raw_line.len < 9 or raw_line[8] != '|') {
                            return error.CorruptBackup;
                        }
                        const ok = try self.replayWalLineLocked(raw_line, manifest);
                        if (!ok) return error.CorruptBackup;
                    }
                    line_buf.clearRetainingCapacity();
                    start = nl + 1;
                } else {
                    try line_buf.appendSlice(self.allocator, chunk[start..n]);
                    if (line_buf.items.len > 64 * 1024 * 1024) {
                        return error.CorruptBackup;
                    }
                    break;
                }
            }
        }

        // Any unterminated non-whitespace trailing data indicates a truncated backup.
        if (std.mem.trim(u8, line_buf.items, " \t\r").len > 0) {
            return error.CorruptBackup;
        }

        return .{
            .bytes = @intCast(offset),
            .crc32 = hasher.final(),
        };
    }

    /// Replay a WAL byte buffer into this store (also used directly by crash-recovery & fuzz tests).
    /// - Only newline-terminated frames are considered committed (trailing partial frames are torn writes).
    /// - CRC32-framed lines (`<8-hex-crc>|<json>`) reject any bit-flip corruption atomically.
    /// - Every op in a line is fully validated before any state is mutated.
    pub fn replayWalBytes(self: *WalStore, bytes: []const u8, manifest: *const manifest_mod.AppManifest) !void {
        self.rwlock.lockUncancelable(self.io);
        defer self.rwlock.unlock(self.io);
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
            if (!(try self.replayWalLineLocked(raw_line, manifest))) break;
        }
    }

    fn replayWalLineLocked(self: *WalStore, raw_line: []const u8, manifest: *const manifest_mod.AppManifest) !bool {
        // Verify CRC32 framing if present (`<8-hex-crc>|<json>`).
        var json_slice = raw_line;
        if (raw_line.len >= 9 and raw_line[8] == '|') {
            const expected_crc = std.fmt.parseInt(u32, raw_line[0..8], 16) catch return false;
            const payload = raw_line[9..];
            if (std.hash.Crc32.hash(payload) != expected_crc) {
                // Corrupted WAL record => stop replay at the last valid committed prefix.
                return false;
            }
            json_slice = payload;
        } else if (raw_line[0] != '{') {
            return false;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json_slice, .{}) catch return false;
        if (parsed != .object) return false;
        const ts_v = parsed.object.get("ts") orelse return false;
        if (ts_v != .integer or ts_v.integer <= 0) return false;
        const ops_v = parsed.object.get("ops") orelse return false;
        if (ops_v != .array) return false;

        // Validate and decode all ops in this transaction before applying any of them.
        var decoded_ops: std.ArrayList(WriteOp) = .empty;
        for (ops_v.array.items) |op_v| {
            if (op_v != .object) return false;
            const kind = jsonStrField(op_v.object, "op") orelse return false;
            const ns = jsonStrField(op_v.object, "ns") orelse return false;
            const tbl = jsonStrField(op_v.object, "table") orelse return false;
            const id = jsonStrField(op_v.object, "id") orelse return false;

            if (std.mem.eql(u8, kind, "insert")) {
                const ct = jsonIntField(op_v.object, "ct") orelse return false;
                const body = jsonStrField(op_v.object, "body") orelse return false;
                try decoded_ops.append(a, .{ .insert = .{
                    .namespace = @constCast(ns),
                    .table = @constCast(tbl),
                    .doc_id = @constCast(id),
                    .creation_time_ms = ct,
                    .body_json = @constCast(body),
                } });
            } else if (std.mem.eql(u8, kind, "replace")) {
                const body = jsonStrField(op_v.object, "body") orelse return false;
                try decoded_ops.append(a, .{ .replace = .{
                    .namespace = @constCast(ns),
                    .table = @constCast(tbl),
                    .doc_id = @constCast(id),
                    .body_json = @constCast(body),
                } });
            } else if (std.mem.eql(u8, kind, "patch")) {
                const patch = jsonStrField(op_v.object, "patch") orelse return false;
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
                return false;
            }
        }

        // Validate doc existence for replace/patch before mutating state.
        var v_exists: std.StringHashMapUnmanaged(bool) = .empty;
        for (decoded_ops.items) |op| {
            switch (op) {
                .insert => |ins| {
                    const k = try makeDocKey(a, ins.namespace, ins.table, ins.doc_id);
                    try v_exists.put(a, k, true);
                },
                .replace => |r| {
                    const k = try makeDocKey(a, r.namespace, r.table, r.doc_id);
                    if (!(v_exists.get(k) orelse self.docs.contains(k))) return false;
                },
                .patch => |p| {
                    const k = try makeDocKey(a, p.namespace, p.table, p.doc_id);
                    if (!(v_exists.get(k) orelse self.docs.contains(k))) return false;
                },
                .delete => |d| {
                    const k = try makeDocKey(a, d.namespace, d.table, d.doc_id);
                    try v_exists.put(a, k, false);
                },
            }
        }

        var ws: readset_mod.WriteSet = .{};
        defer ws.deinit(self.allocator);
        for (decoded_ops.items) |op| {
            self.applyOpLocked(manifest, op, &ws) catch return false;
        }
        if (ts_v.integer > self.latest_ts) {
            self.latest_ts = ts_v.integer;
            self.latest_ts_atomic.store(ts_v.integer, .release);
        }
        return true;
    }

    /// Assert that `self.indexes` matches `computeIndexEntries` across every live document (no orphan or missing rows).
    pub fn verifyIndexIntegrity(self: *WalStore, allocator: Allocator, manifest: *const manifest_mod.AppManifest) !void {
        self.rwlock.lockSharedUncancelable(self.io);
        defer self.rwlock.unlockShared(self.io);

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

        var bit = self.index_buckets.iterator();
        while (bit.next()) |b| {
            var bparts = std.mem.splitScalar(u8, b.key_ptr.*, 0x1F);
            const b_ns = bparts.next() orelse continue;
            const b_tbl = bparts.next() orelse continue;
            const b_idx = bparts.next() orelse continue;
            for (b.value_ptr.items) |row| {
                const sig = try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{x}", .{
                    b_ns, b_tbl, b_idx, row.doc_id, row.encoded_key,
                });
                defer allocator.free(sig);
                const cnt = expected.getPtr(sig) orelse return error.IndexIntegrityViolation;
                if (cnt.* == 0) return error.IndexIntegrityViolation;
                cnt.* -= 1;
            }
        }

        var eit = expected.valueIterator();
        while (eit.next()) |rem| {
            if (rem.* != 0) return error.IndexIntegrityViolation;
        }
    }
};

const empty_backup_manifest_json =
    \\{"app_name":"wal-backup","tables":[],"components":[],"functions":[]}
;

fn makeTempPath(io: std.Io, allocator: Allocator, dst_path: []const u8) ![]u8 {
    var rand_bytes: [8]u8 = undefined;
    io.random(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    return try std.fmt.allocPrint(allocator, "{s}.{s}.tmp", .{ dst_path, hex });
}

fn writeFileAtomic(io: std.Io, allocator: Allocator, dst_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(dst_path)) |dir| {
        if (dir.len > 0) {
            try std.Io.Dir.cwd().createDirPath(io, dir);
        }
    }

    const tmp_path = try makeTempPath(io, allocator, dst_path);
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer file.close(io);
        if (data.len > 0) {
            try file.writePositionalAll(io, data, 0);
        }
        try file.sync(io);
    }

    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), dst_path, io);
}

/// Create a clean, compacted, fsynced, CRC32-valid WAL snapshot backup of `src_wal_path`,
/// written atomically to `dst_path` (temp file + fsync + rename).
/// Does not modify `src_wal_path`. Returns total bytes written to `dst_path`.
pub fn backupWalFile(io: std.Io, allocator: Allocator, src_wal_path: []const u8, dst_path: []const u8) !usize {
    const src_size: u64 = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, src_wal_path, .{ .mode = .read_only });
        defer f.close(io);
        const st = try f.stat(io);
        break :blk st.size;
    };

    var manifest = try manifest_mod.AppManifest.parseJson(allocator, empty_backup_manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();

    try store.replayWalLocked(src_wal_path, &manifest);
    if (src_size > 0 and store.latest_ts == 0) {
        return error.CorruptBackup;
    }

    const snapshot = try store.formatCompactSnapshotLocked(allocator);
    defer allocator.free(snapshot);

    try writeFileAtomic(io, allocator, dst_path, snapshot);
    return snapshot.len;
}

/// Strictly validate `backup_path` by replaying every record and CRC32 checksum into a temporary
/// `WalStore` (rejecting corrupted or truncated backups with `error.CorruptBackup` before
/// touching `dst_wal_path`), then atomically copy + fsync + rename it to `dst_wal_path`.
/// Returns total bytes restored.
pub fn restoreWalFile(io: std.Io, allocator: Allocator, backup_path: []const u8, dst_wal_path: []const u8) !usize {
    var manifest = try manifest_mod.AppManifest.parseJson(allocator, empty_backup_manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();

    const verified = try store.replayWalStrictLocked(backup_path, &manifest);

    if (std.fs.path.dirname(dst_wal_path)) |dir| {
        if (dir.len > 0) {
            try std.Io.Dir.cwd().createDirPath(io, dir);
        }
    }

    const tmp_path = try makeTempPath(io, allocator, dst_wal_path);
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    {
        const src_file = try std.Io.Dir.cwd().openFile(io, backup_path, .{ .mode = .read_only });
        defer src_file.close(io);

        const dst_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .truncate = true });
        defer dst_file.close(io);

        var chunk: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        var copy_hasher = std.hash.Crc32.init();
        while (true) {
            const n = try src_file.readPositionalAll(io, &chunk, offset);
            if (n == 0) break;
            try dst_file.writePositionalAll(io, chunk[0..n], offset);
            copy_hasher.update(chunk[0..n]);
            offset += n;
        }
        if (offset != verified.bytes or copy_hasher.final() != verified.crc32) {
            return error.CorruptBackup;
        }
        try dst_file.sync(io);
    }

    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), dst_wal_path, io);
    return verified.bytes;
}

fn jsonStrField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn jsonIntField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = obj.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

const KeySlice = struct {
    slice: []const u8,
    owned: bool,
};

fn formatKey3Buf(buf: []u8, allocator: Allocator, a: []const u8, b: []const u8, c: []const u8) !KeySlice {
    const needed = a.len + 1 + b.len + 1 + c.len;
    if (needed <= buf.len) {
        @memcpy(buf[0..a.len], a);
        buf[a.len] = 0x1F;
        @memcpy(buf[a.len + 1 .. a.len + 1 + b.len], b);
        buf[a.len + 1 + b.len] = 0x1F;
        @memcpy(buf[a.len + 2 + b.len .. needed], c);
        return .{ .slice = buf[0..needed], .owned = false };
    }
    return .{ .slice = try makeDocKey(allocator, a, b, c), .owned = true };
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

test "wal store leader-follower group commit batches concurrent fsyncs and preserves durability" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const wal_path = ".zig-cache/test-group-commit.wal";
    std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, wal_path) catch {};

    const manifest_json =
        \\{"app_name":"gc","tables":[{"name":"events","document_schema":{"kind":"any"},"indexes":[{"name":"by_worker","fields":["worker"]}]}],"components":[],"functions":[]}
    ;
    var manifest = try manifest_mod.AppManifest.parseJson(allocator, manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openFile(allocator, io, wal_path);
    var store_open = true;
    errdefer if (store_open) store.deinit();
    store.compact_threshold = 0;
    try store.initSchema(&manifest);

    const NUM_THREADS = 12;
    const PER_THREAD = 15;
    const WorkerCtx = struct {
        store: *WalStore,
        manifest: *const manifest_mod.AppManifest,
        worker_id: usize,
        ok_count: std.atomic.Value(usize) = .init(0),

        fn run(ctx: *@This()) void {
            const alloc = std.heap.smp_allocator;
            var empty_rs: readset_mod.ReadSet = .{};
            for (0..PER_THREAD) |j| {
                var id_buf: [32]u8 = undefined;
                const doc_id = std.fmt.bufPrint(&id_buf, "w{d}_i{d}", .{ ctx.worker_id, j }) catch return;
                var body_buf: [64]u8 = undefined;
                const body = std.fmt.bufPrint(&body_buf, "{{\"worker\":{d},\"seq\":{d}}}", .{ ctx.worker_id, j }) catch return;
                const ops = [_]WriteOp{.{ .insert = .{
                    .namespace = @constCast(""),
                    .table = @constCast("events"),
                    .doc_id = @constCast(doc_id),
                    .creation_time_ms = @intCast(1000 + ctx.worker_id * 100 + j),
                    .body_json = @constCast(body),
                } }};
                const snap = ctx.store.latestCommitTs() catch 0;
                var res = ctx.store.commitTx(alloc, ctx.manifest, snap, &empty_rs, &ops) catch return;
                res.deinit(alloc);
                _ = ctx.ok_count.fetchAdd(1, .monotonic);
            }
        }
    };

    var ctxs: [NUM_THREADS]WorkerCtx = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |t| {
        ctxs[t] = .{ .store = store, .manifest = &manifest, .worker_id = t };
        threads[t] = try std.Thread.spawn(.{}, WorkerCtx.run, .{&ctxs[t]});
    }
    var total_ok: usize = 0;
    for (0..NUM_THREADS) |t| {
        threads[t].join();
        total_ok += ctxs[t].ok_count.load(.acquire);
    }

    const total_expected = NUM_THREADS * PER_THREAD;
    try std.testing.expectEqual(total_expected, total_ok);
    try std.testing.expectEqual(@as(i64, @intCast(total_expected)), try store.latestCommitTs());
    // Group commit must coalesce concurrent writers into strictly fewer fsyncs than total commits.
    const fsyncs = store.wal_fsync_count.load(.acquire);
    try std.testing.expect(fsyncs > 0 and fsyncs < total_expected);
    store.deinit();
    store_open = false;

    // Crash/restart recovery: replay WAL from disk and assert every single committed doc & index survives!
    var reopened = try WalStore.openFile(allocator, io, wal_path);
    defer reopened.deinit();
    try reopened.initSchema(&manifest);
    try std.testing.expectEqual(@as(i64, @intCast(total_expected)), try reopened.latestCommitTs());
    try reopened.verifyIndexIntegrity(allocator, &manifest);

    // Also test zero-clone scanIndexToWireJson matches exact doc count.
    var wire: std.Io.Writer.Allocating = .init(allocator);
    defer wire.deinit();
    try reopened.scanIndexToWireJson(&.{
        .namespace = "",
        .table = "events",
        .index_name = "by_creation_time",
        .start = .unbounded,
        .end = .unbounded,
        .order = .asc,
        .limit = null,
    }, &wire.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, wire.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(total_expected, parsed.value.array.items.len);
}

test "backupWalFile and restoreWalFile round-trip compacted snapshot and preserve state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const src_path = ".zig-cache/test-backup-src.wal";
    const bak_path = ".zig-cache/test-backup-out.bak";
    const dst_path = ".zig-cache/test-backup-restored.wal";
    std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, bak_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, dst_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, src_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, bak_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, dst_path) catch {};

    const manifest_json =
        \\{"app_name":"bak","tables":[{"name":"notes","document_schema":{"kind":"any"},"indexes":[{"name":"by_tag","fields":["tag"]}]}],"components":[],"functions":[]}
    ;
    var manifest = try manifest_mod.AppManifest.parseJson(allocator, manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openFile(allocator, io, src_path);
    store.compact_threshold = 0;
    try store.initSchema(&manifest);

    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);

    {
        const w_ins = [_]WriteOp{
            .{ .insert = .{ .namespace = @constCast(""), .table = @constCast("notes"), .doc_id = @constCast("n1"), .creation_time_ms = 1000, .body_json = @constCast("{\"tag\":\"v0\",\"text\":\"init\"}") } },
            .{ .insert = .{ .namespace = @constCast(""), .table = @constCast("notes"), .doc_id = @constCast("n2"), .creation_time_ms = 2000, .body_json = @constCast("{\"tag\":\"drop\",\"text\":\"ephemeral\"}") } },
        };
        var c = try store.commitTx(allocator, &manifest, 0, &empty_rs, &w_ins);
        c.deinit(allocator);
    }
    for (1..25) |i| {
        const patch_json = try std.fmt.allocPrint(allocator, "{{\"tag\":\"v{d}\",\"text\":\"rev {d}\"}}", .{ i, i });
        defer allocator.free(patch_json);
        const w_pat = [_]WriteOp{.{ .patch = .{ .namespace = @constCast(""), .table = @constCast("notes"), .doc_id = @constCast("n1"), .patch_json = patch_json } }};
        var c = try store.commitTx(allocator, &manifest, try store.latestCommitTs(), &empty_rs, &w_pat);
        c.deinit(allocator);
    }
    {
        const w_del = [_]WriteOp{.{ .delete = .{ .namespace = @constCast(""), .table = @constCast("notes"), .doc_id = @constCast("n2") } }};
        var c = try store.commitTx(allocator, &manifest, try store.latestCommitTs(), &empty_rs, &w_del);
        c.deinit(allocator);
    }

    const expected_ts = try store.latestCommitTs();
    store.deinit();

    const src_bytes = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .limited(10 * 1024 * 1024));
    const src_len = src_bytes.len;
    allocator.free(src_bytes);

    // Backup produces a smaller, compacted CRC32-framed snapshot.
    const backed_up_bytes = try backupWalFile(io, allocator, src_path, bak_path);
    try std.testing.expect(backed_up_bytes > 0);
    try std.testing.expect(backed_up_bytes < src_len);

    // Restore validates and atomically writes to dst_path.
    const restored_bytes = try restoreWalFile(io, allocator, bak_path, dst_path);
    try std.testing.expectEqual(backed_up_bytes, restored_bytes);

    // Reopen restored WAL and verify exact state + commit_ts + secondary index integrity.
    var reopened = try WalStore.openFile(allocator, io, dst_path);
    defer reopened.deinit();
    try reopened.initSchema(&manifest);
    try std.testing.expectEqual(expected_ts, try reopened.latestCommitTs());

    const n1 = (try reopened.getDoc(allocator, "", "notes", "n1")).?;
    defer n1.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, n1.body_json, "\"v24\"") != null);
    try std.testing.expect((try reopened.getDoc(allocator, "", "notes", "n2")) == null);
    try reopened.verifyIndexIntegrity(allocator, &manifest);
}

test "restoreWalFile rejects corrupted and truncated backups without touching destination" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const src_path = ".zig-cache/test-corrupt-src.wal";
    const bak_path = ".zig-cache/test-corrupt-good.bak";
    const bad_flip_path = ".zig-cache/test-corrupt-flip.bak";
    const bad_trunc_path = ".zig-cache/test-corrupt-trunc.bak";
    const bad_garbage_path = ".zig-cache/test-corrupt-garbage.bak";
    const dst_path = ".zig-cache/test-corrupt-dst.wal";

    const paths = [_][]const u8{ src_path, bak_path, bad_flip_path, bad_trunc_path, bad_garbage_path, dst_path };
    for (paths) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
    defer for (paths) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};

    const manifest_json =
        \\{"app_name":"bak-err","tables":[{"name":"notes","document_schema":{"kind":"any"},"indexes":[]}],"components":[],"functions":[]}
    ;
    var manifest = try manifest_mod.AppManifest.parseJson(allocator, manifest_json);
    defer manifest.deinit();

    var store = try WalStore.openFile(allocator, io, src_path);
    try store.initSchema(&manifest);
    var empty_rs: readset_mod.ReadSet = .{};
    defer empty_rs.deinit(allocator);
    const w = [_]WriteOp{.{ .insert = .{
        .namespace = @constCast(""),
        .table = @constCast("notes"),
        .doc_id = @constCast("k1"),
        .creation_time_ms = 500,
        .body_json = @constCast("{\"msg\":\"important\"}"),
    } }};
    var c = try store.commitTx(allocator, &manifest, 0, &empty_rs, &w);
    c.deinit(allocator);
    store.deinit();

    _ = try backupWalFile(io, allocator, src_path, bak_path);
    const good_bytes = try std.Io.Dir.cwd().readFileAlloc(io, bak_path, allocator, .limited(1024 * 1024));
    defer allocator.free(good_bytes);

    // Seed destination with sentinel data to verify failed restores NEVER overwrite it.
    const sentinel = "SENTINEL_UNTOUCHED_DATA";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = sentinel });

    // 1. Bit-flipped payload (CRC mismatch) -> rejected.
    const flipped = try allocator.dupe(u8, good_bytes);
    defer allocator.free(flipped);
    flipped[flipped.len / 2] ^= 0x01;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_flip_path, .data = flipped });
    try std.testing.expectError(error.CorruptBackup, restoreWalFile(io, allocator, bad_flip_path, dst_path));

    // 2. Truncated backup (missing trailing newline & cut-off JSON) -> rejected.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_trunc_path, .data = good_bytes[0 .. good_bytes.len / 2] });
    try std.testing.expectError(error.CorruptBackup, restoreWalFile(io, allocator, bad_trunc_path, dst_path));

    // 3. Garbage non-WAL content -> rejected.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = bad_garbage_path, .data = "not a wal file\n" });
    try std.testing.expectError(error.CorruptBackup, restoreWalFile(io, allocator, bad_garbage_path, dst_path));

    // 4. Missing backup file -> FileNotFound.
    try std.testing.expectError(error.FileNotFound, restoreWalFile(io, allocator, ".zig-cache/does-not-exist.bak", dst_path));

    // Verify destination file is 100% intact.
    const after_dst = try std.Io.Dir.cwd().readFileAlloc(io, dst_path, allocator, .limited(1024));
    defer allocator.free(after_dst);
    try std.testing.expectEqualStrings(sentinel, after_dst);
}
