const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest_mod = @import("../core/manifest.zig");
const readset_mod = @import("../core/readset.zig");
const storage_mod = @import("../core/storage.zig");

const Document = storage_mod.Document;
const IndexQuery = storage_mod.IndexQuery;
const Storage = storage_mod.Storage;
const WriteOp = storage_mod.WriteOp;

/// Transaction context with exact `ReadSet` tracking and read-your-own-writes overlay.
pub const TxContext = struct {
    allocator: Allocator,
    io: std.Io,
    storage: Storage,
    manifest: *const manifest_mod.AppManifest,
    snapshot_ts: i64,
    read_only: bool,
    read_set: readset_mod.ReadSet = .{},
    writes: std.ArrayList(WriteOp) = .empty,
    /// Overlay keyed by `"<ns>\x1f<table>\x1f<id>"` -> `?Document` (`null` means deleted in this tx).
    pending_docs: std.StringHashMapUnmanaged(?Document) = .empty,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        storage: Storage,
        manifest: *const manifest_mod.AppManifest,
        snapshot_ts: i64,
        read_only: bool,
    ) TxContext {
        return .{
            .allocator = allocator,
            .io = io,
            .storage = storage,
            .manifest = manifest,
            .snapshot_ts = snapshot_ts,
            .read_only = read_only,
        };
    }

    pub fn deinit(self: *TxContext) void {
        self.read_set.deinit(self.allocator);
        for (self.writes.items) |*op| op.deinit(self.allocator);
        self.writes.deinit(self.allocator);
        var it = self.pending_docs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |*doc| doc.deinit(self.allocator);
        }
        self.pending_docs.deinit(self.allocator);
    }

    pub fn get(self: *TxContext, allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) !?Document {
        try self.read_set.recordDocRead(self.allocator, ns, table, doc_id);
        const key = try makeKey(self.allocator, ns, table, doc_id);
        defer self.allocator.free(key);

        if (self.pending_docs.get(key)) |maybe_doc| {
            return if (maybe_doc) |d| try d.clone(allocator) else null;
        }
        return try self.storage.getDoc(allocator, ns, table, doc_id);
    }

    pub fn scanIndex(self: *TxContext, allocator: Allocator, query: *const IndexQuery) ![]Document {
        try self.read_set.recordIndexRange(
            self.allocator,
            query.namespace,
            query.table,
            query.index_name,
            query.start,
            query.end,
        );

        const prefix = try std.fmt.allocPrint(self.allocator, "{s}\x1f{s}\x1f", .{ query.namespace, query.table });
        defer self.allocator.free(prefix);

        var has_pending = false;
        var pit = self.pending_docs.keyIterator();
        while (pit.next()) |k| {
            if (std.mem.startsWith(u8, k.*, prefix)) {
                has_pending = true;
                break;
            }
        }

        if (!has_pending) {
            return try self.storage.scanIndex(allocator, query);
        }

        // Read-your-own-writes merge when this transaction already mutated the same table.
        var unbounded = query.*;
        unbounded.limit = null;
        const base = try self.storage.scanIndex(self.allocator, &unbounded);
        defer {
            for (base) |*d| d.deinit(self.allocator);
            self.allocator.free(base);
        }

        var merged: std.StringHashMapUnmanaged(Document) = .empty;
        defer {
            var mit = merged.iterator();
            while (mit.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                e.value_ptr.deinit(self.allocator);
            }
            merged.deinit(self.allocator);
        }

        for (base) |*d| {
            const dk = try self.allocator.dupe(u8, d.id);
            try merged.put(self.allocator, dk, try d.clone(self.allocator));
        }

        var oit = self.pending_docs.iterator();
        while (oit.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
            const doc_id = entry.key_ptr.*[prefix.len..];
            if (merged.fetchRemove(doc_id)) |old| {
                self.allocator.free(old.key);
                old.value.deinit(self.allocator);
            }
            if (entry.value_ptr.*) |*doc| {
                const dk = try self.allocator.dupe(u8, doc.id);
                try merged.put(self.allocator, dk, try doc.clone(self.allocator));
            }
        }

        const range = readset_mod.IndexRangeRead{
            .namespace = @constCast(query.namespace),
            .table = @constCast(query.table),
            .index_name = @constCast(query.index_name),
            .start = query.start,
            .end = query.end,
        };

        const Keyed = struct {
            encoded_key: []u8,
            doc: Document,
        };
        var keyed: std.ArrayList(Keyed) = .empty;
        defer {
            for (keyed.items) |*item| {
                self.allocator.free(item.encoded_key);
                item.doc.deinit(self.allocator);
            }
            keyed.deinit(self.allocator);
        }

        var vit = merged.valueIterator();
        while (vit.next()) |doc| {
            const entries = try storage_mod.computeIndexEntries(
                self.allocator,
                self.manifest,
                query.namespace,
                query.table,
                doc,
            );
            defer {
                for (entries) |*e| e.deinit(self.allocator);
                self.allocator.free(entries);
            }
            for (entries) |e| {
                if (std.mem.eql(u8, e.index_name, query.index_name) and range.containsKey(e.encoded_key)) {
                    try keyed.append(self.allocator, .{
                        .encoded_key = try self.allocator.dupe(u8, e.encoded_key),
                        .doc = try doc.clone(self.allocator),
                    });
                    break;
                }
            }
        }

        const SortCtx = struct {
            order: storage_mod.QueryOrder,
            fn lessThan(ctx: @This(), a: Keyed, b: Keyed) bool {
                const cmp = std.mem.order(u8, a.encoded_key, b.encoded_key);
                const ord = if (cmp != .eq) cmp else std.mem.order(u8, a.doc.id, b.doc.id);
                return switch (ctx.order) {
                    .asc => ord == .lt,
                    .desc => ord == .gt,
                };
            }
        };
        std.mem.sort(Keyed, keyed.items, SortCtx{ .order = query.order }, SortCtx.lessThan);

        const count = if (query.limit) |lim| @min(lim, keyed.items.len) else keyed.items.len;
        var out = try allocator.alloc(Document, count);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*d| d.deinit(allocator);
            allocator.free(out);
        }
        for (keyed.items[0..count], 0..) |item, i| {
            out[i] = try item.doc.clone(allocator);
            built += 1;
        }
        return out;
    }

    pub fn insert(self: *TxContext, allocator: Allocator, ns: []const u8, table: []const u8, body_json: []const u8) ![]u8 {
        if (self.read_only) return storage_mod.StorageError.ReadOnly;
        const clean_body = try storage_mod.stripSystemFields(self.allocator, body_json);
        errdefer self.allocator.free(clean_body);

        const doc_id = try storage_mod.newDocId(self.allocator, self.io);
        errdefer self.allocator.free(doc_id);
        const ct = storage_mod.nowMillis(self.io);

        try self.putPending(ns, table, doc_id, .{
            .id = try self.allocator.dupe(u8, doc_id),
            .creation_time_ms = ct,
            .body_json = try self.allocator.dupe(u8, clean_body),
        });

        try self.writes.append(self.allocator, .{ .insert = .{
            .namespace = try self.allocator.dupe(u8, ns),
            .table = try self.allocator.dupe(u8, table),
            .doc_id = doc_id,
            .creation_time_ms = ct,
            .body_json = clean_body,
        } });

        return try allocator.dupe(u8, doc_id);
    }

    pub fn patch(self: *TxContext, ns: []const u8, table: []const u8, doc_id: []const u8, patch_json: []const u8) !void {
        if (self.read_only) return storage_mod.StorageError.ReadOnly;
        const existing = try self.get(self.allocator, ns, table, doc_id) orelse return storage_mod.StorageError.NotFound;
        defer existing.deinit(self.allocator);

        const merged = try storage_mod.applyPatchJson(self.allocator, existing.body_json, patch_json);
        try self.putPending(ns, table, doc_id, .{
            .id = try self.allocator.dupe(u8, doc_id),
            .creation_time_ms = existing.creation_time_ms,
            .body_json = merged,
        });

        try self.writes.append(self.allocator, .{ .patch = .{
            .namespace = try self.allocator.dupe(u8, ns),
            .table = try self.allocator.dupe(u8, table),
            .doc_id = try self.allocator.dupe(u8, doc_id),
            .patch_json = try self.allocator.dupe(u8, patch_json),
        } });
    }

    pub fn replace(self: *TxContext, ns: []const u8, table: []const u8, doc_id: []const u8, body_json: []const u8) !void {
        if (self.read_only) return storage_mod.StorageError.ReadOnly;
        const existing = try self.get(self.allocator, ns, table, doc_id) orelse return storage_mod.StorageError.NotFound;
        defer existing.deinit(self.allocator);

        const clean_body = try storage_mod.stripSystemFields(self.allocator, body_json);
        errdefer self.allocator.free(clean_body);

        try self.putPending(ns, table, doc_id, .{
            .id = try self.allocator.dupe(u8, doc_id),
            .creation_time_ms = existing.creation_time_ms,
            .body_json = try self.allocator.dupe(u8, clean_body),
        });

        try self.writes.append(self.allocator, .{ .replace = .{
            .namespace = try self.allocator.dupe(u8, ns),
            .table = try self.allocator.dupe(u8, table),
            .doc_id = try self.allocator.dupe(u8, doc_id),
            .body_json = clean_body,
        } });
    }

    pub fn delete(self: *TxContext, ns: []const u8, table: []const u8, doc_id: []const u8) !void {
        if (self.read_only) return storage_mod.StorageError.ReadOnly;
        if (try self.get(self.allocator, ns, table, doc_id)) |doc| {
            doc.deinit(self.allocator);
        }
        try self.putPending(ns, table, doc_id, null);
        try self.writes.append(self.allocator, .{ .delete = .{
            .namespace = try self.allocator.dupe(u8, ns),
            .table = try self.allocator.dupe(u8, table),
            .doc_id = try self.allocator.dupe(u8, doc_id),
        } });
    }

    fn putPending(self: *TxContext, ns: []const u8, table: []const u8, doc_id: []const u8, doc: ?Document) !void {
        const key = try makeKey(self.allocator, ns, table, doc_id);
        if (self.pending_docs.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            if (old.value) |*d| d.deinit(self.allocator);
        }
        try self.pending_docs.put(self.allocator, key, doc);
    }
};

fn makeKey(allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x1f{s}\x1f{s}", .{ ns, table, doc_id });
}
