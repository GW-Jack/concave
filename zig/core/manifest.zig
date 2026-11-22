const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FunctionKind = enum {
    query,
    mutation,
    action,

    pub fn fromStr(s: []const u8) !FunctionKind {
        if (std.mem.eql(u8, s, "query")) return .query;
        if (std.mem.eql(u8, s, "mutation")) return .mutation;
        if (std.mem.eql(u8, s, "action")) return .action;
        return error.InvalidManifest;
    }

    pub fn toStr(self: FunctionKind) []const u8 {
        return switch (self) {
            .query => "query",
            .mutation => "mutation",
            .action => "action",
        };
    }
};

pub const FieldSpec = struct {
    name: []const u8,
    schema: SchemaType,
    optional: bool = false,
};

pub const VariantSpec = struct {
    tag: []const u8,
    payload: ?*SchemaType = null,
};

pub const SchemaType = union(enum) {
    null_t,
    bool_t,
    int_t,
    float_t,
    str_t,
    id_t: struct {
        table: []const u8,
        namespace: []const u8,
    },
    list_t: *SchemaType,
    optional_t: *SchemaType,
    record_t: []FieldSpec,
    union_t: []VariantSpec,
    any_t,
};

pub const IndexSpec = struct {
    name: []const u8,
    fields: []const []const u8,
};

pub const TableSpec = struct {
    name: []const u8,
    document_schema: SchemaType,
    indexes: []const IndexSpec,
};

pub const ComponentSpec = struct {
    namespace: []const u8,
    package: []const u8,
    tables: []const TableSpec,
};

pub const FunctionSpec = struct {
    name: []const u8,
    kind: FunctionKind,
    namespace: []const u8,
    args_schema: SchemaType,
    returns_schema: SchemaType,
};

pub const CronSpec = struct {
    name: []const u8,
    interval_ms: i64,
    fn_name: []const u8,
    args_json: []const u8,
};

pub const HttpRouteSpec = struct {
    method: []const u8,
    path: []const u8,
};

const system_sched_idx_status_fields = [_][]const u8{ "status", "run_at_ms" };
const system_sched_idx_cron_fields = [_][]const u8{ "cron_name", "status" };
const system_sched_indexes = [_]IndexSpec{
    .{ .name = "by_status_run_at", .fields = &system_sched_idx_status_fields },
    .{ .name = "by_cron", .fields = &system_sched_idx_cron_fields },
};
const system_scheduled_jobs_table = TableSpec{
    .name = "_scheduled_jobs",
    .document_schema = .any_t,
    .indexes = &system_sched_indexes,
};
const system_storage_table = TableSpec{
    .name = "_storage",
    .document_schema = .any_t,
    .indexes = &.{},
};

pub const AppManifest = struct {
    arena: std.heap.ArenaAllocator,
    raw_json: []const u8,
    app_name: []const u8,
    tables: []const TableSpec,
    components: []const ComponentSpec,
    functions: []const FunctionSpec,
    crons: []const CronSpec = &.{},
    http_routes: []const HttpRouteSpec = &.{},

    pub fn deinit(self: *AppManifest) void {
        self.arena.deinit();
    }

    pub fn parseJson(parent_allocator: Allocator, json_bytes: []const u8) !AppManifest {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const raw_copy = try alloc.dupe(u8, json_bytes);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, raw_copy, .{});
        if (parsed != .object) return error.InvalidManifest;
        const obj = parsed.object;

        const app_name = try getRequiredStr(obj, "app_name");

        var tables: std.ArrayList(TableSpec) = .empty;
        if (obj.get("tables")) |tv| {
            if (tv == .array) {
                for (tv.array.items) |item| {
                    try tables.append(alloc, try parseTable(alloc, item));
                }
            }
        }

        var components: std.ArrayList(ComponentSpec) = .empty;
        if (obj.get("components")) |cv| {
            if (cv == .array) {
                for (cv.array.items) |item| {
                    try components.append(alloc, try parseComponent(alloc, item));
                }
            }
        }

        var functions: std.ArrayList(FunctionSpec) = .empty;
        if (obj.get("functions")) |fv| {
            if (fv == .array) {
                for (fv.array.items) |item| {
                    try functions.append(alloc, try parseFunction(alloc, item));
                }
            }
        }

        var crons: std.ArrayList(CronSpec) = .empty;
        if (obj.get("crons")) |crv| {
            if (crv == .array) {
                for (crv.array.items) |item| {
                    if (item != .object) continue;
                    const cname = getOptionalStr(item.object, "name");
                    const fn_name = getOptionalStr(item.object, "fn_name");
                    const args_json = if (item.object.get("args_json")) |av| (if (av == .string) av.string else "{}") else "{}";
                    const iv_ms: i64 = if (item.object.get("interval_ms")) |iv| (if (iv == .integer) iv.integer else 0) else 0;
                    if (cname.len > 0 and fn_name.len > 0 and iv_ms > 0) {
                        try crons.append(alloc, .{
                            .name = cname,
                            .interval_ms = iv_ms,
                            .fn_name = fn_name,
                            .args_json = args_json,
                        });
                    }
                }
            }
        }

        var http_routes: std.ArrayList(HttpRouteSpec) = .empty;
        if (obj.get("http_routes")) |hrv| {
            if (hrv == .array) {
                for (hrv.array.items) |item| {
                    if (item != .object) continue;
                    const method = getOptionalStr(item.object, "method");
                    const route_path = getOptionalStr(item.object, "path");
                    if (method.len > 0 and route_path.len > 0) {
                        try http_routes.append(alloc, .{
                            .method = method,
                            .path = route_path,
                        });
                    }
                }
            }
        }

        return .{
            .arena = arena,
            .raw_json = raw_copy,
            .app_name = app_name,
            .tables = try tables.toOwnedSlice(alloc),
            .components = try components.toOwnedSlice(alloc),
            .functions = try functions.toOwnedSlice(alloc),
            .crons = try crons.toOwnedSlice(alloc),
            .http_routes = try http_routes.toOwnedSlice(alloc),
        };
    }

    pub fn findTable(self: *const AppManifest, namespace: []const u8, table_name: []const u8) ?*const TableSpec {
        if (std.mem.eql(u8, namespace, "_system")) {
            if (std.mem.eql(u8, table_name, "_scheduled_jobs")) return &system_scheduled_jobs_table;
            if (std.mem.eql(u8, table_name, "_storage")) return &system_storage_table;
            return null;
        }
        if (namespace.len == 0) {
            for (self.tables) |*t| {
                if (std.mem.eql(u8, t.name, table_name)) return t;
            }
            return null;
        }
        for (self.components) |*c| {
            if (std.mem.eql(u8, c.namespace, namespace)) {
                for (c.tables) |*t| {
                    if (std.mem.eql(u8, t.name, table_name)) return t;
                }
            }
        }
        return null;
    }

    pub fn findFunction(self: *const AppManifest, name: []const u8) ?*const FunctionSpec {
        for (self.functions) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    pub fn matchHttpRoute(self: *const AppManifest, method: []const u8, req_path: []const u8) ?*const HttpRouteSpec {
        for (self.http_routes) |*r| {
            const method_ok = std.mem.eql(u8, r.method, "*") or std.ascii.eqlIgnoreCase(r.method, method);
            if (!method_ok) continue;
            if (std.mem.endsWith(u8, r.path, "*")) {
                const prefix = r.path[0 .. r.path.len - 1];
                if (std.mem.startsWith(u8, req_path, prefix)) return r;
            } else if (std.mem.eql(u8, r.path, req_path)) {
                return r;
            }
        }
        return null;
    }
};

fn getRequiredStr(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.InvalidManifest;
    if (v != .string) return error.InvalidManifest;
    return v.string;
}

fn getOptionalStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

fn parseTable(alloc: Allocator, val: std.json.Value) !TableSpec {
    if (val != .object) return error.InvalidManifest;
    const obj = val.object;
    const name = try getRequiredStr(obj, "name");
    const doc_schema = if (obj.get("document_schema")) |ds| try parseSchema(alloc, ds) else .any_t;

    var indexes: std.ArrayList(IndexSpec) = .empty;
    if (obj.get("indexes")) |iv| {
        if (iv == .array) {
            for (iv.array.items) |idx_val| {
                if (idx_val != .object) return error.InvalidManifest;
                const idx_name = try getRequiredStr(idx_val.object, "name");
                var fields: std.ArrayList([]const u8) = .empty;
                if (idx_val.object.get("fields")) |farr| {
                    if (farr == .array) {
                        for (farr.array.items) |f| {
                            if (f != .string) return error.InvalidManifest;
                            try fields.append(alloc, f.string);
                        }
                    }
                }
                try indexes.append(alloc, .{
                    .name = idx_name,
                    .fields = try fields.toOwnedSlice(alloc),
                });
            }
        }
    }

    return .{
        .name = name,
        .document_schema = doc_schema,
        .indexes = try indexes.toOwnedSlice(alloc),
    };
}

fn parseComponent(alloc: Allocator, val: std.json.Value) !ComponentSpec {
    if (val != .object) return error.InvalidManifest;
    const obj = val.object;
    const namespace = try getRequiredStr(obj, "namespace");
    const package = getOptionalStr(obj, "package");

    var tables: std.ArrayList(TableSpec) = .empty;
    if (obj.get("tables")) |tv| {
        if (tv == .array) {
            for (tv.array.items) |t| {
                try tables.append(alloc, try parseTable(alloc, t));
            }
        }
    }

    return .{
        .namespace = namespace,
        .package = package,
        .tables = try tables.toOwnedSlice(alloc),
    };
}

fn parseFunction(alloc: Allocator, val: std.json.Value) !FunctionSpec {
    if (val != .object) return error.InvalidManifest;
    const obj = val.object;
    return .{
        .name = try getRequiredStr(obj, "name"),
        .kind = try FunctionKind.fromStr(try getRequiredStr(obj, "kind")),
        .namespace = getOptionalStr(obj, "namespace"),
        .args_schema = if (obj.get("args_schema")) |s| try parseSchema(alloc, s) else .any_t,
        .returns_schema = if (obj.get("returns_schema")) |s| try parseSchema(alloc, s) else .any_t,
    };
}

fn parseSchema(alloc: Allocator, val: std.json.Value) !SchemaType {
    if (val != .object) return error.InvalidManifest;
    const obj = val.object;
    const kind = try getRequiredStr(obj, "kind");

    if (std.mem.eql(u8, kind, "null")) return .null_t;
    if (std.mem.eql(u8, kind, "bool")) return .bool_t;
    if (std.mem.eql(u8, kind, "int")) return .int_t;
    if (std.mem.eql(u8, kind, "float")) return .float_t;
    if (std.mem.eql(u8, kind, "str")) return .str_t;
    if (std.mem.eql(u8, kind, "any")) return .any_t;

    if (std.mem.eql(u8, kind, "id")) {
        return .{ .id_t = .{
            .table = try getRequiredStr(obj, "table"),
            .namespace = getOptionalStr(obj, "namespace"),
        } };
    }
    if (std.mem.eql(u8, kind, "list")) {
        const item_v = obj.get("item") orelse return error.InvalidManifest;
        const ptr = try alloc.create(SchemaType);
        ptr.* = try parseSchema(alloc, item_v);
        return .{ .list_t = ptr };
    }
    if (std.mem.eql(u8, kind, "optional")) {
        const inner_v = obj.get("inner") orelse return error.InvalidManifest;
        const ptr = try alloc.create(SchemaType);
        ptr.* = try parseSchema(alloc, inner_v);
        return .{ .optional_t = ptr };
    }
    if (std.mem.eql(u8, kind, "record")) {
        var fields: std.ArrayList(FieldSpec) = .empty;
        if (obj.get("fields")) |farr| {
            if (farr == .array) {
                for (farr.array.items) |fv| {
                    if (fv != .object) return error.InvalidManifest;
                    const opt = if (fv.object.get("optional")) |ov| (ov == .bool and ov.bool) else false;
                    try fields.append(alloc, .{
                        .name = try getRequiredStr(fv.object, "name"),
                        .schema = try parseSchema(alloc, fv.object.get("schema") orelse return error.InvalidManifest),
                        .optional = opt,
                    });
                }
            }
        }
        return .{ .record_t = try fields.toOwnedSlice(alloc) };
    }
    if (std.mem.eql(u8, kind, "union")) {
        var variants: std.ArrayList(VariantSpec) = .empty;
        if (obj.get("variants")) |varr| {
            if (varr == .array) {
                for (varr.array.items) |vv| {
                    if (vv != .object) return error.InvalidManifest;
                    var payload: ?*SchemaType = null;
                    if (vv.object.get("payload")) |pv| {
                        if (pv != .null) {
                            const ptr = try alloc.create(SchemaType);
                            ptr.* = try parseSchema(alloc, pv);
                            payload = ptr;
                        }
                    }
                    try variants.append(alloc, .{
                        .tag = try getRequiredStr(vv.object, "tag"),
                        .payload = payload,
                    });
                }
            }
        }
        return .{ .union_t = try variants.toOwnedSlice(alloc) };
    }
    return .any_t;
}
