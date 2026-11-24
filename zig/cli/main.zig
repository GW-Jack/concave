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
    if (isHelpFlag(cmd)) {
        printUsage();
        return;
    }
    if (std.mem.eql(u8, cmd, "codegen")) {
        var entry: []const u8 = "backend/main.roc";
        var out_dir: []const u8 = "frontend/src/_generated";
        var opt: []const u8 = "dev";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (isHelpFlag(args[i])) {
                printCodegenUsage();
                return;
            } else if (std.mem.eql(u8, args[i], "--entry") and i + 1 < args.len) {
                i += 1;
                entry = args[i];
            } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
                i += 1;
                out_dir = args[i];
            } else if (std.mem.eql(u8, args[i], "--opt") and i + 1 < args.len) {
                i += 1;
                opt = args[i];
            } else {
                std.debug.print("Unknown or incomplete option for `concave codegen`: {s}\n\n", .{args[i]});
                printCodegenUsage();
                std.process.exit(2);
            }
        }
        const bin = try defaultDevBin(gpa, entry);
        defer gpa.free(bin);
        buildRocApp(gpa, io, entry, bin, opt) catch std.process.exit(1);
        var manifest = introspectBinary(gpa, io, bin) catch std.process.exit(1);
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
            if (isHelpFlag(args[i])) {
                printBuildUsage();
                return;
            } else if (std.mem.eql(u8, args[i], "--entry") and i + 1 < args.len) {
                i += 1;
                entry = args[i];
            } else if ((std.mem.eql(u8, args[i], "--output") or std.mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
                i += 1;
                output = args[i];
            } else if (std.mem.eql(u8, args[i], "--opt") and i + 1 < args.len) {
                i += 1;
                opt = args[i];
            } else {
                std.debug.print("Unknown or incomplete option for `concave build`: {s}\n\n", .{args[i]});
                printBuildUsage();
                std.process.exit(2);
            }
        }
        buildRocApp(gpa, io, entry, output, opt) catch std.process.exit(1);
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
            if (isHelpFlag(args[i])) {
                printDevUsage();
                return;
            } else if (std.mem.eql(u8, args[i], "--entry") and i + 1 < args.len) {
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
            } else {
                std.debug.print("Unknown or incomplete option for `concave dev`: {s}\n\n", .{args[i]});
                printDevUsage();
                std.process.exit(2);
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
        var dir: ?[]const u8 = null;
        var template: []const u8 = "minimal";
        var platform: []const u8 = "./platform/main.roc";
        var sdk: []const u8 = "./packages/concave-sdk/main.roc";
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (isHelpFlag(args[i])) {
                printInitUsage();
                return;
            } else if (std.mem.eql(u8, args[i], "--template") and i + 1 < args.len) {
                i += 1;
                template = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--template=")) {
                template = args[i]["--template=".len..];
            } else if (std.mem.eql(u8, args[i], "--platform") and i + 1 < args.len) {
                i += 1;
                platform = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--platform=")) {
                platform = args[i]["--platform=".len..];
            } else if (std.mem.eql(u8, args[i], "--sdk") and i + 1 < args.len) {
                i += 1;
                sdk = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--sdk=")) {
                sdk = args[i]["--sdk=".len..];
            } else if (std.mem.startsWith(u8, args[i], "-")) {
                std.debug.print("Unknown or incomplete option for `concave init`: {s}\n\n", .{args[i]});
                printInitUsage();
                std.process.exit(2);
            } else if (dir == null) {
                dir = args[i];
            } else {
                std.debug.print("Unexpected positional argument for `concave init`: {s}\n\n", .{args[i]});
                printInitUsage();
                std.process.exit(2);
            }
        }
        const target_dir = dir orelse {
            printInitUsage();
            std.process.exit(2);
        };
        try scaffoldApp(gpa, io, target_dir, template, platform, sdk);
        std.debug.print("Initialized Concave app ({s} template) in {s}\n", .{ template, target_dir });
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{cmd});
        printUsage();
        std.process.exit(2);
    }
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn printUsage() void {
    std.debug.print(
        \\Concave — Zero-Dependency Reactive Roc Platform CLI
        \\
        \\Commands:
        \\  codegen  Build Roc app, run --introspect, emit api.js / api.d.ts / dataModel.d.ts
        \\  dev      Watch .roc files, rebuild, run codegen, and supervise the live server
        \\  build    Build a standalone native Concave server executable
        \\  init     Scaffold a new Concave app (--template minimal|chat|kanban)
        \\
        \\Run `concave <command> --help` for subcommand options.
        \\
    , .{});
}

fn printCodegenUsage() void {
    std.debug.print(
        \\Usage: concave codegen [--entry <path>] [--out <dir>] [--opt dev|size|speed]
        \\
        \\Options:
        \\  --entry <path>   Roc backend entrypoint (default: backend/main.roc)
        \\  --out <dir>      Output directory for api.js / api.d.ts / dataModel.d.ts (default: frontend/src/_generated)
        \\  --opt <mode>     Roc optimization level: dev, size, or speed (default: dev)
        \\
    , .{});
}

fn printBuildUsage() void {
    std.debug.print(
        \\Usage: concave build [--entry <path>] [--output|-o <path>] [--opt dev|size|speed]
        \\
        \\Options:
        \\  --entry <path>   Roc backend entrypoint (default: backend/main.roc)
        \\  -o, --output     Output binary path (default: .concave/server)
        \\  --opt <mode>     Roc optimization level: dev, size, or speed (default: speed)
        \\
    , .{});
}

fn printDevUsage() void {
    std.debug.print(
        \\Usage: concave dev [options]
        \\
        \\Options:
        \\  --entry <path>          Roc backend entrypoint (default: backend/main.roc)
        \\  --out <dir>             Codegen output directory (default: frontend/src/_generated)
        \\  --host <addr>           Bind address (default: 127.0.0.1)
        \\  --port <port>           Listen port (default: 3210)
        \\  --db <path>             Local WAL database path (default: .concave/dev.wal)
        \\  --database-url <url>    PostgreSQL connection URL (overrides --db)
        \\  --deployment-id <id>    Deployment namespace (default: default)
        \\  --static-dir <dir>      Serve static frontend files with live reload
        \\  --opt <mode>            Roc optimization level (default: dev)
        \\
    , .{});
}

fn printInitUsage() void {
    std.debug.print(
        \\Usage: concave init <dir> [--template minimal|chat|kanban] [--platform <path>] [--sdk <path>]
        \\
        \\Options:
        \\  --template <name>   Starter template: minimal, chat, or kanban (default: minimal)
        \\  --platform <path>   Relative path or URL to platform/main.roc (from <dir>/backend/main.roc)
        \\  --sdk <path>        Relative path or URL to packages/concave-sdk/main.roc
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
            std.debug.print("--introspect exited {d}:\n{s}\n", .{ code, res.stderr });
            return error.IntrospectFailed;
        },
        .signal => |sig| {
            std.debug.print("--introspect killed by signal {any}:\n{s}\n", .{ sig, res.stderr });
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
        try argv.appendSlice(allocator, &.{ "--static-dir", sd, "--live-reload" });
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
    var attempted = false;
    while (true) {
        const fp = computeRocFingerprint(allocator, io, watch_dir);
        if (!attempted or fp != last_fp) {
            attempted = true;
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

fn scaffoldApp(
    allocator: Allocator,
    io: std.Io,
    dir: []const u8,
    template: []const u8,
    platform: []const u8,
    sdk: []const u8,
) !void {
    const backend_dir = try std.fs.path.join(allocator, &.{ dir, "backend" });
    defer allocator.free(backend_dir);
    try std.Io.Dir.cwd().createDirPath(io, backend_dir);

    const frontend_src = try std.fs.path.join(allocator, &.{ dir, "frontend", "src" });
    defer allocator.free(frontend_src);
    try std.Io.Dir.cwd().createDirPath(io, frontend_src);

    const roc_content = if (std.mem.eql(u8, template, "kanban"))
        try std.fmt.allocPrint(
            allocator,
            \\app [concave_app] {{
            \\    pf: platform "{s}",
            \\    sdk: "{s}",
            \\}}
            \\
            \\import sdk.App
            \\import sdk.Ctx
            \\import sdk.Db
            \\import sdk.Key
            \\import sdk.Schema
            \\import sdk.Table
            \\
            \\CardDoc : {{
            \\    id : Str,
            \\    created_at : I64,
            \\    title : Str,
            \\    column : Str,
            \\    assignee : Str,
            \\}}
            \\
            \\cards_schema : Schema
            \\cards_schema = Schema.record([
            \\    Schema.field("title", Schema.str),
            \\    Schema.field("column", Schema.str),
            \\    Schema.field("assignee", Schema.str),
            \\])
            \\
            \\cards_table : Table(CardDoc)
            \\cards_table =
            \\    Table.define("cards", cards_schema)
            \\    |> Table.with_index("by_column", ["column"])
            \\
            \\list_cards! : Ctx.QueryCtx, {{}} => Try(Str, Str)
            \\list_cards! = |ctx, _|
            \\    Db.query(cards_table) |> Db.asc() |> Db.collect_raw!(ctx.db)
            \\
            \\create_card! : Ctx.MutationCtx, {{ title : Str, column : Str, assignee : Str }} => Try(Str, Str)
            \\create_card! = |ctx, args| {{
            \\    trimmed = Str.trim(args.title)
            \\    if Str.is_empty(trimmed) {{
            \\        return Err("Card title cannot be empty")
            \\    }}
            \\    Db.insert!(ctx.db, cards_table, {{
            \\        title: trimmed,
            \\        column: args.column,
            \\        assignee: args.assignee,
            \\    }})
            \\}}
            \\
            \\move_card! : Ctx.MutationCtx, {{ id : Str, column : Str }} => Try({{}}, Str)
            \\move_card! = |ctx, args|
            \\    Db.patch!(ctx.db, cards_table, args.id, {{ column: args.column }})
            \\
            \\delete_card! : Ctx.MutationCtx, {{ id : Str }} => Try({{}}, Str)
            \\delete_card! = |ctx, args|
            \\    Db.delete!(ctx.db, cards_table, args.id)
            \\
            \\concave_app : () -> App
            \\concave_app = ||
            \\    App.new("concave-kanban")
            \\    |> App.table(cards_table)
            \\    |> App.query_raw("cards.list", Schema.record([]), Schema.list(Table.doc_schema(cards_table)), list_cards!)
            \\    |> App.mutation(
            \\        "cards.create",
            \\        Schema.record([
            \\            Schema.field("title", Schema.str),
            \\            Schema.field("column", Schema.str),
            \\            Schema.field("assignee", Schema.str),
            \\        ]),
            \\        Schema.id("cards"),
            \\        create_card!,
            \\    )
            \\    |> App.mutation(
            \\        "cards.move",
            \\        Schema.record([
            \\            Schema.field("id", Schema.id("cards")),
            \\            Schema.field("column", Schema.str),
            \\        ]),
            \\        Schema.record([]),
            \\        move_card!,
            \\    )
            \\    |> App.mutation(
            \\        "cards.delete",
            \\        Schema.record([Schema.field("id", Schema.id("cards"))]),
            \\        Schema.record([]),
            \\        delete_card!,
            \\    )
            \\
        ,
            .{ platform, sdk },
        )
    else if (std.mem.eql(u8, template, "chat"))
        try std.fmt.allocPrint(
            allocator,
            \\app [concave_app] {{
            \\    pf: platform "{s}",
            \\    sdk: "{s}",
            \\}}
            \\
            \\import sdk.App
            \\import sdk.Ctx
            \\import sdk.Db
            \\import sdk.Key
            \\import sdk.Schema
            \\import sdk.Table
            \\
            \\MessageDoc : {{
            \\    id : Str,
            \\    created_at : I64,
            \\    room : Str,
            \\    author : Str,
            \\    body : Str,
            \\}}
            \\
            \\messages_schema : Schema
            \\messages_schema = Schema.record([
            \\    Schema.field("room", Schema.str),
            \\    Schema.field("author", Schema.str),
            \\    Schema.field("body", Schema.str),
            \\])
            \\
            \\messages_table : Table(MessageDoc)
            \\messages_table =
            \\    Table.define("messages", messages_schema)
            \\    |> Table.with_index("by_room", ["room"])
            \\
            \\by_room : Table.Index(MessageDoc)
            \\by_room = Table.index_ref(messages_table, "by_room")
            \\
            \\list_messages! : Ctx.QueryCtx, {{ room : Str }} => Try(Str, Str)
            \\list_messages! = |ctx, args|
            \\    Db.from_index(by_room)
            \\    |> Db.eq([Key.str(args.room)])
            \\    |> Db.asc()
            \\    |> Db.take(100)
            \\    |> Db.collect_raw!(ctx.db)
            \\
            \\send_message! : Ctx.MutationCtx, {{ room : Str, author : Str, body : Str }} => Try(Str, Str)
            \\send_message! = |ctx, args| {{
            \\    trimmed = Str.trim(args.body)
            \\    if Str.is_empty(trimmed) {{
            \\        return Err("Message cannot be empty")
            \\    }}
            \\    Db.insert!(ctx.db, messages_table, {{
            \\        room: args.room,
            \\        author: args.author,
            \\        body: trimmed,
            \\    }})
            \\}}
            \\
            \\concave_app : () -> App
            \\concave_app = ||
            \\    App.new("concave-chat-starter")
            \\    |> App.table(messages_table)
            \\    |> App.query_raw(
            \\        "messages.list",
            \\        Schema.record([Schema.field("room", Schema.str)]),
            \\        Schema.list(Table.doc_schema(messages_table)),
            \\        list_messages!,
            \\    )
            \\    |> App.mutation(
            \\        "messages.send",
            \\        Schema.record([
            \\            Schema.field("room", Schema.str),
            \\            Schema.field("author", Schema.str),
            \\            Schema.field("body", Schema.str),
            \\        ]),
            \\        Schema.id("messages"),
            \\        send_message!,
            \\    )
            \\
        ,
            .{ platform, sdk },
        )
    else
        try std.fmt.allocPrint(
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
            \\list_notes! : Ctx.QueryCtx, {{}} => Try(Str, Str)
            \\list_notes! = |ctx, _|
            \\    Db.query(notes_table) |> Db.desc() |> Db.collect_raw!(ctx.db)
            \\
            \\add_note! : Ctx.MutationCtx, {{ text : Str }} => Try(Str, Str)
            \\add_note! = |ctx, args|
            \\    Db.insert!(ctx.db, notes_table, {{ text: args.text }})
            \\
            \\concave_app : () -> App
            \\concave_app = ||
            \\    App.new("my-concave-app")
            \\    |> App.table(notes_table)
            \\    |> App.query_raw("notes.list", Schema.record([]), Schema.list(Table.doc_schema(notes_table)), list_notes!)
            \\    |> App.mutation("notes.add", Schema.record([Schema.field("text", Schema.str)]), Schema.id("notes"), add_note!)
            \\
        ,
            .{ platform, sdk },
        );
    defer allocator.free(roc_content);

    const main_path = try std.fs.path.join(allocator, &.{ backend_dir, "main.roc" });
    defer allocator.free(main_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = roc_content });

    // Write zero-dependency reactive frontend starter (`frontend/index.html` + `frontend/src/main.js`).
    const html_path = try std.fs.path.join(allocator, &.{ dir, "frontend", "index.html" });
    defer allocator.free(html_path);
    const extra_css = if (std.mem.eql(u8, template, "kanban"))
        "    .cols { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; margin-top: 1rem; }\n    .col { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 0.75rem; }\n"
    else
        "";
    const html_data = try std.fmt.allocPrint(
        allocator,
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8" />
        \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
        \\  <title>Concave App</title>
        \\  <style>
        \\    body {{ font-family: system-ui, -apple-system, sans-serif; max-width: 820px; margin: 2rem auto; padding: 0 1rem; background: #0f1115; color: #e6edf3; }}
        \\    input, button {{ padding: 0.5rem 0.75rem; border-radius: 6px; border: 1px solid #30363d; background: #161b22; color: #e6edf3; }}
        \\    button {{ background: #238636; border-color: #2ea043; cursor: pointer; }}
        \\{s}    .card {{ background: #21262d; padding: 0.6rem; border-radius: 6px; margin-bottom: 0.5rem; display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }}
        \\    a {{ color: #58a6ff; }}
        \\  </style>
        \\</head>
        \\<body>
        \\  <div id="app"></div>
        \\  <script type="module" src="/src/main.js"></script>
        \\</body>
        \\</html>
        \\
    ,
        .{extra_css},
    );
    defer allocator.free(html_data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = html_path, .data = html_data });

    const js_data = if (std.mem.eql(u8, template, "kanban"))
        \\import { ConcaveClient, bindValue, each, mount, signal, tags } from "/_concave/index.js";
        \\import { createApi } from "./_generated/api.js";
        \\
        \\const { a, button, div, form, h1, h3, input, p, span } = tags;
        \\const client = new ConcaveClient(window.location.origin);
        \\const db = createApi(client);
        \\const cards = db.cards.list();
        \\const draft = signal("");
        \\const COLS = ["todo", "doing", "done"];
        \\
        \\mount(document.getElementById("app"), () => div(
        \\  h1("Concave Live Kanban"),
        \\  p("Open a second tab — every move syncs live. ", a({ href: "/_dashboard", target: "_blank" }, "Open Dashboard")),
        \\  form({
        \\    onSubmit: async (e) => {
        \\      e.preventDefault();
        \\      const title = draft().trim();
        \\      if (!title) return;
        \\      draft.set("");
        \\      await db.cards.create({ title, column: "todo", assignee: "you" });
        \\    },
        \\  },
        \\    input({ placeholder: "New task...", style: "width: 65%; margin-right: 0.5rem;", ...bindValue(draft) }),
        \\    button({ type: "submit" }, "Add Card"),
        \\  ),
        \\  div({ class: "cols" }, ...COLS.map((col) =>
        \\    div({ class: "col" },
        \\      h3(col.toUpperCase()),
        \\      each(() => (cards().data ?? []).filter((c) => c.column === col), (c) => c.id, (card) =>
        \\        div({ class: "card" },
        \\          span(() => card().title),
        \\          div(
        \\            col !== "done" ? button({ onClick: () => db.cards.move({ id: card().id, column: COLS[COLS.indexOf(col) + 1] }) }, "→") : "",
        \\          ),
        \\        ),
        \\      ),
        \\    ),
        \\  )),
        \\));
        \\
    else if (std.mem.eql(u8, template, "chat"))
        \\import { ConcaveClient, bindValue, each, mount, signal, tags } from "/_concave/index.js";
        \\import { createApi } from "./_generated/api.js";
        \\
        \\const { a, button, div, form, h1, input, p, span } = tags;
        \\const client = new ConcaveClient(window.location.origin);
        \\const db = createApi(client);
        \\const messages = db.messages.list({ room: "general" });
        \\const draft = signal("");
        \\
        \\mount(document.getElementById("app"), () => div(
        \\  h1("Concave Live Chat (#general)"),
        \\  p("Zero npm dependencies. ", a({ href: "/_dashboard", target: "_blank" }, "Open Dashboard")),
        \\  div(
        \\    each(() => messages().data ?? [], (m) => m.id, (msg) =>
        \\      div({ class: "card" }, span(() => `${msg().author}: ${msg().body}`)),
        \\    ),
        \\  ),
        \\  form({
        \\    onSubmit: async (e) => {
        \\      e.preventDefault();
        \\      const body = draft().trim();
        \\      if (!body) return;
        \\      draft.set("");
        \\      await db.messages.send({ room: "general", author: "You", body });
        \\    },
        \\  },
        \\    input({ placeholder: "Say hi...", style: "width: 70%; margin-right: 0.5rem;", ...bindValue(draft) }),
        \\    button({ type: "submit" }, "Send"),
        \\  ),
        \\));
        \\
    else
        \\import { ConcaveClient, bindValue, each, mount, signal, tags } from "/_concave/index.js";
        \\import { createApi } from "./_generated/api.js";
        \\
        \\const { a, button, div, form, h1, input, p, span } = tags;
        \\const client = new ConcaveClient(window.location.origin);
        \\const db = createApi(client);
        \\const notes = db.notes.list();
        \\const draft = signal("");
        \\
        \\mount(document.getElementById("app"), () => div(
        \\  h1("Concave Live Notes"),
        \\  p("Zero npm dependencies. ", a({ href: "/_dashboard", target: "_blank" }, "Open Dashboard")),
        \\  form({
        \\    onSubmit: async (e) => {
        \\      e.preventDefault();
        \\      const text = draft().trim();
        \\      if (!text) return;
        \\      draft.set("");
        \\      await db.notes.add({ text });
        \\    },
        \\  },
        \\    input({ placeholder: "Write a note...", style: "width: 70%; margin-right: 0.5rem;", ...bindValue(draft) }),
        \\    button({ type: "submit" }, "Add"),
        \\  ),
        \\  div({ style: "margin-top: 1rem;" },
        \\    each(() => notes().data ?? [], (n) => n.id, (note) =>
        \\      div({ class: "card" }, span(() => note().text)),
        \\    ),
        \\  ),
        \\));
        \\
    ;

    const js_path = try std.fs.path.join(allocator, &.{ frontend_src, "main.js" });
    defer allocator.free(js_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = js_path, .data = js_data });
}
