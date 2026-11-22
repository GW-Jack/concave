const std = @import("std");
const Allocator = std.mem.Allocator;

const TAG_NULL: u8 = 0x01;
const TAG_BOOL: u8 = 0x02;
const TAG_INT: u8 = 0x03;
const TAG_FLOAT: u8 = 0x04;
const TAG_STR: u8 = 0x05;
const TAG_ID: u8 = 0x06;

pub const KeyError = error{
    InvalidKey,
    OutOfMemory,
};

pub const IndexValue = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    str_val: []const u8,
    id_val: []const u8,

    pub fn fromJsonValue(val: std.json.Value) KeyError!IndexValue {
        return switch (val) {
            .null => .null_val,
            .bool => |b| .{ .bool_val = b },
            .integer => |i| .{ .int_val = i },
            .float => |f| {
                if (std.math.isNan(f)) return error.InvalidKey;
                return .{ .float_val = f };
            },
            .number_string => |s| {
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    return .{ .int_val = i };
                } else |_| {
                    const f = std.fmt.parseFloat(f64, s) catch return error.InvalidKey;
                    if (std.math.isNan(f)) return error.InvalidKey;
                    return .{ .float_val = f };
                }
            },
            .string => |s| .{ .str_val = s },
            else => error.InvalidKey,
        };
    }

    /// Parse a wire-format IndexValue JSON object: `{"type":"str","value":"general"}`.
    pub fn fromWireJson(val: std.json.Value) KeyError!IndexValue {
        if (val != .object) return error.InvalidKey;
        const type_v = val.object.get("type") orelse return error.InvalidKey;
        if (type_v != .string) return error.InvalidKey;
        const kind = type_v.string;

        if (std.mem.eql(u8, kind, "null")) return .null_val;
        const payload = val.object.get("value") orelse return error.InvalidKey;
        if (std.mem.eql(u8, kind, "bool")) {
            if (payload != .bool) return error.InvalidKey;
            return .{ .bool_val = payload.bool };
        }
        if (std.mem.eql(u8, kind, "int")) {
            return switch (payload) {
                .integer => |i| .{ .int_val = i },
                .float => |f| .{ .int_val = @intFromFloat(f) },
                else => error.InvalidKey,
            };
        }
        if (std.mem.eql(u8, kind, "float")) {
            return switch (payload) {
                .float => |f| if (std.math.isNan(f)) error.InvalidKey else .{ .float_val = f },
                .integer => |i| .{ .float_val = @floatFromInt(i) },
                else => error.InvalidKey,
            };
        }
        if (std.mem.eql(u8, kind, "str")) {
            if (payload != .string) return error.InvalidKey;
            return .{ .str_val = payload.string };
        }
        if (std.mem.eql(u8, kind, "id")) {
            if (payload != .string) return error.InvalidKey;
            return .{ .id_val = payload.string };
        }
        return error.InvalidKey;
    }
};

pub fn encodeKey(allocator: Allocator, values: []const IndexValue) KeyError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values) |v| {
        try encodeValue(allocator, v, &out);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn encodePrefixUpperBound(allocator: Allocator, prefix: []const IndexValue) KeyError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (prefix) |v| {
        try encodeValue(allocator, v, &out);
    }
    try out.append(allocator, 0xFF);
    return try out.toOwnedSlice(allocator);
}

fn encodeValue(allocator: Allocator, val: IndexValue, out: *std.ArrayList(u8)) KeyError!void {
    switch (val) {
        .null_val => try out.append(allocator, TAG_NULL),
        .bool_val => |b| {
            try out.append(allocator, TAG_BOOL);
            try out.append(allocator, if (b) 1 else 0);
        },
        .int_val => |i| {
            try out.append(allocator, TAG_INT);
            const raw: u64 = @bitCast(i);
            const ordered = raw ^ (@as(u64, 1) << 63);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, ordered, .big);
            try out.appendSlice(allocator, &buf);
        },
        .float_val => |f| {
            if (std.math.isNan(f)) return error.InvalidKey;
            try out.append(allocator, TAG_FLOAT);
            const canonical: f64 = if (f == 0.0) 0.0 else f;
            const bits: u64 = @bitCast(canonical);
            const ordered = if ((bits & (@as(u64, 1) << 63)) != 0)
                ~bits
            else
                bits ^ (@as(u64, 1) << 63);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, ordered, .big);
            try out.appendSlice(allocator, &buf);
        },
        .str_val => |s| {
            try out.append(allocator, TAG_STR);
            try encodeEscapedBytes(allocator, s, out);
        },
        .id_val => |id| {
            try out.append(allocator, TAG_ID);
            try encodeEscapedBytes(allocator, id, out);
        },
    }
}

fn encodeEscapedBytes(allocator: Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    for (bytes) |b| {
        if (b == 0x00) {
            try out.append(allocator, 0x00);
            try out.append(allocator, 0xFF);
        } else {
            try out.append(allocator, b);
        }
    }
    try out.append(allocator, 0x00);
    try out.append(allocator, 0x00);
}

test "signed integers preserve lexicographic order" {
    const allocator = std.testing.allocator;
    const nums = [_]i64{ std.math.minInt(i64), -1000, -1, 0, 1, 42, std.math.maxInt(i64) };
    var prev: ?[]u8 = null;
    defer if (prev) |p| allocator.free(p);
    for (nums) |n| {
        const cur = try encodeKey(allocator, &.{.{ .int_val = n }});
        if (prev) |p| {
            try std.testing.expect(std.mem.order(u8, p, cur) == .lt);
            allocator.free(p);
        }
        prev = cur;
    }
}

test "floats preserve order and canonicalize negative zero" {
    const allocator = std.testing.allocator;
    const vals = [_]f64{ -std.math.inf(f64), -100.5, -0.001, 0.0, 0.001, 42.25, std.math.inf(f64) };
    var prev: ?[]u8 = null;
    defer if (prev) |p| allocator.free(p);
    for (vals) |f| {
        const cur = try encodeKey(allocator, &.{.{ .float_val = f }});
        if (prev) |p| {
            try std.testing.expect(std.mem.order(u8, p, cur) == .lt);
            allocator.free(p);
        }
        prev = cur;
    }
    const neg_zero = try encodeKey(allocator, &.{.{ .float_val = -0.0 }});
    defer allocator.free(neg_zero);
    const pos_zero = try encodeKey(allocator, &.{.{ .float_val = 0.0 }});
    defer allocator.free(pos_zero);
    try std.testing.expectEqualSlices(u8, neg_zero, pos_zero);
    try std.testing.expectError(error.InvalidKey, encodeKey(allocator, &.{.{ .float_val = std.math.nan(f64) }}));
}

test "strings with embedded NUL preserve order and composite prefix upper bound brackets cleanly" {
    const allocator = std.testing.allocator;
    const strs = [_][]const u8{ "", "\x00", "\x00a", "a", "a\x00", "a\x00b", "aa", "b" };
    var prev: ?[]u8 = null;
    defer if (prev) |p| allocator.free(p);
    for (strs) |s| {
        const cur = try encodeKey(allocator, &.{.{ .str_val = s }});
        if (prev) |p| {
            try std.testing.expect(std.mem.order(u8, p, cur) == .lt);
            allocator.free(p);
        }
        prev = cur;
    }

    const prefix = try encodeKey(allocator, &.{.{ .str_val = "room-a" }});
    defer allocator.free(prefix);
    const upper = try encodePrefixUpperBound(allocator, &.{.{ .str_val = "room-a" }});
    defer allocator.free(upper);
    const in_a = try encodeKey(allocator, &.{ .{ .str_val = "room-a" }, .{ .int_val = 999 } });
    defer allocator.free(in_a);
    const in_b = try encodeKey(allocator, &.{ .{ .str_val = "room-b" }, .{ .int_val = 0 } });
    defer allocator.free(in_b);

    try std.testing.expect(std.mem.order(u8, prefix, in_a) != .gt);
    try std.testing.expect(std.mem.order(u8, in_a, upper) == .lt);
    try std.testing.expect(std.mem.order(u8, upper, in_b) == .lt);
}
