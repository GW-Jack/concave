const std = @import("std");
const Allocator = std.mem.Allocator;
const storage_mod = @import("../core/storage.zig");

/// Fixed latency histogram upper bounds in microseconds (matching Prometheus seconds buckets:
/// 1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, +Inf).
pub const BUCKET_BOUNDS_US = [_]u64{
    1_000,
    5_000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000,
};

pub const BUCKET_LABELS_SEC = [_][]const u8{
    "0.001",
    "0.005",
    "0.01",
    "0.025",
    "0.05",
    "0.1",
    "0.25",
    "0.5",
    "1",
    "2.5",
    "5",
};

fn zeroBuckets() [BUCKET_BOUNDS_US.len + 1]std.atomic.Value(u64) {
    var out: [BUCKET_BOUNDS_US.len + 1]std.atomic.Value(u64) = undefined;
    for (&out) |*b| b.* = .init(0);
    return out;
}

/// Lock-free, zero-allocation fixed-bucket latency histogram.
pub const LatencyHistogram = struct {
    /// Non-cumulative per-bucket counts (index `BUCKET_BOUNDS_US.len` is the +Inf overflow bucket).
    buckets: [BUCKET_BOUNDS_US.len + 1]std.atomic.Value(u64) = zeroBuckets(),
    count: std.atomic.Value(u64) = .init(0),
    sum_us: std.atomic.Value(u64) = .init(0),

    pub fn observeUs(self: *LatencyHistogram, duration_us: u64) void {
        _ = self.count.fetchAdd(1, .monotonic);
        _ = self.sum_us.fetchAdd(duration_us, .monotonic);
        for (BUCKET_BOUNDS_US, 0..) |bound, idx| {
            if (duration_us <= bound) {
                _ = self.buckets[idx].fetchAdd(1, .monotonic);
                return;
            }
        }
        _ = self.buckets[BUCKET_BOUNDS_US.len].fetchAdd(1, .monotonic);
    }

    pub fn avgMs(self: *const LatencyHistogram) f64 {
        const c = self.count.load(.monotonic);
        if (c == 0) return 0.0;
        const sum_us = self.sum_us.load(.monotonic);
        return (@as(f64, @floatFromInt(sum_us)) / @as(f64, @floatFromInt(c))) / 1000.0;
    }

    pub fn writePrometheus(self: *const LatencyHistogram, w: *std.Io.Writer, metric_name: []const u8, help: []const u8) !void {
        try w.print("# HELP {s} {s}\n", .{ metric_name, help });
        try w.print("# TYPE {s} histogram\n", .{metric_name});
        var cumulative: u64 = 0;
        for (BUCKET_LABELS_SEC, 0..) |le, idx| {
            cumulative += self.buckets[idx].load(.monotonic);
            try w.print("{s}_bucket{{le=\"{s}\"}} {d}\n", .{ metric_name, le, cumulative });
        }
        cumulative += self.buckets[BUCKET_BOUNDS_US.len].load(.monotonic);
        try w.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ metric_name, cumulative });

        const sum_sec = @as(f64, @floatFromInt(self.sum_us.load(.monotonic))) / 1_000_000.0;
        try w.print("{s}_sum {d:.6}\n", .{ metric_name, sum_sec });
        try w.print("{s}_count {d}\n", .{ metric_name, self.count.load(.monotonic) });
    }
};

pub const StatusSnapshotInput = struct {
    app_name: []const u8,
    storage_backend: []const u8,
    commit_ts: i64,
    last_broadcast_ts: i64,
    active_clients: usize,
    active_subscriptions: usize,
};

/// Lock-free platform operator telemetry owned by `ConcaveEngine`.
/// Zero heap allocations on the request hot path and completely independent of storage health.
pub const PlatformMetrics = struct {
    started_at_ms: i64 = 0,
    log_json: bool = false,

    // Function execution counters
    queries_total: std.atomic.Value(u64) = .init(0),
    queries_err_total: std.atomic.Value(u64) = .init(0),
    mutations_total: std.atomic.Value(u64) = .init(0),
    mutations_err_total: std.atomic.Value(u64) = .init(0),
    actions_total: std.atomic.Value(u64) = .init(0),
    actions_err_total: std.atomic.Value(u64) = .init(0),
    http_routes_total: std.atomic.Value(u64) = .init(0),
    http_routes_err_total: std.atomic.Value(u64) = .init(0),

    // OCC & storage counters
    occ_retries_total: std.atomic.Value(u64) = .init(0),
    occ_exhausted_total: std.atomic.Value(u64) = .init(0),
    storage_commits_total: std.atomic.Value(u64) = .init(0),
    storage_errors_total: std.atomic.Value(u64) = .init(0),

    // WebSocket & reactive fanout counters
    ws_connections_total: std.atomic.Value(u64) = .init(0),
    ws_invalidations_total: std.atomic.Value(u64) = .init(0),
    ws_transitions_sent_total: std.atomic.Value(u64) = .init(0),

    // Scheduler / cron counters
    scheduler_jobs_executed_total: std.atomic.Value(u64) = .init(0),
    scheduler_jobs_failed_total: std.atomic.Value(u64) = .init(0),

    // HTTP transport counters
    http_requests_total: std.atomic.Value(u64) = .init(0),
    http_4xx_total: std.atomic.Value(u64) = .init(0),
    http_5xx_total: std.atomic.Value(u64) = .init(0),

    // Latency histograms
    query_latency: LatencyHistogram = .{},
    mutation_latency: LatencyHistogram = .{},
    action_latency: LatencyHistogram = .{},
    commit_latency: LatencyHistogram = .{},
    fanout_latency: LatencyHistogram = .{},

    pub fn init(io: std.Io, log_json: bool) PlatformMetrics {
        return .{
            .started_at_ms = storage_mod.nowMillis(io),
            .log_json = log_json,
        };
    }

    pub fn nowMicros(io: std.Io) i64 {
        return @intCast(@divTrunc(std.Io.Clock.awake.now(io).toNanoseconds(), 1000));
    }

    pub fn elapsedUs(io: std.Io, start_us: i64) u64 {
        const end_us = nowMicros(io);
        return if (end_us > start_us) @intCast(end_us - start_us) else 0;
    }

    pub fn uptimeMs(self: *const PlatformMetrics, io: std.Io) i64 {
        const now = storage_mod.nowMillis(io);
        return if (now > self.started_at_ms) now - self.started_at_ms else 0;
    }

    pub fn recordHttpStatus(self: *PlatformMetrics, status: u16) void {
        _ = self.http_requests_total.fetchAdd(1, .monotonic);
        if (status >= 500) {
            _ = self.http_5xx_total.fetchAdd(1, .monotonic);
        } else if (status >= 400) {
            _ = self.http_4xx_total.fetchAdd(1, .monotonic);
        }
    }

    /// Emit a structured JSON log line to stderr when `CONCAVE_LOG_FORMAT=json` is enabled.
    /// Compatible with Google Cloud Run / Cloud Logging structured severity ingestion.
    pub fn logRpc(
        self: *const PlatformMetrics,
        io: std.Io,
        kind: []const u8,
        name: []const u8,
        duration_us: u64,
        ok: bool,
        occ_retries: usize,
        err_msg: ?[]const u8,
    ) void {
        if (!self.log_json) return;
        const severity = if (ok) "INFO" else "ERROR";
        const ts_ms = storage_mod.nowMillis(io);
        const dur_ms = @as(f64, @floatFromInt(duration_us)) / 1000.0;

        var buf: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print(
            "{{\"severity\":\"{s}\",\"ts_ms\":{d},\"event\":\"rpc\",\"kind\":\"{s}\",\"fn\":",
            .{ severity, ts_ms, kind },
        ) catch return;
        storage_mod.writeJsonString(&w, name) catch return;
        w.print(
            ",\"ok\":{s},\"duration_ms\":{d:.3},\"occ_retries\":{d}",
            .{ if (ok) "true" else "false", dur_ms, occ_retries },
        ) catch return;
        if (err_msg) |msg| {
            w.writeAll(",\"error\":") catch return;
            const capped = if (msg.len > 256) msg[0..256] else msg;
            storage_mod.writeJsonString(&w, capped) catch return;
        }
        w.writeAll("}\n") catch return;
        std.debug.print("{s}", .{w.buffered()});
    }

    /// Render Prometheus / OpenMetrics text exposition (`text/plain; version=0.0.4; charset=utf-8`).
    pub fn formatPrometheus(
        self: *const PlatformMetrics,
        allocator: Allocator,
        io: std.Io,
        snap: StatusSnapshotInput,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;

        const uptime_sec = @as(f64, @floatFromInt(self.uptimeMs(io))) / 1000.0;
        const commit_lag: i64 = if (snap.commit_ts > snap.last_broadcast_ts) snap.commit_ts - snap.last_broadcast_ts else 0;

        try w.writeAll("# HELP concave_up Whether the Concave runtime process is up.\n");
        try w.writeAll("# TYPE concave_up gauge\n");
        try w.print("concave_up{{storage=\"{s}\"}} 1\n", .{snap.storage_backend});

        try w.writeAll("# HELP concave_uptime_seconds Process uptime in seconds.\n");
        try w.writeAll("# TYPE concave_uptime_seconds gauge\n");
        try w.print("concave_uptime_seconds {d:.3}\n", .{uptime_sec});

        try w.writeAll("# HELP concave_commit_ts Latest durable storage commit timestamp.\n");
        try w.writeAll("# TYPE concave_commit_ts gauge\n");
        try w.print("concave_commit_ts {d}\n", .{snap.commit_ts});

        try w.writeAll("# HELP concave_commit_lag Commits pending reactive broadcast on this replica.\n");
        try w.writeAll("# TYPE concave_commit_lag gauge\n");
        try w.print("concave_commit_lag {d}\n", .{commit_lag});

        try w.writeAll("# HELP concave_active_clients Currently connected WebSocket clients.\n");
        try w.writeAll("# TYPE concave_active_clients gauge\n");
        try w.print("concave_active_clients {d}\n", .{snap.active_clients});

        try w.writeAll("# HELP concave_active_subscriptions Currently active reactive query subscriptions.\n");
        try w.writeAll("# TYPE concave_active_subscriptions gauge\n");
        try w.print("concave_active_subscriptions {d}\n", .{snap.active_subscriptions});

        try w.writeAll("# HELP concave_rpcs_total Total RPC executions by kind and outcome.\n");
        try w.writeAll("# TYPE concave_rpcs_total counter\n");
        const q_tot = self.queries_total.load(.monotonic);
        const q_err = self.queries_err_total.load(.monotonic);
        const m_tot = self.mutations_total.load(.monotonic);
        const m_err = self.mutations_err_total.load(.monotonic);
        const a_tot = self.actions_total.load(.monotonic);
        const a_err = self.actions_err_total.load(.monotonic);
        const h_tot = self.http_routes_total.load(.monotonic);
        const h_err = self.http_routes_err_total.load(.monotonic);
        try w.print("concave_rpcs_total{{kind=\"query\",status=\"ok\"}} {d}\n", .{q_tot -| q_err});
        try w.print("concave_rpcs_total{{kind=\"query\",status=\"error\"}} {d}\n", .{q_err});
        try w.print("concave_rpcs_total{{kind=\"mutation\",status=\"ok\"}} {d}\n", .{m_tot -| m_err});
        try w.print("concave_rpcs_total{{kind=\"mutation\",status=\"error\"}} {d}\n", .{m_err});
        try w.print("concave_rpcs_total{{kind=\"action\",status=\"ok\"}} {d}\n", .{a_tot -| a_err});
        try w.print("concave_rpcs_total{{kind=\"action\",status=\"error\"}} {d}\n", .{a_err});
        try w.print("concave_rpcs_total{{kind=\"http_route\",status=\"ok\"}} {d}\n", .{h_tot -| h_err});
        try w.print("concave_rpcs_total{{kind=\"http_route\",status=\"error\"}} {d}\n", .{h_err});

        try w.writeAll("# HELP concave_occ_retries_total Total OCC transaction conflict retries.\n");
        try w.writeAll("# TYPE concave_occ_retries_total counter\n");
        try w.print("concave_occ_retries_total {d}\n", .{self.occ_retries_total.load(.monotonic)});

        try w.writeAll("# HELP concave_occ_exhausted_total Total mutations aborted after exceeding max OCC retries.\n");
        try w.writeAll("# TYPE concave_occ_exhausted_total counter\n");
        try w.print("concave_occ_exhausted_total {d}\n", .{self.occ_exhausted_total.load(.monotonic)});

        try w.writeAll("# HELP concave_storage_commits_total Total committed storage transactions.\n");
        try w.writeAll("# TYPE concave_storage_commits_total counter\n");
        try w.print("concave_storage_commits_total {d}\n", .{self.storage_commits_total.load(.monotonic)});

        try w.writeAll("# HELP concave_storage_errors_total Total storage-level errors.\n");
        try w.writeAll("# TYPE concave_storage_errors_total counter\n");
        try w.print("concave_storage_errors_total {d}\n", .{self.storage_errors_total.load(.monotonic)});

        try w.writeAll("# HELP concave_ws_connections_total Total WebSocket connections accepted.\n");
        try w.writeAll("# TYPE concave_ws_connections_total counter\n");
        try w.print("concave_ws_connections_total {d}\n", .{self.ws_connections_total.load(.monotonic)});

        try w.writeAll("# HELP concave_ws_invalidations_total Total reactive commit invalidation broadcasts.\n");
        try w.writeAll("# TYPE concave_ws_invalidations_total counter\n");
        try w.print("concave_ws_invalidations_total {d}\n", .{self.ws_invalidations_total.load(.monotonic)});

        try w.writeAll("# HELP concave_ws_transitions_sent_total Total reactive transition frames sent to clients.\n");
        try w.writeAll("# TYPE concave_ws_transitions_sent_total counter\n");
        try w.print("concave_ws_transitions_sent_total {d}\n", .{self.ws_transitions_sent_total.load(.monotonic)});

        try w.writeAll("# HELP concave_scheduler_jobs_total Total scheduled/cron jobs processed by status.\n");
        try w.writeAll("# TYPE concave_scheduler_jobs_total counter\n");
        const j_tot = self.scheduler_jobs_executed_total.load(.monotonic);
        const j_err = self.scheduler_jobs_failed_total.load(.monotonic);
        try w.print("concave_scheduler_jobs_total{{status=\"ok\"}} {d}\n", .{j_tot -| j_err});
        try w.print("concave_scheduler_jobs_total{{status=\"error\"}} {d}\n", .{j_err});

        try w.writeAll("# HELP concave_http_requests_total Total HTTP responses served.\n");
        try w.writeAll("# TYPE concave_http_requests_total counter\n");
        try w.print("concave_http_requests_total {d}\n", .{self.http_requests_total.load(.monotonic)});
        try w.print("concave_http_errors_total{{class=\"4xx\"}} {d}\n", .{self.http_4xx_total.load(.monotonic)});
        try w.print("concave_http_errors_total{{class=\"5xx\"}} {d}\n", .{self.http_5xx_total.load(.monotonic)});

        try self.query_latency.writePrometheus(w, "concave_query_duration_seconds", "Query execution latency in seconds.");
        try self.mutation_latency.writePrometheus(w, "concave_mutation_duration_seconds", "Mutation end-to-end latency in seconds.");
        try self.action_latency.writePrometheus(w, "concave_action_duration_seconds", "Action execution latency in seconds.");
        try self.commit_latency.writePrometheus(w, "concave_storage_commit_duration_seconds", "Storage commitTx latency in seconds.");
        try self.fanout_latency.writePrometheus(w, "concave_ws_fanout_duration_seconds", "WebSocket invalidation fanout latency in seconds.");

        return try out.toOwnedSlice();
    }

    /// Render a structured JSON reliability snapshot for `/_internal/status`.
    pub fn formatStatusJson(
        self: *const PlatformMetrics,
        allocator: Allocator,
        io: std.Io,
        snap: StatusSnapshotInput,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        const w = &out.writer;

        const uptime_ms = self.uptimeMs(io);
        const commit_lag: i64 = if (snap.commit_ts > snap.last_broadcast_ts) snap.commit_ts - snap.last_broadcast_ts else 0;

        try w.writeAll("{\"status\":\"ok\",\"app_name\":");
        try storage_mod.writeJsonString(w, snap.app_name);
        try w.writeAll(",\"storage_backend\":");
        try storage_mod.writeJsonString(w, snap.storage_backend);
        try w.print(
            ",\"uptime_ms\":{d},\"commit_ts\":{d},\"last_broadcast_ts\":{d},\"commit_lag\":{d}," ++
                "\"active_clients\":{d},\"active_subscriptions\":{d}," ++
                "\"rpcs\":{{\"queries_total\":{d},\"queries_err\":{d},\"mutations_total\":{d},\"mutations_err\":{d}," ++
                "\"actions_total\":{d},\"actions_err\":{d},\"http_routes_total\":{d},\"http_routes_err\":{d}}}," ++
                "\"occ\":{{\"retries\":{d},\"exhausted\":{d}}}," ++
                "\"storage\":{{\"commits\":{d},\"errors\":{d}}}," ++
                "\"websocket\":{{\"connections_total\":{d},\"invalidations\":{d},\"transitions_sent\":{d}}}," ++
                "\"scheduler\":{{\"jobs_executed\":{d},\"jobs_failed\":{d}}}," ++
                "\"http\":{{\"requests_total\":{d},\"errors_4xx\":{d},\"errors_5xx\":{d}}}," ++
                "\"latency_avg_ms\":{{\"query\":{d:.3},\"mutation\":{d:.3},\"action\":{d:.3},\"commit\":{d:.3},\"fanout\":{d:.3}}}}}",
            .{
                uptime_ms,
                snap.commit_ts,
                snap.last_broadcast_ts,
                commit_lag,
                snap.active_clients,
                snap.active_subscriptions,
                self.queries_total.load(.monotonic),
                self.queries_err_total.load(.monotonic),
                self.mutations_total.load(.monotonic),
                self.mutations_err_total.load(.monotonic),
                self.actions_total.load(.monotonic),
                self.actions_err_total.load(.monotonic),
                self.http_routes_total.load(.monotonic),
                self.http_routes_err_total.load(.monotonic),
                self.occ_retries_total.load(.monotonic),
                self.occ_exhausted_total.load(.monotonic),
                self.storage_commits_total.load(.monotonic),
                self.storage_errors_total.load(.monotonic),
                self.ws_connections_total.load(.monotonic),
                self.ws_invalidations_total.load(.monotonic),
                self.ws_transitions_sent_total.load(.monotonic),
                self.scheduler_jobs_executed_total.load(.monotonic),
                self.scheduler_jobs_failed_total.load(.monotonic),
                self.http_requests_total.load(.monotonic),
                self.http_4xx_total.load(.monotonic),
                self.http_5xx_total.load(.monotonic),
                self.query_latency.avgMs(),
                self.mutation_latency.avgMs(),
                self.action_latency.avgMs(),
                self.commit_latency.avgMs(),
                self.fanout_latency.avgMs(),
            },
        );
        return try out.toOwnedSlice();
    }
};

test "LatencyHistogram buckets and Prometheus exposition" {
    const alloc = std.testing.allocator;
    var h = LatencyHistogram{};
    h.observeUs(500); // <= 1ms (0.001)
    h.observeUs(7_500); // <= 10ms (0.01)
    h.observeUs(6_000_000); // > 5s (+Inf)

    try std.testing.expectEqual(@as(u64, 3), h.count.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 6_008_000), h.sum_us.load(.monotonic));

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try h.writePrometheus(&out.writer, "test_latency_seconds", "Test histogram.");
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "test_latency_seconds_bucket{le=\"0.001\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "test_latency_seconds_bucket{le=\"0.01\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "test_latency_seconds_bucket{le=\"+Inf\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "test_latency_seconds_count 3\n") != null);
}

test "PlatformMetrics Prometheus and JSON status formatting" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = PlatformMetrics.init(io, false);
    _ = m.queries_total.fetchAdd(10, .monotonic);
    _ = m.queries_err_total.fetchAdd(2, .monotonic);
    _ = m.occ_retries_total.fetchAdd(3, .monotonic);
    m.recordHttpStatus(200);
    m.recordHttpStatus(404);
    m.recordHttpStatus(500);
    m.query_latency.observeUs(12_000);

    const snap = StatusSnapshotInput{
        .app_name = "demo-app",
        .storage_backend = "wal",
        .commit_ts = 42,
        .last_broadcast_ts = 40,
        .active_clients = 3,
        .active_subscriptions = 7,
    };

    const prom = try m.formatPrometheus(alloc, io, snap);
    defer alloc.free(prom);
    try std.testing.expect(std.mem.indexOf(u8, prom, "concave_up{storage=\"wal\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "concave_commit_lag 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "concave_rpcs_total{kind=\"query\",status=\"ok\"} 8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "concave_rpcs_total{kind=\"query\",status=\"error\"} 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "concave_occ_retries_total 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "concave_http_errors_total{class=\"4xx\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prom, "concave_http_errors_total{class=\"5xx\"} 1\n") != null);

    const status_json = try m.formatStatusJson(alloc, io, snap);
    defer alloc.free(status_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, status_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("demo-app", parsed.value.object.get("app_name").?.string);
    try std.testing.expectEqual(@as(i64, 2), parsed.value.object.get("commit_lag").?.integer);
    try std.testing.expectEqual(@as(i64, 10), parsed.value.object.get("rpcs").?.object.get("queries_total").?.integer);
}
