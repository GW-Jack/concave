const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Frame = union(enum) {
    text: []u8,
    ping: []u8,
    pong: []u8,
    close,

    pub fn deinit(self: *const Frame, allocator: Allocator) void {
        switch (self.*) {
            .text => |b| allocator.free(b),
            .ping => |b| allocator.free(b),
            .pong => |b| allocator.free(b),
            .close => {},
        }
    }
};

/// Compute RFC 6455 `Sec-WebSocket-Accept` header value from `Sec-WebSocket-Key`.
pub fn computeAcceptKey(key: []const u8, out_buf: *[28]u8) []const u8 {
    var sha = Sha1.init(.{});
    sha.update(std.mem.trim(u8, key, " \t\r\n"));
    sha.update(WS_GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out_buf, &digest);
}

/// Thread-safe WebSocket writer handle shared between the connection loop and broadcast fanout.
pub const WsSender = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init(io: std.Io, stream: std.Io.net.Stream) WsSender {
        return .{ .io = io, .stream = stream };
    }

    pub fn markClosed(self: *WsSender) void {
        self.closed.store(true, .release);
    }

    pub fn sendText(self: *WsSender, payload: []const u8) !void {
        try self.writeFrame(0x81, payload);
    }

    pub fn sendPong(self: *WsSender, payload: []const u8) !void {
        try self.writeFrame(0x8A, payload);
    }

    pub fn sendClose(self: *WsSender) void {
        self.writeFrame(0x88, &.{}) catch {};
        self.closed.store(true, .release);
    }

    fn writeFrame(self: *WsSender, first_byte: u8, payload: []const u8) !void {
        if (self.closed.load(.acquire)) return error.Closed;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed.load(.acquire)) return error.Closed;

        var hdr: [10]u8 = undefined;
        var hdr_len: usize = 2;
        hdr[0] = first_byte;

        if (payload.len < 126) {
            hdr[1] = @intCast(payload.len);
        } else if (payload.len <= 65535) {
            hdr[1] = 126;
            std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
            hdr_len = 4;
        } else {
            hdr[1] = 127;
            std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
            hdr_len = 10;
        }

        var wbuf: [4096]u8 = undefined;
        var sw = self.stream.writer(self.io, &wbuf);
        sw.interface.writeAll(hdr[0..hdr_len]) catch {
            self.closed.store(true, .release);
            return error.BrokenPipe;
        };
        if (payload.len > 0) {
            sw.interface.writeAll(payload) catch {
                self.closed.store(true, .release);
                return error.BrokenPipe;
            };
        }
        sw.interface.flush() catch {
            self.closed.store(true, .release);
            return error.BrokenPipe;
        };
    }
};

/// Read the next complete RFC 6455 message from `reader` (handling fragmentation and unmasking).
pub fn readFrame(allocator: Allocator, reader: *std.Io.Reader) !Frame {
    var msg_buf: std.ArrayList(u8) = .empty;
    errdefer msg_buf.deinit(allocator);
    var in_fragment = false;

    while (true) {
        const b0 = reader.takeByte() catch return .close;
        const b1 = reader.takeByte() catch return .close;

        const fin = (b0 & 0x80) != 0;
        const opcode = b0 & 0x0F;
        const masked = (b1 & 0x80) != 0;
        var payload_len: u64 = b1 & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            reader.readSliceAll(&ext) catch return .close;
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            reader.readSliceAll(&ext) catch return .close;
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // Guard against oversized payloads (16 MiB cap).
        if (payload_len > 16 * 1024 * 1024) return error.FrameTooLarge;

        var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            reader.readSliceAll(&mask_key) catch return .close;
        }

        const len_usize: usize = @intCast(payload_len);
        const chunk = try allocator.alloc(u8, len_usize);
        errdefer allocator.free(chunk);
        if (len_usize > 0) {
            reader.readSliceAll(chunk) catch return .close;
            if (masked) {
                for (chunk, 0..) |*byte, i| {
                    byte.* ^= mask_key[i & 3];
                }
            }
        }

        switch (opcode) {
            0x8 => {
                allocator.free(chunk);
                msg_buf.deinit(allocator);
                return .close;
            },
            0x9 => {
                // Control frames can be interleaved inside fragmented messages; return Ping immediately.
                if (!in_fragment) msg_buf.deinit(allocator);
                return .{ .ping = chunk };
            },
            0xA => {
                if (!in_fragment) msg_buf.deinit(allocator);
                return .{ .pong = chunk };
            },
            0x1, 0x2 => {
                if (fin and !in_fragment) {
                    msg_buf.deinit(allocator);
                    return .{ .text = chunk };
                }
                in_fragment = true;
                try msg_buf.appendSlice(allocator, chunk);
                allocator.free(chunk);
                if (fin) return .{ .text = try msg_buf.toOwnedSlice(allocator) };
            },
            0x0 => {
                try msg_buf.appendSlice(allocator, chunk);
                allocator.free(chunk);
                if (fin) return .{ .text = try msg_buf.toOwnedSlice(allocator) };
            },
            else => {
                allocator.free(chunk);
            },
        }
    }
}

test "computes RFC 6455 Sec-WebSocket-Accept key accurately" {
    var out: [28]u8 = undefined;
    const accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}
