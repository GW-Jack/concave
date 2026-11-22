const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DocRef = struct {
    namespace: []u8,
    table: []u8,
    doc_id: []u8,

    pub fn clone(allocator: Allocator, ns: []const u8, tbl: []const u8, id: []const u8) !DocRef {
        const ns_c = try allocator.dupe(u8, ns);
        errdefer allocator.free(ns_c);
        const tbl_c = try allocator.dupe(u8, tbl);
        errdefer allocator.free(tbl_c);
        const id_c = try allocator.dupe(u8, id);
        return .{ .namespace = ns_c, .table = tbl_c, .doc_id = id_c };
    }

    pub fn deinit(self: *const DocRef, allocator: Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.table);
        allocator.free(self.doc_id);
    }

    pub fn eql(self: *const DocRef, other: *const DocRef) bool {
        return std.mem.eql(u8, self.namespace, other.namespace) and
            std.mem.eql(u8, self.table, other.table) and
            std.mem.eql(u8, self.doc_id, other.doc_id);
    }
};

pub const KeyBound = union(enum) {
    unbounded,
    included: []u8,
    excluded: []u8,

    pub fn clone(self: KeyBound, allocator: Allocator) !KeyBound {
        return switch (self) {
            .unbounded => .unbounded,
            .included => |k| .{ .included = try allocator.dupe(u8, k) },
            .excluded => |k| .{ .excluded = try allocator.dupe(u8, k) },
        };
    }

    pub fn deinit(self: KeyBound, allocator: Allocator) void {
        switch (self) {
            .unbounded => {},
            .included => |k| allocator.free(k),
            .excluded => |k| allocator.free(k),
        }
    }
};

pub const IndexRangeRead = struct {
    namespace: []u8,
    table: []u8,
    index_name: []u8,
    start: KeyBound,
    end: KeyBound,

    pub fn deinit(self: *const IndexRangeRead, allocator: Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.table);
        allocator.free(self.index_name);
        self.start.deinit(allocator);
        self.end.deinit(allocator);
    }

    pub fn containsKey(self: *const IndexRangeRead, encoded_key: []const u8) bool {
        const above_start = switch (self.start) {
            .unbounded => true,
            .included => |lo| std.mem.order(u8, encoded_key, lo) != .lt,
            .excluded => |lo| std.mem.order(u8, encoded_key, lo) == .gt,
        };
        if (!above_start) return false;
        return switch (self.end) {
            .unbounded => true,
            .included => |hi| std.mem.order(u8, encoded_key, hi) != .gt,
            .excluded => |hi| std.mem.order(u8, encoded_key, hi) == .lt,
        };
    }
};

pub const WrittenIndexKey = struct {
    namespace: []u8,
    table: []u8,
    index_name: []u8,
    encoded_key: []u8,

    pub fn deinit(self: *const WrittenIndexKey, allocator: Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.table);
        allocator.free(self.index_name);
        allocator.free(self.encoded_key);
    }
};

pub const WriteSet = struct {
    docs: std.ArrayList(DocRef) = .empty,
    index_keys: std.ArrayList(WrittenIndexKey) = .empty,

    pub fn deinit(self: *WriteSet, allocator: Allocator) void {
        for (self.docs.items) |*d| d.deinit(allocator);
        self.docs.deinit(allocator);
        for (self.index_keys.items) |*k| k.deinit(allocator);
        self.index_keys.deinit(allocator);
    }

    pub fn recordDoc(self: *WriteSet, allocator: Allocator, ns: []const u8, tbl: []const u8, doc_id: []const u8) !void {
        for (self.docs.items) |*existing| {
            if (std.mem.eql(u8, existing.namespace, ns) and
                std.mem.eql(u8, existing.table, tbl) and
                std.mem.eql(u8, existing.doc_id, doc_id)) return;
        }
        try self.docs.append(allocator, try DocRef.clone(allocator, ns, tbl, doc_id));
    }

    pub fn recordIndexKey(
        self: *WriteSet,
        allocator: Allocator,
        ns: []const u8,
        tbl: []const u8,
        idx_name: []const u8,
        encoded_key: []const u8,
    ) !void {
        const ns_c = try allocator.dupe(u8, ns);
        errdefer allocator.free(ns_c);
        const tbl_c = try allocator.dupe(u8, tbl);
        errdefer allocator.free(tbl_c);
        const idx_c = try allocator.dupe(u8, idx_name);
        errdefer allocator.free(idx_c);
        const key_c = try allocator.dupe(u8, encoded_key);
        try self.index_keys.append(allocator, .{
            .namespace = ns_c,
            .table = tbl_c,
            .index_name = idx_c,
            .encoded_key = key_c,
        });
    }

    pub fn isEmpty(self: *const WriteSet) bool {
        return self.docs.items.len == 0 and self.index_keys.items.len == 0;
    }

    pub fn clone(self: *const WriteSet, allocator: Allocator) !WriteSet {
        var out: WriteSet = .{};
        errdefer out.deinit(allocator);
        for (self.docs.items) |*d| {
            try out.recordDoc(allocator, d.namespace, d.table, d.doc_id);
        }
        for (self.index_keys.items) |*k| {
            try out.recordIndexKey(allocator, k.namespace, k.table, k.index_name, k.encoded_key);
        }
        return out;
    }
};

pub const ReadSet = struct {
    doc_reads: std.ArrayList(DocRef) = .empty,
    index_ranges: std.ArrayList(IndexRangeRead) = .empty,

    pub fn deinit(self: *ReadSet, allocator: Allocator) void {
        for (self.doc_reads.items) |*d| d.deinit(allocator);
        self.doc_reads.deinit(allocator);
        for (self.index_ranges.items) |*r| r.deinit(allocator);
        self.index_ranges.deinit(allocator);
    }

    pub fn recordDocRead(self: *ReadSet, allocator: Allocator, ns: []const u8, tbl: []const u8, doc_id: []const u8) !void {
        for (self.doc_reads.items) |*existing| {
            if (std.mem.eql(u8, existing.namespace, ns) and
                std.mem.eql(u8, existing.table, tbl) and
                std.mem.eql(u8, existing.doc_id, doc_id)) return;
        }
        try self.doc_reads.append(allocator, try DocRef.clone(allocator, ns, tbl, doc_id));
    }

    pub fn recordIndexRange(
        self: *ReadSet,
        allocator: Allocator,
        ns: []const u8,
        tbl: []const u8,
        idx_name: []const u8,
        start: KeyBound,
        end: KeyBound,
    ) !void {
        const ns_c = try allocator.dupe(u8, ns);
        errdefer allocator.free(ns_c);
        const tbl_c = try allocator.dupe(u8, tbl);
        errdefer allocator.free(tbl_c);
        const idx_c = try allocator.dupe(u8, idx_name);
        errdefer allocator.free(idx_c);
        const start_c = try start.clone(allocator);
        errdefer start_c.deinit(allocator);
        const end_c = try end.clone(allocator);
        try self.index_ranges.append(allocator, .{
            .namespace = ns_c,
            .table = tbl_c,
            .index_name = idx_c,
            .start = start_c,
            .end = end_c,
        });
    }

    pub fn intersects(self: *const ReadSet, writes: *const WriteSet) bool {
        for (writes.docs.items) |*wd| {
            for (self.doc_reads.items) |*rd| {
                if (rd.eql(wd)) return true;
            }
        }
        for (writes.index_keys.items) |*wk| {
            for (self.index_ranges.items) |*r| {
                if (std.mem.eql(u8, r.namespace, wk.namespace) and
                    std.mem.eql(u8, r.table, wk.table) and
                    std.mem.eql(u8, r.index_name, wk.index_name) and
                    r.containsKey(wk.encoded_key))
                {
                    return true;
                }
            }
        }
        return false;
    }
};

test "readset isolates rooms and component namespaces" {
    const key = @import("key.zig");
    const allocator = std.testing.allocator;

    var read_a: ReadSet = .{};
    defer read_a.deinit(allocator);
    const start_a = try key.encodeKey(allocator, &.{.{ .str_val = "room-a" }});
    defer allocator.free(start_a);
    const end_a = try key.encodePrefixUpperBound(allocator, &.{.{ .str_val = "room-a" }});
    defer allocator.free(end_a);
    try read_a.recordIndexRange(allocator, "", "messages", "by_room", .{ .included = start_a }, .{ .excluded = end_a });

    var write_b: WriteSet = .{};
    defer write_b.deinit(allocator);
    const key_b = try key.encodeKey(allocator, &.{ .{ .str_val = "room-b" }, .{ .int_val = 100 } });
    defer allocator.free(key_b);
    try write_b.recordIndexKey(allocator, "", "messages", "by_room", key_b);
    try std.testing.expect(!read_a.intersects(&write_b));

    var write_other_ns: WriteSet = .{};
    defer write_other_ns.deinit(allocator);
    const key_a = try key.encodeKey(allocator, &.{ .{ .str_val = "room-a" }, .{ .int_val = 100 } });
    defer allocator.free(key_a);
    try write_other_ns.recordIndexKey(allocator, "presence", "messages", "by_room", key_a);
    try std.testing.expect(!read_a.intersects(&write_other_ns));

    var write_a: WriteSet = .{};
    defer write_a.deinit(allocator);
    try write_a.recordIndexKey(allocator, "", "messages", "by_room", key_a);
    try std.testing.expect(read_a.intersects(&write_a));
}
