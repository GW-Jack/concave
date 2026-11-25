const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 0. Build-time zero-dependency asset bundler, JS/CSS/HTML minifier, ETag & gzip pre-compressor.
    const asset_tool_mod = b.createModule(.{
        .root_source_file = b.path("zig/tools/minify_assets.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const asset_tool = b.addExecutable(.{
        .name = "minify_assets",
        .root_module = asset_tool_mod,
    });
    const run_assets = b.addRunArtifact(asset_tool);
    const embedded_assets_file = run_assets.addOutputFileArg("embedded_assets.zig");
    run_assets.addFileArg(b.path("client/concave-client/src/signals.js"));
    run_assets.addFileArg(b.path("client/concave-client/src/client.js"));
    run_assets.addFileArg(b.path("client/concave-client/src/dom.js"));
    run_assets.addFileArg(b.path("client/concave-client/src/router.js"));
    run_assets.addFileArg(b.path("packages/auth/client.js"));
    run_assets.addFileArg(b.path("packages/analytics/client.js"));
    run_assets.addFileArg(b.path("packages/monitor/client.js"));
    run_assets.addFileArg(b.path("client/concave-dashboard/index.html"));
    run_assets.addFileArg(b.path("client/concave-dashboard/styles.css"));
    run_assets.addFileArg(b.path("client/concave-dashboard/app.js"));

    const embedded_assets_mod = b.createModule(.{
        .root_source_file = embedded_assets_file,
    });

    // 1. Native Roc 0.1.0_RC1 static library host (`libhost.a`) — ZERO third-party dependencies!
    const host_mod = b.createModule(.{
        .root_source_file = b.path("zig/host_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    host_mod.addImport("embedded_assets", embedded_assets_mod);

    const host_lib = b.addLibrary(.{
        .name = "host",
        .linkage = .static,
        .root_module = host_mod,
    });
    host_lib.bundle_compiler_rt = true;
    b.installArtifact(host_lib);

    // 2. Zero-dependency `concave` CLI (`init`, `dev`, `codegen`, `build`)
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("zig/cli_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_exe = b.addExecutable(.{
        .name = "concave",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // 3. Wave 3 PostgreSQL vs WalStore differential test runner (`zig build pg-diff`)
    const pg_diff_mod = b.createModule(.{
        .root_source_file = b.path("zig/pg_diff_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pg_diff_exe = b.addExecutable(.{
        .name = "pg-diff",
        .root_module = pg_diff_mod,
    });
    const install_pg_diff = b.addInstallArtifact(pg_diff_exe, .{});
    const pg_diff_step = b.step("pg-diff", "Build the Wave 3 Postgres vs WalStore differential verifier");
    pg_diff_step.dependOn(&install_pg_diff.step);

    // 4. All Zig unit, DST, crash-recovery, and fuzz-corpus tests (`zig build test`)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("zig/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("embedded_assets", embedded_assets_mod);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);

    const secrets_test_mod = b.createModule(.{
        .root_source_file = b.path("zig/core/secrets.zig"),
        .target = target,
        .optimize = optimize,
    });
    const secrets_tests = b.addTest(.{
        .root_module = secrets_test_mod,
    });
    const run_secrets_tests = b.addRunArtifact(secrets_tests);

    const rate_limit_test_mod = b.createModule(.{
        .root_source_file = b.path("zig/runtime/rate_limit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rate_limit_tests = b.addTest(.{
        .root_module = rate_limit_test_mod,
    });
    const run_rate_limit_tests = b.addRunArtifact(rate_limit_tests);

    const test_step = b.step("test", "Run all Concave Zig unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_secrets_tests.step);
    test_step.dependOn(&run_rate_limit_tests.step);
}
