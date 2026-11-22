const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest_mod = @import("../core/manifest.zig");
const readset_mod = @import("../core/readset.zig");
const storage_mod = @import("../core/storage.zig");
const auth_mod = @import("auth.zig");
const http_client = @import("http_client.zig");
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
};

pub const ClientSink = struct {
    ptr: *anyopaque,
    sendFn: *const fn (ptr: *anyopaque, payload: []const u8) void,

    pub fn send(self: ClientSink, payload: []const u8) void {
        self.sendFn(self.ptr, payload);
    }

    pub fn fromWsSender(sender: *ws_mod.WsSender) ClientSink {
        const Wrapper = struct {
            fn sendText(ptr: *anyopaque, payload: []const u8) void {
                const ws: *ws_mod.WsSender = @ptrCast(@alignCast(ptr));
                ws.sendText(payload) catch {};
            }
        };
        return .{ .ptr = @ptrCast(sender), .sendFn = &Wrapper.sendText };
    }
};

const ActiveSubscription = struct {
    sub_id: []u8,
    name: []u8,
    args_json: []u8,
    read_set: readset_mod.ReadSet,
    last_payload: ?ExecResult = null,

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

    clients_mutex: std.Io.Mutex = .init,
    clients: std.AutoHashMapUnmanaged(u64, *ClientSession) = .empty,
    next_client_id: std.atomic.Value(u64) = .init(1),

    last_broadcast_ts: std.atomic.Value(i64) = .init(0),
    sync_mutex: std.Io.Mutex = .init,
    stop_tailer: std.atomic.Value(bool) = .init(false),

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
        errdefer if (new_auth) |*a| a.deinit(self.allocator);

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

        var sink: ?ClientSink = null;
        {
            self.clients_mutex.lockUncancelable(self.io);
            defer self.clients_mutex.unlock(self.io);
            const sess = self.clients.get(client_id) orelse
                return try formatAuthError(self.allocator, "client disconnected");
            if (sess.auth) |*old| old.deinit(self.allocator);
            sess.auth = if (new_auth) |*a| try a.clone(self.allocator) else null;
            sink = sess.sink;

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
            if (sink) |client_sink| {
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
                client_sink.send(frame_json);
            }
        }

        defer if (new_auth) |*a| a.deinit(self.allocator);
        return try formatAuthOk(self.allocator, if (new_auth) |*a| a else null);
    }

    pub fn subscribe(self: *ConcaveEngine, client_id: u64, sub_id: []const u8, name: []const u8, args_json: []const u8) !void {
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

        var sink: ?ClientSink = null;
        {
            self.clients_mutex.lockUncancelable(self.io);
            defer self.clients_mutex.unlock(self.io);
            if (self.clients.get(client_id)) |sess| {
                sink = sess.sink;
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
                });
            } else {
                ran.read_set.deinit(self.allocator);
                ran.result.deinit(self.allocator);
            }
        }

        if (sink) |s| s.send(frame_json);
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
        var ran = self.runQueryInternal(name, args_json, auth);
        defer ran.read_set.deinit(self.allocator);
        defer ran.result.deinit(self.allocator);
        return try ran.result.clone(allocator);
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
        const snapshot_ts = self.storage.latestCommitTs() catch |err| {
            return .{
                .result = .{ .err = std.fmt.allocPrint(self.allocator, "storage error: {s}", .{@errorName(err)}) catch &.{} },
                .read_set = .{},
                .snapshot_ts = 0,
            };
        };

        var tx = tx_mod.TxContext.init(self.allocator, self.io, self.storage, self.manifest, snapshot_ts, true);
        defer {
            // Move read_set out before deiniting remaining tx fields.
            tx.read_set = .{};
            tx.deinit();
        }

        const auth_clone = if (auth) |a| a.clone(self.allocator) catch null else null;
        defer if (auth_clone) |*ac| ac.deinit(self.allocator);

        var env = ExecutionEnv{
            .allocator = self.allocator,
            .io = self.io,
            .auth = auth_clone,
            .mode = .{ .tx = &tx },
        };

        const res = self.executor.executeQuery(self.allocator, name, args_json, &env);
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
        for (0..MAX_OCC_RETRIES) |_| {
            const snapshot_ts = self.storage.latestCommitTs() catch |err| {
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
                .mode = .{ .tx = &tx },
            };

            const res = self.executor.executeMutation(allocator, name, args_json, &env);
            switch (res) {
                .err => return .{ .result = res, .commit_ts = 0 },
                .ok => {},
            }

            var commit = self.storage.commitTx(
                self.allocator,
                self.manifest,
                snapshot_ts,
                &tx.read_set,
                tx.writes.items,
            ) catch |err| {
                res.deinit(allocator);
                if (err == storage_mod.StorageError.Conflict) {
                    continue;
                }
                return .{ .result = .{ .err = try std.fmt.allocPrint(allocator, "commit error: {s}", .{@errorName(err)}) } };
            };
            defer commit.deinit(self.allocator);

            if (!commit.write_set.isEmpty()) {
                self.handleLocalCommit(commit.commit_ts, &commit.write_set);
            }
            return .{ .result = res, .commit_ts = commit.commit_ts };
        }

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
        const auth_clone = if (auth) |a| a.clone(self.allocator) catch null else null;
        defer if (auth_clone) |*ac| ac.deinit(self.allocator);

        var env = ExecutionEnv{
            .allocator = self.allocator,
            .io = self.io,
            .auth = auth_clone,
            .mode = .{ .action = self },
        };
        return self.executor.executeAction(allocator, name, args_json, &env);
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

            for (cj.subs.items) |sj| {
                var ran = self.runQueryInternal(sj.name, sj.args_json, if (cj.auth) |*a| a else null);
                var changed = false;

                {
                    self.clients_mutex.lockUncancelable(self.io);
                    defer self.clients_mutex.unlock(self.io);
                    if (self.clients.get(cj.client_id)) |sess| {
                        if (sess.subscriptions.getPtr(sj.sub_id)) |sub| {
                            changed = if (sub.last_payload) |*prev| !prev.eql(&ran.result) else true;
                            sub.read_set.deinit(self.allocator);
                            sub.read_set = ran.read_set;
                            ran.read_set = .{};
                            if (sub.last_payload) |*lp| lp.deinit(self.allocator);
                            sub.last_payload = ran.result.clone(self.allocator) catch null;
                        }
                    }
                }

                ran.read_set.deinit(self.allocator);
                if (changed) {
                    updates.append(self.allocator, .{
                        .sub_id = self.allocator.dupe(u8, sj.sub_id) catch {
                            ran.result.deinit(self.allocator);
                            continue;
                        },
                        .result = ran.result,
                    }) catch {
                        ran.result.deinit(self.allocator);
                    };
                } else {
                    ran.result.deinit(self.allocator);
                }
            }

            if (updates.items.len > 0) {
                const frame_json = formatTransition(self.allocator, commit_ts, updates.items) catch continue;
                defer self.allocator.free(frame_json);
                cj.sink.send(frame_json);
            }
        }
    }
};

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
    const key_mod = @import("../core/key.zig");
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
