const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
    _,
};

pub const FLAG_END_STREAM: u8 = 0x1;
pub const FLAG_ACK: u8 = 0x1;
pub const FLAG_END_HEADERS: u8 = 0x4;
pub const FLAG_PADDED: u8 = 0x8;
pub const FLAG_PRIORITY: u8 = 0x20;

pub const MAX_FRAME_SIZE: usize = 16384;

pub const H2Request = struct {
    method: []u8,
    path: []u8,
    query: []u8,
    content_type: ?[]u8 = null,
    authorization: ?[]u8 = null,
    accept_encoding: ?[]u8 = null,
    if_none_match: ?[]u8 = null,
    body: []u8,

    pub fn deinit(self: *const H2Request, allocator: Allocator) void {
        allocator.free(self.method);
        allocator.free(self.path);
        allocator.free(self.query);
        if (self.content_type) |v| allocator.free(v);
        if (self.authorization) |v| allocator.free(v);
        if (self.accept_encoding) |v| allocator.free(v);
        if (self.if_none_match) |v| allocator.free(v);
        allocator.free(self.body);
    }
};

pub const H2Response = struct {
    status: u16,
    content_type: []const u8,
    body: []u8,
    body_owned: bool = true,
    content_encoding: ?[]const u8 = null,
    etag: ?[]u8 = null,
    etag_owned: bool = true,
    cache_control: ?[]const u8 = null,

    pub fn deinit(self: *const H2Response, allocator: Allocator) void {
        if (self.body_owned and self.body.len > 0) allocator.free(self.body);
        if (self.etag_owned) {
            if (self.etag) |e| allocator.free(e);
        }
    }
};

pub const DispatchFn = *const fn (ctx: *anyopaque, allocator: Allocator, req: *const H2Request) H2Response;

const StreamBuf = struct {
    method: ?[]u8 = null,
    raw_path: ?[]u8 = null,
    content_type: ?[]u8 = null,
    authorization: ?[]u8 = null,
    accept_encoding: ?[]u8 = null,
    if_none_match: ?[]u8 = null,
    header_block: std.ArrayList(u8) = .empty,
    body: std.ArrayList(u8) = .empty,
    end_stream: bool = false,

    fn deinit(self: *StreamBuf, allocator: Allocator) void {
        if (self.method) |v| allocator.free(v);
        if (self.raw_path) |v| allocator.free(v);
        if (self.content_type) |v| allocator.free(v);
        if (self.authorization) |v| allocator.free(v);
        if (self.accept_encoding) |v| allocator.free(v);
        if (self.if_none_match) |v| allocator.free(v);
        self.header_block.deinit(allocator);
        self.body.deinit(allocator);
    }
};

/// Handle a cleartext HTTP/2 (`h2c` prior knowledge, RFC 9113) connection.
/// Caller has already verified and consumed the 24-byte `PREFACE`.
pub fn serveConnection(
    allocator: Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: *std.Io.Reader,
    dispatch_ctx: *anyopaque,
    dispatch_fn: DispatchFn,
) void {
    var wbuf: [16384]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    const writer = &sw.interface;

    // Send initial server SETTINGS: MAX_CONCURRENT_STREAMS=128, INITIAL_WINDOW_SIZE=1MB, ENABLE_PUSH=0
    const initial_settings = [_]u8{
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, // ENABLE_PUSH = 0
        0x00, 0x03, 0x00, 0x00, 0x00, 0x80, // MAX_CONCURRENT_STREAMS = 128
        0x00, 0x04, 0x00, 0x10, 0x00, 0x00, // INITIAL_WINDOW_SIZE = 1 MiB
    };
    writeFrame(writer, .settings, 0, 0, &initial_settings) catch return;
    // Grow connection-level receive window to 2 MiB
    var conn_wu: [4]u8 = undefined;
    std.mem.writeInt(u32, &conn_wu, 2 * 1024 * 1024, .big);
    writeFrame(writer, .window_update, 0, 0, &conn_wu) catch return;
    writer.flush() catch return;

    var hpack = HpackDecoder.init(allocator);
    defer hpack.deinit();

    var streams: std.AutoHashMapUnmanaged(u32, StreamBuf) = .empty;
    defer {
        var it = streams.valueIterator();
        while (it.next()) |sb| sb.deinit(allocator);
        streams.deinit(allocator);
    }

    var peer_max_frame: usize = MAX_FRAME_SIZE;
    var last_stream_id: u32 = 0;
    var stack_payload: [4096]u8 = undefined;
    var req_arena = std.heap.ArenaAllocator.init(allocator);
    defer req_arena.deinit();

    while (true) {
        if (reader.bufferedLen() == 0) {
            writer.flush() catch break;
        }
        var fhdr: [9]u8 = undefined;
        reader.readSliceAll(&fhdr) catch break;

        const length: usize = (@as(usize, fhdr[0]) << 16) | (@as(usize, fhdr[1]) << 8) | @as(usize, fhdr[2]);
        const ftype: FrameType = @enumFromInt(fhdr[3]);
        const flags: u8 = fhdr[4];
        const sid: u32 = std.mem.readInt(u32, fhdr[5..9], .big) & 0x7FFF_FFFF;

        if (length > 1024 * 1024) {
            sendGoAway(writer, last_stream_id, 6); // FRAME_SIZE_ERROR
            break;
        }
        var heap_payload: ?[]u8 = null;
        defer if (heap_payload) |hp| allocator.free(hp);
        const payload: []u8 = if (length <= stack_payload.len)
            stack_payload[0..length]
        else blk: {
            const hp = allocator.alloc(u8, length) catch break;
            heap_payload = hp;
            break :blk hp;
        };
        if (length > 0) {
            reader.readSliceAll(payload) catch break;
        }

        switch (ftype) {
            .settings => {
                if ((flags & FLAG_ACK) == 0) {
                    var off: usize = 0;
                    while (off + 6 <= payload.len) : (off += 6) {
                        const id = std.mem.readInt(u16, payload[off..][0..2], .big);
                        const val = std.mem.readInt(u32, payload[off + 2 ..][0..4], .big);
                        if (id == 0x5 and val >= 16384 and val <= 16777215) {
                            peer_max_frame = @min(@as(usize, val), 65536);
                        }
                    }
                    writeFrame(writer, .settings, FLAG_ACK, 0, &.{}) catch break;
                    writer.flush() catch break;
                }
            },
            .ping => {
                if ((flags & FLAG_ACK) == 0 and payload.len == 8) {
                    writeFrame(writer, .ping, FLAG_ACK, 0, payload) catch break;
                    writer.flush() catch break;
                }
            },
            .goaway => break,
            .window_update, .priority => {},
            .rst_stream => {
                if (streams.fetchRemove(sid)) |kv| {
                    var sb = kv.value;
                    sb.deinit(allocator);
                }
            },
            .headers, .continuation => {
                if (sid == 0) break;
                if (sid > last_stream_id) last_stream_id = sid;
                const gop = streams.getOrPut(allocator, sid) catch break;
                if (!gop.found_existing) gop.value_ptr.* = .{};

                var frag = payload;
                if (ftype == .headers) {
                    var pad_len: usize = 0;
                    if ((flags & FLAG_PADDED) != 0) {
                        if (frag.len < 1) break;
                        pad_len = frag[0];
                        frag = frag[1..];
                    }
                    if ((flags & FLAG_PRIORITY) != 0) {
                        if (frag.len < 5) break;
                        frag = frag[5..];
                    }
                    if (pad_len > frag.len) break;
                    frag = frag[0 .. frag.len - pad_len];
                    if ((flags & FLAG_END_STREAM) != 0) {
                        gop.value_ptr.end_stream = true;
                    }
                }
                gop.value_ptr.header_block.appendSlice(allocator, frag) catch break;

                if ((flags & FLAG_END_HEADERS) != 0) {
                    hpack.decodeBlock(gop.value_ptr.header_block.items, gop.value_ptr) catch {
                        sendGoAway(writer, last_stream_id, 9); // COMPRESSION_ERROR
                        break;
                    };
                    gop.value_ptr.header_block.clearRetainingCapacity();
                    if (gop.value_ptr.end_stream) {
                        defer _ = req_arena.reset(.retain_capacity);
                        completeStream(req_arena.allocator(), writer, reader, sid, gop.value_ptr, peer_max_frame, dispatch_ctx, dispatch_fn) catch break;
                        if (streams.fetchRemove(sid)) |kv| {
                            var sb = kv.value;
                            sb.deinit(allocator);
                        }
                    }
                }
            },
            .data => {
                if (sid == 0) break;
                const sb = streams.getPtr(sid) orelse continue;
                var data = payload;
                if ((flags & FLAG_PADDED) != 0) {
                    if (data.len < 1) break;
                    const pad_len = data[0];
                    data = data[1..];
                    if (pad_len > data.len) break;
                    data = data[0 .. data.len - pad_len];
                }
                if (sb.body.items.len + data.len > 16 * 1024 * 1024) {
                    var rst: [4]u8 = undefined;
                    std.mem.writeInt(u32, &rst, 11, .big); // ENHANCE_YOUR_CALM
                    writeFrame(writer, .rst_stream, 0, sid, &rst) catch break;
                    writer.flush() catch break;
                    if (streams.fetchRemove(sid)) |kv| {
                        var rem = kv.value;
                        rem.deinit(allocator);
                    }
                    continue;
                }
                sb.body.appendSlice(allocator, data) catch break;
                if (payload.len > 0) {
                    var wu: [4]u8 = undefined;
                    std.mem.writeInt(u32, &wu, @intCast(payload.len), .big);
                    writeFrame(writer, .window_update, 0, 0, &wu) catch break;
                    if ((flags & FLAG_END_STREAM) == 0) {
                        writeFrame(writer, .window_update, 0, sid, &wu) catch break;
                    }
                    writer.flush() catch break;
                }
                if ((flags & FLAG_END_STREAM) != 0) {
                    sb.end_stream = true;
                    defer _ = req_arena.reset(.retain_capacity);
                    completeStream(req_arena.allocator(), writer, reader, sid, sb, peer_max_frame, dispatch_ctx, dispatch_fn) catch break;
                    if (streams.fetchRemove(sid)) |kv| {
                        var rem = kv.value;
                        rem.deinit(allocator);
                    }
                }
            },
            else => {},
        }
    }
}

fn completeStream(
    allocator: Allocator,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    stream_id: u32,
    sb: *StreamBuf,
    max_frame: usize,
    dispatch_ctx: *anyopaque,
    dispatch_fn: DispatchFn,
) !void {
    const raw_target = sb.raw_path orelse "/";
    const q_idx = std.mem.indexOfScalar(u8, raw_target, '?');
    const path_slice = if (q_idx) |qi| raw_target[0..qi] else raw_target;
    const query_slice = if (q_idx) |qi| raw_target[qi + 1 ..] else "";

    // Zero-copy view directly over `sb` (valid for the entire duration of `dispatch_fn`).
    const req = H2Request{
        .method = @constCast(sb.method orelse "GET"),
        .path = @constCast(path_slice),
        .query = @constCast(query_slice),
        .content_type = sb.content_type,
        .authorization = sb.authorization,
        .accept_encoding = sb.accept_encoding,
        .if_none_match = sb.if_none_match,
        .body = sb.body.items,
    };

    const resp = dispatch_fn(dispatch_ctx, allocator, &req);
    defer resp.deinit(allocator);

    var hdr_block = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer hdr_block.deinit(allocator);

    // Encode `:status`
    switch (resp.status) {
        200 => try hdr_block.append(allocator, 0x88),
        204 => try hdr_block.append(allocator, 0x89),
        206 => try hdr_block.append(allocator, 0x8a),
        304 => try hdr_block.append(allocator, 0x8b),
        400 => try hdr_block.append(allocator, 0x8c),
        404 => try hdr_block.append(allocator, 0x8d),
        500 => try hdr_block.append(allocator, 0x8e),
        else => {
            var sbuf: [8]u8 = undefined;
            const sstr = std.fmt.bufPrint(&sbuf, "{d}", .{resp.status}) catch "200";
            try encodeHpackLiteralIndexedName(allocator, &hdr_block, 8, sstr);
        },
    }

    if (resp.content_type.len > 0) {
        try encodeHpackLiteralIndexedName(allocator, &hdr_block, 31, resp.content_type); // content-type
    }
    var cl_buf: [24]u8 = undefined;
    const cl_str = std.fmt.bufPrint(&cl_buf, "{d}", .{resp.body.len}) catch "0";
    try encodeHpackLiteralIndexedName(allocator, &hdr_block, 28, cl_str); // content-length
    if (resp.content_encoding) |ce| {
        try encodeHpackLiteralIndexedName(allocator, &hdr_block, 26, ce); // content-encoding
    }
    if (resp.etag) |et| {
        try encodeHpackLiteralIndexedName(allocator, &hdr_block, 34, et); // etag
    }
    if (resp.cache_control) |cc| {
        try encodeHpackLiteralIndexedName(allocator, &hdr_block, 24, cc); // cache-control
    }
    try encodeHpackLiteralIndexedName(allocator, &hdr_block, 59, "Accept-Encoding"); // vary
    try encodeHpackLiteralIndexedName(allocator, &hdr_block, 20, "*"); // access-control-allow-origin
    try encodeHpackLiteralNewName(allocator, &hdr_block, "access-control-allow-headers", "Content-Type, Authorization");
    try encodeHpackLiteralNewName(allocator, &hdr_block, "access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS");

    const hdr_flags: u8 = FLAG_END_HEADERS | (if (resp.body.len == 0) FLAG_END_STREAM else 0);
    try writeFrame(writer, .headers, hdr_flags, stream_id, hdr_block.items);

    var off: usize = 0;
    while (off < resp.body.len) {
        const chunk_len = @min(max_frame, resp.body.len - off);
        const is_last = (off + chunk_len == resp.body.len);
        try writeFrame(writer, .data, if (is_last) FLAG_END_STREAM else 0, stream_id, resp.body[off .. off + chunk_len]);
        off += chunk_len;
    }
    // Coalesce flushes when more HTTP/2 frames are already buffered on the socket!
    if (reader.bufferedLen() == 0) {
        try writer.flush();
    }
}

fn writeFrame(writer: *std.Io.Writer, ftype: FrameType, flags: u8, stream_id: u32, payload: []const u8) !void {
    var hdr: [9]u8 = undefined;
    hdr[0] = @intCast((payload.len >> 16) & 0xFF);
    hdr[1] = @intCast((payload.len >> 8) & 0xFF);
    hdr[2] = @intCast(payload.len & 0xFF);
    hdr[3] = @intFromEnum(ftype);
    hdr[4] = flags;
    std.mem.writeInt(u32, hdr[5..9], stream_id & 0x7FFF_FFFF, .big);
    try writer.writeAll(&hdr);
    if (payload.len > 0) try writer.writeAll(payload);
}

fn sendGoAway(writer: *std.Io.Writer, last_stream_id: u32, err_code: u32) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], last_stream_id & 0x7FFF_FFFF, .big);
    std.mem.writeInt(u32, buf[4..8], err_code, .big);
    writeFrame(writer, .goaway, 0, 0, &buf) catch {};
    writer.flush() catch {};
}

// =============================================================================
// RFC 7541 HPACK Encoder / Decoder + Appendix B Huffman Decoder
// =============================================================================

fn encodeHpackInt(allocator: Allocator, out: *std.ArrayList(u8), prefix_bits: u3, prefix_mask: u8, value: usize) !void {
    const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;
    if (value < max_prefix) {
        try out.append(allocator, prefix_mask | @as(u8, @intCast(value)));
        return;
    }
    try out.append(allocator, prefix_mask | @as(u8, @intCast(max_prefix)));
    var v = value - max_prefix;
    while (v >= 128) {
        try out.append(allocator, @as(u8, @intCast((v & 0x7F) | 0x80)));
        v >>= 7;
    }
    try out.append(allocator, @as(u8, @intCast(v)));
}

fn encodeHpackLiteralIndexedName(allocator: Allocator, out: *std.ArrayList(u8), name_index: usize, value: []const u8) !void {
    try encodeHpackInt(allocator, out, 4, 0x00, name_index); // Literal Header Field without Indexing
    try encodeHpackInt(allocator, out, 7, 0x00, value.len);
    try out.appendSlice(allocator, value);
}

fn encodeHpackLiteralNewName(allocator: Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try out.append(allocator, 0x00);
    try encodeHpackInt(allocator, out, 7, 0x00, name.len);
    try out.appendSlice(allocator, name);
    try encodeHpackInt(allocator, out, 7, 0x00, value.len);
    try out.appendSlice(allocator, value);
}

const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

const STATIC_TABLE = [_]HeaderPair{
    .{ .name = ":authority", .value = "" }, // 1
    .{ .name = ":method", .value = "GET" }, // 2
    .{ .name = ":method", .value = "POST" }, // 3
    .{ .name = ":path", .value = "/" }, // 4
    .{ .name = ":path", .value = "/index.html" }, // 5
    .{ .name = ":scheme", .value = "http" }, // 6
    .{ .name = ":scheme", .value = "https" }, // 7
    .{ .name = ":status", .value = "200" }, // 8
    .{ .name = ":status", .value = "204" }, // 9
    .{ .name = ":status", .value = "206" }, // 10
    .{ .name = ":status", .value = "304" }, // 11
    .{ .name = ":status", .value = "400" }, // 12
    .{ .name = ":status", .value = "404" }, // 13
    .{ .name = ":status", .value = "500" }, // 14
    .{ .name = "accept-charset", .value = "" }, // 15
    .{ .name = "accept-encoding", .value = "gzip, deflate" }, // 16
    .{ .name = "accept-language", .value = "" }, // 17
    .{ .name = "accept-ranges", .value = "" }, // 18
    .{ .name = "accept", .value = "" }, // 19
    .{ .name = "access-control-allow-origin", .value = "" }, // 20
    .{ .name = "age", .value = "" }, // 21
    .{ .name = "allow", .value = "" }, // 22
    .{ .name = "authorization", .value = "" }, // 23
    .{ .name = "cache-control", .value = "" }, // 24
    .{ .name = "content-disposition", .value = "" }, // 25
    .{ .name = "content-encoding", .value = "" }, // 26
    .{ .name = "content-language", .value = "" }, // 27
    .{ .name = "content-length", .value = "" }, // 28
    .{ .name = "content-location", .value = "" }, // 29
    .{ .name = "content-range", .value = "" }, // 30
    .{ .name = "content-type", .value = "" }, // 31
    .{ .name = "cookie", .value = "" }, // 32
    .{ .name = "date", .value = "" }, // 33
    .{ .name = "etag", .value = "" }, // 34
    .{ .name = "expect", .value = "" }, // 35
    .{ .name = "expires", .value = "" }, // 36
    .{ .name = "from", .value = "" }, // 37
    .{ .name = "host", .value = "" }, // 38
    .{ .name = "if-match", .value = "" }, // 39
    .{ .name = "if-modified-since", .value = "" }, // 40
    .{ .name = "if-none-match", .value = "" }, // 41
    .{ .name = "if-range", .value = "" }, // 42
    .{ .name = "if-unmodified-since", .value = "" }, // 43
    .{ .name = "last-modified", .value = "" }, // 44
    .{ .name = "link", .value = "" }, // 45
    .{ .name = "location", .value = "" }, // 46
    .{ .name = "max-forwards", .value = "" }, // 47
    .{ .name = "proxy-authenticate", .value = "" }, // 48
    .{ .name = "proxy-authorization", .value = "" }, // 49
    .{ .name = "range", .value = "" }, // 50
    .{ .name = "referer", .value = "" }, // 51
    .{ .name = "refresh", .value = "" }, // 52
    .{ .name = "retry-after", .value = "" }, // 53
    .{ .name = "server", .value = "" }, // 54
    .{ .name = "set-cookie", .value = "" }, // 55
    .{ .name = "strict-transport-security", .value = "" }, // 56
    .{ .name = "transfer-encoding", .value = "" }, // 57
    .{ .name = "user-agent", .value = "" }, // 58
    .{ .name = "vary", .value = "" }, // 59
    .{ .name = "via", .value = "" }, // 60
    .{ .name = "www-authenticate", .value = "" }, // 61
};

const DynEntry = struct {
    name: []u8,
    value: []u8,
};

pub const HpackDecoder = struct {
    allocator: Allocator,
    dynamic: std.ArrayList(DynEntry) = .empty,
    dynamic_size: usize = 0,
    max_dynamic_size: usize = 4096,

    pub fn init(allocator: Allocator) HpackDecoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HpackDecoder) void {
        for (self.dynamic.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.value);
        }
        self.dynamic.deinit(self.allocator);
    }

    fn getEntry(self: *const HpackDecoder, idx: usize) !HeaderPair {
        if (idx == 0) return error.InvalidHpackIndex;
        if (idx <= STATIC_TABLE.len) return STATIC_TABLE[idx - 1];
        const d_idx = idx - STATIC_TABLE.len - 1;
        if (d_idx >= self.dynamic.items.len) return error.InvalidHpackIndex;
        // Newest entry is at the end of `self.dynamic` (index 0 in RFC 7541).
        const e = self.dynamic.items[self.dynamic.items.len - 1 - d_idx];
        return .{ .name = e.name, .value = e.value };
    }

    fn insertDynamic(self: *HpackDecoder, name: []const u8, value: []const u8) !void {
        const entry_size = name.len + value.len + 32;
        if (entry_size > self.max_dynamic_size) {
            self.evictTo(0);
            return;
        }
        self.evictTo(self.max_dynamic_size - entry_size);
        const nc = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(nc);
        const vc = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(vc);
        try self.dynamic.append(self.allocator, .{ .name = nc, .value = vc });
        self.dynamic_size += entry_size;
    }

    fn evictTo(self: *HpackDecoder, target_max: usize) void {
        while (self.dynamic_size > target_max and self.dynamic.items.len > 0) {
            const oldest = self.dynamic.orderedRemove(0);
            const sz = oldest.name.len + oldest.value.len + 32;
            self.dynamic_size -|= sz;
            self.allocator.free(oldest.name);
            self.allocator.free(oldest.value);
        }
    }

    pub fn decodeBlock(self: *HpackDecoder, block: []const u8, target: *StreamBuf) !void {
        var pos: usize = 0;
        while (pos < block.len) {
            const b = block[pos];
            if ((b & 0x80) != 0) {
                // Indexed Header Field (7-bit prefix)
                const idx = try decodeInt(block, &pos, 7);
                const pair = try self.getEntry(idx);
                try applyHeader(self.allocator, target, pair.name, pair.value);
            } else if ((b & 0xC0) == 0x40) {
                // Literal Header Field with Incremental Indexing (6-bit prefix)
                const idx = try decodeInt(block, &pos, 6);
                const name = if (idx == 0) try decodeStr(self.allocator, block, &pos) else try self.allocator.dupe(u8, (try self.getEntry(idx)).name);
                defer self.allocator.free(name);
                const value = try decodeStr(self.allocator, block, &pos);
                defer self.allocator.free(value);
                try self.insertDynamic(name, value);
                try applyHeader(self.allocator, target, name, value);
            } else if ((b & 0xE0) == 0x20) {
                // Dynamic Table Size Update (5-bit prefix)
                const new_max = try decodeInt(block, &pos, 5);
                self.max_dynamic_size = @min(new_max, 65536);
                self.evictTo(self.max_dynamic_size);
            } else {
                // Literal Header Field without Indexing / Never Indexed (4-bit prefix)
                const idx = try decodeInt(block, &pos, 4);
                const name = if (idx == 0) try decodeStr(self.allocator, block, &pos) else try self.allocator.dupe(u8, (try self.getEntry(idx)).name);
                defer self.allocator.free(name);
                const value = try decodeStr(self.allocator, block, &pos);
                defer self.allocator.free(value);
                try applyHeader(self.allocator, target, name, value);
            }
        }
    }
};

fn applyHeader(allocator: Allocator, sb: *StreamBuf, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, ":method")) {
        if (sb.method) |old| allocator.free(old);
        sb.method = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, name, ":path")) {
        if (sb.raw_path) |old| allocator.free(old);
        sb.raw_path = try allocator.dupe(u8, value);
    } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
        if (sb.content_type) |old| allocator.free(old);
        sb.content_type = try allocator.dupe(u8, value);
    } else if (std.ascii.eqlIgnoreCase(name, "authorization")) {
        if (sb.authorization) |old| allocator.free(old);
        sb.authorization = try allocator.dupe(u8, value);
    } else if (std.ascii.eqlIgnoreCase(name, "accept-encoding")) {
        if (sb.accept_encoding) |old| allocator.free(old);
        sb.accept_encoding = try allocator.dupe(u8, value);
    } else if (std.ascii.eqlIgnoreCase(name, "if-none-match")) {
        if (sb.if_none_match) |old| allocator.free(old);
        sb.if_none_match = try allocator.dupe(u8, value);
    }
}

fn decodeInt(buf: []const u8, pos: *usize, prefix_bits: u3) !usize {
    if (pos.* >= buf.len) return error.UnexpectedEof;
    const mask: u8 = (@as(u8, 1) << prefix_bits) - 1;
    var val: usize = buf[pos.*] & mask;
    pos.* += 1;
    if (val < mask) return val;

    var shift: u6 = 0;
    while (pos.* < buf.len) {
        const b = buf[pos.*];
        pos.* += 1;
        if (shift >= 28) return error.IntegerOverflow;
        val += @as(usize, b & 0x7F) << shift;
        if ((b & 0x80) == 0) return val;
        shift += 7;
    }
    return error.UnexpectedEof;
}

fn decodeStr(allocator: Allocator, buf: []const u8, pos: *usize) ![]u8 {
    if (pos.* >= buf.len) return error.UnexpectedEof;
    const is_huffman = (buf[pos.*] & 0x80) != 0;
    const len = try decodeInt(buf, pos, 7);
    if (pos.* + len > buf.len) return error.UnexpectedEof;
    const slice = buf[pos.* .. pos.* + len];
    pos.* += len;
    if (!is_huffman) return try allocator.dupe(u8, slice);
    return try decodeHuffman(allocator, slice);
}

// RFC 7541 Appendix B Huffman code table (256 byte symbols: code + bit length).
const HuffCode = struct { code: u32, len: u5 };
const HUFFMAN_TABLE = [256]HuffCode{
    .{ .code = 0x1ff8, .len = 13 }, .{ .code = 0x7fffd8, .len = 23 }, .{ .code = 0xfffffe2, .len = 28 }, .{ .code = 0xfffffe3, .len = 28 },
    .{ .code = 0xfffffe4, .len = 28 }, .{ .code = 0xfffffe5, .len = 28 }, .{ .code = 0xfffffe6, .len = 28 }, .{ .code = 0xfffffe7, .len = 28 },
    .{ .code = 0xfffffe8, .len = 28 }, .{ .code = 0xffffea, .len = 24 }, .{ .code = 0x3ffffffc, .len = 30 }, .{ .code = 0xfffffe9, .len = 28 },
    .{ .code = 0xfffffea, .len = 28 }, .{ .code = 0x3ffffffd, .len = 30 }, .{ .code = 0xfffffeb, .len = 28 }, .{ .code = 0xfffffec, .len = 28 },
    .{ .code = 0xfffffed, .len = 28 }, .{ .code = 0xfffffee, .len = 28 }, .{ .code = 0xfffffef, .len = 28 }, .{ .code = 0xffffff0, .len = 28 },
    .{ .code = 0xffffff1, .len = 28 }, .{ .code = 0xffffff2, .len = 28 }, .{ .code = 0x3ffffffe, .len = 30 }, .{ .code = 0xffffff3, .len = 28 },
    .{ .code = 0xffffff4, .len = 28 }, .{ .code = 0xffffff5, .len = 28 }, .{ .code = 0xffffff6, .len = 28 }, .{ .code = 0xffffff7, .len = 28 },
    .{ .code = 0xffffff8, .len = 28 }, .{ .code = 0xffffff9, .len = 28 }, .{ .code = 0xffffffa, .len = 28 }, .{ .code = 0xffffffb, .len = 28 },
    .{ .code = 0x14, .len = 6 }, .{ .code = 0x3f8, .len = 10 }, .{ .code = 0x3f9, .len = 10 }, .{ .code = 0xffa, .len = 12 },
    .{ .code = 0x1ff9, .len = 13 }, .{ .code = 0x15, .len = 6 }, .{ .code = 0xf8, .len = 8 }, .{ .code = 0x7fa, .len = 11 },
    .{ .code = 0x3fa, .len = 10 }, .{ .code = 0x3fb, .len = 10 }, .{ .code = 0xf9, .len = 8 }, .{ .code = 0x7fb, .len = 11 },
    .{ .code = 0xfa, .len = 8 }, .{ .code = 0x16, .len = 6 }, .{ .code = 0x17, .len = 6 }, .{ .code = 0x18, .len = 6 },
    .{ .code = 0x0, .len = 5 }, .{ .code = 0x1, .len = 5 }, .{ .code = 0x2, .len = 5 }, .{ .code = 0x19, .len = 6 },
    .{ .code = 0x1a, .len = 6 }, .{ .code = 0x1b, .len = 6 }, .{ .code = 0x1c, .len = 6 }, .{ .code = 0x1d, .len = 6 },
    .{ .code = 0x1e, .len = 6 }, .{ .code = 0x1f, .len = 6 }, .{ .code = 0x5c, .len = 7 }, .{ .code = 0xfb, .len = 8 },
    .{ .code = 0x7ffc, .len = 15 }, .{ .code = 0x20, .len = 6 }, .{ .code = 0xffb, .len = 12 }, .{ .code = 0x3fc, .len = 10 },
    .{ .code = 0x1ffa, .len = 13 }, .{ .code = 0x21, .len = 6 }, .{ .code = 0x5d, .len = 7 }, .{ .code = 0x5e, .len = 7 },
    .{ .code = 0x5f, .len = 7 }, .{ .code = 0x60, .len = 7 }, .{ .code = 0x61, .len = 7 }, .{ .code = 0x62, .len = 7 },
    .{ .code = 0x63, .len = 7 }, .{ .code = 0x64, .len = 7 }, .{ .code = 0x65, .len = 7 }, .{ .code = 0x66, .len = 7 },
    .{ .code = 0x67, .len = 7 }, .{ .code = 0x68, .len = 7 }, .{ .code = 0x69, .len = 7 }, .{ .code = 0x6a, .len = 7 },
    .{ .code = 0x6b, .len = 7 }, .{ .code = 0x6c, .len = 7 }, .{ .code = 0x6d, .len = 7 }, .{ .code = 0x6e, .len = 7 },
    .{ .code = 0x6f, .len = 7 }, .{ .code = 0x70, .len = 7 }, .{ .code = 0x71, .len = 7 }, .{ .code = 0x72, .len = 7 },
    .{ .code = 0xfc, .len = 8 }, .{ .code = 0x73, .len = 7 }, .{ .code = 0xfd, .len = 8 }, .{ .code = 0x1ffb, .len = 13 },
    .{ .code = 0x7fff0, .len = 19 }, .{ .code = 0x1ffc, .len = 13 }, .{ .code = 0x3ffc, .len = 14 }, .{ .code = 0x22, .len = 6 },
    .{ .code = 0x7ffd, .len = 15 }, .{ .code = 0x3, .len = 5 }, .{ .code = 0x23, .len = 6 }, .{ .code = 0x4, .len = 5 },
    .{ .code = 0x24, .len = 6 }, .{ .code = 0x5, .len = 5 }, .{ .code = 0x25, .len = 6 }, .{ .code = 0x26, .len = 6 },
    .{ .code = 0x27, .len = 6 }, .{ .code = 0x6, .len = 5 }, .{ .code = 0x74, .len = 7 }, .{ .code = 0x75, .len = 7 },
    .{ .code = 0x28, .len = 6 }, .{ .code = 0x29, .len = 6 }, .{ .code = 0x2a, .len = 6 }, .{ .code = 0x7, .len = 5 },
    .{ .code = 0x2b, .len = 6 }, .{ .code = 0x76, .len = 7 }, .{ .code = 0x2c, .len = 6 }, .{ .code = 0x8, .len = 5 },
    .{ .code = 0x9, .len = 5 }, .{ .code = 0x2d, .len = 6 }, .{ .code = 0x77, .len = 7 }, .{ .code = 0x78, .len = 7 },
    .{ .code = 0x79, .len = 7 }, .{ .code = 0x7a, .len = 7 }, .{ .code = 0x7b, .len = 7 }, .{ .code = 0x7ffe, .len = 15 },
    .{ .code = 0x7fc, .len = 11 }, .{ .code = 0x3ffd, .len = 14 }, .{ .code = 0x1ffd, .len = 13 }, .{ .code = 0xffffffc, .len = 28 },
    .{ .code = 0xfffe6, .len = 20 }, .{ .code = 0x3fffd2, .len = 22 }, .{ .code = 0xfffe7, .len = 20 }, .{ .code = 0xfffe8, .len = 20 },
    .{ .code = 0x3fffd3, .len = 22 }, .{ .code = 0x3fffd4, .len = 22 }, .{ .code = 0x3fffd5, .len = 22 }, .{ .code = 0x7fffd9, .len = 23 },
    .{ .code = 0x3fffd6, .len = 22 }, .{ .code = 0x7fffda, .len = 23 }, .{ .code = 0x7fffdb, .len = 23 }, .{ .code = 0x7fffdc, .len = 23 },
    .{ .code = 0x7fffdd, .len = 23 }, .{ .code = 0x7fffde, .len = 23 }, .{ .code = 0xffffeb, .len = 24 }, .{ .code = 0x7fffdf, .len = 23 },
    .{ .code = 0xffffec, .len = 24 }, .{ .code = 0xffffed, .len = 24 }, .{ .code = 0x3fffd7, .len = 22 }, .{ .code = 0x7fffe0, .len = 23 },
    .{ .code = 0xffffee, .len = 24 }, .{ .code = 0x7fffe1, .len = 23 }, .{ .code = 0x7fffe2, .len = 23 }, .{ .code = 0x7fffe3, .len = 23 },
    .{ .code = 0x7fffe4, .len = 23 }, .{ .code = 0x1fffdc, .len = 21 }, .{ .code = 0x3fffd8, .len = 22 }, .{ .code = 0x7fffe5, .len = 23 },
    .{ .code = 0x3fffd9, .len = 22 }, .{ .code = 0x7fffe6, .len = 23 }, .{ .code = 0x7fffe7, .len = 23 }, .{ .code = 0xffffef, .len = 24 },
    .{ .code = 0x3fffda, .len = 22 }, .{ .code = 0x1fffdd, .len = 21 }, .{ .code = 0xfffe9, .len = 20 }, .{ .code = 0x3fffdb, .len = 22 },
    .{ .code = 0x3fffdc, .len = 22 }, .{ .code = 0x7fffe8, .len = 23 }, .{ .code = 0x7fffe9, .len = 23 }, .{ .code = 0x1fffde, .len = 21 },
    .{ .code = 0x7fffea, .len = 23 }, .{ .code = 0x3fffdd, .len = 22 }, .{ .code = 0x3fffde, .len = 22 }, .{ .code = 0xfffff0, .len = 24 },
    .{ .code = 0x1fffdf, .len = 21 }, .{ .code = 0x3fffdf, .len = 22 }, .{ .code = 0x7fffeb, .len = 23 }, .{ .code = 0x7fffec, .len = 23 },
    .{ .code = 0x1fffe0, .len = 21 }, .{ .code = 0x1fffe1, .len = 21 }, .{ .code = 0x3fffe0, .len = 22 }, .{ .code = 0x1fffe2, .len = 21 },
    .{ .code = 0x7fffed, .len = 23 }, .{ .code = 0x3fffe1, .len = 22 }, .{ .code = 0x7fffee, .len = 23 }, .{ .code = 0x7fffef, .len = 23 },
    .{ .code = 0xfffea, .len = 20 }, .{ .code = 0x3fffe2, .len = 22 }, .{ .code = 0x3fffe3, .len = 22 }, .{ .code = 0x3fffe4, .len = 22 },
    .{ .code = 0x7ffff0, .len = 23 }, .{ .code = 0x3fffe5, .len = 22 }, .{ .code = 0x3fffe6, .len = 22 }, .{ .code = 0x7ffff1, .len = 23 },
    .{ .code = 0x3ffffe0, .len = 26 }, .{ .code = 0x3ffffe1, .len = 26 }, .{ .code = 0xfffeb, .len = 20 }, .{ .code = 0x7fff1, .len = 19 },
    .{ .code = 0x3fffe7, .len = 22 }, .{ .code = 0x7ffff2, .len = 23 }, .{ .code = 0x3fffe8, .len = 22 }, .{ .code = 0x1ffffec, .len = 25 },
    .{ .code = 0x3ffffe2, .len = 26 }, .{ .code = 0x3ffffe3, .len = 26 }, .{ .code = 0x3ffffe4, .len = 26 }, .{ .code = 0x7ffffde, .len = 27 },
    .{ .code = 0x7ffffdf, .len = 27 }, .{ .code = 0x3ffffe5, .len = 26 }, .{ .code = 0xfffff1, .len = 24 }, .{ .code = 0x1ffffed, .len = 25 },
    .{ .code = 0x7fff2, .len = 19 }, .{ .code = 0x1fffe3, .len = 21 }, .{ .code = 0x3ffffe6, .len = 26 }, .{ .code = 0x7ffffe0, .len = 27 },
    .{ .code = 0x7ffffe1, .len = 27 }, .{ .code = 0x3ffffe7, .len = 26 }, .{ .code = 0x7ffffe2, .len = 27 }, .{ .code = 0xfffff2, .len = 24 },
    .{ .code = 0x1fffe4, .len = 21 }, .{ .code = 0x1fffe5, .len = 21 }, .{ .code = 0x3ffffe8, .len = 26 }, .{ .code = 0x3ffffe9, .len = 26 },
    .{ .code = 0xffffffd, .len = 28 }, .{ .code = 0x7ffffe3, .len = 27 }, .{ .code = 0x7ffffe4, .len = 27 }, .{ .code = 0x7ffffe5, .len = 27 },
    .{ .code = 0xfffec, .len = 20 }, .{ .code = 0xfffff3, .len = 24 }, .{ .code = 0xfffed, .len = 20 }, .{ .code = 0x1fffe6, .len = 21 },
    .{ .code = 0x3fffe9, .len = 22 }, .{ .code = 0x1fffe7, .len = 21 }, .{ .code = 0x1fffe8, .len = 21 }, .{ .code = 0x7ffff3, .len = 23 },
    .{ .code = 0x3fffea, .len = 22 }, .{ .code = 0x3fffeb, .len = 22 }, .{ .code = 0x1ffffee, .len = 25 }, .{ .code = 0x1ffffef, .len = 25 },
    .{ .code = 0xfffff4, .len = 24 }, .{ .code = 0xfffff5, .len = 24 }, .{ .code = 0x3ffffea, .len = 26 }, .{ .code = 0x7ffff4, .len = 23 },
    .{ .code = 0x3ffffeb, .len = 26 }, .{ .code = 0x7ffffe6, .len = 27 }, .{ .code = 0x3ffffec, .len = 26 }, .{ .code = 0x3ffffed, .len = 26 },
    .{ .code = 0x7ffffe7, .len = 27 }, .{ .code = 0x7ffffe8, .len = 27 }, .{ .code = 0x7ffffe9, .len = 27 }, .{ .code = 0x7ffffea, .len = 27 },
    .{ .code = 0x7ffffeb, .len = 27 }, .{ .code = 0xffffffe, .len = 28 }, .{ .code = 0x7ffffec, .len = 27 }, .{ .code = 0x7ffffed, .len = 27 },
    .{ .code = 0x7ffffee, .len = 27 }, .{ .code = 0x7ffffef, .len = 27 }, .{ .code = 0x7fffff0, .len = 27 }, .{ .code = 0x3ffffee, .len = 26 },
};

const TrieNode = struct {
    children: [2]u16 = .{ 0, 0 },
    sym: i16 = -1,
};

const HUFFMAN_TRIE = blk: {
    @setEvalBranchQuota(50000);
    var nodes: [600]TrieNode = @splat(TrieNode{});
    var count: u16 = 1;
    for (HUFFMAN_TABLE, 0..) |hc, sym| {
        var cur: u16 = 0;
        var b: i32 = @as(i32, hc.len) - 1;
        while (b >= 0) : (b -= 1) {
            const bit: u1 = @intCast((hc.code >> @intCast(b)) & 1);
            if (nodes[cur].children[bit] == 0) {
                nodes[cur].children[bit] = count;
                count += 1;
            }
            cur = nodes[cur].children[bit];
        }
        nodes[cur].sym = @intCast(sym);
    }
    break :blk nodes;
};

pub fn decodeHuffman(allocator: Allocator, input: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, input.len + input.len / 2);
    errdefer out.deinit(allocator);

    var cur: u16 = 0;
    var rem_bits: u8 = 0;
    var all_ones = true;

    for (input) |byte| {
        var shift: i32 = 7;
        while (shift >= 0) : (shift -= 1) {
            const bit: u1 = @intCast((byte >> @intCast(shift)) & 1);
            if (bit == 0) all_ones = false;
            rem_bits += 1;
            const next = HUFFMAN_TRIE[cur].children[bit];
            if (next == 0) return error.InvalidHuffman;
            cur = next;
            const sym = HUFFMAN_TRIE[cur].sym;
            if (sym >= 0) {
                try out.append(allocator, @intCast(sym));
                cur = 0;
                rem_bits = 0;
                all_ones = true;
            }
        }
    }

    if (rem_bits >= 8 or (rem_bits > 0 and !all_ones)) return error.InvalidHuffman;
    return try out.toOwnedSlice(allocator);
}

test "http2: HPACK static/dynamic/Huffman decoding (RFC 7541 Appendix C.4.1)" {
    const allocator = std.testing.allocator;
    // RFC 7541 C.4.1 Huffman-encoded "www.example.com" = f1e3 c2e5 f23a 6ba0 ab90 f4ff
    const huff_bytes = [_]u8{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    const decoded = try decodeHuffman(allocator, &huff_bytes);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("www.example.com", decoded);

    // Decode indexed `:method: GET` (0x82) + `:path: /` (0x84) + `accept-encoding: gzip, deflate` (0x90)
    var dec = HpackDecoder.init(allocator);
    defer dec.deinit();
    var sb = StreamBuf{};
    defer sb.deinit(allocator);
    try dec.decodeBlock(&[_]u8{ 0x82, 0x84, 0x90 }, &sb);
    try std.testing.expectEqualStrings("GET", sb.method.?);
    try std.testing.expectEqualStrings("/", sb.raw_path.?);
    try std.testing.expectEqualStrings("gzip, deflate", sb.accept_encoding.?);
}
