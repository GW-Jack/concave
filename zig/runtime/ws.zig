const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Frame = union(enum) {
    text: []u8,
    binary: []u8,
    ping: []u8,
    pong: []u8,
    close,

    pub fn deinit(self: *const Frame, allocator: Allocator) void {
        switch (self.*) {
            .text => |b| allocator.free(b),
            .binary => |b| allocator.free(b),
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

/// Thread-safe, reference-counted WebSocket writer handle shared between the connection loop and broadcast fanout.
/// Reference counting allows broadcast threads to send frames outside `clients_mutex`/`sync_mutex`
/// without any risk of use-after-free or fd reuse if the connection disconnects concurrently.
pub const WsSender = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),
    ref_count: std.atomic.Value(usize) = .init(1),
    allocator: ?Allocator = null,
    owns_stream: bool = false,

    pub fn init(io: std.Io, stream: std.Io.net.Stream) WsSender {
        const tv = std.posix.timeval{ .sec = 5, .usec = 0 };
        std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
        return .{ .io = io, .stream = stream };
    }

    pub fn createShared(allocator: Allocator, io: std.Io, stream: std.Io.net.Stream, owns_stream: bool) !*WsSender {
        const self = try allocator.create(WsSender);
        self.* = init(io, stream);
        self.allocator = allocator;
        self.owns_stream = owns_stream;
        return self;
    }

    pub fn retain(self: *WsSender) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *WsSender) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            if (self.owns_stream) {
                self.stream.close(self.io);
            }
            if (self.allocator) |alloc| {
                alloc.destroy(self);
            }
        }
    }

    pub fn markClosed(self: *WsSender) void {
        self.closed.store(true, .release);
        if (self.owns_stream) {
            self.stream.shutdown(self.io, .send) catch {};
        }
    }

    pub fn sendText(self: *WsSender, payload: []const u8) !void {
        try self.writeFrame(0x81, payload);
    }

    pub fn sendBinary(self: *WsSender, payload: []const u8) !void {
        try self.writeFrame(0x82, payload);
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

        var wbuf: [8192]u8 = undefined;
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

pub const WsReadError = error{
    FrameTooLarge,
    ProtocolError,
    OutOfMemory,
};

pub const MAX_MESSAGE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_FRAMES_PER_MSG: usize = 256;

/// Read the next complete RFC 6455 message from `reader` (handling fragmentation and unmasking).
/// Enforces RFC 6455 §5.1 client-to-server masking, UTF-8 validation on text frames, and a cap
/// on interleaved/continuation frames per message to prevent CPU spin DoS.
pub fn readFrame(allocator: Allocator, reader: *std.Io.Reader) WsReadError!Frame {
    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(allocator);
    var in_fragment = false;
    var frag_is_binary = false;
    var frame_count: usize = 0;

    while (true) {
        frame_count += 1;
        if (frame_count > MAX_FRAMES_PER_MSG) return error.ProtocolError;

        const b0 = reader.takeByte() catch return .close;
        const b1 = reader.takeByte() catch return .close;

        // RSV1..RSV3 bits must be 0 when no extensions are negotiated (RFC 6455 §5.2).
        if ((b0 & 0x70) != 0) return error.ProtocolError;

        const fin = (b0 & 0x80) != 0;
        const opcode = b0 & 0x0F;
        const masked = (b1 & 0x80) != 0;
        // RFC 6455 §5.1: A server MUST close the connection upon receiving an unmasked frame.
        if (!masked) return error.ProtocolError;
        var payload_len: u64 = b1 & 0x7F;

        const is_control = opcode >= 0x8;
        if (is_control and !fin) return error.ProtocolError;

        if (payload_len == 126) {
            if (is_control) return error.ProtocolError;
            var ext: [2]u8 = undefined;
            reader.readSliceAll(&ext) catch return .close;
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            if (is_control) return error.ProtocolError;
            var ext: [8]u8 = undefined;
            reader.readSliceAll(&ext) catch return .close;
            payload_len = std.mem.readInt(u64, &ext, .big);
            // RFC 6455 §5.2: MSB of 64-bit length must be 0.
            if ((payload_len & (@as(u64, 1) << 63)) != 0) return error.ProtocolError;
        }

        if (is_control and payload_len > 125) return error.ProtocolError;
        if (payload_len > MAX_MESSAGE_BYTES) return error.FrameTooLarge;

        var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            reader.readSliceAll(&mask_key) catch return .close;
        }

        const len_usize: usize = @intCast(payload_len);
        const chunk = try allocator.alloc(u8, len_usize);
        var keep_chunk = false;
        defer if (!keep_chunk) allocator.free(chunk);

        if (len_usize > 0) {
            reader.readSliceAll(chunk) catch return .close;
            if (masked) {
                var idx: usize = 0;
                if (chunk.len >= 8) {
                    const m32 = std.mem.readInt(u32, &mask_key, .little);
                    const m64: u64 = (@as(u64, m32) << 32) | @as(u64, m32);
                    while (idx + 8 <= chunk.len) : (idx += 8) {
                        const v = std.mem.readInt(u64, chunk[idx..][0..8], .little);
                        std.mem.writeInt(u64, chunk[idx..][0..8], v ^ m64, .little);
                    }
                }
                while (idx < chunk.len) : (idx += 1) {
                    chunk[idx] ^= mask_key[idx & 3];
                }
            }
        }

        switch (opcode) {
            0x8 => return .close,
            0x9 => {
                if (!in_fragment) {
                    keep_chunk = true;
                    return .{ .ping = chunk };
                }
                // Interleaved ping inside a fragmented message: keep assembling cleanly without leaking.
            },
            0xA => {
                if (!in_fragment) {
                    keep_chunk = true;
                    return .{ .pong = chunk };
                }
            },
            0x1, 0x2 => {
                if (in_fragment) return error.ProtocolError;
                const is_bin = (opcode == 0x2);
                if (fin) {
                    if (!is_bin and !std.unicode.utf8ValidateSlice(chunk)) return error.ProtocolError;
                    keep_chunk = true;
                    return if (is_bin) .{ .binary = chunk } else .{ .text = chunk };
                }
                in_fragment = true;
                frag_is_binary = is_bin;
                try msg_buf.appendSlice(allocator, chunk);
            },
            0x0 => {
                if (!in_fragment) return error.ProtocolError;
                if (msg_buf.items.len + chunk.len > MAX_MESSAGE_BYTES) return error.FrameTooLarge;
                try msg_buf.appendSlice(allocator, chunk);
                if (fin) {
                    if (!frag_is_binary and !std.unicode.utf8ValidateSlice(msg_buf.items)) return error.ProtocolError;
                    const owned = try msg_buf.toOwnedSlice(allocator);
                    return if (frag_is_binary) .{ .binary = owned } else .{ .text = owned };
                }
            },
            else => return error.ProtocolError,
        }
    }
}

test "computes RFC 6455 Sec-WebSocket-Accept key accurately" {
    var out: [28]u8 = undefined;
    const accept = computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}
