const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HttpFetchRequest = struct {
    method: []const u8,
    url: []const u8,
    body: ?[]const u8 = null,
};

pub const HttpFetchResponse = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *const HttpFetchResponse, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

/// Zero-dependency HTTP & HTTPS client powered by Zig's built-in `std.http.Client` + `std.crypto.tls`.
pub fn fetch(allocator: Allocator, io: std.Io, req: HttpFetchRequest) !HttpFetchResponse {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const method = parseMethod(req.method);
    var body_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_out.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = req.url },
        .method = method,
        .payload = if (req.body) |b| (if (b.len > 0) b else null) else null,
        .response_writer = &body_out.writer,
    });

    return .{
        .status = @intFromEnum(res.status),
        .body = try body_out.toOwnedSlice(),
    };
}

fn parseMethod(s: []const u8) std.http.Method {
    if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(s, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(s, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(s, "OPTIONS")) return .OPTIONS;
    return .GET;
}
