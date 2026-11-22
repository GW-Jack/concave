const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest_mod = @import("../core/manifest.zig");
const codegen_mod = @import("../codegen/codegen.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "codegen")) {
        var entry: []const u8 = "backend/main.roc";
        var out_dir: []const u8 = "frontend/src/_generated";
        var opt: []const u8 = "dev";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--entry") and i + 1 < args.len) {
                i += 1;
                entry = args[i];
            } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
                i += 1;
                out_dir = args[i];
            } else if (std.mem.eql(u8, args[i], "--opt") and i + 1 < args.len) {
                i += 1;
                opt = args[i];
            }
        }
        const bin = try defaultDevBin(gpa, entry);
        defer gpa.free(bin);
        try buildRocApp(gpa, io, entry, bin, opt);
        var manifest = try introspectBinary(gpa, io, bin);
        defer manifest.deinit();
        try codegen_mod.writeGeneratedFiles(gpa, io, &manifest, out_dir);
        std.debug.print(
            "Generated {s}/dataModel.d.ts, {s}/api.d.ts, and {s}/api.js ({d} tables, {d} components, {d} functions)\n",
            .{ out_dir, out_dir, out_dir, manifest.tables.len, manifest.components.len, manifest.functions.len },
        );
    } else if (std.mem.eql(u8, cmd, "build")) {
        var entry: []const u8 = "backend/main.roc";
        var output: []const u8 = ".concave/server";
        var opt: []const u8 = "speed";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--entry") and i + 1 < args.len) {
                i += 1;
                entry = args[i];
            } else if ((std.mem.eql(u8, args[i], "--output") or std.mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
                i += 1;
                output = args[i];
            } else if (std.mem.eql(u8, args[i], "--opt") and i + 1 < args.len) {
                i += 1;
                opt = args[i];
            }
        }
        try buildRocApp(gpa, io, entry, output, opt);
        std.debug.print("Built standalone Concave server binary: {s}\n", .{output});
    } else if (std.mem.eql(u8, cmd, "dev")) {
        var entry: []const u8 = "backend/main.roc";
        var out_dir: []const u8 = "frontend/src/_generated";
        var host: []const u8 = "127.0.0.1";
        var port: []const u8 = "3210";
        var db: []const u8 = ".concave/dev.wal";
        var database_url: ?[]const u8 = null;
        var deployment_id: []const u8 = "default";
        var static_dir: ?[]const u8 = null;
        var opt: []const u8 = "dev";

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--entry") and i + 1 < args.len) {
                i += 1;
                entry = args[i];
            } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
                i += 1;
                out_dir = args[i];
            } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
                i += 1;
                host = args[i];
            } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
                i += 1;
                port = args[i];
            } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
                i += 1;
                db = args[i];
            } else if (std.mem.eql(u8, args[i], "--database-url") and i + 1 < args.len) {
                i += 1;
                database_url = args[i];
            } else if (std.mem.eql(u8, args[i], "--deployment-id") and i + 1 < args.len) {
                i += 1;
                deployment_id = args[i];
            } else if (std.mem.eql(u8, args[i], "--static-dir") and i + 1 < args.len) {
                i += 1;
                static_dir = args[i];
            } else if (std.mem.eql(u8, args[i], "--opt") and i + 1 < args.len) {
                i += 1;
                opt = args[i];
            }
        }

        try runDevLoop(gpa, io, .{
            .entry = entry,
            .out_dir = out_dir,
            .host = host,
            .port = port,
            .db = db,
            .database_url = database_url,
            .deployment_id = deployment_id,
            .static_dir = static_dir,
            .opt = opt,
        });
    } else if (std.mem.eql(u8, cmd, "init")) {
        if (args.len < 3) {
            std.debug.print("Usage: concave init <dir> [--platform <path>] [--sdk <path>]\n", .{});
            return;
        }
        const dir = args[2];
        var platform: []const u8 = "./platform/main.roc";
        var sdk: []const u8 = "./packages/concave-sdk/main.roc";
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--platform") and i + 1 < args.len) {
                i += 1;
                platform = args[i];
            } else if (std.mem.eql(u8, args[i], "--sdk") and i + 1 < args.len) {
                i += 1;
                sdk = args[i];
            }
        }
        try scaffoldApp(gpa, io, dir, platform, sdk);
        std.debug.print("Initialized Concave app in {s}\n", .{dir});
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Concave — Zero-Dependency Reactive Roc Platform CLI
        \\
        \\Commands:
        \\  codegen  Build Roc app, run --introspect, emit api.js / api.d.ts / dataModel.d.ts
        \\  dev      Watch .roc files, rebuild, run codegen, and supervise the live server
        \\  build    Build a standalone native Concave server executable
        \\  init     Scaffold a new Concave Roc application
        \\
    , .{});
}

fn defaultDevBin(allocator: Allocator, entry: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(entry) orelse ".";
    const base = std.fs.path.dirname(parent) orelse ".";
    return try std.fs.path.join(allocator, &.{ base, ".concave", "dev-server" });
}

fn buildRocApp(allocator: Allocator, io: std.Io, entry: []const u8, output: []const u8, opt: []const u8) !void {
    if (std.fs.path.dirname(output)) |dir| {
        if (dir.len > 0) try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    const opt_flag = try std.fmt.allocPrint(allocator, "--opt={s}", .{opt});
    defer allocator.free(opt_flag);
    const out_flag = try std.fmt.allocPrint(allocator, "--output={s}", .{output});
    defer allocator.free(out_flag);

    const res = try std.process.run(allocator, io, .{
        .argv = &.{ "roc", "build", opt_flag, out_flag, entry },
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    if (res.stdout.len > 0) std.debug.print("{s}", .{res.stdout});
    if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});

    switch (res.term) {
        .exited => |code| if (code != 0) return error.RocBuildFailed,
        else => return error.RocBuildFailed,
    }
}

fn introspectBinary(allocator: Allocator, io: std.Io, bin: []const u8) !manifest_mod.AppManifest {
    const res = try std.process.run(allocator, io, .{
        .argv = &.{ bin, "--introspect" },
    });
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);

    switch (res.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("--introspect failed:\n{s}\n", .{res.stderr});
            return error.IntrospectFailed;
        },
        else => return error.IntrospectFailed,
    }

    return try manifest_mod.AppManifest.parseJson(allocator, std.mem.trim(u8, res.stdout, " \t\r\n"));
}

const DevOptions = struct {
    entry: []const u8,
    out_dir: []const u8,
    host: []const u8,
    port: []const u8,
    db: []const u8,
    database_url: ?[]const u8,
    deployment_id: []const u8,
    static_dir: ?[]const u8,
    opt: []const u8,
};

fn spawnServer(allocator: Allocator, io: std.Io, bin: []const u8, opts: DevOptions) !std.process.Child {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        bin,
        "--serve",
        "--host",
        opts.host,
        "--port",
        opts.port,
        "--db",
        opts.db,
        "--deployment-id",
        opts.deployment_id,
    });
    if (opts.database_url) |url| {
        try argv.appendSlice(allocator, &.{ "--database-url", url });
    }
    if (opts.static_dir) |sd| {
        try argv.appendSlice(allocator, &.{ "--static-dir", sd });
    }
    return try std.process.spawn(io, .{ .argv = argv.items });
}

fn computeRocFingerprint(allocator: Allocator, io: std.Io, dir_path: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".roc")) continue;
        const stat = dir.statFile(io, entry.path, .{}) catch continue;
        h.update(entry.path);
        const mtime_ns: i96 = stat.mtime.nanoseconds;
        h.update(std.mem.asBytes(&mtime_ns));
        h.update(std.mem.asBytes(&stat.size));
    }
    return h.final();
}

fn runDevLoop(allocator: Allocator, io: std.Io, opts: DevOptions) !void {
    const bin = try defaultDevBin(allocator, opts.entry);
    defer allocator.free(bin);
    const watch_dir = std.fs.path.dirname(opts.entry) orelse ".";

    var child: ?std.process.Child = null;
    defer if (child) |*c| c.kill(io);

    var last_fp: u64 = 0;
    while (true) {
        const fp = computeRocFingerprint(allocator, io, watch_dir);
        if (fp != last_fp or child == null) {
            last_fp = fp;
            if (child) |*c| {
                c.kill(io);
                child = null;
            }
            std.debug.print("[concave dev] building {s}...\n", .{opts.entry});
            if (buildRocApp(allocator, io, opts.entry, bin, opts.opt)) |_| {
                if (introspectBinary(allocator, io, bin)) |mf| {
                    var manifest = mf;
                    defer manifest.deinit();
                    codegen_mod.writeGeneratedFiles(allocator, io, &manifest, opts.out_dir) catch |err| {
                        std.debug.print("[concave dev] codegen error: {s}\n", .{@errorName(err)});
                    };
                    std.debug.print(
                        "[concave dev] codegen updated ({s}) — starting server on http://{s}:{s}\n",
                        .{ opts.out_dir, opts.host, opts.port },
                    );
                    child = spawnServer(allocator, io, bin, opts) catch |err| blk: {
                        std.debug.print("[concave dev] failed to spawn server: {s}\n", .{@errorName(err)});
                        break :blk null;
                    };
                } else |err| {
                    std.debug.print("[concave dev] introspect failed: {s}\n", .{@errorName(err)});
                }
            } else |err| {
                std.debug.print("[concave dev] build failed ({s}) — watching for fixes...\n", .{@errorName(err)});
            }
        }
        io.sleep(.fromMilliseconds(400), .awake) catch break;
    }
}

fn scaffoldApp(allocator: Allocator, io: std.Io, dir: []const u8, platform: []const u8, sdk: []const u8) !void {
    const backend_dir = try std.fs.path.join(allocator, &.{ dir, "backend" });
    defer allocator.free(backend_dir);
    try std.Io.Dir.cwd().createDirPath(io, backend_dir);

    const content = try std.fmt.allocPrint(
        allocator,
        \\app [concave_app] {{
        \\    pf: platform "{s}",
        \\    sdk: "{s}",
        \\}}
        \\
        \\import sdk.App
        \\import sdk.Ctx
        \\import sdk.Db
        \\import sdk.Schema
        \\import sdk.Table
        \\
        \\NoteDoc : {{
        \\    id : Str,
        \\    created_at : I64,
        \\    text : Str,
        \\}}
        \\
        \\notes_schema : Schema
        \\notes_schema = Schema.record([
        \\    Schema.field("text", Schema.str),
        \\])
        \\
        \\notes_table : Table(NoteDoc)
        \\notes_table = Table.define("notes", notes_schema)
        \\
        \\list_notes! : Ctx.QueryCtx, {{}} => Try(List(NoteDoc), Str)
        \\list_notes! = |ctx, _|
        \\    Db.query(notes_table) |> Db.desc() |> Db.collect!(ctx.db)
        \\
        \\add_note! : Ctx.MutationCtx, {{ text : Str }} => Try(Str, Str)
        \\add_note! = |ctx, args|
        \\    Db.insert!(ctx.db, notes_table, {{ text: args.text }})
        \\
        \\concave_app : () -> App
        \\concave_app = ||
        \\    App.new("my-concave-app")
        \\    |> App.table(notes_table)
        \\    |> App.query("notes.list", Schema.record([]), Schema.list(Table.doc_schema(notes_table)), list_notes!)
        \\    |> App.mutation("notes.add", Schema.record([Schema.field("text", Schema.str)]), Schema.id("notes"), add_note!)
        \\
    ,
        .{ platform, sdk },
    );
    defer allocator.free(content);

    const main_path = try std.fs.path.join(allocator, &.{ backend_dir, "main.roc" });
    defer allocator.free(main_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = content });
}
