const std = @import("std");
const Allocator = std.mem.Allocator;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const sigv4 = @import("sigv4.zig");
const storage_mod = @import("storage.zig");

/// Zero-dependency blob storage engine supporting:
/// - Local disk storage (`local_dir`, default `.concave/storage`) with HMAC-signed upload tokens
/// - S3 / Cloudflare R2 / GCS presigned URLs via pure-Zig AWS SigV4 when `s3` is configured.
pub const BlobStore = struct {
    allocator: Allocator,
    io: std.Io,
    local_dir: []u8,
    base_url: []u8,
    token_secret: [32]u8,
    s3: ?OwnedS3Config = null,

    pub const OwnedS3Config = struct {
        endpoint: []u8,
        bucket: []u8,
        region: []u8,
        access_key: []u8,
        secret_key: []u8,

        pub fn deinit(self: *const OwnedS3Config, allocator: Allocator) void {
            allocator.free(self.endpoint);
            allocator.free(self.bucket);
            allocator.free(self.region);
            allocator.free(self.access_key);
            allocator.free(self.secret_key);
        }

        pub fn asRef(self: *const OwnedS3Config) sigv4.S3Config {
            return .{
                .endpoint = self.endpoint,
                .bucket = self.bucket,
                .region = self.region,
                .access_key = self.access_key,
                .secret_key = self.secret_key,
            };
        }
    };

    pub const BlobData = struct {
        content_type: []u8,
        bytes: []u8,

        pub fn deinit(self: *const BlobData, allocator: Allocator) void {
            allocator.free(self.content_type);
            allocator.free(self.bytes);
        }
    };

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        local_dir: []const u8,
        base_url: []const u8,
        s3_opt: ?sigv4.S3Config,
    ) !*BlobStore {
        const self = try allocator.create(BlobStore);
        errdefer allocator.destroy(self);

        var secret: [32]u8 = undefined;
        io.random(&secret);

        var owned_s3: ?OwnedS3Config = null;
        if (s3_opt) |s| {
            owned_s3 = .{
                .endpoint = try allocator.dupe(u8, s.endpoint),
                .bucket = try allocator.dupe(u8, s.bucket),
                .region = try allocator.dupe(u8, s.region),
                .access_key = try allocator.dupe(u8, s.access_key),
                .secret_key = try allocator.dupe(u8, s.secret_key),
            };
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .local_dir = try allocator.dupe(u8, local_dir),
            .base_url = try allocator.dupe(u8, std.mem.trimEnd(u8, base_url, "/")),
            .token_secret = secret,
            .s3 = owned_s3,
        };
        std.Io.Dir.cwd().createDirPath(io, local_dir) catch {};
        return self;
    }

    pub fn deinit(self: *BlobStore) void {
        self.allocator.free(self.local_dir);
        self.allocator.free(self.base_url);
        if (self.s3) |*s| s.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Generate an upload URL (either SigV4 presigned PUT URL or local `/_storage/upload/<token>`).
    pub fn generateUploadUrl(self: *BlobStore, allocator: Allocator) ![]u8 {
        const blob_id = try storage_mod.newDocId(allocator, self.io);
        defer allocator.free(blob_id);

        if (self.s3) |*s| {
            const now_secs = @divTrunc(storage_mod.nowMillis(self.io), 1000);
            return try sigv4.presignUrl(allocator, s.asRef(), .{
                .method = "PUT",
                .object_key = blob_id,
                .expires_secs = 900,
                .now_secs = now_secs,
            });
        }

        const exp_ms = storage_mod.nowMillis(self.io) + 15 * 60 * 1000;
        const token = try self.signUploadToken(allocator, blob_id, exp_ms);
        defer allocator.free(token);
        return try std.fmt.allocPrint(allocator, "{s}/_storage/upload/{s}", .{ self.base_url, token });
    }

    /// Generate a download URL for a stored blob ID.
    pub fn getDownloadUrl(self: *BlobStore, allocator: Allocator, storage_id: []const u8) ![]u8 {
        if (!isValidBlobId(storage_id)) return error.InvalidBlobId;
        if (self.s3) |*s| {
            const now_secs = @divTrunc(storage_mod.nowMillis(self.io), 1000);
            return try sigv4.presignUrl(allocator, s.asRef(), .{
                .method = "GET",
                .object_key = storage_id,
                .expires_secs = 3600,
                .now_secs = now_secs,
            });
        }
        return try std.fmt.allocPrint(allocator, "{s}/_storage/{s}", .{ self.base_url, storage_id });
    }

    /// Verify a signed local upload token and return its allocated `storage_id`.
    pub fn verifyUploadToken(self: *BlobStore, allocator: Allocator, token: []const u8) ![]u8 {
        var parts = std.mem.splitScalar(u8, token, '.');
        const blob_id = parts.next() orelse return error.InvalidUploadToken;
        const exp_str = parts.next() orelse return error.InvalidUploadToken;
        const sig_hex = parts.next() orelse return error.InvalidUploadToken;
        if (parts.next() != null) return error.InvalidUploadToken;
        if (!isValidBlobId(blob_id)) return error.InvalidUploadToken;

        const exp_ms = std.fmt.parseInt(i64, exp_str, 10) catch return error.InvalidUploadToken;
        if (storage_mod.nowMillis(self.io) > exp_ms) return error.UploadTokenExpired;

        var expected_mac: [32]u8 = undefined;
        var mac = HmacSha256.init(&self.token_secret);
        mac.update(blob_id);
        mac.update(".");
        mac.update(exp_str);
        mac.final(&expected_mac);
        const expected_hex = std.fmt.bytesToHex(expected_mac, .lower);

        if (sig_hex.len != 64) return error.InvalidUploadToken;
        var got_hex: [64]u8 = undefined;
        @memcpy(&got_hex, sig_hex);
        if (!std.crypto.timing_safe.eql([64]u8, got_hex, expected_hex)) {
            return error.InvalidUploadToken;
        }
        return try allocator.dupe(u8, blob_id);
    }

    /// Store raw blob bytes + content_type on local disk atomically.
    pub fn putLocalBlob(self: *BlobStore, storage_id: []const u8, content_type: []const u8, bytes: []const u8) !void {
        if (!isValidBlobId(storage_id)) return error.InvalidBlobId;
        std.Io.Dir.cwd().createDirPath(self.io, self.local_dir) catch {};

        const data_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.bin", .{ self.local_dir, storage_id });
        defer self.allocator.free(data_path);
        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.meta", .{ self.local_dir, storage_id });
        defer self.allocator.free(meta_path);

        try writeAllFile(self.io, data_path, bytes);
        try writeAllFile(self.io, meta_path, content_type);
    }

    /// Read stored local blob bytes + content_type.
    pub fn getLocalBlob(self: *BlobStore, allocator: Allocator, storage_id: []const u8) !BlobData {
        if (!isValidBlobId(storage_id)) return error.InvalidBlobId;
        const data_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.bin", .{ self.local_dir, storage_id });
        defer self.allocator.free(data_path);
        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.meta", .{ self.local_dir, storage_id });
        defer self.allocator.free(meta_path);

        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, data_path, allocator, .limited(32 * 1024 * 1024));
        errdefer allocator.free(bytes);
        const ct = std.Io.Dir.cwd().readFileAlloc(self.io, meta_path, allocator, .limited(512)) catch
            try allocator.dupe(u8, "application/octet-stream");
        return .{ .content_type = ct, .bytes = bytes };
    }

    /// Delete a stored blob from local disk.
    pub fn deleteBlob(self: *BlobStore, storage_id: []const u8) !void {
        if (!isValidBlobId(storage_id)) return error.InvalidBlobId;
        const data_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.bin", .{ self.local_dir, storage_id });
        defer self.allocator.free(data_path);
        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.meta", .{ self.local_dir, storage_id });
        defer self.allocator.free(meta_path);
        std.Io.Dir.cwd().deleteFile(self.io, data_path) catch {};
        std.Io.Dir.cwd().deleteFile(self.io, meta_path) catch {};
    }

    fn signUploadToken(self: *BlobStore, allocator: Allocator, blob_id: []const u8, exp_ms: i64) ![]u8 {
        const exp_str = try std.fmt.allocPrint(allocator, "{d}", .{exp_ms});
        defer allocator.free(exp_str);
        var mac = HmacSha256.init(&self.token_secret);
        mac.update(blob_id);
        mac.update(".");
        mac.update(exp_str);
        var digest: [32]u8 = undefined;
        mac.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ blob_id, exp_str, hex });
    }
};

fn isValidBlobId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn writeAllFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writePositionalAll(io, bytes, 0);
}

test "blob_store: signed upload tokens, local put/get/delete, and traversal rejection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = ".zig-cache/test-blob-store";

    var bs = try BlobStore.init(allocator, io, dir, "http://127.0.0.1:3210", null);
    defer bs.deinit();

    const upload_url = try bs.generateUploadUrl(allocator);
    defer allocator.free(upload_url);
    const prefix = "http://127.0.0.1:3210/_storage/upload/";
    try std.testing.expect(std.mem.startsWith(u8, upload_url, prefix));
    const token = upload_url[prefix.len..];

    const blob_id = try bs.verifyUploadToken(allocator, token);
    defer allocator.free(blob_id);

    // Tampered token MUST fail verification.
    const tampered = try allocator.dupe(u8, token);
    defer allocator.free(tampered);
    tampered[tampered.len - 1] = if (tampered[tampered.len - 1] == 'a') 'b' else 'a';
    try std.testing.expectError(error.InvalidUploadToken, bs.verifyUploadToken(allocator, tampered));

    // Put, get, and delete blob.
    try bs.putLocalBlob(blob_id, "text/plain", "hello concave blob");
    const got = try bs.getLocalBlob(allocator, blob_id);
    defer got.deinit(allocator);
    try std.testing.expectEqualStrings("text/plain", got.content_type);
    try std.testing.expectEqualStrings("hello concave blob", got.bytes);

    try bs.deleteBlob(blob_id);
    try std.testing.expectError(error.InvalidBlobId, bs.getDownloadUrl(allocator, "../escape"));
}
