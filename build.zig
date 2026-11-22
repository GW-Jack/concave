const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Native Roc 0.1.0_RC1 static library host (`libhost.a`) — ZERO third-party dependencies!
    const host_mod = b.createModule(.{
        .root_source_file = b.path("zig/host_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    host_mod.addAnonymousImport("concave_client_index_js", .{
        .root_source_file = b.path("client/concave-client/src/index.js"),
    });
    host_mod.addAnonymousImport("concave_client_signals_js", .{
        .root_source_file = b.path("client/concave-client/src/signals.js"),
    });
    host_mod.addAnonymousImport("concave_client_client_js", .{
        .root_source_file = b.path("client/concave-client/src/client.js"),
    });
    host_mod.addAnonymousImport("concave_client_dom_js", .{
        .root_source_file = b.path("client/concave-client/src/dom.js"),
    });
    host_mod.addAnonymousImport("concave_analytics_client_js", .{
        .root_source_file = b.path("packages/analytics/client.js"),
    });
    host_mod.addAnonymousImport("concave_monitor_client_js", .{
        .root_source_file = b.path("packages/monitor/client.js"),
    });
    host_mod.addAnonymousImport("concave_dashboard_index_html", .{
        .root_source_file = b.path("client/concave-dashboard/index.html"),
    });
    host_mod.addAnonymousImport("concave_dashboard_styles_css", .{
        .root_source_file = b.path("client/concave-dashboard/styles.css"),
    });
    host_mod.addAnonymousImport("concave_dashboard_app_js", .{
        .root_source_file = b.path("client/concave-dashboard/app.js"),
    });

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
    test_mod.addAnonymousImport("concave_client_index_js", .{
        .root_source_file = b.path("client/concave-client/src/index.js"),
    });
    test_mod.addAnonymousImport("concave_client_signals_js", .{
        .root_source_file = b.path("client/concave-client/src/signals.js"),
    });
    test_mod.addAnonymousImport("concave_client_client_js", .{
        .root_source_file = b.path("client/concave-client/src/client.js"),
    });
    test_mod.addAnonymousImport("concave_client_dom_js", .{
        .root_source_file = b.path("client/concave-client/src/dom.js"),
    });
    test_mod.addAnonymousImport("concave_analytics_client_js", .{
        .root_source_file = b.path("packages/analytics/client.js"),
    });
    test_mod.addAnonymousImport("concave_monitor_client_js", .{
        .root_source_file = b.path("packages/monitor/client.js"),
    });
    test_mod.addAnonymousImport("concave_dashboard_index_html", .{
        .root_source_file = b.path("client/concave-dashboard/index.html"),
    });
    test_mod.addAnonymousImport("concave_dashboard_styles_css", .{
        .root_source_file = b.path("client/concave-dashboard/styles.css"),
    });
    test_mod.addAnonymousImport("concave_dashboard_app_js", .{
        .root_source_file = b.path("client/concave-dashboard/app.js"),
    });
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run all Concave Zig unit tests");
    test_step.dependOn(&run_tests.step);
}
