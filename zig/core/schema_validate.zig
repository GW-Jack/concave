const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest_mod = @import("manifest.zig");
const storage_mod = @import("storage.zig");

const SchemaType = manifest_mod.SchemaType;
const AppManifest = manifest_mod.AppManifest;

/// Validate a stripped document JSON body against a declared `TableSpec.document_schema`.
///
/// System fields (`id`, `created_at`, `_id`, `_creationTime`) are skipped because they are
/// managed by the host outside `body_json`. Returns `StorageError.SchemaViolation` on mismatch.
pub fn validateDocumentJson(allocator: Allocator, schema: SchemaType, body_json: []const u8) !void {
    if (schema == .any_t) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body_json, .{}) catch
        return storage_mod.StorageError.InvalidJson;

    if (!validateValue(schema, parsed, true)) {
        return storage_mod.StorageError.SchemaViolation;
    }
}

fn isSystemField(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "created_at") or
        std.mem.eql(u8, name, "_id") or
        std.mem.eql(u8, name, "_creationTime");
}

fn validateValue(schema: SchemaType, val: std.json.Value, is_doc_root: bool) bool {
    switch (schema) {
        .any_t => return true,
        .null_t => return val == .null,
        .bool_t => return val == .bool,
        .int_t => return switch (val) {
            .integer => true,
            .float => |f| std.math.isFinite(f) and @trunc(f) == f,
            else => false,
        },
        .float_t => return switch (val) {
            .integer => true,
            .float => |f| std.math.isFinite(f),
            else => false,
        },
        .str_t => return val == .string,
        .id_t => return val == .string,
        .optional_t => |inner| {
            if (val == .null) return true;
            return validateValue(inner.*, val, false);
        },
        .list_t => |item_schema| {
            if (val != .array) return false;
            for (val.array.items) |elem| {
                if (!validateValue(item_schema.*, elem, false)) return false;
            }
            return true;
        },
        .record_t => |fields| {
            if (val != .object) return false;
            for (fields) |f| {
                if (is_doc_root and isSystemField(f.name)) continue;
                if (val.object.get(f.name)) |fv| {
                    if (!validateValue(f.schema, fv, false)) return false;
                } else {
                    if (!f.optional and f.schema != .optional_t) return false;
                }
            }
            return true;
        },
        .union_t => |variants| {
            for (variants) |v| {
                if (v.payload) |payload_schema| {
                    if (val == .object) {
                        if (val.object.get(v.tag)) |pv| {
                            if (validateValue(payload_schema.*, pv, false)) return true;
                        }
                        if (val.object.get("tag")) |tv| {
                            if (tv == .string and std.mem.eql(u8, tv.string, v.tag)) {
                                if (val.object.get("value")) |pv| {
                                    if (validateValue(payload_schema.*, pv, false)) return true;
                                }
                            }
                        }
                    }
                } else {
                    if (val == .string and std.mem.eql(u8, val.string, v.tag)) return true;
                    if (val == .object) {
                        if (val.object.get("tag")) |tv| {
                            if (tv == .string and std.mem.eql(u8, tv.string, v.tag)) return true;
                        }
                    }
                }
            }
            return false;
        },
    }
}

pub const MigrationReport = struct {
    additive_changes: [][]u8,
    breaking_changes: [][]u8,

    pub fn deinit(self: *const MigrationReport, allocator: Allocator) void {
        for (self.additive_changes) |s| allocator.free(s);
        allocator.free(self.additive_changes);
        for (self.breaking_changes) |s| allocator.free(s);
        allocator.free(self.breaking_changes);
    }

    pub fn isBreaking(self: *const MigrationReport) bool {
        return self.breaking_changes.len > 0;
    }
};

fn schemaKindTag(s: SchemaType) []const u8 {
    return switch (s) {
        .null_t => "null",
        .bool_t => "bool",
        .int_t => "int",
        .float_t => "float",
        .str_t => "str",
        .id_t => "id",
        .list_t => "list",
        .optional_t => "optional",
        .record_t => "record",
        .union_t => "union",
        .any_t => "any",
    };
}

/// Serialize a compact canonical schema snapshot for startup migration diffing.
pub fn encodeSchemaSnapshot(allocator: Allocator, manifest: *const AppManifest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"tables\":{");
    var first_tbl = true;
    try writeTableGroup(w, "", manifest.tables, &first_tbl);
    for (manifest.components) |comp| {
        try writeTableGroup(w, comp.namespace, comp.tables, &first_tbl);
    }
    try w.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeTableGroup(w: *std.Io.Writer, ns: []const u8, tables: []const manifest_mod.TableSpec, first_tbl: *bool) !void {
    for (tables) |t| {
        if (!first_tbl.*) try w.writeByte(',');
        first_tbl.* = false;

        var key_buf: [256]u8 = undefined;
        const full_name = if (ns.len == 0)
            t.name
        else
            std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ ns, t.name }) catch t.name;

        try storage_mod.writeJsonString(w, full_name);
        try w.writeAll(":{\"fields\":{");
        switch (t.document_schema) {
            .record_t => |fields| {
                var first_f = true;
                for (fields) |f| {
                    if (isSystemField(f.name)) continue;
                    if (!first_f) try w.writeByte(',');
                    first_f = false;
                    try storage_mod.writeJsonString(w, f.name);
                    try w.writeAll(":{\"kind\":");
                    try storage_mod.writeJsonString(w, schemaKindTag(f.schema));
                    try w.print(",\"optional\":{s}}}", .{if (f.optional or f.schema == .optional_t) "true" else "false"});
                }
            },
            else => {},
        }
        try w.writeAll("},\"indexes\":[");
        for (t.indexes, 0..) |idx, i| {
            if (i > 0) try w.writeByte(',');
            try storage_mod.writeJsonString(w, idx.name);
        }
        try w.writeAll("]}");
    }
}

/// Compare a previously persisted schema snapshot JSON against the current `AppManifest`.
/// Classifies safe additive changes (new tables/indexes/optional fields) vs breaking changes
/// (dropped tables, dropped fields, field type changes, new required fields on existing tables).
pub fn diffSchemaSnapshots(allocator: Allocator, prev_json: []const u8, curr_manifest: *const AppManifest) !MigrationReport {
    const curr_json = try encodeSchemaSnapshot(allocator, curr_manifest);
    defer allocator.free(curr_json);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prev_root = std.json.parseFromSliceLeaky(std.json.Value, a, prev_json, .{}) catch
        return .{ .additive_changes = try allocator.alloc([]u8, 0), .breaking_changes = try allocator.alloc([]u8, 0) };
    const curr_root = try std.json.parseFromSliceLeaky(std.json.Value, a, curr_json, .{});

    const prev_tables = if (prev_root == .object) (prev_root.object.get("tables") orelse return .{
        .additive_changes = try allocator.alloc([]u8, 0),
        .breaking_changes = try allocator.alloc([]u8, 0),
    }) else return .{
        .additive_changes = try allocator.alloc([]u8, 0),
        .breaking_changes = try allocator.alloc([]u8, 0),
    };
    const curr_tables = curr_root.object.get("tables").?;
    if (prev_tables != .object or curr_tables != .object) {
        return .{ .additive_changes = try allocator.alloc([]u8, 0), .breaking_changes = try allocator.alloc([]u8, 0) };
    }

    var additive: std.ArrayList([]u8) = .empty;
    errdefer {
        for (additive.items) |s| allocator.free(s);
        additive.deinit(allocator);
    }
    var breaking: std.ArrayList([]u8) = .empty;
    errdefer {
        for (breaking.items) |s| allocator.free(s);
        breaking.deinit(allocator);
    }

    // Detect dropped tables & changed/dropped fields.
    var pit = prev_tables.object.iterator();
    while (pit.next()) |pe| {
        const tname = pe.key_ptr.*;
        const c_tbl = curr_tables.object.get(tname) orelse {
            try breaking.append(allocator, try std.fmt.allocPrint(allocator, "dropped table `{s}`", .{tname}));
            continue;
        };
        if (pe.value_ptr.* != .object or c_tbl != .object) continue;
        const p_fields = pe.value_ptr.object.get("fields") orelse continue;
        const c_fields = c_tbl.object.get("fields") orelse continue;
        if (p_fields != .object or c_fields != .object) continue;

        var pfit = p_fields.object.iterator();
        while (pfit.next()) |pf| {
            const fname = pf.key_ptr.*;
            const cf = c_fields.object.get(fname) orelse {
                try breaking.append(allocator, try std.fmt.allocPrint(allocator, "dropped field `{s}.{s}`", .{ tname, fname }));
                continue;
            };
            if (pf.value_ptr.* == .object and cf == .object) {
                const pk = if (pf.value_ptr.object.get("kind")) |v| (if (v == .string) v.string else "") else "";
                const ck = if (cf.object.get("kind")) |v| (if (v == .string) v.string else "") else "";
                if (!std.mem.eql(u8, pk, ck)) {
                    try breaking.append(allocator, try std.fmt.allocPrint(
                        allocator,
                        "changed type of `{s}.{s}` from {s} to {s}",
                        .{ tname, fname, pk, ck },
                    ));
                }
            }
        }
    }

    // Detect new tables, new fields (optional = additive, required = breaking on existing table), and new indexes.
    var cit = curr_tables.object.iterator();
    while (cit.next()) |ce| {
        const tname = ce.key_ptr.*;
        const p_tbl = prev_tables.object.get(tname) orelse {
            try additive.append(allocator, try std.fmt.allocPrint(allocator, "added table `{s}`", .{tname}));
            continue;
        };
        if (p_tbl != .object or ce.value_ptr.* != .object) continue;
        const p_fields = p_tbl.object.get("fields") orelse continue;
        const c_fields = ce.value_ptr.object.get("fields") orelse continue;
        if (p_fields == .object and c_fields == .object) {
            var cfit = c_fields.object.iterator();
            while (cfit.next()) |cf| {
                const fname = cf.key_ptr.*;
                if (!p_fields.object.contains(fname)) {
                    const is_opt = if (cf.value_ptr.* == .object)
                        (if (cf.value_ptr.object.get("optional")) |ov| (ov == .bool and ov.bool) else false)
                    else
                        false;
                    if (is_opt) {
                        try additive.append(allocator, try std.fmt.allocPrint(allocator, "added optional field `{s}.{s}`", .{ tname, fname }));
                    } else {
                        try breaking.append(allocator, try std.fmt.allocPrint(allocator, "added required field `{s}.{s}` on existing table", .{ tname, fname }));
                    }
                }
            }
        }
        const p_idxs = p_tbl.object.get("indexes");
        const c_idxs = ce.value_ptr.object.get("indexes");
        if (p_idxs != null and c_idxs != null and p_idxs.? == .array and c_idxs.? == .array) {
            for (c_idxs.?.array.items) |ci| {
                if (ci != .string) continue;
                var found = false;
                for (p_idxs.?.array.items) |pi| {
                    if (pi == .string and std.mem.eql(u8, pi.string, ci.string)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try additive.append(allocator, try std.fmt.allocPrint(allocator, "added index `{s}.{s}`", .{ tname, ci.string }));
                }
            }
        }
    }

    return .{
        .additive_changes = try additive.toOwnedSlice(allocator),
        .breaking_changes = try breaking.toOwnedSlice(allocator),
    };
}

test "runtime schema validator accepts valid docs and rejects type mismatches or missing required fields" {
    const allocator = std.testing.allocator;
    const mf_json =
        \\{
        \\  "app_name": "val-test",
        \\  "tables": [{
        \\    "name": "tasks",
        \\    "document_schema": {
        \\      "kind": "record",
        \\      "fields": [
        \\        {"name": "id", "schema": {"kind": "id", "table": "tasks"}},
        \\        {"name": "created_at", "schema": {"kind": "int"}},
        \\        {"name": "title", "schema": {"kind": "str"}},
        \\        {"name": "priority", "schema": {"kind": "int"}},
        \\        {"name": "done", "schema": {"kind": "bool"}},
        \\        {"name": "tags", "schema": {"kind": "list", "item": {"kind": "str"}}},
        \\        {"name": "notes", "schema": {"kind": "optional", "inner": {"kind": "str"}}, "optional": true}
        \\      ]
        \\    },
        \\    "indexes": []
        \\  }],
        \\  "components": [],
        \\  "functions": []
        \\}
    ;
    var mf = try AppManifest.parseJson(allocator, mf_json);
    defer mf.deinit();
    const tbl = mf.findTable("", "tasks").?;

    // Valid document (optional omitted, integral Dec float accepted for int)
    try validateDocumentJson(allocator, tbl.document_schema, "{\"title\":\"Ship v1\",\"priority\":1.0,\"done\":false,\"tags\":[\"core\"]}");
    // Valid document with optional present
    try validateDocumentJson(allocator, tbl.document_schema, "{\"title\":\"Ship v1\",\"priority\":2,\"done\":true,\"tags\":[],\"notes\":\"ready\"}");

    // Missing required field `done`
    try std.testing.expectError(
        storage_mod.StorageError.SchemaViolation,
        validateDocumentJson(allocator, tbl.document_schema, "{\"title\":\"Bad\",\"priority\":1,\"tags\":[]}"),
    );
    // Wrong field type (`priority` is string instead of int)
    try std.testing.expectError(
        storage_mod.StorageError.SchemaViolation,
        validateDocumentJson(allocator, tbl.document_schema, "{\"title\":\"Bad\",\"priority\":\"high\",\"done\":false,\"tags\":[]}"),
    );
    // Wrong list item type
    try std.testing.expectError(
        storage_mod.StorageError.SchemaViolation,
        validateDocumentJson(allocator, tbl.document_schema, "{\"title\":\"Bad\",\"priority\":1,\"done\":false,\"tags\":[123]}"),
    );
}

test "schema migration diff detects additive vs breaking schema changes" {
    const allocator = std.testing.allocator;
    const v1_json =
        \\{"app_name":"m","tables":[{"name":"users","document_schema":{"kind":"record","fields":[{"name":"name","schema":{"kind":"str"}},{"name":"age","schema":{"kind":"int"}}]},"indexes":[]}],"components":[],"functions":[]}
    ;
    const v2_safe_json =
        \\{"app_name":"m","tables":[{"name":"users","document_schema":{"kind":"record","fields":[{"name":"name","schema":{"kind":"str"}},{"name":"age","schema":{"kind":"int"}},{"name":"bio","schema":{"kind":"optional","inner":{"kind":"str"}},"optional":true}]},"indexes":[{"name":"by_name","fields":["name"]}]},{"name":"posts","document_schema":{"kind":"record","fields":[{"name":"title","schema":{"kind":"str"}}]},"indexes":[]}],"components":[],"functions":[]}
    ;
    const v3_break_json =
        \\{"app_name":"m","tables":[{"name":"users","document_schema":{"kind":"record","fields":[{"name":"name","schema":{"kind":"str"}},{"name":"age","schema":{"kind":"str"}},{"name":"email","schema":{"kind":"str"}}]},"indexes":[]}],"components":[],"functions":[]}
    ;

    var m1 = try AppManifest.parseJson(allocator, v1_json);
    defer m1.deinit();
    var m2 = try AppManifest.parseJson(allocator, v2_safe_json);
    defer m2.deinit();
    var m3 = try AppManifest.parseJson(allocator, v3_break_json);
    defer m3.deinit();

    const snap1 = try encodeSchemaSnapshot(allocator, &m1);
    defer allocator.free(snap1);

    const rep_safe = try diffSchemaSnapshots(allocator, snap1, &m2);
    defer rep_safe.deinit(allocator);
    try std.testing.expect(!rep_safe.isBreaking());
    try std.testing.expectEqual(@as(usize, 3), rep_safe.additive_changes.len);

    const rep_break = try diffSchemaSnapshots(allocator, snap1, &m3);
    defer rep_break.deinit(allocator);
    try std.testing.expect(rep_break.isBreaking());
    try std.testing.expectEqual(@as(usize, 2), rep_break.breaking_changes.len);
}
