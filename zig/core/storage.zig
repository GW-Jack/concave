const std = @import("std");
const Allocator = std.mem.Allocator;
const key_mod = @import("key.zig");
const manifest_mod = @import("manifest.zig");
const readset_mod = @import("readset.zig");
const WalStore = @import("wal_store.zig").WalStore;
const PgStore = @import("pg_wire.zig").PgStore;

pub const BY_CREATION_TIME_INDEX = "by_creation_time";

pub const StorageError = error{
    Conflict,
    NotFound,
    ReadOnly,
    InvalidJson,
    InvalidKey,
    StorageFailure,
    OutOfMemory,
};

pub const Document = struct {
    id: []u8,
    creation_time_ms: i64,
    /// Raw JSON object string representing the document body (without system fields).
    body_json: []u8,

    pub fn clone(self: *const Document, allocator: Allocator) !Document {
        const id_c = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id_c);
        const body_c = try allocator.dupe(u8, self.body_json);
        return .{
            .id = id_c,
            .creation_time_ms = self.creation_time_ms,
            .body_json = body_c,
        };
    }

    pub fn deinit(self: *const Document, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.body_json);
    }

    /// Stream the merged wire JSON (`id`, `created_at`, plus body fields) directly into `w` with zero temp allocations.
    pub fn writeWireJson(self: *const Document, w: *std.Io.Writer) !void {
        const trimmed = std.mem.trim(u8, self.body_json, " \t\r\n");
        try w.writeAll("{\"id\":");
        try writeJsonString(w, self.id);
        try w.print(",\"created_at\":{d}", .{self.creation_time_ms});
        if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
            const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
            if (inner.len > 0) {
                try w.writeByte(',');
                try w.writeAll(inner);
            }
        } else {
            try w.writeAll(",\"value\":");
            try w.writeAll(trimmed);
        }
        try w.writeByte('}');
    }

    /// Merge system fields (`id`, `created_at`) into the document's JSON object representation.
    pub fn toWireJson(self: *const Document, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try self.writeWireJson(&out.writer);
        return try out.toOwnedSlice();
    }
};

pub const QueryOrder = enum {
    asc,
    desc,
};

pub const IndexQuery = struct {
    namespace: []const u8,
    table: []const u8,
    index_name: []const u8,
    start: readset_mod.KeyBound,
    end: readset_mod.KeyBound,
    order: QueryOrder = .asc,
    limit: ?usize = null,
};

pub const WriteOp = union(enum) {
    insert: struct {
        namespace: []u8,
        table: []u8,
        doc_id: []u8,
        creation_time_ms: i64,
        body_json: []u8,
    },
    replace: struct {
        namespace: []u8,
        table: []u8,
        doc_id: []u8,
        body_json: []u8,
    },
    patch: struct {
        namespace: []u8,
        table: []u8,
        doc_id: []u8,
        patch_json: []u8,
    },
    delete: struct {
        namespace: []u8,
        table: []u8,
        doc_id: []u8,
    },

    pub fn deinit(self: *const WriteOp, allocator: Allocator) void {
        switch (self.*) {
            .insert => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.doc_id);
                allocator.free(op.body_json);
            },
            .replace => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.doc_id);
                allocator.free(op.body_json);
            },
            .patch => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.doc_id);
                allocator.free(op.patch_json);
            },
            .delete => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.doc_id);
            },
        }
    }
};

pub const CommitEntry = struct {
    commit_ts: i64,
    write_set: readset_mod.WriteSet,

    pub fn deinit(self: *CommitEntry, allocator: Allocator) void {
        self.write_set.deinit(allocator);
    }
};

pub const CommitResult = struct {
    commit_ts: i64,
    write_set: readset_mod.WriteSet,

    pub fn deinit(self: *CommitResult, allocator: Allocator) void {
        self.write_set.deinit(allocator);
    }
};

pub const IndexKeyPair = struct {
    index_name: []u8,
    encoded_key: []u8,

    pub fn deinit(self: *const IndexKeyPair, allocator: Allocator) void {
        allocator.free(self.index_name);
        allocator.free(self.encoded_key);
    }
};

pub const Storage = union(enum) {
    wal: *WalStore,
    pg: *PgStore,

    pub fn initSchema(self: Storage, manifest: *const manifest_mod.AppManifest) !void {
        return switch (self) {
            .wal => |w| w.initSchema(manifest),
            .pg => |p| p.initSchema(manifest),
        };
    }

    pub fn latestCommitTs(self: Storage) !i64 {
        return switch (self) {
            .wal => |w| w.latestCommitTs(),
            .pg => |p| p.latestCommitTs(),
        };
    }

    pub fn getDoc(self: Storage, allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) !?Document {
        return switch (self) {
            .wal => |w| w.getDoc(allocator, ns, table, doc_id),
            .pg => |p| p.getDoc(allocator, ns, table, doc_id),
        };
    }

    pub fn scanIndex(self: Storage, allocator: Allocator, query: *const IndexQuery) ![]Document {
        return switch (self) {
            .wal => |w| w.scanIndex(allocator, query),
            .pg => |p| p.scanIndex(allocator, query),
        };
    }

    pub fn commitTx(
        self: Storage,
        allocator: Allocator,
        manifest: *const manifest_mod.AppManifest,
        snapshot_ts: i64,
        read_set: *const readset_mod.ReadSet,
        writes: []const WriteOp,
    ) !CommitResult {
        return switch (self) {
            .wal => |w| w.commitTx(allocator, manifest, snapshot_ts, read_set, writes),
            .pg => |p| p.commitTx(allocator, manifest, snapshot_ts, read_set, writes),
        };
    }

    pub fn commitsSince(self: Storage, allocator: Allocator, since_ts: i64) ![]CommitEntry {
        return switch (self) {
            .wal => |w| w.commitsSince(allocator, since_ts),
            .pg => |p| p.commitsSince(allocator, since_ts),
        };
    }
};

pub fn nowMillis(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Generate a time-ordered UUIDv7-style ID (`xxxxxxxx-xxxx-7xxx-yxxx-xxxxxxxxxxxx`) with zero dependencies.
pub fn newDocId(allocator: Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const ms: u64 = @intCast(@max(0, nowMillis(io)));
    bytes[0] = @intCast((ms >> 40) & 0xFF);
    bytes[1] = @intCast((ms >> 32) & 0xFF);
    bytes[2] = @intCast((ms >> 24) & 0xFF);
    bytes[3] = @intCast((ms >> 16) & 0xFF);
    bytes[4] = @intCast((ms >> 8) & 0xFF);
    bytes[5] = @intCast(ms & 0xFF);
    bytes[6] = (bytes[6] & 0x0F) | 0x70;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    return try std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

pub fn stringifyJsonValue(allocator: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// Remove system fields (`id`, `created_at`, `_id`, `_creationTime`) from a JSON object string.
pub fn stripSystemFields(allocator: Allocator, body_json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body_json, .{}) catch
        return error.InvalidJson;
    if (parsed == .object) {
        _ = parsed.object.swapRemove("id");
        _ = parsed.object.swapRemove("created_at");
        _ = parsed.object.swapRemove("_id");
        _ = parsed.object.swapRemove("_creationTime");
    }
    return try stringifyJsonValue(allocator, parsed);
}

/// Shallow-merge `patch_json` onto `base_json`, ignoring protected system fields.
pub fn applyPatchJson(allocator: Allocator, base_json: []const u8, patch_json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var base = std.json.parseFromSliceLeaky(std.json.Value, a, base_json, .{}) catch
        return error.InvalidJson;
    const patch = std.json.parseFromSliceLeaky(std.json.Value, a, patch_json, .{}) catch
        return error.InvalidJson;

    if (patch != .object) return error.InvalidJson;
    if (base != .object) {
        base = .{ .object = .empty };
    }

    var it = patch.object.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.eql(u8, k, "id") or
            std.mem.eql(u8, k, "created_at") or
            std.mem.eql(u8, k, "_id") or
            std.mem.eql(u8, k, "_creationTime")) continue;
        try base.object.put(a, k, entry.value_ptr.*);
    }

    return try stringifyJsonValue(allocator, base);
}

/// Compute all `(index_name, encoded_key)` pairs for `doc` according to `manifest`.
pub fn computeIndexEntries(
    allocator: Allocator,
    manifest: *const manifest_mod.AppManifest,
    namespace: []const u8,
    table: []const u8,
    doc: *const Document,
) ![]IndexKeyPair {
    var out: std.ArrayList(IndexKeyPair) = .empty;
    errdefer {
        for (out.items) |*p| p.deinit(allocator);
        out.deinit(allocator);
    }

    // Built-in `by_creation_time` index on every table.
    const ct_name = try allocator.dupe(u8, BY_CREATION_TIME_INDEX);
    errdefer allocator.free(ct_name);
    const ct_key = try key_mod.encodeKey(allocator, &.{.{ .int_val = doc.creation_time_ms }});
    try out.append(allocator, .{ .index_name = ct_name, .encoded_key = ct_key });

    if (manifest.findTable(namespace, table)) |table_spec| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const body_val = std.json.parseFromSliceLeaky(std.json.Value, a, doc.body_json, .{}) catch
            return error.InvalidJson;

        for (table_spec.indexes) |idx| {
            if (std.mem.eql(u8, idx.name, BY_CREATION_TIME_INDEX)) continue;
            var vals: std.ArrayList(key_mod.IndexValue) = .empty;
            var has_ct = false;
            for (idx.fields) |field| {
                if (std.mem.eql(u8, field, "id") or std.mem.eql(u8, field, "_id")) {
                    try vals.append(a, .{ .id_val = doc.id });
                } else if (std.mem.eql(u8, field, "created_at") or std.mem.eql(u8, field, "_creationTime")) {
                    has_ct = true;
                    try vals.append(a, .{ .int_val = doc.creation_time_ms });
                } else {
                    const extracted = extractJsonPath(body_val, field);
                    try vals.append(a, try key_mod.IndexValue.fromJsonValue(extracted));
                }
            }
            if (!has_ct) {
                try vals.append(a, .{ .int_val = doc.creation_time_ms });
            }
            const name_copy = try allocator.dupe(u8, idx.name);
            errdefer allocator.free(name_copy);
            const encoded = try key_mod.encodeKey(allocator, vals.items);
            try out.append(allocator, .{ .index_name = name_copy, .encoded_key = encoded });
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn extractJsonPath(root: std.json.Value, path: []const u8) std.json.Value {
    var curr = root;
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (curr != .object) return .null;
        curr = curr.object.get(seg) orelse return .null;
    }
    return curr;
}
