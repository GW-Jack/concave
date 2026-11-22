const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;
const manifest_mod = @import("manifest.zig");
const readset_mod = @import("readset.zig");
const storage_mod = @import("storage.zig");

const Document = storage_mod.Document;
const IndexQuery = storage_mod.IndexQuery;
const WriteOp = storage_mod.WriteOp;
const CommitEntry = storage_mod.CommitEntry;
const CommitResult = storage_mod.CommitResult;

pub const PgUrl = struct {
    host: []u8,
    port: u16,
    user: []u8,
    password: []u8,
    database: []u8,
    use_tls: bool,

    pub fn deinit(self: *const PgUrl, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.user);
        allocator.free(self.password);
        allocator.free(self.database);
    }

    /// Parse `postgres://user:pass@host:5432/dbname?sslmode=require` (or `postgresql://`).
    pub fn parse(allocator: Allocator, raw_url: []const u8) !PgUrl {
        const rest = if (std.mem.startsWith(u8, raw_url, "postgres://"))
            raw_url["postgres://".len..]
        else if (std.mem.startsWith(u8, raw_url, "postgresql://"))
            raw_url["postgresql://".len..]
        else
            return error.InvalidDatabaseUrl;

        // Split query string
        var main_part = rest;
        var query_part: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '?')) |qi| {
            main_part = rest[0..qi];
            query_part = rest[qi + 1 ..];
        }

        // Split auth@host/db
        var auth_part: []const u8 = "";
        var host_and_db = main_part;
        if (std.mem.lastIndexOfScalar(u8, main_part, '@')) |ai| {
            auth_part = main_part[0..ai];
            host_and_db = main_part[ai + 1 ..];
        }

        var user_raw: []const u8 = "postgres";
        var pass_raw: []const u8 = "";
        if (auth_part.len > 0) {
            if (std.mem.indexOfScalar(u8, auth_part, ':')) |ci| {
                user_raw = auth_part[0..ci];
                pass_raw = auth_part[ci + 1 ..];
            } else {
                user_raw = auth_part;
            }
        }

        var host_port = host_and_db;
        var db_raw: []const u8 = "postgres";
        if (std.mem.indexOfScalar(u8, host_and_db, '/')) |si| {
            host_port = host_and_db[0..si];
            if (si + 1 < host_and_db.len) {
                db_raw = host_and_db[si + 1 ..];
            }
        }

        var host_raw = host_port;
        var port: u16 = 5432;
        if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |pi| {
            host_raw = host_port[0..pi];
            port = std.fmt.parseInt(u16, host_port[pi + 1 ..], 10) catch 5432;
        }

        var use_tls = !std.mem.eql(u8, host_raw, "localhost") and !std.mem.eql(u8, host_raw, "127.0.0.1");
        var qit = std.mem.splitScalar(u8, query_part, '&');
        while (qit.next()) |kv| {
            if (std.mem.startsWith(u8, kv, "sslmode=")) {
                const mode = kv["sslmode=".len..];
                if (std.mem.eql(u8, mode, "disable")) {
                    use_tls = false;
                } else if (std.mem.eql(u8, mode, "require") or
                    std.mem.eql(u8, mode, "verify-ca") or
                    std.mem.eql(u8, mode, "verify-full"))
                {
                    use_tls = true;
                }
            }
        }

        return .{
            .host = try percentDecode(allocator, host_raw),
            .port = port,
            .user = try percentDecode(allocator, user_raw),
            .password = try percentDecode(allocator, pass_raw),
            .database = try percentDecode(allocator, db_raw),
            .use_tls = use_tls,
        };
    }
};

fn percentDecode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const byte = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch {
                try out.append(allocator, input[i]);
                i += 1;
                continue;
            };
            try out.append(allocator, byte);
            i += 3;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

const PgRow = struct {
    cols: [][]u8,

    fn deinit(self: *const PgRow, allocator: Allocator) void {
        for (self.cols) |c| allocator.free(c);
        allocator.free(self.cols);
    }
};

/// Single authenticated PostgreSQL Wire Protocol v3 connection (plain TCP or TLS 1.3).
const PgConn = struct {
    allocator: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    net_read_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined,
    net_write_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined,
    tls_read_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined,
    tls_write_buf: [std.crypto.tls.max_ciphertext_record_len]u8 = undefined,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    tls_client: ?std.crypto.tls.Client = null,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,

    fn connect(allocator: Allocator, io: std.Io, url: *const PgUrl) !*PgConn {
        const self = try allocator.create(PgConn);
        errdefer allocator.destroy(self);

        const host_name = try std.Io.net.HostName.init(url.host);
        const stream = try host_name.connect(io, url.port, .{ .mode = .stream });
        errdefer stream.close(io);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
        };
        self.stream_reader = self.stream.reader(io, &self.net_read_buf);
        self.stream_writer = self.stream.writer(io, &self.net_write_buf);

        if (url.use_tls) {
            // PostgreSQL SSLRequest: length=8, code=80877103 (0x04d2162f).
            var ssl_req: [8]u8 = undefined;
            std.mem.writeInt(u32, ssl_req[0..4], 8, .big);
            std.mem.writeInt(u32, ssl_req[4..8], 80877103, .big);
            try self.stream_writer.interface.writeAll(&ssl_req);
            try self.stream_writer.interface.flush();

            const reply = try self.stream_reader.interface.takeByte();
            if (reply != 'S') return error.PostgresTlsRejected;

            const now = std.Io.Clock.real.now(io);
            try self.ca_bundle.rescan(allocator, io, now);
            errdefer self.ca_bundle.deinit(allocator);

            var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);

            self.tls_client = try std.crypto.tls.Client.init(
                &self.stream_reader.interface,
                &self.stream_writer.interface,
                .{
                    .host = .{ .explicit = url.host },
                    .ca = .{ .bundle = .{
                        .gpa = allocator,
                        .io = io,
                        .lock = &self.ca_lock,
                        .bundle = &self.ca_bundle,
                    } },
                    .read_buffer = &self.tls_read_buf,
                    .write_buffer = &self.tls_write_buf,
                    .entropy = &entropy,
                    .realtime_now = now,
                },
            );
        }

        try self.startupAndAuth(url);
        return self;
    }

    fn deinit(self: *PgConn) void {
        // Best-effort Terminate ('X', len=4)
        const term = [5]u8{ 'X', 0, 0, 0, 4 };
        self.writer().writeAll(&term) catch {};
        self.writer().flush() catch {};
        self.ca_bundle.deinit(self.allocator);
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }

    fn reader(self: *PgConn) *std.Io.Reader {
        if (self.tls_client) |*t| return &t.reader;
        return &self.stream_reader.interface;
    }

    fn writer(self: *PgConn) *std.Io.Writer {
        if (self.tls_client) |*t| return &t.writer;
        return &self.stream_writer.interface;
    }

    fn readMsg(self: *PgConn, allocator: Allocator) !struct { tag: u8, payload: []u8 } {
        const r = self.reader();
        const tag = try r.takeByte();
        var len_buf: [4]u8 = undefined;
        try r.readSliceAll(&len_buf);
        const total_len = std.mem.readInt(u32, &len_buf, .big);
        if (total_len < 4) return error.InvalidPostgresFrame;
        const payload_len = total_len - 4;
        const payload = try allocator.alloc(u8, payload_len);
        errdefer allocator.free(payload);
        try r.readSliceAll(payload);
        return .{ .tag = tag, .payload = payload };
    }

    fn sendMsg(self: *PgConn, tag: ?u8, payload: []const u8) !void {
        const w = self.writer();
        if (tag) |t| try w.writeByte(t);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(payload.len + 4), .big);
        try w.writeAll(&len_buf);
        try w.writeAll(payload);
        try w.flush();
    }

    fn startupAndAuth(self: *PgConn, url: *const PgUrl) !void {
        var startup: std.ArrayList(u8) = .empty;
        defer startup.deinit(self.allocator);

        var ver_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver_buf, 196608, .big); // protocol 3.0
        try startup.appendSlice(self.allocator, &ver_buf);
        try startup.appendSlice(self.allocator, "user\x00");
        try startup.appendSlice(self.allocator, url.user);
        try startup.append(self.allocator, 0);
        try startup.appendSlice(self.allocator, "database\x00");
        try startup.appendSlice(self.allocator, url.database);
        try startup.append(self.allocator, 0);
        try startup.append(self.allocator, 0); // terminator

        try self.sendMsg(null, startup.items);

        var scram_client_first_bare: ?[]u8 = null;
        defer if (scram_client_first_bare) |s| self.allocator.free(s);
        var scram_nonce: ?[]u8 = null;
        defer if (scram_nonce) |s| self.allocator.free(s);

        while (true) {
            const msg = try self.readMsg(self.allocator);
            defer self.allocator.free(msg.payload);

            switch (msg.tag) {
                'R' => {
                    if (msg.payload.len < 4) return error.PostgresAuthFailed;
                    const auth_type = std.mem.readInt(u32, msg.payload[0..4], .big);
                    switch (auth_type) {
                        0 => {}, // AuthenticationOk
                        3 => {
                            // CleartextPassword
                            var p = try self.allocator.alloc(u8, url.password.len + 1);
                            defer self.allocator.free(p);
                            @memcpy(p[0..url.password.len], url.password);
                            p[url.password.len] = 0;
                            try self.sendMsg('p', p);
                        },
                        5 => {
                            // MD5Password
                            if (msg.payload.len < 8) return error.PostgresAuthFailed;
                            const salt = msg.payload[4..8];
                            var h1 = Md5.init(.{});
                            h1.update(url.password);
                            h1.update(url.user);
                            var d1: [16]u8 = undefined;
                            h1.final(&d1);
                            const hex1 = std.fmt.bytesToHex(d1, .lower);

                            var h2 = Md5.init(.{});
                            h2.update(&hex1);
                            h2.update(salt);
                            var d2: [16]u8 = undefined;
                            h2.final(&d2);
                            const hex2 = std.fmt.bytesToHex(d2, .lower);

                            var resp: [36]u8 = undefined;
                            @memcpy(resp[0..3], "md5");
                            @memcpy(resp[3..35], &hex2);
                            resp[35] = 0;
                            try self.sendMsg('p', &resp);
                        },
                        10 => {
                            // AuthenticationSASL -> SCRAM-SHA-256
                            var raw_nonce: [18]u8 = undefined;
                            self.io.random(&raw_nonce);
                            var nonce_buf: [24]u8 = undefined;
                            const nonce = std.base64.standard.Encoder.encode(&nonce_buf, &raw_nonce);
                            scram_nonce = try self.allocator.dupe(u8, nonce);
                            scram_client_first_bare = try std.fmt.allocPrint(self.allocator, "n=,r={s}", .{nonce});
                            const client_first = try std.fmt.allocPrint(self.allocator, "n,,{s}", .{scram_client_first_bare.?});
                            defer self.allocator.free(client_first);

                            var sasl: std.ArrayList(u8) = .empty;
                            defer sasl.deinit(self.allocator);
                            try sasl.appendSlice(self.allocator, "SCRAM-SHA-256\x00");
                            var clen: [4]u8 = undefined;
                            std.mem.writeInt(u32, &clen, @intCast(client_first.len), .big);
                            try sasl.appendSlice(self.allocator, &clen);
                            try sasl.appendSlice(self.allocator, client_first);
                            try self.sendMsg('p', sasl.items);
                        },
                        11 => {
                            // AuthenticationSASLContinue
                            const server_first = msg.payload[4..];
                            const client_final = try buildScramClientFinal(
                                self.allocator,
                                url.password,
                                scram_client_first_bare orelse return error.PostgresAuthFailed,
                                scram_nonce orelse return error.PostgresAuthFailed,
                                server_first,
                            );
                            defer self.allocator.free(client_final);
                            try self.sendMsg('p', client_final);
                        },
                        12 => {}, // AuthenticationSASLFinal
                        else => return error.UnsupportedPostgresAuth,
                    }
                },
                'Z' => return, // ReadyForQuery
                'E' => return error.PostgresAuthFailed,
                'S', 'K', 'N' => {}, // ParameterStatus, BackendKeyData, NoticeResponse
                else => {},
            }
        }
    }

    /// Execute a SQL query using PostgreSQL Simple Query protocol (`'Q'`), returning all text rows.
    /// Never uses server-side prepared statements, making it 100% compatible with PgBouncer / Neon poolers.
    fn queryRows(self: *PgConn, allocator: Allocator, sql: []const u8) ![]PgRow {
        const buf = try allocator.alloc(u8, sql.len + 1);
        defer allocator.free(buf);
        @memcpy(buf[0..sql.len], sql);
        buf[sql.len] = 0;
        try self.sendMsg('Q', buf);

        var rows: std.ArrayList(PgRow) = .empty;
        errdefer {
            for (rows.items) |*r| r.deinit(allocator);
            rows.deinit(allocator);
        }

        var had_error = false;
        while (true) {
            const msg = try self.readMsg(allocator);
            defer allocator.free(msg.payload);

            switch (msg.tag) {
                'D' => {
                    // DataRow
                    if (msg.payload.len < 2) continue;
                    const col_count = std.mem.readInt(u16, msg.payload[0..2], .big);
                    var cols = try allocator.alloc([]u8, col_count);
                    var filled: usize = 0;
                    errdefer {
                        for (cols[0..filled]) |c| allocator.free(c);
                        allocator.free(cols);
                    }
                    var pos: usize = 2;
                    for (0..col_count) |ci| {
                        const clen_i = std.mem.readInt(i32, msg.payload[pos..][0..4], .big);
                        pos += 4;
                        if (clen_i < 0) {
                            cols[ci] = try allocator.dupe(u8, "");
                        } else {
                            const clen: usize = @intCast(clen_i);
                            cols[ci] = try allocator.dupe(u8, msg.payload[pos .. pos + clen]);
                            pos += clen;
                        }
                        filled += 1;
                    }
                    try rows.append(allocator, .{ .cols = cols });
                },
                'E' => had_error = true,
                'Z' => {
                    if (had_error) return storage_mod.StorageError.StorageFailure;
                    return try rows.toOwnedSlice(allocator);
                },
                else => {},
            }
        }
    }

    fn exec(self: *PgConn, sql: []const u8) !void {
        const rows = try self.queryRows(self.allocator, sql);
        for (rows) |*r| r.deinit(self.allocator);
        self.allocator.free(rows);
    }
};

fn pbkdf2HmacSha256(password: []const u8, salt: []const u8, iterations: u32) [32]u8 {
    var u_prev: [32]u8 = undefined;
    var hmac = HmacSha256.init(password);
    hmac.update(salt);
    hmac.update(&[_]u8{ 0, 0, 0, 1 });
    hmac.final(&u_prev);

    var out = u_prev;
    var iter: u32 = 1;
    while (iter < iterations) : (iter += 1) {
        var next_u: [32]u8 = undefined;
        var h = HmacSha256.init(password);
        h.update(&u_prev);
        h.final(&next_u);
        for (0..32) |i| out[i] ^= next_u[i];
        u_prev = next_u;
    }
    return out;
}

fn buildScramClientFinal(
    allocator: Allocator,
    password: []const u8,
    client_first_bare: []const u8,
    client_nonce: []const u8,
    server_first: []const u8,
) ![]u8 {
    var full_nonce: ?[]const u8 = null;
    var salt_b64: ?[]const u8 = null;
    var iterations: u32 = 4096;

    var it = std.mem.splitScalar(u8, server_first, ',');
    while (it.next()) |part| {
        if (std.mem.startsWith(u8, part, "r=")) {
            full_nonce = part[2..];
        } else if (std.mem.startsWith(u8, part, "s=")) {
            salt_b64 = part[2..];
        } else if (std.mem.startsWith(u8, part, "i=")) {
            iterations = std.fmt.parseInt(u32, part[2..], 10) catch 4096;
        }
    }
    const r_val = full_nonce orelse return error.PostgresAuthFailed;
    if (!std.mem.startsWith(u8, r_val, client_nonce)) return error.PostgresAuthFailed;
    const s_b64 = salt_b64 orelse return error.PostgresAuthFailed;

    const salt_len = try std.base64.standard.Decoder.calcSizeForSlice(s_b64);
    const salt = try allocator.alloc(u8, salt_len);
    defer allocator.free(salt);
    try std.base64.standard.Decoder.decode(salt, s_b64);

    const salted = pbkdf2HmacSha256(password, salt, iterations);

    var client_key: [32]u8 = undefined;
    var ck_mac = HmacSha256.init(&salted);
    ck_mac.update("Client Key");
    ck_mac.final(&client_key);

    var stored_key: [32]u8 = undefined;
    Sha256.hash(&client_key, &stored_key, .{});

    const client_final_without_proof = try std.fmt.allocPrint(allocator, "c=biws,r={s}", .{r_val});
    defer allocator.free(client_final_without_proof);

    var sig_mac = HmacSha256.init(&stored_key);
    sig_mac.update(client_first_bare);
    sig_mac.update(",");
    sig_mac.update(server_first);
    sig_mac.update(",");
    sig_mac.update(client_final_without_proof);
    var client_sig: [32]u8 = undefined;
    sig_mac.final(&client_sig);

    var proof: [32]u8 = undefined;
    for (0..32) |i| proof[i] = client_key[i] ^ client_sig[i];

    var proof_b64_buf: [44]u8 = undefined;
    const proof_b64 = std.base64.standard.Encoder.encode(&proof_b64_buf, &proof);
    return try std.fmt.allocPrint(allocator, "{s},p={s}", .{ client_final_without_proof, proof_b64 });
}

/// Zero-dependency PostgreSQL `StorageBackend` implementation for Neon, PlanetScale PG, and Cloud SQL.
pub const PgStore = struct {
    allocator: Allocator,
    io: std.Io,
    url: PgUrl,
    deployment_id: []u8,
    mutex: std.Io.Mutex = .init,
    conn: ?*PgConn = null,

    pub fn connect(allocator: Allocator, io: std.Io, database_url: []const u8, deployment_id: []const u8) !*PgStore {
        const self = try allocator.create(PgStore);
        errdefer allocator.destroy(self);
        const parsed = try PgUrl.parse(allocator, database_url);
        errdefer parsed.deinit(allocator);
        const dep = try allocator.dupe(u8, deployment_id);
        errdefer allocator.free(dep);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .url = parsed,
            .deployment_id = dep,
            .conn = null,
        };
        // Eagerly establish initial connection to validate credentials.
        self.conn = try PgConn.connect(allocator, io, &self.url);
        return self;
    }

    pub fn deinit(self: *PgStore) void {
        if (self.conn) |c| c.deinit();
        self.url.deinit(self.allocator);
        self.allocator.free(self.deployment_id);
        self.allocator.destroy(self);
    }

    fn ensureConnLocked(self: *PgStore) !*PgConn {
        if (self.conn) |c| return c;
        const c = try PgConn.connect(self.allocator, self.io, &self.url);
        self.conn = c;
        return c;
    }

    pub fn initSchema(self: *PgStore, manifest: *const manifest_mod.AppManifest) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const conn = try self.ensureConnLocked();

        try conn.exec(
            \\CREATE TABLE IF NOT EXISTS documents (
            \\  deployment_id TEXT NOT NULL,
            \\  namespace TEXT NOT NULL,
            \\  table_name TEXT NOT NULL,
            \\  doc_id TEXT NOT NULL,
            \\  creation_time_ms BIGINT NOT NULL,
            \\  body_json JSONB NOT NULL,
            \\  PRIMARY KEY (deployment_id, namespace, table_name, doc_id)
            \\)
        );
        try conn.exec(
            \\CREATE TABLE IF NOT EXISTS index_entries (
            \\  deployment_id TEXT NOT NULL,
            \\  namespace TEXT NOT NULL,
            \\  table_name TEXT NOT NULL,
            \\  index_name TEXT NOT NULL,
            \\  encoded_key BYTEA NOT NULL,
            \\  doc_id TEXT NOT NULL,
            \\  PRIMARY KEY (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
            \\)
        );
        try conn.exec(
            \\CREATE INDEX IF NOT EXISTS idx_index_entries_doc
            \\  ON index_entries (deployment_id, namespace, table_name, doc_id)
        );
        try conn.exec(
            \\CREATE TABLE IF NOT EXISTS commit_log (
            \\  deployment_id TEXT NOT NULL,
            \\  commit_ts BIGINT NOT NULL,
            \\  writes_json JSONB NOT NULL,
            \\  PRIMARY KEY (deployment_id, commit_ts)
            \\)
        );
        _ = manifest;
    }

    pub fn latestCommitTs(self: *PgStore) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const conn = try self.ensureConnLocked();

        const sql = try allocSqlFormat(self.allocator, "SELECT COALESCE(MAX(commit_ts), 0) FROM commit_log WHERE deployment_id = {s}", .{try quoteSql(self.allocator, self.deployment_id)});
        defer self.allocator.free(sql);

        const rows = try conn.queryRows(self.allocator, sql);
        defer {
            for (rows) |*r| r.deinit(self.allocator);
            self.allocator.free(rows);
        }
        if (rows.len == 0 or rows[0].cols.len == 0) return 0;
        return std.fmt.parseInt(i64, rows[0].cols[0], 10) catch 0;
    }

    pub fn getDoc(self: *PgStore, allocator: Allocator, ns: []const u8, table: []const u8, doc_id: []const u8) !?Document {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const conn = try self.ensureConnLocked();

        const q_dep = try quoteSql(self.allocator, self.deployment_id);
        defer self.allocator.free(q_dep);
        const q_ns = try quoteSql(self.allocator, ns);
        defer self.allocator.free(q_ns);
        const q_tbl = try quoteSql(self.allocator, table);
        defer self.allocator.free(q_tbl);
        const q_id = try quoteSql(self.allocator, doc_id);
        defer self.allocator.free(q_id);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT creation_time_ms, body_json::text FROM documents WHERE deployment_id = {s} AND namespace = {s} AND table_name = {s} AND doc_id = {s}",
            .{ q_dep, q_ns, q_tbl, q_id },
        );
        defer self.allocator.free(sql);

        const rows = try conn.queryRows(self.allocator, sql);
        defer {
            for (rows) |*r| r.deinit(self.allocator);
            self.allocator.free(rows);
        }
        if (rows.len == 0 or rows[0].cols.len < 2) return null;
        return .{
            .id = try allocator.dupe(u8, doc_id),
            .creation_time_ms = std.fmt.parseInt(i64, rows[0].cols[0], 10) catch 0,
            .body_json = try allocator.dupe(u8, rows[0].cols[1]),
        };
    }

    pub fn scanIndex(self: *PgStore, allocator: Allocator, query: *const IndexQuery) ![]Document {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const conn = try self.ensureConnLocked();

        var sql: std.Io.Writer.Allocating = .init(self.allocator);
        defer sql.deinit();
        const w = &sql.writer;

        const q_dep = try quoteSql(self.allocator, self.deployment_id);
        defer self.allocator.free(q_dep);
        const q_ns = try quoteSql(self.allocator, query.namespace);
        defer self.allocator.free(q_ns);
        const q_tbl = try quoteSql(self.allocator, query.table);
        defer self.allocator.free(q_tbl);
        const q_idx = try quoteSql(self.allocator, query.index_name);
        defer self.allocator.free(q_idx);

        try w.print(
            \\SELECT d.doc_id, d.creation_time_ms, d.body_json::text
            \\FROM index_entries ie
            \\INNER JOIN documents d
            \\  ON d.deployment_id = ie.deployment_id
            \\ AND d.namespace = ie.namespace
            \\ AND d.table_name = ie.table_name
            \\ AND d.doc_id = ie.doc_id
            \\WHERE ie.deployment_id = {s} AND ie.namespace = {s} AND ie.table_name = {s} AND ie.index_name = {s}
        , .{ q_dep, q_ns, q_tbl, q_idx });

        switch (query.start) {
            .unbounded => {},
            .included => |k| {
                const hex = try quoteByteaHex(self.allocator, k);
                defer self.allocator.free(hex);
                try w.print(" AND ie.encoded_key >= {s}", .{hex});
            },
            .excluded => |k| {
                const hex = try quoteByteaHex(self.allocator, k);
                defer self.allocator.free(hex);
                try w.print(" AND ie.encoded_key > {s}", .{hex});
            },
        }
        switch (query.end) {
            .unbounded => {},
            .included => |k| {
                const hex = try quoteByteaHex(self.allocator, k);
                defer self.allocator.free(hex);
                try w.print(" AND ie.encoded_key <= {s}", .{hex});
            },
            .excluded => |k| {
                const hex = try quoteByteaHex(self.allocator, k);
                defer self.allocator.free(hex);
                try w.print(" AND ie.encoded_key < {s}", .{hex});
            },
        }
        switch (query.order) {
            .asc => try w.writeAll(" ORDER BY ie.encoded_key ASC, ie.doc_id ASC"),
            .desc => try w.writeAll(" ORDER BY ie.encoded_key DESC, ie.doc_id DESC"),
        }
        if (query.limit) |lim| {
            try w.print(" LIMIT {d}", .{lim});
        }

        const rows = try conn.queryRows(self.allocator, sql.written());
        defer {
            for (rows) |*r| r.deinit(self.allocator);
            self.allocator.free(rows);
        }

        var out = try allocator.alloc(Document, rows.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*d| d.deinit(allocator);
            allocator.free(out);
        }
        for (rows, 0..) |row, i| {
            out[i] = .{
                .id = try allocator.dupe(u8, row.cols[0]),
                .creation_time_ms = std.fmt.parseInt(i64, row.cols[1], 10) catch 0,
                .body_json = try allocator.dupe(u8, row.cols[2]),
            };
            built += 1;
        }
        return out;
    }

    pub fn commitTx(
        self: *PgStore,
        allocator: Allocator,
        manifest: *const manifest_mod.AppManifest,
        snapshot_ts: i64,
        read_set: *const readset_mod.ReadSet,
        writes: []const WriteOp,
    ) !CommitResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const conn = try self.ensureConnLocked();

        const q_dep = try quoteSql(self.allocator, self.deployment_id);
        defer self.allocator.free(q_dep);

        try conn.exec("BEGIN");
        errdefer conn.exec("ROLLBACK") catch {};

        const lock_sql = try std.fmt.allocPrint(self.allocator, "SELECT pg_advisory_xact_lock(hashtext({s}))", .{q_dep});
        defer self.allocator.free(lock_sql);
        try conn.exec(lock_sql);

        const ts_sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT COALESCE(MAX(commit_ts), 0) FROM commit_log WHERE deployment_id = {s}",
            .{q_dep},
        );
        defer self.allocator.free(ts_sql);
        const ts_rows = try conn.queryRows(self.allocator, ts_sql);
        const latest_ts: i64 = if (ts_rows.len > 0 and ts_rows[0].cols.len > 0)
            std.fmt.parseInt(i64, ts_rows[0].cols[0], 10) catch 0
        else
            0;
        for (ts_rows) |*r| r.deinit(self.allocator);
        self.allocator.free(ts_rows);

        if (latest_ts > snapshot_ts) {
            const log_sql = try std.fmt.allocPrint(
                self.allocator,
                "SELECT writes_json::text FROM commit_log WHERE deployment_id = {s} AND commit_ts > {d} ORDER BY commit_ts ASC",
                .{ q_dep, snapshot_ts },
            );
            defer self.allocator.free(log_sql);
            const log_rows = try conn.queryRows(self.allocator, log_sql);
            defer {
                for (log_rows) |*r| r.deinit(self.allocator);
                self.allocator.free(log_rows);
            }
            for (log_rows) |row| {
                var ws = try parseWriteSetJson(self.allocator, row.cols[0]);
                defer ws.deinit(self.allocator);
                if (read_set.intersects(&ws)) {
                    conn.exec("ROLLBACK") catch {};
                    return storage_mod.StorageError.Conflict;
                }
            }
        }

        if (writes.len == 0) {
            try conn.exec("COMMIT");
            return .{ .commit_ts = latest_ts, .write_set = .{} };
        }

        var write_set: readset_mod.WriteSet = .{};
        errdefer write_set.deinit(allocator);

        for (writes) |op| {
            try self.applyPgOp(conn, manifest, q_dep, op, allocator, &write_set);
        }

        const next_ts = latest_ts + 1;
        const ws_json = try serializeWriteSetJson(self.allocator, &write_set);
        defer self.allocator.free(ws_json);
        const q_ws = try quoteSql(self.allocator, ws_json);
        defer self.allocator.free(q_ws);

        const ins_log = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO commit_log (deployment_id, commit_ts, writes_json) VALUES ({s}, {d}, {s}::jsonb)",
            .{ q_dep, next_ts, q_ws },
        );
        defer self.allocator.free(ins_log);
        try conn.exec(ins_log);
        try conn.exec("COMMIT");

        return .{ .commit_ts = next_ts, .write_set = write_set };
    }

    fn applyPgOp(
        self: *PgStore,
        conn: *PgConn,
        manifest: *const manifest_mod.AppManifest,
        q_dep: []const u8,
        op: WriteOp,
        ws_alloc: Allocator,
        write_set: *readset_mod.WriteSet,
    ) !void {
        switch (op) {
            .insert => |ins| {
                const q_ns = try quoteSql(self.allocator, ins.namespace);
                defer self.allocator.free(q_ns);
                const q_tbl = try quoteSql(self.allocator, ins.table);
                defer self.allocator.free(q_tbl);
                const q_id = try quoteSql(self.allocator, ins.doc_id);
                defer self.allocator.free(q_id);
                const q_body = try quoteSql(self.allocator, ins.body_json);
                defer self.allocator.free(q_body);

                const sql = try std.fmt.allocPrint(
                    self.allocator,
                    "INSERT INTO documents (deployment_id, namespace, table_name, doc_id, creation_time_ms, body_json) VALUES ({s}, {s}, {s}, {s}, {d}, {s}::jsonb)",
                    .{ q_dep, q_ns, q_tbl, q_id, ins.creation_time_ms, q_body },
                );
                defer self.allocator.free(sql);
                try conn.exec(sql);

                const doc = Document{
                    .id = ins.doc_id,
                    .creation_time_ms = ins.creation_time_ms,
                    .body_json = ins.body_json,
                };
                try write_set.recordDoc(ws_alloc, ins.namespace, ins.table, ins.doc_id);
                try self.insertPgIndexes(conn, manifest, q_dep, ins.namespace, ins.table, &doc, ws_alloc, write_set);
            },
            .replace => |rep| {
                const old = try self.fetchPgDocTx(conn, q_dep, rep.namespace, rep.table, rep.doc_id) orelse
                    return storage_mod.StorageError.NotFound;
                defer old.deinit(self.allocator);
                try self.recordOldPgIndexes(manifest, rep.namespace, rep.table, &old, ws_alloc, write_set);
                try self.deletePgIndexes(conn, q_dep, rep.namespace, rep.table, rep.doc_id);

                const q_ns = try quoteSql(self.allocator, rep.namespace);
                defer self.allocator.free(q_ns);
                const q_tbl = try quoteSql(self.allocator, rep.table);
                defer self.allocator.free(q_tbl);
                const q_id = try quoteSql(self.allocator, rep.doc_id);
                defer self.allocator.free(q_id);
                const q_body = try quoteSql(self.allocator, rep.body_json);
                defer self.allocator.free(q_body);

                const sql = try std.fmt.allocPrint(
                    self.allocator,
                    "UPDATE documents SET body_json = {s}::jsonb WHERE deployment_id = {s} AND namespace = {s} AND table_name = {s} AND doc_id = {s}",
                    .{ q_body, q_dep, q_ns, q_tbl, q_id },
                );
                defer self.allocator.free(sql);
                try conn.exec(sql);

                const new_doc = Document{
                    .id = rep.doc_id,
                    .creation_time_ms = old.creation_time_ms,
                    .body_json = rep.body_json,
                };
                try write_set.recordDoc(ws_alloc, rep.namespace, rep.table, rep.doc_id);
                try self.insertPgIndexes(conn, manifest, q_dep, rep.namespace, rep.table, &new_doc, ws_alloc, write_set);
            },
            .patch => |pat| {
                const old = try self.fetchPgDocTx(conn, q_dep, pat.namespace, pat.table, pat.doc_id) orelse
                    return storage_mod.StorageError.NotFound;
                defer old.deinit(self.allocator);
                try self.recordOldPgIndexes(manifest, pat.namespace, pat.table, &old, ws_alloc, write_set);
                try self.deletePgIndexes(conn, q_dep, pat.namespace, pat.table, pat.doc_id);

                const merged = try storage_mod.applyPatchJson(self.allocator, old.body_json, pat.patch_json);
                defer self.allocator.free(merged);

                const q_ns = try quoteSql(self.allocator, pat.namespace);
                defer self.allocator.free(q_ns);
                const q_tbl = try quoteSql(self.allocator, pat.table);
                defer self.allocator.free(q_tbl);
                const q_id = try quoteSql(self.allocator, pat.doc_id);
                defer self.allocator.free(q_id);
                const q_body = try quoteSql(self.allocator, merged);
                defer self.allocator.free(q_body);

                const sql = try std.fmt.allocPrint(
                    self.allocator,
                    "UPDATE documents SET body_json = {s}::jsonb WHERE deployment_id = {s} AND namespace = {s} AND table_name = {s} AND doc_id = {s}",
                    .{ q_body, q_dep, q_ns, q_tbl, q_id },
                );
                defer self.allocator.free(sql);
                try conn.exec(sql);

                const new_doc = Document{
                    .id = pat.doc_id,
                    .creation_time_ms = old.creation_time_ms,
                    .body_json = merged,
                };
                try write_set.recordDoc(ws_alloc, pat.namespace, pat.table, pat.doc_id);
                try self.insertPgIndexes(conn, manifest, q_dep, pat.namespace, pat.table, &new_doc, ws_alloc, write_set);
            },
            .delete => |del| {
                if (try self.fetchPgDocTx(conn, q_dep, del.namespace, del.table, del.doc_id)) |old| {
                    defer old.deinit(self.allocator);
                    try self.recordOldPgIndexes(manifest, del.namespace, del.table, &old, ws_alloc, write_set);
                    try self.deletePgIndexes(conn, q_dep, del.namespace, del.table, del.doc_id);

                    const q_ns = try quoteSql(self.allocator, del.namespace);
                    defer self.allocator.free(q_ns);
                    const q_tbl = try quoteSql(self.allocator, del.table);
                    defer self.allocator.free(q_tbl);
                    const q_id = try quoteSql(self.allocator, del.doc_id);
                    defer self.allocator.free(q_id);

                    const sql = try std.fmt.allocPrint(
                        self.allocator,
                        "DELETE FROM documents WHERE deployment_id = {s} AND namespace = {s} AND table_name = {s} AND doc_id = {s}",
                        .{ q_dep, q_ns, q_tbl, q_id },
                    );
                    defer self.allocator.free(sql);
                    try conn.exec(sql);
                    try write_set.recordDoc(ws_alloc, del.namespace, del.table, del.doc_id);
                }
            },
        }
    }

    fn fetchPgDocTx(self: *PgStore, conn: *PgConn, q_dep: []const u8, ns: []const u8, table: []const u8, doc_id: []const u8) !?Document {
        const q_ns = try quoteSql(self.allocator, ns);
        defer self.allocator.free(q_ns);
        const q_tbl = try quoteSql(self.allocator, table);
        defer self.allocator.free(q_tbl);
        const q_id = try quoteSql(self.allocator, doc_id);
        defer self.allocator.free(q_id);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT creation_time_ms, body_json::text FROM documents WHERE deployment_id = {s} AND namespace = {s} AND table_name = {s} AND doc_id = {s}",
            .{ q_dep, q_ns, q_tbl, q_id },
        );
        defer self.allocator.free(sql);
        const rows = try conn.queryRows(self.allocator, sql);
        defer {
            for (rows) |*r| r.deinit(self.allocator);
            self.allocator.free(rows);
        }
        if (rows.len == 0 or rows[0].cols.len < 2) return null;
        return .{
            .id = try self.allocator.dupe(u8, doc_id),
            .creation_time_ms = std.fmt.parseInt(i64, rows[0].cols[0], 10) catch 0,
            .body_json = try self.allocator.dupe(u8, rows[0].cols[1]),
        };
    }

    fn recordOldPgIndexes(
        self: *PgStore,
        manifest: *const manifest_mod.AppManifest,
        ns: []const u8,
        table: []const u8,
        doc: *const Document,
        ws_alloc: Allocator,
        write_set: *readset_mod.WriteSet,
    ) !void {
        const entries = try storage_mod.computeIndexEntries(self.allocator, manifest, ns, table, doc);
        defer {
            for (entries) |*e| e.deinit(self.allocator);
            self.allocator.free(entries);
        }
        for (entries) |e| {
            try write_set.recordIndexKey(ws_alloc, ns, table, e.index_name, e.encoded_key);
        }
    }

    fn deletePgIndexes(self: *PgStore, conn: *PgConn, q_dep: []const u8, ns: []const u8, table: []const u8, doc_id: []const u8) !void {
        const q_ns = try quoteSql(self.allocator, ns);
        defer self.allocator.free(q_ns);
        const q_tbl = try quoteSql(self.allocator, table);
        defer self.allocator.free(q_tbl);
        const q_id = try quoteSql(self.allocator, doc_id);
        defer self.allocator.free(q_id);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "DELETE FROM index_entries WHERE deployment_id = {s} AND namespace = {s} AND table_name = {s} AND doc_id = {s}",
            .{ q_dep, q_ns, q_tbl, q_id },
        );
        defer self.allocator.free(sql);
        try conn.exec(sql);
    }

    fn insertPgIndexes(
        self: *PgStore,
        conn: *PgConn,
        manifest: *const manifest_mod.AppManifest,
        q_dep: []const u8,
        ns: []const u8,
        table: []const u8,
        doc: *const Document,
        ws_alloc: Allocator,
        write_set: *readset_mod.WriteSet,
    ) !void {
        const q_ns = try quoteSql(self.allocator, ns);
        defer self.allocator.free(q_ns);
        const q_tbl = try quoteSql(self.allocator, table);
        defer self.allocator.free(q_tbl);
        const q_id = try quoteSql(self.allocator, doc.id);
        defer self.allocator.free(q_id);

        const entries = try storage_mod.computeIndexEntries(self.allocator, manifest, ns, table, doc);
        defer {
            for (entries) |*e| e.deinit(self.allocator);
            self.allocator.free(entries);
        }
        for (entries) |e| {
            const q_idx = try quoteSql(self.allocator, e.index_name);
            defer self.allocator.free(q_idx);
            const q_hex = try quoteByteaHex(self.allocator, e.encoded_key);
            defer self.allocator.free(q_hex);
            const sql = try std.fmt.allocPrint(
                self.allocator,
                "INSERT INTO index_entries (deployment_id, namespace, table_name, index_name, encoded_key, doc_id) VALUES ({s}, {s}, {s}, {s}, {s}, {s})",
                .{ q_dep, q_ns, q_tbl, q_idx, q_hex, q_id },
            );
            defer self.allocator.free(sql);
            try conn.exec(sql);
            try write_set.recordIndexKey(ws_alloc, ns, table, e.index_name, e.encoded_key);
        }
    }

    pub fn commitsSince(self: *PgStore, allocator: Allocator, since_ts: i64) ![]CommitEntry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const conn = try self.ensureConnLocked();

        const q_dep = try quoteSql(self.allocator, self.deployment_id);
        defer self.allocator.free(q_dep);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT commit_ts, writes_json::text FROM commit_log WHERE deployment_id = {s} AND commit_ts > {d} ORDER BY commit_ts ASC",
            .{ q_dep, since_ts },
        );
        defer self.allocator.free(sql);

        const rows = try conn.queryRows(self.allocator, sql);
        defer {
            for (rows) |*r| r.deinit(self.allocator);
            self.allocator.free(rows);
        }

        var out = try allocator.alloc(CommitEntry, rows.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |*c| c.deinit(allocator);
            allocator.free(out);
        }
        for (rows, 0..) |row, i| {
            out[i] = .{
                .commit_ts = std.fmt.parseInt(i64, row.cols[0], 10) catch 0,
                .write_set = try parseWriteSetJson(allocator, row.cols[1]),
            };
            built += 1;
        }
        return out;
    }
};

fn allocSqlFormat(allocator: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    defer allocator.free(args[0]);
    return try std.fmt.allocPrint(allocator, fmt, args);
}

fn quoteSql(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn quoteByteaHex(allocator: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "E'\\\\x");
    const hex_chars = "0123456789abcdef";
    for (bytes) |b| {
        try out.append(allocator, hex_chars[b >> 4]);
        try out.append(allocator, hex_chars[b & 0x0F]);
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn serializeWriteSetJson(allocator: Allocator, ws: *const readset_mod.WriteSet) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\"docs\":[");
    for (ws.docs.items, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"ns\":");
        try storage_mod.writeJsonString(w, d.namespace);
        try w.writeAll(",\"t\":");
        try storage_mod.writeJsonString(w, d.table);
        try w.writeAll(",\"id\":");
        try storage_mod.writeJsonString(w, d.doc_id);
        try w.writeByte('}');
    }
    try w.writeAll("],\"keys\":[");
    for (ws.index_keys.items, 0..) |k, i| {
        if (i > 0) try w.writeByte(',');
        const b64_len = std.base64.standard.Encoder.calcSize(k.encoded_key.len);
        const b64_buf = try allocator.alloc(u8, b64_len);
        defer allocator.free(b64_buf);
        const b64 = std.base64.standard.Encoder.encode(b64_buf, k.encoded_key);

        try w.writeAll("{\"ns\":");
        try storage_mod.writeJsonString(w, k.namespace);
        try w.writeAll(",\"t\":");
        try storage_mod.writeJsonString(w, k.table);
        try w.writeAll(",\"i\":");
        try storage_mod.writeJsonString(w, k.index_name);
        try w.writeAll(",\"k\":");
        try storage_mod.writeJsonString(w, b64);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return try out.toOwnedSlice();
}

fn parseWriteSetJson(allocator: Allocator, raw: []const u8) !readset_mod.WriteSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ws: readset_mod.WriteSet = .{};
    errdefer ws.deinit(allocator);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return ws;
    if (parsed != .object) return ws;

    if (parsed.object.get("docs")) |docs_v| {
        if (docs_v == .array) {
            for (docs_v.array.items) |dv| {
                if (dv != .object) continue;
                const ns = (dv.object.get("ns") orelse continue).string;
                const t = (dv.object.get("t") orelse continue).string;
                const id = (dv.object.get("id") orelse continue).string;
                try ws.recordDoc(allocator, ns, t, id);
            }
        }
    }
    if (parsed.object.get("keys")) |keys_v| {
        if (keys_v == .array) {
            for (keys_v.array.items) |kv| {
                if (kv != .object) continue;
                const ns = (kv.object.get("ns") orelse continue).string;
                const t = (kv.object.get("t") orelse continue).string;
                const i_name = (kv.object.get("i") orelse continue).string;
                const b64 = (kv.object.get("k") orelse continue).string;
                const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch continue;
                const dec = try allocator.alloc(u8, dec_len);
                defer allocator.free(dec);
                std.base64.standard.Decoder.decode(dec, b64) catch continue;
                try ws.recordIndexKey(allocator, ns, t, i_name, dec);
            }
        }
    }
    return ws;
}

test "pg url parser handles Neon and PlanetScale connection strings" {
    const allocator = std.testing.allocator;
    const url = try PgUrl.parse(allocator, "postgresql://neondb_owner:s3cr%40t@ep-cool-123-pooler.us-east-1.aws.neon.tech:5432/neondb?sslmode=require");
    defer url.deinit(allocator);
    try std.testing.expectEqualStrings("neondb_owner", url.user);
    try std.testing.expectEqualStrings("s3cr@t", url.password);
    try std.testing.expectEqualStrings("ep-cool-123-pooler.us-east-1.aws.neon.tech", url.host);
    try std.testing.expectEqual(@as(u16, 5432), url.port);
    try std.testing.expectEqualStrings("neondb", url.database);
    try std.testing.expect(url.use_tls);
}
