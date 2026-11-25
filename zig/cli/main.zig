const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest_mod = @import("../core/manifest.zig");
const codegen_mod = @import("../codegen/codegen.zig");
const secrets_mod = @import("../core/secrets.zig");
const wal_store = @import("../core/wal_store.zig");

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
        codegen_mod.writeGeneratedFiles(gpa, io, &manifest, out_dir) catch |err| {
            std.debug.print("Error writing generated files to `{s}`: {s}\n", .{ out_dir, @errorName(err) });
            std.process.exit(1);
        };
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

        try runDevLoop(gpa, io, init.environ_map, .{
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
        var sdk_provided = false;
        var auth_opt: ?[]const u8 = null;
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
                sdk_provided = true;
            } else if (std.mem.startsWith(u8, args[i], "--sdk=")) {
                sdk = args[i]["--sdk=".len..];
                sdk_provided = true;
            } else if (std.mem.eql(u8, args[i], "--auth") and i + 1 < args.len) {
                i += 1;
                auth_opt = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--auth=")) {
                auth_opt = args[i]["--auth=".len..];
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
        const derived_auth: ?[]u8 = if (auth_opt == null and sdk_provided)
            try deriveSiblingAuthPkg(gpa, sdk)
        else
            null;
        defer if (derived_auth) |p| gpa.free(p);
        const auth_pkg: []const u8 = auth_opt orelse derived_auth orelse "../../packages/auth/main.roc";
        scaffoldApp(gpa, io, target_dir, template, platform, sdk, auth_pkg) catch |err| {
            std.debug.print("Error initializing Concave app in `{s}`: {s}\n", .{ target_dir, @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("Initialized Concave app ({s} template) in {s}\n", .{ template, target_dir });
    } else if (std.mem.eql(u8, cmd, "backup")) {
        var db_path: ?[]const u8 = null;
        var out_path: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (isHelpFlag(args[i])) {
                printBackupUsage();
                return;
            } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
                i += 1;
                db_path = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--db=")) {
                db_path = args[i]["--db=".len..];
            } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
                i += 1;
                out_path = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--out=")) {
                out_path = args[i]["--out=".len..];
            } else {
                std.debug.print("Unknown or incomplete option for `concave backup`: {s}\n\n", .{args[i]});
                printBackupUsage();
                std.process.exit(2);
            }
        }
        const src_db = db_path orelse {
            std.debug.print("Missing required option `--db <wal_path>` for `concave backup`\n\n", .{});
            printBackupUsage();
            std.process.exit(2);
        };
        const dst_out = out_path orelse {
            std.debug.print("Missing required option `--out <backup_path>` for `concave backup`\n\n", .{});
            printBackupUsage();
            std.process.exit(2);
        };
        validatePathArg("--db", src_db) catch {
            printBackupUsage();
            std.process.exit(2);
        };
        validatePathArg("--out", dst_out) catch {
            printBackupUsage();
            std.process.exit(2);
        };
        const written = wal_store.backupWalFile(io, gpa, src_db, dst_out) catch |err| {
            std.debug.print("Error backing up WAL `{s}` to `{s}`: {s}\n", .{ src_db, dst_out, @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("Backed up WAL `{s}` -> `{s}` ({d} bytes)\n", .{ src_db, dst_out, written });
    } else if (std.mem.eql(u8, cmd, "restore")) {
        var in_path: ?[]const u8 = null;
        var db_path: ?[]const u8 = null;
        var force = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (isHelpFlag(args[i])) {
                printRestoreUsage();
                return;
            } else if (std.mem.eql(u8, args[i], "--in") and i + 1 < args.len) {
                i += 1;
                in_path = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--in=")) {
                in_path = args[i]["--in=".len..];
            } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
                i += 1;
                db_path = args[i];
            } else if (std.mem.startsWith(u8, args[i], "--db=")) {
                db_path = args[i]["--db=".len..];
            } else if (std.mem.eql(u8, args[i], "--force")) {
                force = true;
            } else {
                std.debug.print("Unknown or incomplete option for `concave restore`: {s}\n\n", .{args[i]});
                printRestoreUsage();
                std.process.exit(2);
            }
        }
        const src_in = in_path orelse {
            std.debug.print("Missing required option `--in <backup_path>` for `concave restore`\n\n", .{});
            printRestoreUsage();
            std.process.exit(2);
        };
        const dst_db = db_path orelse {
            std.debug.print("Missing required option `--db <wal_path>` for `concave restore`\n\n", .{});
            printRestoreUsage();
            std.process.exit(2);
        };
        validatePathArg("--in", src_in) catch {
            printRestoreUsage();
            std.process.exit(2);
        };
        validatePathArg("--db", dst_db) catch {
            printRestoreUsage();
            std.process.exit(2);
        };
        if (!force) {
            if (std.Io.Dir.cwd().statFile(io, dst_db, .{})) |_| {
                std.debug.print(
                    "Refusing to overwrite existing database `{s}`. Pass --force to overwrite.\n",
                    .{dst_db},
                );
                std.process.exit(1);
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    std.debug.print("Error checking destination `{s}`: {s}\n", .{ dst_db, @errorName(err) });
                    std.process.exit(1);
                },
            }
        }
        const restored = wal_store.restoreWalFile(io, gpa, src_in, dst_db) catch |err| {
            std.debug.print("Error restoring WAL `{s}` to `{s}`: {s}\n", .{ src_in, dst_db, @errorName(err) });
            std.process.exit(1);
        };
        std.debug.print("Restored WAL `{s}` -> `{s}` ({d} bytes)\n", .{ src_in, dst_db, restored });
    } else if (std.mem.eql(u8, cmd, "secrets")) {
        if (args.len < 3 or isHelpFlag(args[2])) {
            printSecretsUsage();
            return;
        }
        const sub = args[2];
        var vault_path: []const u8 = init.environ_map.get("CONCAVE_SECRETS_VAULT") orelse ".concave/dev.vault";
        var passphrase: ?[]const u8 = init.environ_map.get("CONCAVE_VAULT_PASSPHRASE");

        if (std.mem.eql(u8, sub, "set")) {
            var secret_name: ?[]const u8 = null;
            var secret_value: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (isHelpFlag(args[i])) {
                    printSecretsUsage();
                    return;
                } else if (std.mem.eql(u8, args[i], "--vault") and i + 1 < args.len) {
                    i += 1;
                    vault_path = args[i];
                } else if (std.mem.eql(u8, args[i], "--value") and i + 1 < args.len) {
                    i += 1;
                    secret_value = args[i];
                } else if (std.mem.eql(u8, args[i], "--passphrase") and i + 1 < args.len) {
                    i += 1;
                    passphrase = args[i];
                } else if (!std.mem.startsWith(u8, args[i], "-") and secret_name == null) {
                    secret_name = args[i];
                } else {
                    std.debug.print("Unknown or incomplete option for `concave secrets set`: {s}\n\n", .{args[i]});
                    printSecretsUsage();
                    std.process.exit(2);
                }
            }
            const name = secret_name orelse {
                printSecretsUsage();
                std.process.exit(2);
            };
            const val = secret_value orelse {
                std.debug.print("Missing required `--value <secret>` for `concave secrets set`\n\n", .{});
                printSecretsUsage();
                std.process.exit(2);
            };
            validatePathArg("--vault", vault_path) catch std.process.exit(2);
            secrets_mod.vaultSet(io, gpa, vault_path, passphrase, name, val) catch |err| {
                std.debug.print("Error setting secret `{s}` in `{s}`: {s}\n", .{ name, vault_path, @errorName(err) });
                std.process.exit(1);
            };
            std.debug.print("Encrypted and stored secret `{s}` in `{s}`\n", .{ name, vault_path });
        } else if (std.mem.eql(u8, sub, "list")) {
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (isHelpFlag(args[i])) {
                    printSecretsUsage();
                    return;
                } else if (std.mem.eql(u8, args[i], "--vault") and i + 1 < args.len) {
                    i += 1;
                    vault_path = args[i];
                } else if (std.mem.eql(u8, args[i], "--passphrase") and i + 1 < args.len) {
                    i += 1;
                    passphrase = args[i];
                } else {
                    printSecretsUsage();
                    std.process.exit(2);
                }
            }
            validatePathArg("--vault", vault_path) catch std.process.exit(2);
            const names = secrets_mod.vaultList(io, gpa, vault_path, passphrase) catch |err| {
                std.debug.print("Error listing secrets in `{s}`: {s}\n", .{ vault_path, @errorName(err) });
                std.process.exit(1);
            };
            defer {
                for (names) |n| gpa.free(n);
                gpa.free(names);
            }
            for (names) |n| std.debug.print("{s}\n", .{n});
        } else if (std.mem.eql(u8, sub, "delete")) {
            var secret_name: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (isHelpFlag(args[i])) {
                    printSecretsUsage();
                    return;
                } else if (std.mem.eql(u8, args[i], "--vault") and i + 1 < args.len) {
                    i += 1;
                    vault_path = args[i];
                } else if (std.mem.eql(u8, args[i], "--passphrase") and i + 1 < args.len) {
                    i += 1;
                    passphrase = args[i];
                } else if (!std.mem.startsWith(u8, args[i], "-") and secret_name == null) {
                    secret_name = args[i];
                } else {
                    printSecretsUsage();
                    std.process.exit(2);
                }
            }
            const name = secret_name orelse {
                printSecretsUsage();
                std.process.exit(2);
            };
            validatePathArg("--vault", vault_path) catch std.process.exit(2);
            const deleted = secrets_mod.vaultDelete(io, gpa, vault_path, passphrase, name) catch |err| {
                std.debug.print("Error deleting secret `{s}` from `{s}`: {s}\n", .{ name, vault_path, @errorName(err) });
                std.process.exit(1);
            };
            if (deleted) {
                std.debug.print("Deleted secret `{s}` from `{s}`\n", .{ name, vault_path });
            } else {
                std.debug.print("Secret `{s}` not found in `{s}`\n", .{ name, vault_path });
            }
        } else {
            printSecretsUsage();
            std.process.exit(2);
        }
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
        \\  init     Scaffold a new Concave app (--template minimal|chat|kanban|auth)
        \\  backup   Create a compacted, checksum-valid atomic backup of a local WAL database
        \\  restore  Verify and atomically restore a WAL backup to a target database path
        \\  secrets  Manage offline encrypted local dev vault secrets (set|list|delete)
        \\
        \\Run `concave <command> --help` for subcommand options.
        \\
    , .{});
}

fn printSecretsUsage() void {
    std.debug.print(
        \\Usage:
        \\  concave secrets set <NAME> --value <VALUE> [--vault <path>] [--passphrase <pass>]
        \\  concave secrets list [--vault <path>] [--passphrase <pass>]
        \\  concave secrets delete <NAME> [--vault <path>] [--passphrase <pass>]
        \\
        \\Notes:
        \\  Stores secrets encrypted with XChaCha20-Poly1305 (default: .concave/dev.vault)
        \\  for offline local dev. In production, use Google Cloud Secret Manager (`CONCAVE_GCP_PROJECT`).
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
        \\Usage: concave init <dir> [--template minimal|chat|kanban|auth] [--platform <path>] [--sdk <path>] [--auth <path>]
        \\
        \\Options:
        \\  --template <name>   Starter template: minimal, chat, kanban, or auth (default: minimal)
        \\  --platform <path>   Relative path or URL to platform/main.roc (from <dir>/backend/main.roc)
        \\  --sdk <path>        Relative path or URL to packages/concave-sdk/main.roc
        \\  --auth <path>       Relative path or URL to packages/auth/main.roc (for --template auth)
        \\
    , .{});
}

fn printBackupUsage() void {
    std.debug.print(
        \\Usage: concave backup --db <wal_path> --out <backup_path>
        \\
        \\Options:
        \\  --db <path>    Source WAL database path (required)
        \\  --out <path>   Destination compacted backup file path (required)
        \\
    , .{});
}

fn printRestoreUsage() void {
    std.debug.print(
        \\Usage: concave restore --in <backup_path> --db <wal_path> [--force]
        \\
        \\Options:
        \\  --in <path>    Source WAL backup file path (required)
        \\  --db <path>    Destination WAL database path (required)
        \\  --force        Overwrite destination database if it already exists
        \\
    , .{});
}

fn validatePathArg(flag_name: []const u8, path: []const u8) !void {
    if (path.len == 0 or path[0] == '-' or std.mem.indexOfScalar(u8, path, 0) != null) {
        std.debug.print("Invalid {s} path `{s}` (must be non-empty and not start with `-`)\n", .{ flag_name, path });
        return error.InvalidOption;
    }
}

fn defaultDevBin(allocator: Allocator, entry: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(entry) orelse ".";
    const parent_base = std.fs.path.basename(parent);
    const base = if (std.mem.eql(u8, parent_base, "backend"))
        (std.fs.path.dirname(parent) orelse ".")
    else
        parent;
    return try std.fs.path.join(allocator, &.{ base, ".concave", "dev-server" });
}

fn validateOptMode(opt: []const u8) !void {
    if (!std.mem.eql(u8, opt, "dev") and !std.mem.eql(u8, opt, "size") and !std.mem.eql(u8, opt, "speed")) {
        std.debug.print("Invalid --opt mode `{s}` (expected dev, size, or speed)\n", .{opt});
        return error.InvalidOption;
    }
}

fn validateRocSafeString(label: []const u8, val: []const u8) !void {
    if (val.len == 0) return error.InvalidOption;
    for (val) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c < 0x20) {
            std.debug.print("Invalid {s} value: contains disallowed characters\n", .{label});
            return error.InvalidOption;
        }
    }
}

fn buildRocApp(allocator: Allocator, io: std.Io, entry: []const u8, output: []const u8, opt: []const u8) !void {
    try validateOptMode(opt);
    if (entry.len == 0 or entry[0] == '-') {
        std.debug.print("Invalid --entry path `{s}` (must not start with `-`)\n", .{entry});
        return error.InvalidOption;
    }
    if (output.len == 0 or output[0] == '-') {
        std.debug.print("Invalid --output path `{s}` (must not start with `-`)\n", .{output});
        return error.InvalidOption;
    }
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

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

fn spawnServer(
    allocator: Allocator,
    io: std.Io,
    base_env: *const std.process.Environ.Map,
    bin: []const u8,
    opts: DevOptions,
) !std.process.Child {
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
    if (opts.static_dir) |sd| {
        try argv.appendSlice(allocator, &.{ "--static-dir", sd, "--live-reload" });
    }

    var child_env = try base_env.clone(allocator);
    defer child_env.deinit();
    // Pass database URL via environment variable rather than argv so credentials stay out of `ps`.
    if (opts.database_url) |url| {
        try child_env.put("DATABASE_URL", url);
    }
    // Enable dev tokens automatically only in `concave dev` when bound to loopback and not overridden.
    if (child_env.get("CONCAVE_ALLOW_DEV_TOKENS") == null and isLoopbackHost(opts.host)) {
        try child_env.put("CONCAVE_ALLOW_DEV_TOKENS", "true");
    }

    return try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &child_env,
    });
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

var g_dev_stop: std.atomic.Value(bool) = .init(false);

fn handleDevSignal(_: std.posix.SIG) callconv(.c) void {
    g_dev_stop.store(true, .release);
}

fn installDevSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = &handleDevSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

fn runDevLoop(allocator: Allocator, io: std.Io, base_env: *const std.process.Environ.Map, opts: DevOptions) !void {
    installDevSignalHandlers();
    const bin = try defaultDevBin(allocator, opts.entry);
    defer allocator.free(bin);
    const watch_dir = std.fs.path.dirname(opts.entry) orelse ".";

    var child: ?std.process.Child = null;
    defer if (child) |*c| c.kill(io);

    var last_fp: u64 = 0;
    var attempted = false;
    while (!g_dev_stop.load(.acquire)) {
        const fp = computeRocFingerprint(allocator, io, watch_dir);
        if (!attempted or fp != last_fp) {
            attempted = true;
            last_fp = fp;
            if (child) |*c| {
                c.kill(io);
                child = null;
            }
            if (g_dev_stop.load(.acquire)) break;
            std.debug.print("[concave dev] building {s}...\n", .{opts.entry});
            if (buildRocApp(allocator, io, opts.entry, bin, opts.opt)) |_| {
                if (g_dev_stop.load(.acquire)) break;
                if (introspectBinary(allocator, io, bin)) |mf| {
                    var manifest = mf;
                    defer manifest.deinit();
                    codegen_mod.writeGeneratedFiles(allocator, io, &manifest, opts.out_dir) catch |err| {
                        std.debug.print("[concave dev] codegen error: {s}\n", .{@errorName(err)});
                    };
                    if (g_dev_stop.load(.acquire)) break;
                    std.debug.print(
                        "[concave dev] codegen updated ({s}) — starting server on http://{s}:{s}\n",
                        .{ opts.out_dir, opts.host, opts.port },
                    );
                    child = spawnServer(allocator, io, base_env, bin, opts) catch |err| blk: {
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
        var ticks: usize = 0;
        while (ticks < 8 and !g_dev_stop.load(.acquire)) : (ticks += 1) {
            io.sleep(.fromMilliseconds(50), .awake) catch break;
        }
    }
}

fn deriveSiblingAuthPkg(allocator: Allocator, sdk_path: []const u8) ![]u8 {
    if (std.fs.path.dirname(sdk_path)) |sdk_dir| {
        if (std.fs.path.dirname(sdk_dir)) |pkgs_dir| {
            return try std.fmt.allocPrint(allocator, "{s}/auth/main.roc", .{std.mem.trimEnd(u8, pkgs_dir, "/")});
        }
        return try allocator.dupe(u8, "auth/main.roc");
    }
    return try allocator.dupe(u8, "../../packages/auth/main.roc");
}

fn scaffoldApp(
    allocator: Allocator,
    io: std.Io,
    dir: []const u8,
    template: []const u8,
    platform: []const u8,
    sdk: []const u8,
    auth_pkg: []const u8,
) !void {
    if (!std.mem.eql(u8, template, "minimal") and
        !std.mem.eql(u8, template, "chat") and
        !std.mem.eql(u8, template, "kanban") and
        !std.mem.eql(u8, template, "auth"))
    {
        std.debug.print("Invalid --template `{s}` (expected minimal, chat, kanban, or auth)\n", .{template});
        return error.InvalidOption;
    }
    try validateRocSafeString("--platform", platform);
    try validateRocSafeString("--sdk", sdk);
    if (std.mem.eql(u8, template, "auth")) {
        try validateRocSafeString("--auth", auth_pkg);
    }

    const backend_dir = try std.fs.path.join(allocator, &.{ dir, "backend" });
    defer allocator.free(backend_dir);
    try std.Io.Dir.cwd().createDirPath(io, backend_dir);

    const frontend_src = try std.fs.path.join(allocator, &.{ dir, "frontend", "src" });
    defer allocator.free(frontend_src);
    try std.Io.Dir.cwd().createDirPath(io, frontend_src);

    const roc_content = if (std.mem.eql(u8, template, "auth"))
        try std.fmt.allocPrint(
            allocator,
            \\app [concave_app] {{
            \\    pf: platform "{s}",
            \\    sdk: "{s}",
            \\    auth: "{s}",
            \\}}
            \\
            \\import sdk.App
            \\import sdk.Ctx
            \\import sdk.Db
            \\import sdk.Key
            \\import sdk.Schema
            \\import sdk.Table
            \\import auth.Auth
            \\
            \\## Mounted Auth v2 component (`auth` namespace: password + OTP + Ed25519 JWKS).
            \\## Store an Ed25519 signing seed before signing in:
            \\##   concave secrets set AUTH_JWT_PRIVATE_KEY --value <64-hex-char-seed>
            \\app_auth : Auth.Mount
            \\app_auth =
            \\    Auth.mount("auth")
            \\    |> Auth.with_expose_otp_for_dev(True)
            \\    |> Auth.with_secure_cookies(False)
            \\
            \\UserDoc : {{
            \\    id : Str,
            \\    created_at : I64,
            \\    user_id : Str,
            \\    email : Str,
            \\    display_name : Str,
            \\    bio : Str,
            \\}}
            \\
            \\users_schema : Schema
            \\users_schema = Schema.record([
            \\    Schema.field("user_id", Schema.str),
            \\    Schema.field("email", Schema.str),
            \\    Schema.field("display_name", Schema.str),
            \\    Schema.field("bio", Schema.str),
            \\])
            \\
            \\users_table : Table(UserDoc)
            \\users_table =
            \\    Table.define("users", users_schema)
            \\    |> Table.with_index("by_user_id", ["user_id"])
            \\
            \\users_by_user_id : Table.Index(UserDoc)
            \\users_by_user_id = Table.index_ref(users_table, "by_user_id")
            \\
            \\MeResult : {{
            \\    user_id : Str,
            \\    session_id : Str,
            \\    email : Str,
            \\    display_name : Str,
            \\    bio : Str,
            \\}}
            \\
            \\me_result_schema : Schema
            \\me_result_schema = Schema.record([
            \\    Schema.field("user_id", Schema.str),
            \\    Schema.field("session_id", Schema.str),
            \\    Schema.field("email", Schema.str),
            \\    Schema.field("display_name", Schema.str),
            \\    Schema.field("bio", Schema.str),
            \\])
            \\
            \\me_query! : Ctx.QueryCtx, {{}} => Try(MeResult, Str)
            \\me_query! = |ctx, _| {{
            \\    id = Auth.require_active_session!(app_auth, ctx)?
            \\    found =
            \\        Db.from_index(users_by_user_id)
            \\        |> Db.eq([Key.str(id.subject)])
            \\        |> Db.first!(ctx.db)?
            \\    match found {{
            \\        Found(doc) =>
            \\            Ok({{
            \\                user_id: id.subject,
            \\                session_id: id.session_id,
            \\                email: id.email,
            \\                display_name: doc.display_name,
            \\                bio: doc.bio,
            \\            }})
            \\        NotFound =>
            \\            Ok({{
            \\                user_id: id.subject,
            \\                session_id: id.session_id,
            \\                email: id.email,
            \\                display_name: id.name,
            \\                bio: "",
            \\            }})
            \\    }}
            \\}}
            \\
            \\upsert_profile! : Ctx.MutationCtx, {{ display_name : Str, bio : Str }} => Try(Str, Str)
            \\upsert_profile! = |ctx, args| {{
            \\    id = Auth.require_active_session_mut!(app_auth, ctx)?
            \\    existing =
            \\        Db.from_index(users_by_user_id)
            \\        |> Db.eq([Key.str(id.subject)])
            \\        |> Db.first!(ctx.db)?
            \\    match existing {{
            \\        Found(doc) => {{
            \\            Db.patch!(ctx.db, users_table, doc.id, {{
            \\                display_name: Str.trim(args.display_name),
            \\                bio: Str.trim(args.bio),
            \\            }})?
            \\            Ok(doc.id)
            \\        }}
            \\        NotFound =>
            \\            Db.insert!(ctx.db, users_table, {{
            \\                user_id: id.subject,
            \\                email: id.email,
            \\                display_name: Str.trim(args.display_name),
            \\                bio: Str.trim(args.bio),
            \\            }})
            \\    }}
            \\}}
            \\
            \\concave_app : () -> App
            \\concave_app = ||
            \\    App.new("concave-auth-starter")
            \\    |> App.table(users_table)
            \\    |> Auth.attach_with_cron(app_auth, 3600000)
            \\    |> App.query("users.me", Schema.record([]), me_result_schema, me_query!)
            \\    |> App.mutation(
            \\        "users.upsertProfile",
            \\        Schema.record([
            \\            Schema.field("display_name", Schema.str),
            \\            Schema.field("bio", Schema.str),
            \\        ]),
            \\        Schema.id("users"),
            \\        upsert_profile!,
            \\    )
            \\
        ,
            .{ platform, sdk, auth_pkg },
        )
    else if (std.mem.eql(u8, template, "kanban"))
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
    else if (std.mem.eql(u8, template, "auth"))
        "    nav { display: flex; gap: 1rem; margin-bottom: 1rem; }\n    .panel { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; display: grid; gap: 0.6rem; }\n    .row { display: flex; gap: 0.5rem; flex-wrap: wrap; }\n    .err { color: #f85149; }\n    .muted { color: #8b949e; font-size: 0.9rem; }\n"
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

    const js_data = if (std.mem.eql(u8, template, "auth"))
        \\import { ConcaveClient, bindValue, createRouter, each, el, mount, show, signal } from "/_concave/index.js";
        \\import { createAuth } from "/_concave/auth.js";
        \\import { api, createApi } from "./_generated/api.js";
        \\
        \\const client = new ConcaveClient(window.location.origin);
        \\const db = createApi(client);
        \\const auth = createAuth(client, api.auth, { storage: window.localStorage });
        \\auth.consumeOAuthCallback();
        \\
        \\const router = createRouter([
        \\  { path: "/", name: "home" },
        \\  { path: "/login", name: "login" },
        \\]);
        \\
        \\const me = db.users.me(() => (client.isAuthenticated() ? {} : null));
        \\const sessions = auth.subscribeSessions();
        \\
        \\const email = signal("");
        \\const password = signal("");
        \\const name = signal("");
        \\const otpCode = signal("");
        \\const otpHint = signal("");
        \\const displayName = signal("");
        \\const bio = signal("");
        \\const errMsg = signal("");
        \\
        \\async function runAuth(fn) {
        \\  errMsg.set("");
        \\  try {
        \\    await fn();
        \\    router.navigate("/");
        \\  } catch (e) {
        \\    errMsg.set(e?.message ?? String(e));
        \\  }
        \\}
        \\
        \\mount(document.getElementById("app"), () =>
        \\  el("div", null,
        \\    el("h1", null, "Concave Auth v2 Starter"),
        \\    el("nav", null,
        \\      router.link("/", "Home"),
        \\      router.link("/login", "Sign In / Sign Up"),
        \\      el("a", { href: "/.well-known/jwks.json", target: "_blank" }, "JWKS"),
        \\      el("a", { href: "/_dashboard", target: "_blank" }, "Dashboard"),
        \\    ),
        \\    show(() => !!errMsg(), () => el("p", { class: "err" }, () => errMsg())),
        \\    show(
        \\      () => router.current().route?.name === "login",
        \\      () =>
        \\        el("div", null,
        \\          el("form", {
        \\            class: "panel",
        \\            onSubmit: (e) => {
        \\              e.preventDefault();
        \\              runAuth(() => auth.signInPassword({ email: email(), password: password() }));
        \\            },
        \\          },
        \\            el("h3", null, "Email & Password"),
        \\            el("input", { placeholder: "Email", type: "email", ...bindValue(email) }),
        \\            el("input", { placeholder: "Password (min 8 chars)", type: "password", ...bindValue(password) }),
        \\            el("input", { placeholder: "Name (for sign up)", ...bindValue(name) }),
        \\            el("div", { class: "row" },
        \\              el("button", { type: "submit" }, "Sign In"),
        \\              el("button", {
        \\                type: "button",
        \\                onClick: () => runAuth(() => auth.signUpPassword({ email: email(), password: password(), name: name() })),
        \\              }, "Sign Up"),
        \\            ),
        \\          ),
        \\          el("form", {
        \\            class: "panel",
        \\            onSubmit: (e) => {
        \\              e.preventDefault();
        \\              runAuth(() => auth.verifyOtp({ email: email(), code: otpCode(), name: name() }));
        \\            },
        \\          },
        \\            el("h3", null, "Email OTP"),
        \\            el("div", { class: "row" },
        \\              el("button", {
        \\                type: "button",
        \\                onClick: async () => {
        \\                  errMsg.set("");
        \\                  try {
        \\                    const res = await auth.requestOtp(email());
        \\                    otpHint.set(res.dev_code ? `Dev OTP: ${res.dev_code}` : "OTP sent!");
        \\                  } catch (e) {
        \\                    errMsg.set(e?.message ?? String(e));
        \\                  }
        \\                },
        \\              }, "Send 6-Digit Code"),
        \\              el("span", { class: "muted" }, () => otpHint()),
        \\            ),
        \\            el("input", { placeholder: "6-digit code", ...bindValue(otpCode) }),
        \\            el("button", { type: "submit" }, "Verify OTP & Sign In"),
        \\          ),
        \\        ),
        \\      () =>
        \\        show(
        \\          () => client.isAuthenticated(),
        \\          () =>
        \\            el("div", null,
        \\              el("div", { class: "panel" },
        \\                el("h3", null, "Your Profile"),
        \\                el("p", null, () => {
        \\                  const d = me().data;
        \\                  return d ? `${d.display_name || d.email} (${d.email}) — ${d.bio || "no bio yet"}` : "Loading profile...";
        \\                }),
        \\                el("form", {
        \\                  class: "row",
        \\                  onSubmit: async (e) => {
        \\                    e.preventDefault();
        \\                    await db.users.upsertProfile({ display_name: displayName(), bio: bio() });
        \\                  },
        \\                },
        \\                  el("input", { placeholder: "Display name", ...bindValue(displayName) }),
        \\                  el("input", { placeholder: "Bio", ...bindValue(bio) }),
        \\                  el("button", { type: "submit" }, "Save Profile"),
        \\                ),
        \\                el("div", { class: "row" },
        \\                  el("button", { onClick: () => auth.signOut() }, "Sign Out"),
        \\                  el("button", { onClick: () => auth.signOutAll() }, "Sign Out All Devices"),
        \\                ),
        \\              ),
        \\              el("div", { class: "panel" },
        \\                el("h3", null, "Active Sessions"),
        \\                each(() => sessions().data ?? [], (s) => s.id, (sess) =>
        \\                  el("div", { class: "card" },
        \\                    el("span", null, () => `${sess().id}${sess().is_current ? " (current)" : ""}`),
        \\                    el("span", { class: "muted" }, () => sess().user_agent || "unknown agent"),
        \\                  ),
        \\                ),
        \\              ),
        \\            ),
        \\          () =>
        \\            el("div", { class: "panel" },
        \\              el("p", null, "You are signed out. ", router.link("/login", "Sign in or create an account →")),
        \\            ),
        \\        ),
        \\    ),
        \\  ),
        \\);
        \\
    else if (std.mem.eql(u8, template, "kanban"))
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
