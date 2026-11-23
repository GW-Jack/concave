const std = @import("std");
const Allocator = std.mem.Allocator;
const blob_store_mod = @import("../core/blob_store.zig");
const key_mod = @import("../core/key.zig");
const manifest_mod = @import("../core/manifest.zig");
const readset_mod = @import("../core/readset.zig");
const storage_mod = @import("../core/storage.zig");
const auth_mod = @import("auth.zig");
const http_client = @import("http_client.zig");
const metrics_mod = @import("metrics.zig");
const tx_mod = @import("tx.zig");
const ws_mod = @import("ws.zig");

const MAX_OCC_RETRIES: usize = 8;

pub const ExecResult = union(enum) {
    ok: []u8,
    err: []u8,

    pub fn deinit(self: *const ExecResult, allocator: Allocator) void {
        switch (self.*) {
            .ok => |s| allocator.free(s),
            .err => |s| allocator.free(s),
        }
    }

    pub fn eql(self: *const ExecResult, other: *const ExecResult) bool {
        return switch (self.*) {
            .ok => |a| switch (other.*) {
                .ok => |b| std.mem.eql(u8, a, b),
                .err => false,
            },
            .err => |a| switch (other.*) {
                .ok => false,
                .err => |b| std.mem.eql(u8, a, b),
            },
        };
    }

    pub fn clone(self: *const ExecResult, allocator: Allocator) !ExecResult {
        return switch (self.*) {
            .ok => |s| .{ .ok = try allocator.dupe(u8, s) },
            .err => |s| .{ .err = try allocator.dupe(u8, s) },
        };
    }
};

pub const MutationExecResult = struct {
    result: ExecResult,
    commit_ts: i64 = 0,

    pub fn deinit(self: *const MutationExecResult, allocator: Allocator) void {
        self.result.deinit(allocator);
    }
};

pub const ExecutionEnv = struct {
    allocator: Allocator,
    io: std.Io,
    auth: ?auth_mod.AuthIdentity,
    blob_store: ?*blob_store_mod.BlobStore = null,
    mode: union(enum) {
        tx: *tx_mod.TxContext,
        action: *ConcaveEngine,
    },

    pub fn dbGet(self: *ExecutionEnv, allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) !?storage_mod.Document {
        return switch (self.mode) {
            .tx => |t| t.get(allocator, ns, table, doc_id),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn dbQuery(self: *ExecutionEnv, allocator: Allocator, query: *const storage_mod.IndexQuery) ![]storage_mod.Document {
        return switch (self.mode) {
            .tx => |t| t.scanIndex(allocator, query),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn dbPaginate(
        self: *ExecutionEnv,
        allocator: Allocator,
        query: *const storage_mod.IndexQuery,
        cursor: []const u8,
        page_size: usize,
    ) !tx_mod.TxContext.PageResult {
        return switch (self.mode) {
            .tx => |t| t.paginate(allocator, query, cursor, page_size),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn dbSearch(
        self: *ExecutionEnv,
        allocator: Allocator,
        ns: []const u8,
        table: []const u8,
        field: []const u8,
        query_text: []const u8,
        limit: usize,
    ) ![]storage_mod.Document {
        return switch (self.mode) {
            .tx => |t| t.search(allocator, ns, table, field, query_text, limit),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn dbInsert(self: *ExecutionEnv, allocator: Allocator, ns: []const u8, table: []const u8, body_json: []const u8) ![]u8 {
        return switch (self.mode) {
            .tx => |t| t.insert(allocator, ns, table, body_json),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn dbPatch(self: *ExecutionEnv, ns: []const u8, table: []const u8, doc_id: []const u8, patch_json: []const u8) !void {
        return switch (self.mode) {
            .tx => |t| t.patch(ns, table, doc_id, patch_json),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn dbReplace(self: *ExecutionEnv, ns: []const u8, table: []const u8, doc_id: []const u8, body_json: []const u8) !void {
        return switch (self.mode) {
            .tx => |t| t.replace(ns, table, doc_id, body_json),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn dbDelete(self: *ExecutionEnv, ns: []const u8, table: []const u8, doc_id: []const u8) !void {
        return switch (self.mode) {
            .tx => |t| t.delete(ns, table, doc_id),
            .action => error.DbNotAllowedInAction,
        };
    }

    pub fn scheduleJob(self: *ExecutionEnv, allocator: Allocator, run_at_ms: i64, fn_name: []const u8, args_json: []const u8) ![]u8 {
        return switch (self.mode) {
            .tx => |t| t.scheduleJob(allocator, run_at_ms, fn_name, args_json, null),
            .action => error.SchedulerOnlyInMutation,
        };
    }

    pub fn cancelJob(self: *ExecutionEnv, job_id: []const u8) !void {
        return switch (self.mode) {
            .tx => |t| t.cancelJob(job_id),
            .action => error.SchedulerOnlyInMutation,
        };
    }

    pub fn storageUploadUrl(self: *ExecutionEnv, allocator: Allocator) ![]u8 {
        switch (self.mode) {
            .tx => |t| if (t.read_only) return storage_mod.StorageError.ReadOnly,
            .action => {},
        }
        const bs = self.blob_store orelse return error.StorageNotConfigured;
        return try bs.generateUploadUrl(allocator);
    }

    pub fn storageGetUrl(self: *ExecutionEnv, allocator: Allocator, storage_id: []const u8) ![]u8 {
        const bs = self.blob_store orelse return error.StorageNotConfigured;
        return try bs.getDownloadUrl(allocator, storage_id);
    }

    pub fn storageDelete(self: *ExecutionEnv, storage_id: []const u8) !void {
        switch (self.mode) {
            .tx => |t| if (t.read_only) return storage_mod.StorageError.ReadOnly,
            .action => {},
        }
        const bs = self.blob_store orelse return error.StorageNotConfigured;
        return try bs.deleteBlob(storage_id);
    }

    pub fn httpFetch(self: *ExecutionEnv, allocator: Allocator, req: http_client.HttpFetchRequest) !http_client.HttpFetchResponse {
        return switch (self.mode) {
            .action => http_client.fetch(allocator, self.io, req),
            .tx => error.HttpOnlyAllowedInAction,
        };
    }

    pub fn runQuery(self: *ExecutionEnv, allocator: Allocator, name: []const u8, args_json: []const u8) !ExecResult {
        return switch (self.mode) {
            .action => |eng| eng.executeQuery(allocator, name, args_json, if (self.auth) |*a| a else null),
            .tx => error.ActionOnly,
        };
    }

    pub fn runMutation(self: *ExecutionEnv, allocator: Allocator, name: []const u8, args_json: []const u8) !MutationExecResult {
        return switch (self.mode) {
            .action => |eng| eng.executeMutation(allocator, name, args_json, if (self.auth) |*a| a else null),
            .tx => error.ActionOnly,
        };
    }
};

pub const AppExecutor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        manifest: *const fn (ptr: *anyopaque) *const manifest_mod.AppManifest,
        executeQuery: *const fn (ptr: *anyopaque, allocator: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult,
        executeMutation: *const fn (ptr: *anyopaque, allocator: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult,
        executeAction: *const fn (ptr: *anyopaque, allocator: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult,
        executeHttpRoute: ?*const fn (ptr: *anyopaque, allocator: Allocator, method: []const u8, path: []const u8, req_json: []const u8, env: *ExecutionEnv) ExecResult = null,
    };

    pub fn manifest(self: AppExecutor) *const manifest_mod.AppManifest {
        return self.vtable.manifest(self.ptr);
    }

    pub fn executeQuery(self: AppExecutor, allocator: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult {
        return self.vtable.executeQuery(self.ptr, allocator, name, args_json, env);
    }

    pub fn executeMutation(self: AppExecutor, allocator: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult {
        return self.vtable.executeMutation(self.ptr, allocator, name, args_json, env);
    }

    pub fn executeAction(self: AppExecutor, allocator: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult {
        return self.vtable.executeAction(self.ptr, allocator, name, args_json, env);
    }

    pub fn executeHttpRoute(self: AppExecutor, allocator: Allocator, method: []const u8, path: []const u8, req_json: []const u8, env: *ExecutionEnv) ExecResult {
        if (self.vtable.executeHttpRoute) |f| {
            return f(self.ptr, allocator, method, path, req_json, env);
        }
        return .{ .err = allocator.dupe(u8, "http routes not supported by executor") catch &.{} };
    }
};

pub const ClientSink = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, payload: []const u8) void,
    closeFn: ?*const fn (ptr: *anyopaque) void = null,

    pub fn send(self: ClientSink, payload: []const u8) void {
        self.sendFn(self.ptr, payload);
    }

    pub fn close(self: ClientSink) void {
        if (self.closeFn) |f| f(self.ptr);
    }

    pub fn fromWsSender(sender: *ws_mod.WsSender) ClientSink {
        const Wrapper = struct {
            fn sendText(ptr: *anyopaque, payload: []const u8) void {
                const ws: *ws_mod.WsSender = @ptrCast(@alignCast(ptr));
                ws.sendText(payload) catch {};
            }
            fn closeWs(ptr: *anyopaque) void {
                const ws: *ws_mod.WsSender = @ptrCast(@alignCast(ptr));
                ws.sendClose();
            }
        };
        return .{ .ptr = @ptrCast(sender), .sendFn = &Wrapper.sendText, .closeFn = &Wrapper.closeWs };
    }
};

pub const EngineStats = struct {
    commit_ts: i64,
    active_clients: usize,
    active_subscriptions: usize,
};

const ActiveSubscription = struct {
    sub_id: []u8,
    name: []u8,
    args_json: []u8,
    read_set: readset_mod.ReadSet,
    last_payload: ?ExecResult = null,
    last_sent_ts: i64 = 0,

    fn deinit(self: *ActiveSubscription, allocator: Allocator) void {
        allocator.free(self.sub_id);
        allocator.free(self.name);
        allocator.free(self.args_json);
        self.read_set.deinit(allocator);
        if (self.last_payload) |*lp| lp.deinit(allocator);
    }
};

const ClientSession = struct {
    id: u64,
    sink: ClientSink,
    auth: ?auth_mod.AuthIdentity = null,
    subscriptions: std.StringHashMapUnmanaged(ActiveSubscription) = .empty,

    fn deinit(self: *ClientSession, allocator: Allocator) void {
        if (self.auth) |*a| a.deinit(allocator);
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.subscriptions.deinit(allocator);
    }
};

pub const ConcaveEngine = struct {
    allocator: Allocator,
    io: std.Io,
    storage: storage_mod.Storage,
    executor: AppExecutor,
    manifest: *const manifest_mod.AppManifest,
    auth_config: auth_mod.AuthConfig,
    blob_store: ?*blob_store_mod.BlobStore = null,

    clients_mutex: std.Io.Mutex = .init,
    clients: std.AutoHashMapUnmanaged(u64, *ClientSession) = .empty,
    next_client_id: std.atomic.Value(u64) = .init(1),

    last_broadcast_ts: std.atomic.Value(i64) = .init(0),
    sync_mutex: std.Io.Mutex = .init,
    stop_tailer: std.atomic.Value(bool) = .init(false),
    metrics: metrics_mod.PlatformMetrics = .{},

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        storage: storage_mod.Storage,
        executor: AppExecutor,
        auth_config: auth_mod.AuthConfig,
    ) !*ConcaveEngine {
        const mf = executor.manifest();
        try storage.initSchema(mf);
        const initial_ts = try storage.latestCommitTs();

        const self = try allocator.create(ConcaveEngine);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .storage = storage,
            .executor = executor,
            .manifest = mf,
            .auth_config = auth_config,
            .last_broadcast_ts = .init(initial_ts),
            .metrics = metrics_mod.PlatformMetrics.init(io, false),
        };
        return self;
    }

    pub fn deinit(self: *ConcaveEngine) void {
        self.stop_tailer.store(true, .release);
        self.clients_mutex.lockUncancelable(self.io);
        var it = self.clients.valueIterator();
        while (it.next()) |sess| {
            sess.*.deinit(self.allocator);
            self.allocator.destroy(sess.*);
        }
        self.clients.deinit(self.allocator);
        self.clients_mutex.unlock(self.io);
        self.allocator.destroy(self);
    }

    pub fn readyCheck(self: *ConcaveEngine) !i64 {
        return try self.storage.latestCommitTs();
    }

    pub fn getStats(self: *ConcaveEngine) EngineStats {
        const ts = self.storage.latestCommitTs() catch self.last_broadcast_ts.load(.acquire);
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        const client_count = self.clients.count();
        var sub_count: usize = 0;
        var it = self.clients.valueIterator();
        while (it.next()) |sess| {
            sub_count += sess.*.subscriptions.count();
        }
        return .{
            .commit_ts = ts,
            .active_clients = client_count,
            .active_subscriptions = sub_count,
        };
    }

    pub fn storageBackendName(self: *const ConcaveEngine) []const u8 {
        return switch (self.storage) {
            .wal => "wal",
            .pg => "postgres",
        };
    }

    pub fn formatPrometheusMetrics(self: *ConcaveEngine, allocator: Allocator) ![]u8 {
        const stats = self.getStats();
        return try self.metrics.formatPrometheus(allocator, self.io, .{
            .app_name = self.manifest.app_name,
            .storage_backend = self.storageBackendName(),
            .commit_ts = stats.commit_ts,
            .last_broadcast_ts = self.last_broadcast_ts.load(.acquire),
            .active_clients = stats.active_clients,
            .active_subscriptions = stats.active_subscriptions,
        });
    }

    pub fn formatInternalStatusJson(self: *ConcaveEngine, allocator: Allocator) ![]u8 {
        const stats = self.getStats();
        return try self.metrics.formatStatusJson(allocator, self.io, .{
            .app_name = self.manifest.app_name,
            .storage_backend = self.storageBackendName(),
            .commit_ts = stats.commit_ts,
            .last_broadcast_ts = self.last_broadcast_ts.load(.acquire),
            .active_clients = stats.active_clients,
            .active_subscriptions = stats.active_subscriptions,
        });
    }

    pub fn adminScanTable(
        self: *ConcaveEngine,
        allocator: Allocator,
        ns: []const u8,
        table: []const u8,
        limit: usize,
    ) ![]storage_mod.Document {
        return try self.storage.scanIndex(allocator, &.{
            .namespace = ns,
            .table = table,
            .index_name = "by_creation_time",
            .start = .unbounded,
            .end = .unbounded,
            .order = .desc,
            .limit = if (limit == 0) 100 else @min(limit, 500),
        });
    }

    /// Gracefully send WebSocket Close frames to every connected client during shutdown drain.
    pub fn closeAllClients(self: *ConcaveEngine) void {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        var it = self.clients.valueIterator();
        while (it.next()) |sess| {
            sess.*.sink.close();
        }
    }

    pub fn verifyAuthToken(self: *ConcaveEngine, allocator: Allocator, token: []const u8) !auth_mod.AuthIdentity {
        return try auth_mod.verifyToken(allocator, self.io, self.auth_config, token);
    }

    pub fn registerClient(self: *ConcaveEngine, sink: ClientSink) !u64 {
        const id = self.next_client_id.fetchAdd(1, .monotonic);
        const sess = try self.allocator.create(ClientSession);
        sess.* = .{ .id = id, .sink = sink };

        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        try self.clients.put(self.allocator, id, sess);
        _ = self.metrics.ws_connections_total.fetchAdd(1, .monotonic);
        return id;
    }

    pub fn unregisterClient(self: *ConcaveEngine, client_id: u64) void {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        if (self.clients.fetchRemove(client_id)) |kv| {
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
        }
    }

    pub fn cloneClientAuth(self: *ConcaveEngine, allocator: Allocator, client_id: u64) ?auth_mod.AuthIdentity {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        const sess = self.clients.get(client_id) orelse return null;
        if (sess.auth) |*a| return a.clone(allocator) catch null;
        return null;
    }

    pub fn authenticateClient(self: *ConcaveEngine, client_id: u64, token: ?[]const u8) ![]u8 {
        var new_auth: ?auth_mod.AuthIdentity = null;
        if (token) |tok| {
            new_auth = auth_mod.verifyToken(self.allocator, self.io, self.auth_config, tok) catch |err| {
                return try formatAuthError(self.allocator, @errorName(err));
            };
        }
        defer if (new_auth) |*a| a.deinit(self.allocator);

        self.sync_mutex.lockUncancelable(self.io);
        defer self.sync_mutex.unlock(self.io);

        const SubSpec = struct { sub_id: []u8, name: []u8, args_json: []u8 };
        var to_rerun: std.ArrayList(SubSpec) = .empty;
        defer {
            for (to_rerun.items) |s| {
                self.allocator.free(s.sub_id);
                self.allocator.free(s.name);
                self.allocator.free(s.args_json);
            }
            to_rerun.deinit(self.allocator);
        }

        {
            self.clients_mutex.lockUncancelable(self.io);
            defer self.clients_mutex.unlock(self.io);
            const sess = self.clients.get(client_id) orelse
                return try formatAuthError(self.allocator, "client disconnected");
            if (sess.auth) |*old| old.deinit(self.allocator);
            sess.auth = if (new_auth) |*a| try a.clone(self.allocator) else null;

            var it = sess.subscriptions.valueIterator();
            while (it.next()) |sub| {
                try to_rerun.append(self.allocator, .{
                    .sub_id = try self.allocator.dupe(u8, sub.sub_id),
                    .name = try self.allocator.dupe(u8, sub.name),
                    .args_json = try self.allocator.dupe(u8, sub.args_json),
                });
            }
        }

        if (to_rerun.items.len > 0) {
            var updates: std.ArrayList(UpdateFrame) = .empty;
            defer {
                for (updates.items) |*u| u.deinit(self.allocator);
                updates.deinit(self.allocator);
            }
            var to_ts: i64 = self.storage.latestCommitTs() catch 0;

            for (to_rerun.items) |item| {
                var ran = self.runQueryInternal(item.name, item.args_json, if (new_auth) |*a| a else null);
                defer ran.read_set.deinit(self.allocator);
                if (ran.snapshot_ts > to_ts) to_ts = ran.snapshot_ts;

                try updates.append(self.allocator, .{
                    .sub_id = try self.allocator.dupe(u8, item.sub_id),
                    .result = try ran.result.clone(self.allocator),
                });

                self.clients_mutex.lockUncancelable(self.io);
                if (self.clients.get(client_id)) |sess| {
                    if (sess.subscriptions.getPtr(item.sub_id)) |sub| {
                        sub.read_set.deinit(self.allocator);
                        sub.read_set = ran.read_set;
                        ran.read_set = .{};
                        if (sub.last_payload) |*lp| lp.deinit(self.allocator);
                        sub.last_payload = ran.result;
                        ran.result = .{ .ok = &.{} };
                    } else {
                        ran.result.deinit(self.allocator);
                    }
                } else {
                    ran.result.deinit(self.allocator);
                }
                self.clients_mutex.unlock(self.io);
            }

            const frame_json = try formatTransition(self.allocator, to_ts, updates.items);
            defer self.allocator.free(frame_json);
            self.sendToClientLockedCheck(client_id, frame_json);
        }

        return try formatAuthOk(self.allocator, if (new_auth) |*a| a else null);
    }

    pub fn subscribe(self: *ConcaveEngine, client_id: u64, sub_id: []const u8, name: []const u8, args_json: []const u8) !void {
        // Hold `sync_mutex` across initial query evaluation, subscription registration, and initial
        // transition delivery so concurrent commits cannot slip between snapshot & registration
        // (eliminating both lost-update races and out-of-order `commit_ts` frames).
        self.sync_mutex.lockUncancelable(self.io);
        defer self.sync_mutex.unlock(self.io);

        var auth_copy = self.cloneClientAuth(self.allocator, client_id);
        defer if (auth_copy) |*a| a.deinit(self.allocator);

        var ran = self.runQueryInternal(name, args_json, if (auth_copy) |*a| a else null);
        errdefer {
            ran.read_set.deinit(self.allocator);
            ran.result.deinit(self.allocator);
        }

        const single_upd = [_]UpdateFrame{.{
            .sub_id = @constCast(sub_id),
            .result = ran.result,
        }};
        const frame_json = try formatTransition(self.allocator, ran.snapshot_ts, &single_upd);
        defer self.allocator.free(frame_json);

        var had_any_subs_before = false;
        {
            self.clients_mutex.lockUncancelable(self.io);
            defer self.clients_mutex.unlock(self.io);

            var cit = self.clients.valueIterator();
            while (cit.next()) |sp| {
                if (sp.*.subscriptions.count() > 0) {
                    had_any_subs_before = true;
                    break;
                }
            }

            if (self.clients.get(client_id)) |sess| {
                const key = try self.allocator.dupe(u8, sub_id);
                if (sess.subscriptions.fetchRemove(key)) |old| {
                    self.allocator.free(old.key);
                    var old_val = old.value;
                    old_val.deinit(self.allocator);
                }
                try sess.subscriptions.put(self.allocator, key, .{
                    .sub_id = try self.allocator.dupe(u8, sub_id),
                    .name = try self.allocator.dupe(u8, name),
                    .args_json = try self.allocator.dupe(u8, args_json),
                    .read_set = ran.read_set,
                    .last_payload = ran.result,
                    .last_sent_ts = ran.snapshot_ts,
                });
                // Send under `clients_mutex` so `unregisterClient` cannot free WsSender concurrently
                // and initial frame strictly precedes any later broadcast.
                sess.sink.send(frame_json);
            } else {
                ran.read_set.deinit(self.allocator);
                ran.result.deinit(self.allocator);
            }
        }

        // If this replica was idle (zero active subscriptions), advance `last_broadcast_ts` to
        // `ran.snapshot_ts` so `pollCommitLog` does not replay stale historical commits already
        // included in this subscriber's initial snapshot.
        if (!had_any_subs_before) {
            const cur = self.last_broadcast_ts.load(.acquire);
            if (ran.snapshot_ts > cur) {
                self.last_broadcast_ts.store(ran.snapshot_ts, .release);
            }
        }
    }

    fn sendToClientLockedCheck(self: *ConcaveEngine, client_id: u64, payload: []const u8) void {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        if (self.clients.get(client_id)) |sess| {
            sess.sink.send(payload);
        }
    }

    pub fn unsubscribe(self: *ConcaveEngine, client_id: u64, sub_id: []const u8) void {
        self.clients_mutex.lockUncancelable(self.io);
        defer self.clients_mutex.unlock(self.io);
        if (self.clients.get(client_id)) |sess| {
            if (sess.subscriptions.fetchRemove(sub_id)) |old| {
                self.allocator.free(old.key);
                var val = old.value;
                val.deinit(self.allocator);
            }
        }
    }

    pub fn executeQuery(
        self: *ConcaveEngine,
        allocator: Allocator,
        name: []const u8,
        args_json: []const u8,
        auth: ?*const auth_mod.AuthIdentity,
    ) !ExecResult {
        const ran = self.runQueryInternalWithOpts(allocator, name, args_json, auth, false);
        return ran.result;
    }

    const InternalQueryRun = struct {
        result: ExecResult,
        read_set: readset_mod.ReadSet,
        snapshot_ts: i64,
    };

    fn runQueryInternal(
        self: *ConcaveEngine,
        name: []const u8,
        args_json: []const u8,
        auth: ?*const auth_mod.AuthIdentity,
    ) InternalQueryRun {
        return self.runQueryInternalWithOpts(self.allocator, name, args_json, auth, true);
    }

    fn runQueryInternalWithOpts(
        self: *ConcaveEngine,
        result_allocator: Allocator,
        name: []const u8,
        args_json: []const u8,
        auth: ?*const auth_mod.AuthIdentity,
        track_reads: bool,
    ) InternalQueryRun {
        const start_us = metrics_mod.PlatformMetrics.nowMicros(self.io);
        _ = self.metrics.queries_total.fetchAdd(1, .monotonic);

        const snapshot_ts = self.storage.latestCommitTs() catch |err| {
            _ = self.metrics.queries_err_total.fetchAdd(1, .monotonic);
            _ = self.metrics.storage_errors_total.fetchAdd(1, .monotonic);
            const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
            self.metrics.query_latency.observeUs(dur_us);
            self.metrics.logRpc(self.io, "query", name, dur_us, false, 0, @errorName(err));
            return .{
                .result = .{ .err = std.fmt.allocPrint(result_allocator, "storage error: {s}", .{@errorName(err)}) catch &.{} },
                .read_set = .{},
                .snapshot_ts = 0,
            };
        };

        var tx = tx_mod.TxContext.init(self.allocator, self.io, self.storage, self.manifest, snapshot_ts, true);
        tx.track_reads = track_reads;
        defer {
            // Move read_set out before deiniting remaining tx fields.
            tx.read_set = .{};
            tx.deinit();
        }

        var env = ExecutionEnv{
            .allocator = self.allocator,
            .io = self.io,
            .auth = if (auth) |a| a.* else null,
            .blob_store = self.blob_store,
            .mode = .{ .tx = &tx },
        };

        const res = self.executor.executeQuery(result_allocator, name, args_json, &env);
        const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
        self.metrics.query_latency.observeUs(dur_us);
        switch (res) {
            .ok => self.metrics.logRpc(self.io, "query", name, dur_us, true, 0, null),
            .err => |emsg| {
                _ = self.metrics.queries_err_total.fetchAdd(1, .monotonic);
                self.metrics.logRpc(self.io, "query", name, dur_us, false, 0, emsg);
            },
        }
        const rs = tx.read_set;
        return .{
            .result = res,
            .read_set = rs,
            .snapshot_ts = snapshot_ts,
        };
    }

    pub fn executeMutation(
        self: *ConcaveEngine,
        allocator: Allocator,
        name: []const u8,
        args_json: []const u8,
        auth: ?*const auth_mod.AuthIdentity,
    ) !MutationExecResult {
        const start_us = metrics_mod.PlatformMetrics.nowMicros(self.io);
        _ = self.metrics.mutations_total.fetchAdd(1, .monotonic);
        var retries: usize = 0;

        for (0..MAX_OCC_RETRIES) |_| {
            const snapshot_ts = self.storage.latestCommitTs() catch |err| {
                _ = self.metrics.mutations_err_total.fetchAdd(1, .monotonic);
                _ = self.metrics.storage_errors_total.fetchAdd(1, .monotonic);
                const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
                self.metrics.mutation_latency.observeUs(dur_us);
                self.metrics.logRpc(self.io, "mutation", name, dur_us, false, retries, @errorName(err));
                return .{ .result = .{ .err = try std.fmt.allocPrint(allocator, "storage error: {s}", .{@errorName(err)}) } };
            };

            var tx = tx_mod.TxContext.init(self.allocator, self.io, self.storage, self.manifest, snapshot_ts, false);
            defer tx.deinit();

            const auth_clone = if (auth) |a| a.clone(self.allocator) catch null else null;
            defer if (auth_clone) |*ac| ac.deinit(self.allocator);

            var env = ExecutionEnv{
                .allocator = self.allocator,
                .io = self.io,
                .auth = auth_clone,
                .blob_store = self.blob_store,
                .mode = .{ .tx = &tx },
            };

            const res = self.executor.executeMutation(allocator, name, args_json, &env);
            switch (res) {
                .err => |emsg| {
                    _ = self.metrics.mutations_err_total.fetchAdd(1, .monotonic);
                    const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
                    self.metrics.mutation_latency.observeUs(dur_us);
                    self.metrics.logRpc(self.io, "mutation", name, dur_us, false, retries, emsg);
                    return .{ .result = res, .commit_ts = 0 };
                },
                .ok => {},
            }

            const commit_start_us = metrics_mod.PlatformMetrics.nowMicros(self.io);
            var commit = self.storage.commitTx(
                self.allocator,
                self.manifest,
                snapshot_ts,
                &tx.read_set,
                tx.writes.items,
            ) catch |err| {
                res.deinit(allocator);
                if (err == storage_mod.StorageError.Conflict) {
                    retries += 1;
                    _ = self.metrics.occ_retries_total.fetchAdd(1, .monotonic);
                    continue;
                }
                _ = self.metrics.mutations_err_total.fetchAdd(1, .monotonic);
                _ = self.metrics.storage_errors_total.fetchAdd(1, .monotonic);
                const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
                self.metrics.mutation_latency.observeUs(dur_us);
                self.metrics.logRpc(self.io, "mutation", name, dur_us, false, retries, @errorName(err));
                return .{ .result = .{ .err = try std.fmt.allocPrint(allocator, "commit error: {s}", .{@errorName(err)}) } };
            };
            defer commit.deinit(self.allocator);
            self.metrics.commit_latency.observeUs(metrics_mod.PlatformMetrics.elapsedUs(self.io, commit_start_us));
            _ = self.metrics.storage_commits_total.fetchAdd(1, .monotonic);

            if (!commit.write_set.isEmpty()) {
                self.handleLocalCommit(commit.commit_ts, &commit.write_set);
            }
            const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
            self.metrics.mutation_latency.observeUs(dur_us);
            self.metrics.logRpc(self.io, "mutation", name, dur_us, true, retries, null);
            return .{ .result = res, .commit_ts = commit.commit_ts };
        }

        _ = self.metrics.mutations_err_total.fetchAdd(1, .monotonic);
        _ = self.metrics.occ_exhausted_total.fetchAdd(1, .monotonic);
        const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
        self.metrics.mutation_latency.observeUs(dur_us);
        self.metrics.logRpc(self.io, "mutation", name, dur_us, false, retries, "occ_exhausted");
        return .{ .result = .{ .err = try std.fmt.allocPrint(
            allocator,
            "mutation `{s}` exceeded {d} OCC retries due to concurrent conflicts",
            .{ name, MAX_OCC_RETRIES },
        ) } };
    }

    pub fn executeAction(
        self: *ConcaveEngine,
        allocator: Allocator,
        name: []const u8,
        args_json: []const u8,
        auth: ?*const auth_mod.AuthIdentity,
    ) !ExecResult {
        const start_us = metrics_mod.PlatformMetrics.nowMicros(self.io);
        _ = self.metrics.actions_total.fetchAdd(1, .monotonic);

        const auth_clone = if (auth) |a| a.clone(self.allocator) catch null else null;
        defer if (auth_clone) |*ac| ac.deinit(self.allocator);

        var env = ExecutionEnv{
            .allocator = self.allocator,
            .io = self.io,
            .auth = auth_clone,
            .blob_store = self.blob_store,
            .mode = .{ .action = self },
        };
        const res = self.executor.executeAction(allocator, name, args_json, &env);
        const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
        self.metrics.action_latency.observeUs(dur_us);
        switch (res) {
            .ok => self.metrics.logRpc(self.io, "action", name, dur_us, true, 0, null),
            .err => |emsg| {
                _ = self.metrics.actions_err_total.fetchAdd(1, .monotonic);
                self.metrics.logRpc(self.io, "action", name, dur_us, false, 0, emsg);
            },
        }
        return res;
    }

    pub fn executeHttpRoute(
        self: *ConcaveEngine,
        allocator: Allocator,
        method: []const u8,
        path: []const u8,
        req_json: []const u8,
        auth: ?*const auth_mod.AuthIdentity,
    ) !ExecResult {
        const start_us = metrics_mod.PlatformMetrics.nowMicros(self.io);
        _ = self.metrics.http_routes_total.fetchAdd(1, .monotonic);

        const auth_clone = if (auth) |a| a.clone(self.allocator) catch null else null;
        defer if (auth_clone) |*ac| ac.deinit(self.allocator);

        var env = ExecutionEnv{
            .allocator = self.allocator,
            .io = self.io,
            .auth = auth_clone,
            .blob_store = self.blob_store,
            .mode = .{ .action = self },
        };
        const res = self.executor.executeHttpRoute(allocator, method, path, req_json, &env);
        const dur_us = metrics_mod.PlatformMetrics.elapsedUs(self.io, start_us);
        switch (res) {
            .ok => self.metrics.logRpc(self.io, "http_route", path, dur_us, true, 0, null),
            .err => |emsg| {
                _ = self.metrics.http_routes_err_total.fetchAdd(1, .monotonic);
                self.metrics.logRpc(self.io, "http_route", path, dur_us, false, 0, emsg);
            },
        }
        return res;
    }

    /// Ensure every manifest cron has an active pending/running job in `_system._scheduled_jobs`.
    pub fn ensureCronJobs(self: *ConcaveEngine) !void {
        if (self.manifest.crons.len == 0) return;
        for (self.manifest.crons) |cron| {
            const snapshot_ts = try self.storage.latestCommitTs();
            var tx = tx_mod.TxContext.init(self.allocator, self.io, self.storage, self.manifest, snapshot_ts, false);
            defer tx.deinit();

            const has_pending = try hasCronJobWithStatus(self.allocator, &tx, cron.name, "pending");
            if (has_pending) continue;
            const has_running = try hasCronJobWithStatus(self.allocator, &tx, cron.name, "running");
            if (has_running) continue;

            const run_at = storage_mod.nowMillis(self.io) + cron.interval_ms;
            const job_id = try tx.scheduleJob(self.allocator, run_at, cron.fn_name, cron.args_json, cron.name);
            defer self.allocator.free(job_id);

            var commit = self.storage.commitTx(
                self.allocator,
                self.manifest,
                snapshot_ts,
                &tx.read_set,
                tx.writes.items,
            ) catch |err| {
                if (err == storage_mod.StorageError.Conflict) continue;
                return err;
            };
            defer commit.deinit(self.allocator);
            if (!commit.write_set.isEmpty()) {
                self.handleLocalCommit(commit.commit_ts, &commit.write_set);
            }
        }
    }

    /// Claim and execute due jobs from `_system._scheduled_jobs` safely across replicas via OCC.
    pub fn pollScheduledJobs(self: *ConcaveEngine) !usize {
        try self.ensureCronJobs();

        const now_ms = storage_mod.nowMillis(self.io);
        const start_key = try key_mod.encodeKey(self.allocator, &.{.{ .str_val = "pending" }});
        defer self.allocator.free(start_key);
        const end_key = try key_mod.encodeKey(self.allocator, &.{ .{ .str_val = "pending" }, .{ .int_val = now_ms } });
        defer self.allocator.free(end_key);

        const due_docs = try self.storage.scanIndex(self.allocator, &.{
            .namespace = "_system",
            .table = "_scheduled_jobs",
            .index_name = "by_status_run_at",
            .start = .{ .included = start_key },
            .end = .{ .included = end_key },
            .order = .asc,
            .limit = 16,
        });
        defer {
            for (due_docs) |*d| d.deinit(self.allocator);
            self.allocator.free(due_docs);
        }

        var executed: usize = 0;
        for (due_docs) |*doc| {
            // Step 1: Atomically claim `pending` -> `running` via OCC.
            var fn_name_owned: []u8 = undefined;
            var args_json_owned: []u8 = undefined;
            var cron_name_owned: ?[]u8 = null;

            const claimed = blk: {
                const snap_ts = self.storage.latestCommitTs() catch break :blk false;
                var tx = tx_mod.TxContext.init(self.allocator, self.io, self.storage, self.manifest, snap_ts, false);
                defer tx.deinit();

                const fresh = (tx.get(self.allocator, "_system", "_scheduled_jobs", doc.id) catch break :blk false) orelse break :blk false;
                defer fresh.deinit(self.allocator);

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), fresh.body_json, .{}) catch break :blk false;
                if (parsed != .object) break :blk false;
                const status_v = parsed.object.get("status") orelse break :blk false;
                if (status_v != .string or !std.mem.eql(u8, status_v.string, "pending")) break :blk false;

                const fn_v = parsed.object.get("fn_name") orelse break :blk false;
                const args_v = parsed.object.get("args_json") orelse break :blk false;
                if (fn_v != .string or args_v != .string) break :blk false;
                const attempts: i64 = if (parsed.object.get("attempts")) |av| (if (av == .integer) av.integer else 0) else 0;

                const patch_json = std.fmt.allocPrint(self.allocator, "{{\"status\":\"running\",\"attempts\":{d}}}", .{attempts + 1}) catch break :blk false;
                defer self.allocator.free(patch_json);
                tx.patch("_system", "_scheduled_jobs", doc.id, patch_json) catch break :blk false;

                var commit = self.storage.commitTx(
                    self.allocator,
                    self.manifest,
                    snap_ts,
                    &tx.read_set,
                    tx.writes.items,
                ) catch break :blk false;
                defer commit.deinit(self.allocator);
                if (!commit.write_set.isEmpty()) {
                    self.handleLocalCommit(commit.commit_ts, &commit.write_set);
                }

                fn_name_owned = try self.allocator.dupe(u8, fn_v.string);
                args_json_owned = try self.allocator.dupe(u8, args_v.string);
                if (parsed.object.get("cron_name")) |cv| {
                    if (cv == .string and cv.string.len > 0) {
                        cron_name_owned = try self.allocator.dupe(u8, cv.string);
                    }
                }
                break :blk true;
            };
            if (!claimed) continue;
            defer self.allocator.free(fn_name_owned);
            defer self.allocator.free(args_json_owned);
            defer if (cron_name_owned) |cn| self.allocator.free(cn);

            // Step 2: Execute the scheduled function (mutation or action).
            var job_err: ?[]u8 = null;
            defer if (job_err) |e| self.allocator.free(e);

            if (self.manifest.findFunction(fn_name_owned)) |fspec| {
                switch (fspec.kind) {
                    .mutation => {
                        const mres: ?MutationExecResult = self.executeMutation(self.allocator, fn_name_owned, args_json_owned, null) catch |err| blk_e: {
                            job_err = try self.allocator.dupe(u8, @errorName(err));
                            break :blk_e null;
                        };
                        if (mres) |mr| {
                            defer mr.deinit(self.allocator);
                            if (mr.result == .err) {
                                job_err = try self.allocator.dupe(u8, mr.result.err);
                            }
                        }
                    },
                    .action => {
                        const ares: ?ExecResult = self.executeAction(self.allocator, fn_name_owned, args_json_owned, null) catch |err| blk_e: {
                            job_err = try self.allocator.dupe(u8, @errorName(err));
                            break :blk_e null;
                        };
                        if (ares) |ar| {
                            defer ar.deinit(self.allocator);
                            if (ar == .err) {
                                job_err = try self.allocator.dupe(u8, ar.err);
                            }
                        }
                    },
                    .query => {
                        job_err = try self.allocator.dupe(u8, "scheduled function must be a mutation or action, not a query");
                    },
                }
            } else {
                job_err = try std.fmt.allocPrint(self.allocator, "unknown scheduled function `{s}`", .{fn_name_owned});
            }

            // Step 3: Record completion/failure and reschedule next cron tick if applicable.
            _ = self.metrics.scheduler_jobs_executed_total.fetchAdd(1, .monotonic);
            if (job_err != null) {
                _ = self.metrics.scheduler_jobs_failed_total.fetchAdd(1, .monotonic);
            }
            for (0..4) |_| {
                const snap_ts = self.storage.latestCommitTs() catch break;
                var tx = tx_mod.TxContext.init(self.allocator, self.io, self.storage, self.manifest, snap_ts, false);
                defer tx.deinit();

                var patch_out: std.Io.Writer.Allocating = .init(self.allocator);
                defer patch_out.deinit();
                if (job_err) |emsg| {
                    try patch_out.writer.writeAll("{\"status\":\"failed\",\"last_error\":");
                    try storage_mod.writeJsonString(&patch_out.writer, emsg);
                    try patch_out.writer.writeByte('}');
                } else {
                    try patch_out.writer.writeAll("{\"status\":\"completed\"}");
                }
                tx.patch("_system", "_scheduled_jobs", doc.id, patch_out.written()) catch break;

                if (cron_name_owned) |cn| {
                    for (self.manifest.crons) |cron| {
                        if (std.mem.eql(u8, cron.name, cn)) {
                            const next_run = storage_mod.nowMillis(self.io) + cron.interval_ms;
                            const next_id = try tx.scheduleJob(self.allocator, next_run, cron.fn_name, cron.args_json, cron.name);
                            self.allocator.free(next_id);
                            break;
                        }
                    }
                }

                var commit = self.storage.commitTx(
                    self.allocator,
                    self.manifest,
                    snap_ts,
                    &tx.read_set,
                    tx.writes.items,
                ) catch |err| {
                    if (err == storage_mod.StorageError.Conflict) continue;
                    break;
                };
                defer commit.deinit(self.allocator);
                if (!commit.write_set.isEmpty()) {
                    self.handleLocalCommit(commit.commit_ts, &commit.write_set);
                }
                break;
            }
            executed += 1;
        }
        return executed;
    }

    pub fn spawnSchedulerWorker(self: *ConcaveEngine, poll_ms: u64) !std.Thread {
        const Ctx = struct {
            engine: *ConcaveEngine,
            poll_ms: u64,
            fn run(ctx: @This()) void {
                while (!ctx.engine.stop_tailer.load(.acquire)) {
                    _ = ctx.engine.pollScheduledJobs() catch {};
                    ctx.engine.io.sleep(.fromMilliseconds(@intCast(ctx.poll_ms)), .awake) catch break;
                }
            }
        };
        return try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .engine = self, .poll_ms = poll_ms }});
    }

    /// Cross-instance commit_log poller (skips DB queries when no WebSocket clients are connected).
    pub fn pollCommitLog(self: *ConcaveEngine) !usize {
        {
            self.clients_mutex.lockUncancelable(self.io);
            const empty = self.clients.count() == 0;
            self.clients_mutex.unlock(self.io);
            if (empty) return 0;
        }

        self.sync_mutex.lockUncancelable(self.io);
        defer self.sync_mutex.unlock(self.io);

        const since = self.last_broadcast_ts.load(.acquire);
        const entries = try self.storage.commitsSince(self.allocator, since);
        defer {
            for (entries) |*e| e.deinit(self.allocator);
            self.allocator.free(entries);
        }

        for (entries) |*entry| {
            if (!entry.write_set.isEmpty()) {
                self.broadcastInvalidation(entry.commit_ts, &entry.write_set);
            }
            self.last_broadcast_ts.store(entry.commit_ts, .release);
        }
        return entries.len;
    }

    pub fn spawnCommitTailer(self: *ConcaveEngine, poll_ms: u64) !std.Thread {
        const Ctx = struct {
            engine: *ConcaveEngine,
            poll_ms: u64,
            fn run(ctx: @This()) void {
                while (!ctx.engine.stop_tailer.load(.acquire)) {
                    ctx.engine.io.sleep(.fromMilliseconds(@intCast(ctx.poll_ms)), .awake) catch break;
                    if (ctx.engine.stop_tailer.load(.acquire)) break;
                    _ = ctx.engine.pollCommitLog() catch {};
                }
            }
        };
        return try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .engine = self, .poll_ms = poll_ms }});
    }

    fn handleLocalCommit(self: *ConcaveEngine, commit_ts: i64, write_set: *const readset_mod.WriteSet) void {
        self.sync_mutex.lockUncancelable(self.io);
        defer self.sync_mutex.unlock(self.io);

        const since = self.last_broadcast_ts.load(.acquire);
        if (commit_ts == since + 1) {
            self.broadcastInvalidation(commit_ts, write_set);
            self.last_broadcast_ts.store(commit_ts, .release);
            return;
        }
        if (commit_ts <= since) return;

        // Catch up any intermediate commits from other Cloud Run instances first.
        const entries = self.storage.commitsSince(self.allocator, since) catch {
            self.broadcastInvalidation(commit_ts, write_set);
            self.last_broadcast_ts.store(commit_ts, .release);
            return;
        };
        defer {
            for (entries) |*e| e.deinit(self.allocator);
            self.allocator.free(entries);
        }
        for (entries) |*entry| {
            if (!entry.write_set.isEmpty()) {
                self.broadcastInvalidation(entry.commit_ts, &entry.write_set);
            }
            self.last_broadcast_ts.store(entry.commit_ts, .release);
        }
    }

    fn broadcastInvalidation(self: *ConcaveEngine, commit_ts: i64, write_set: *const readset_mod.WriteSet) void {
        const fanout_start_us = metrics_mod.PlatformMetrics.nowMicros(self.io);
        _ = self.metrics.ws_invalidations_total.fetchAdd(1, .monotonic);
        defer self.metrics.fanout_latency.observeUs(metrics_mod.PlatformMetrics.elapsedUs(self.io, fanout_start_us));

        const SubJob = struct { sub_id: []u8, name: []u8, args_json: []u8 };
        const ClientJob = struct {
            client_id: u64,
            sink: ClientSink,
            auth: ?auth_mod.AuthIdentity,
            subs: std.ArrayList(SubJob),
        };

        var impacted: std.ArrayList(ClientJob) = .empty;
        defer {
            for (impacted.items) |*cj| {
                if (cj.auth) |*a| a.deinit(self.allocator);
                for (cj.subs.items) |s| {
                    self.allocator.free(s.sub_id);
                    self.allocator.free(s.name);
                    self.allocator.free(s.args_json);
                }
                cj.subs.deinit(self.allocator);
            }
            impacted.deinit(self.allocator);
        }

        {
            self.clients_mutex.lockUncancelable(self.io);
            defer self.clients_mutex.unlock(self.io);
            var cit = self.clients.valueIterator();
            while (cit.next()) |sess_ptr| {
                const sess = sess_ptr.*;
                var matching: std.ArrayList(SubJob) = .empty;
                var sit = sess.subscriptions.valueIterator();
                while (sit.next()) |sub| {
                    if (commit_ts <= sub.last_sent_ts) continue;
                    if (sub.read_set.intersects(write_set)) {
                        matching.append(self.allocator, .{
                            .sub_id = self.allocator.dupe(u8, sub.sub_id) catch continue,
                            .name = self.allocator.dupe(u8, sub.name) catch continue,
                            .args_json = self.allocator.dupe(u8, sub.args_json) catch continue,
                        }) catch continue;
                    }
                }
                if (matching.items.len > 0) {
                    const auth_c = if (sess.auth) |*a| a.clone(self.allocator) catch null else null;
                    impacted.append(self.allocator, .{
                        .client_id = sess.id,
                        .sink = sess.sink,
                        .auth = auth_c,
                        .subs = matching,
                    }) catch {
                        matching.deinit(self.allocator);
                    };
                } else {
                    matching.deinit(self.allocator);
                }
            }
        }

        for (impacted.items) |*cj| {
            var updates: std.ArrayList(UpdateFrame) = .empty;
            defer {
                for (updates.items) |*u| u.deinit(self.allocator);
                updates.deinit(self.allocator);
            }

            // Evaluate all impacted subscriptions for this client at a consistent snapshot_ts
            // (retrying up to 3 times if a concurrent write advances snapshot_ts mid-batch, preventing torn reads).
            var effective_ts: i64 = commit_ts;
            var consistent_attempt: usize = 0;
            while (consistent_attempt < 3) : (consistent_attempt += 1) {
                for (updates.items) |*u| u.deinit(self.allocator);
                updates.clearRetainingCapacity();

                var batch_min_ts: ?i64 = null;
                var batch_max_ts: i64 = commit_ts;

                const Evaluated = struct {
                    sub_id: []const u8,
                    read_set: readset_mod.ReadSet,
                    result: ExecResult,
                };
                var evals: std.ArrayList(Evaluated) = .empty;
                defer {
                    for (evals.items) |*ev| {
                        ev.read_set.deinit(self.allocator);
                        ev.result.deinit(self.allocator);
                    }
                    evals.deinit(self.allocator);
                }

                for (cj.subs.items) |sj| {
                    const ran = self.runQueryInternal(sj.name, sj.args_json, if (cj.auth) |*a| a else null);
                    if (batch_min_ts == null or ran.snapshot_ts < batch_min_ts.?) batch_min_ts = ran.snapshot_ts;
                    if (ran.snapshot_ts > batch_max_ts) batch_max_ts = ran.snapshot_ts;
                    evals.append(self.allocator, .{
                        .sub_id = sj.sub_id,
                        .read_set = ran.read_set,
                        .result = ran.result,
                    }) catch {
                        var rs = ran.read_set;
                        rs.deinit(self.allocator);
                        ran.result.deinit(self.allocator);
                    };
                }

                effective_ts = batch_max_ts;
                // If multiple subscriptions saw different snapshot timestamps, retry once to avoid torn state!
                if (cj.subs.items.len > 1 and batch_min_ts != null and batch_min_ts.? != batch_max_ts and consistent_attempt + 1 < 3) {
                    continue;
                }

                // Commit evaluated states & send atomically under `clients_mutex` (eliminating WsSender UAF!).
                self.clients_mutex.lockUncancelable(self.io);
                defer self.clients_mutex.unlock(self.io);
                if (self.clients.get(cj.client_id)) |sess| {
                    for (evals.items) |*ev| {
                        if (sess.subscriptions.getPtr(ev.sub_id)) |sub| {
                            const changed = if (sub.last_payload) |*prev| !prev.eql(&ev.result) else true;
                            sub.read_set.deinit(self.allocator);
                            sub.read_set = ev.read_set;
                            ev.read_set = .{};
                            if (sub.last_payload) |*lp| lp.deinit(self.allocator);
                            sub.last_payload = ev.result.clone(self.allocator) catch null;
                            if (effective_ts > sub.last_sent_ts) sub.last_sent_ts = effective_ts;
                            if (changed) {
                                updates.append(self.allocator, .{
                                    .sub_id = self.allocator.dupe(u8, ev.sub_id) catch continue,
                                    .result = ev.result.clone(self.allocator) catch continue,
                                }) catch {};
                            }
                        }
                    }
                    if (updates.items.len > 0) {
                        const frame_json = formatTransition(self.allocator, effective_ts, updates.items) catch break;
                        defer self.allocator.free(frame_json);
                        sess.sink.send(frame_json);
                        _ = self.metrics.ws_transitions_sent_total.fetchAdd(1, .monotonic);
                    }
                }
                break;
            }
        }
    }
};

fn hasCronJobWithStatus(allocator: Allocator, tx: *tx_mod.TxContext, cron_name: []const u8, status: []const u8) !bool {
    const start_key = try key_mod.encodeKey(allocator, &.{ .{ .str_val = cron_name }, .{ .str_val = status } });
    defer allocator.free(start_key);
    const end_key = try key_mod.encodePrefixUpperBound(allocator, &.{ .{ .str_val = cron_name }, .{ .str_val = status } });
    defer allocator.free(end_key);
    const docs = try tx.scanIndex(allocator, &.{
        .namespace = "_system",
        .table = "_scheduled_jobs",
        .index_name = "by_cron",
        .start = .{ .included = start_key },
        .end = .{ .excluded = end_key },
        .order = .asc,
        .limit = 1,
    });
    defer {
        for (docs) |*d| d.deinit(allocator);
        allocator.free(docs);
    }
    return docs.len > 0;
}

const UpdateFrame = struct {
    sub_id: []u8,
    result: ExecResult,

    fn deinit(self: *const UpdateFrame, allocator: Allocator) void {
        allocator.free(self.sub_id);
        self.result.deinit(allocator);
    }
};

fn formatTransition(allocator: Allocator, to_ts: i64, updates: []const UpdateFrame) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("{{\"type\":\"transition\",\"to_ts\":{d},\"updates\":[", .{to_ts});
    for (updates, 0..) |u, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"sub_id\":");
        try storage_mod.writeJsonString(w, u.sub_id);
        switch (u.result) {
            .ok => |val_json| {
                try w.writeAll(",\"ok\":true,\"value\":");
                try w.writeAll(val_json);
            },
            .err => |err_msg| {
                try w.writeAll(",\"ok\":false,\"error\":");
                try storage_mod.writeJsonString(w, err_msg);
            },
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return try out.toOwnedSlice();
}

fn formatAuthOk(allocator: Allocator, identity: ?*const auth_mod.AuthIdentity) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"type\":\"auth_result\",\"ok\":true");
    if (identity) |id| {
        const id_json = try id.toJson(allocator);
        defer allocator.free(id_json);
        try w.writeAll(",\"identity\":");
        try w.writeAll(id_json);
    }
    try w.writeByte('}');
    return try out.toOwnedSlice();
}

fn formatAuthError(allocator: Allocator, err_msg: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"type\":\"auth_result\",\"ok\":false,\"error\":");
    try storage_mod.writeJsonString(w, err_msg);
    try w.writeByte('}');
    return try out.toOwnedSlice();
}

test "cross-instance commit_log tailer pushes surgical transitions to remote subscribers" {
    const WalStore = @import("../core/wal_store.zig").WalStore;
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const manifest_json =
        \\{"app_name":"chat","tables":[{"name":"messages","document_schema":{"kind":"any"},"indexes":[{"name":"by_room","fields":["room"]}]}],"components":[],"functions":[]}
    ;
    var manifest = try manifest_mod.AppManifest.parseJson(allocator, manifest_json);
    defer manifest.deinit();

    const MockExec = struct {
        mf: *const manifest_mod.AppManifest,

        fn getManifest(ptr: *anyopaque) *const manifest_mod.AppManifest {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.mf;
        }

        fn runQuery(_: *anyopaque, alloc: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult {
            if (!std.mem.eql(u8, name, "messages.list")) {
                return .{ .err = alloc.dupe(u8, "unknown query") catch &.{} };
            }
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), args_json, .{}) catch
                return .{ .err = alloc.dupe(u8, "bad args") catch &.{} };
            const room = parsed.object.get("room").?.string;
            const start = key_mod.encodeKey(alloc, &.{.{ .str_val = room }}) catch unreachable;
            defer alloc.free(start);
            const end = key_mod.encodePrefixUpperBound(alloc, &.{.{ .str_val = room }}) catch unreachable;
            defer alloc.free(end);

            const docs = env.dbQuery(alloc, &.{
                .namespace = "",
                .table = "messages",
                .index_name = "by_room",
                .start = .{ .included = start },
                .end = .{ .excluded = end },
                .order = .asc,
                .limit = null,
            }) catch return .{ .err = alloc.dupe(u8, "query err") catch &.{} };
            defer {
                for (docs) |*d| d.deinit(alloc);
                alloc.free(docs);
            }

            var out: std.Io.Writer.Allocating = .init(alloc);
            out.writer.writeByte('[') catch unreachable;
            for (docs, 0..) |*d, i| {
                if (i > 0) out.writer.writeByte(',') catch unreachable;
                const wj = d.toWireJson(alloc) catch unreachable;
                defer alloc.free(wj);
                out.writer.writeAll(wj) catch unreachable;
            }
            out.writer.writeByte(']') catch unreachable;
            return .{ .ok = out.toOwnedSlice() catch unreachable };
        }

        fn runMutation(_: *anyopaque, alloc: Allocator, name: []const u8, args_json: []const u8, env: *ExecutionEnv) ExecResult {
            if (!std.mem.eql(u8, name, "messages.send")) {
                return .{ .err = alloc.dupe(u8, "unknown mutation") catch &.{} };
            }
            const id = env.dbInsert(alloc, "", "messages", args_json) catch
                return .{ .err = alloc.dupe(u8, "insert err") catch &.{} };
            defer alloc.free(id);
            var out: std.Io.Writer.Allocating = .init(alloc);
            storage_mod.writeJsonString(&out.writer, id) catch unreachable;
            return .{ .ok = out.toOwnedSlice() catch unreachable };
        }

        fn runAction(_: *anyopaque, alloc: Allocator, _: []const u8, _: []const u8, _: *ExecutionEnv) ExecResult {
            return .{ .ok = alloc.dupe(u8, "true") catch &.{} };
        }

        const vtable = AppExecutor.VTable{
            .manifest = &getManifest,
            .executeQuery = &runQuery,
            .executeMutation = &runMutation,
            .executeAction = &runAction,
        };
    };

    const Capture = struct {
        alloc: Allocator,
        frames: std.ArrayList([]u8) = .empty,

        fn deinit(self: *@This()) void {
            for (self.frames.items) |f| self.alloc.free(f);
            self.frames.deinit(self.alloc);
        }

        fn sink(self: *@This()) ClientSink {
            const Self = @This();
            const Helper = struct {
                fn send(ptr: *anyopaque, payload: []const u8) void {
                    const c: *Self = @ptrCast(@alignCast(ptr));
                    c.frames.append(c.alloc, c.alloc.dupe(u8, payload) catch return) catch {};
                }
            };
            return .{ .ptr = @ptrCast(self), .sendFn = &Helper.send };
        }
    };

    var store = try WalStore.openInMemory(allocator, io);
    defer store.deinit();

    var mock = MockExec{ .mf = &manifest };
    const exec = AppExecutor{ .ptr = @ptrCast(&mock), .vtable = &MockExec.vtable };

    var engine_a = try ConcaveEngine.init(allocator, io, .{ .wal = store }, exec, .{});
    defer engine_a.deinit();
    var engine_b = try ConcaveEngine.init(allocator, io, .{ .wal = store }, exec, .{});
    defer engine_b.deinit();

    var cap_gen = Capture{ .alloc = allocator };
    defer cap_gen.deinit();
    var cap_roc = Capture{ .alloc = allocator };
    defer cap_roc.deinit();

    const cid_gen = try engine_b.registerClient(cap_gen.sink());
    const cid_roc = try engine_b.registerClient(cap_roc.sink());

    try engine_b.subscribe(cid_gen, "s1", "messages.list", "{\"room\":\"general\"}");
    try engine_b.subscribe(cid_roc, "s2", "messages.list", "{\"room\":\"roc\"}");
    try std.testing.expectEqual(@as(usize, 1), cap_gen.frames.items.len);
    try std.testing.expectEqual(@as(usize, 1), cap_roc.frames.items.len);

    // Commit on replica A -> poll on replica B -> only general subscriber receives transition!
    const mres = try engine_a.executeMutation(allocator, "messages.send", "{\"room\":\"general\",\"body\":\"cross-node-zig\"}", null);
    defer mres.deinit(allocator);
    try std.testing.expect(mres.result == .ok);

    const processed = try engine_b.pollCommitLog();
    try std.testing.expectEqual(@as(usize, 1), processed);
    try std.testing.expectEqual(@as(usize, 2), cap_gen.frames.items.len);
    try std.testing.expect(std.mem.indexOf(u8, cap_gen.frames.items[1], "cross-node-zig") != null);
    try std.testing.expectEqual(@as(usize, 1), cap_roc.frames.items.len);
}
