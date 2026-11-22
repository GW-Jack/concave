const std = @import("std");
const key_mod = @import("../core/key.zig");
const IndexValue = key_mod.IndexValue;

fn compareIndexValue(a: IndexValue, b: IndexValue) std.math.Order {
    const tag_a = @intFromEnum(a);
    const tag_b = @intFromEnum(b);
    if (tag_a != tag_b) return std.math.order(tag_a, tag_b);

    return switch (a) {
        .null_val => .eq,
        .bool_val => |va| std.math.order(@intFromBool(va), @intFromBool(b.bool_val)),
        .int_val => |va| std.math.order(va, b.int_val),
        .float_val => |va| blk: {
            const ca: f64 = if (va == 0.0) 0.0 else va;
            const cb: f64 = if (b.float_val == 0.0) 0.0 else b.float_val;
            break :blk std.math.order(ca, cb);
        },
        .str_val => |va| std.mem.order(u8, va, b.str_val),
        .id_val => |va| std.mem.order(u8, va, b.id_val),
    };
}

fn compareTuple(a: []const IndexValue, b: []const IndexValue) std.math.Order {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const ord = compareIndexValue(a[i], b[i]);
        if (ord != .eq) return ord;
    }
    return std.math.order(a.len, b.len);
}

fn randomString(allocator: std.mem.Allocator, rng: std.Random) ![]u8 {
    // Bias toward tricky bytes: NUL (0x00), 0x01, 0xFE, 0xFF, ASCII, UTF-8 multi-byte.
    const alphabet = [_]u8{ 0x00, 0x01, 0x02, 'a', 'b', 'z', 0x7F, 0xC3, 0xA9, 0xFE, 0xFF };
    const len = rng.intRangeAtMost(usize, 0, 10);
    const buf = try allocator.alloc(u8, len);
    for (buf) |*c| {
        c.* = alphabet[rng.intRangeLessThan(usize, 0, alphabet.len)];
    }
    return buf;
}

fn randomIndexValue(allocator: std.mem.Allocator, rng: std.Random) !IndexValue {
    const kind = rng.intRangeLessThan(u8, 0, 6);
    return switch (kind) {
        0 => .null_val,
        1 => .{ .bool_val = rng.boolean() },
        2 => blk: {
            const edge = rng.intRangeLessThan(u8, 0, 10);
            const v: i64 = switch (edge) {
                0 => std.math.minInt(i64),
                1 => std.math.maxInt(i64),
                2 => -1,
                3 => 0,
                4 => 1,
                else => rng.int(i64),
            };
            break :blk .{ .int_val = v };
        },
        3 => blk: {
            const edge = rng.intRangeLessThan(u8, 0, 12);
            const f: f64 = switch (edge) {
                0 => -std.math.inf(f64),
                1 => std.math.inf(f64),
                2 => -0.0,
                3 => 0.0,
                4 => -std.math.floatTrueMin(f64),
                5 => std.math.floatTrueMin(f64),
                6 => -std.math.floatMax(f64),
                7 => std.math.floatMax(f64),
                else => blk2: {
                    const raw: f64 = @bitCast(rng.int(u64));
                    break :blk2 if (std.math.isNan(raw)) 1.5 else raw;
                },
            };
            break :blk .{ .float_val = f };
        },
        4 => .{ .str_val = try randomString(allocator, rng) },
        5 => .{ .id_val = try randomString(allocator, rng) },
        else => unreachable,
    };
}

fn freeIndexValue(allocator: std.mem.Allocator, v: IndexValue) void {
    switch (v) {
        .str_val => |s| allocator.free(s),
        .id_val => |s| allocator.free(s),
        else => {},
    }
}

test "key codec: randomized order-isomorphism and injectivity across 2000 single & composite tuples" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0C4_7E01);
    const rng = prng.random();

    for (0..2000) |_| {
        const len_a = rng.intRangeAtMost(usize, 1, 3);
        const len_b = rng.intRangeAtMost(usize, 1, 3);
        var a_vals: [3]IndexValue = undefined;
        var b_vals: [3]IndexValue = undefined;
        for (0..len_a) |i| a_vals[i] = try randomIndexValue(allocator, rng);
        defer for (0..len_a) |i| freeIndexValue(allocator, a_vals[i]);
        for (0..len_b) |i| b_vals[i] = try randomIndexValue(allocator, rng);
        defer for (0..len_b) |i| freeIndexValue(allocator, b_vals[i]);

        const enc_a = try key_mod.encodeKey(allocator, a_vals[0..len_a]);
        defer allocator.free(enc_a);
        const enc_b = try key_mod.encodeKey(allocator, b_vals[0..len_b]);
        defer allocator.free(enc_b);

        const expected = compareTuple(a_vals[0..len_a], b_vals[0..len_b]);
        const actual = std.mem.order(u8, enc_a, enc_b);
        try std.testing.expectEqual(expected, actual);
    }
}

test "key codec: prefix upper bound brackets all extensions and excludes all strictly greater prefixes" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0C4_7E02);
    const rng = prng.random();

    for (0..1000) |_| {
        const p1 = try randomIndexValue(allocator, rng);
        defer freeIndexValue(allocator, p1);
        const p2 = try randomIndexValue(allocator, rng);
        defer freeIndexValue(allocator, p2);
        const s1 = try randomIndexValue(allocator, rng);
        defer freeIndexValue(allocator, s1);
        const s2 = try randomIndexValue(allocator, rng);
        defer freeIndexValue(allocator, s2);

        const lo = try key_mod.encodeKey(allocator, &.{p1});
        defer allocator.free(lo);
        const hi = try key_mod.encodePrefixUpperBound(allocator, &.{p1});
        defer allocator.free(hi);
        const ext = try key_mod.encodeKey(allocator, &.{ p1, s1 });
        defer allocator.free(ext);
        const ext2 = try key_mod.encodeKey(allocator, &.{ p1, s1, s2 });
        defer allocator.free(ext2);

        // Every extension of p1 is strictly inside [lo, hi).
        try std.testing.expect(std.mem.order(u8, lo, ext) == .lt);
        try std.testing.expect(std.mem.order(u8, ext, hi) == .lt);
        try std.testing.expect(std.mem.order(u8, lo, ext2) == .lt);
        try std.testing.expect(std.mem.order(u8, ext2, hi) == .lt);

        // Any tuple with a different prefix p2 is strictly outside [lo, hi).
        const other = try key_mod.encodeKey(allocator, &.{ p2, s1 });
        defer allocator.free(other);
        switch (compareIndexValue(p2, p1)) {
            .lt => try std.testing.expect(std.mem.order(u8, other, lo) == .lt),
            .gt => try std.testing.expect(std.mem.order(u8, other, hi) == .gt),
            .eq => {
                try std.testing.expect(std.mem.order(u8, lo, other) != .gt);
                try std.testing.expect(std.mem.order(u8, other, hi) == .lt);
            },
        }
    }
}

test "key codec: IEEE-754 subnormals, negative zero, infinities, and hostile wire JSON" {
    const allocator = std.testing.allocator;
    const ordered_floats = [_]f64{
        -std.math.inf(f64),
        -std.math.floatMax(f64),
        -1.0,
        -std.math.floatMin(f64),
        -std.math.floatTrueMin(f64),
        0.0,
        std.math.floatTrueMin(f64),
        std.math.floatMin(f64),
        1.0,
        std.math.floatMax(f64),
        std.math.inf(f64),
    };

    var prev: ?[]u8 = null;
    defer if (prev) |p| allocator.free(p);
    for (ordered_floats) |f| {
        const cur = try key_mod.encodeKey(allocator, &.{.{ .float_val = f }});
        if (prev) |p| {
            try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, p, cur));
            allocator.free(p);
        }
        prev = cur;
    }

    // Hostile wire JSON: out-of-range float for int, NaN, unknown kind, missing value.
    const bad_inputs = [_][]const u8{
        "{\"type\":\"int\",\"value\":1e30}",
        "{\"type\":\"int\",\"value\":-1e30}",
        "{\"type\":\"int\",\"value\":\"not-an-int\"}",
        "{\"type\":\"unknown\",\"value\":1}",
        "{\"type\":\"str\"}",
        "{\"type\":42,\"value\":\"x\"}",
        "123",
    };
    for (bad_inputs) |raw| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidKey, IndexValue.fromWireJson(parsed.value));
    }

    // Direct float NaN / Inf in fromWireJson(int) must return InvalidKey, not panic.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "type", .{ .string = "int" });
    try obj.put(a, "value", .{ .float = std.math.nan(f64) });
    try std.testing.expectError(error.InvalidKey, IndexValue.fromWireJson(.{ .object = obj }));
    try obj.put(a, "value", .{ .float = std.math.inf(f64) });
    try std.testing.expectError(error.InvalidKey, IndexValue.fromWireJson(.{ .object = obj }));
}
