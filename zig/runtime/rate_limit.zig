const std = @import("std");
const Allocator = std.mem.Allocator;

/// Per-IP token-bucket rate limiter with bounded memory and zero external dependencies.
///
/// Thread-safe via `std.Io.Mutex`. Uses the monotonic clock (`std.Io.Clock.awake`) so wall-clock
/// adjustments never stall or burst-refill buckets. Caps active IP buckets at `max_buckets`
/// (default `MAX_BUCKETS = 16_384`) with periodic idle eviction (> 60s) and hard-cap shedding
/// so an IP-spray attack cannot exhaust server memory.
pub const RateLimiter = struct {
    pub const MAX_BUCKETS: usize = 16_384;
    pub const IDLE_EVICT_MS: i64 = 60_000;
    const TOKEN_SCALE: u64 = 1_000_000;

    pub const Decision = struct {
        allowed: bool,
        retry_after_secs: u32,
    };

    const Bucket = struct {
        tokens_micro: u64,
        last_ms: i64,
    };

    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    rps: u32,
    burst: u32,
    max_buckets: usize = MAX_BUCKETS,
    idle_evict_ms: i64 = IDLE_EVICT_MS,
    last_evict_ms: ?i64 = null,
    buckets: std.StringHashMapUnmanaged(Bucket) = .empty,

    /// Create a per-IP token-bucket rate limiter.
    /// When `rps == 0`, rate limiting is disabled and `check()` always allows.
    /// When `rps > 0` and `burst == 0`, burst defaults to `rps`.
    pub fn init(allocator: Allocator, io: std.Io, rps: u32, burst: u32) RateLimiter {
        const effective_burst: u32 = if (rps == 0) 0 else if (burst == 0) rps else burst;
        return .{
            .allocator = allocator,
            .io = io,
            .rps = rps,
            .burst = effective_burst,
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.buckets.keyIterator();
        while (it.next()) |kp| {
            self.allocator.free(kp.*);
        }
        self.buckets.deinit(self.allocator);
    }

    /// Check whether a request from `client_ip` is allowed using the monotonic clock.
    pub fn check(self: *RateLimiter, client_ip: []const u8) Decision {
        if (self.rps == 0) {
            return .{ .allowed = true, .retry_after_secs = 0 };
        }
        const now_ms: i64 = std.Io.Clock.awake.now(self.io).toMilliseconds();
        return self.checkAt(client_ip, now_ms);
    }

    /// Deterministic token-bucket check at an explicit monotonic timestamp `now_ms`.
    pub fn checkAt(self: *RateLimiter, client_ip: []const u8, now_ms: i64) Decision {
        if (self.rps == 0) {
            return .{ .allowed = true, .retry_after_secs = 0 };
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.last_evict_ms == null) {
            self.last_evict_ms = now_ms;
        } else if (self.buckets.count() > 0 and now_ms - self.last_evict_ms.? >= self.idle_evict_ms) {
            self.evictIdleLocked(now_ms);
            self.last_evict_ms = now_ms;
        }

        const capacity_micro: u64 = @as(u64, self.burst) * TOKEN_SCALE;

        if (self.buckets.getPtr(client_ip)) |bucket| {
            if (now_ms > bucket.last_ms) {
                const elapsed_ms: u128 = @intCast(now_ms - bucket.last_ms);
                const refill_micro: u128 = elapsed_ms * @as(u128, self.rps) * (TOKEN_SCALE / 1000);
                const next_tokens: u128 = @min(@as(u128, capacity_micro), @as(u128, bucket.tokens_micro) + refill_micro);
                bucket.tokens_micro = @intCast(next_tokens);
                bucket.last_ms = now_ms;
            }
            if (bucket.tokens_micro >= TOKEN_SCALE) {
                bucket.tokens_micro -= TOKEN_SCALE;
                return .{ .allowed = true, .retry_after_secs = 0 };
            }
            return .{
                .allowed = false,
                .retry_after_secs = self.retryAfterSecs(bucket.tokens_micro),
            };
        }

        // Enforce strict upper bound on bucket map size before inserting a new IP.
        if (self.buckets.count() >= self.max_buckets) {
            self.evictIdleLocked(now_ms);
            self.last_evict_ms = now_ms;
            if (self.buckets.count() >= self.max_buckets) {
                self.evictPressureLocked(now_ms);
            }
        }

        const owned_key = self.allocator.dupe(u8, client_ip) catch {
            return .{ .allowed = false, .retry_after_secs = 1 };
        };
        const initial_tokens: u64 = if (capacity_micro >= TOKEN_SCALE) capacity_micro - TOKEN_SCALE else 0;
        self.buckets.put(self.allocator, owned_key, .{
            .tokens_micro = initial_tokens,
            .last_ms = now_ms,
        }) catch {
            self.allocator.free(owned_key);
            return .{ .allowed = false, .retry_after_secs = 1 };
        };
        return .{ .allowed = true, .retry_after_secs = 0 };
    }

    pub fn bucketCount(self: *RateLimiter) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.buckets.count();
    }

    fn retryAfterSecs(self: *const RateLimiter, tokens_micro: u64) u32 {
        const deficit_micro: u128 = TOKEN_SCALE - tokens_micro;
        const rate_micro_per_sec: u128 = @as(u128, self.rps) * TOKEN_SCALE;
        const wait_secs: u128 = (deficit_micro + rate_micro_per_sec - 1) / rate_micro_per_sec;
        return @intCast(@max(@as(u128, 1), wait_secs));
    }

    fn evictIdleLocked(self: *RateLimiter, now_ms: i64) void {
        var batch: [256][]const u8 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.buckets.iterator();
            while (it.next()) |entry| {
                if (now_ms - entry.value_ptr.last_ms > self.idle_evict_ms) {
                    batch[n] = entry.key_ptr.*;
                    n += 1;
                    if (n == batch.len) break;
                }
            }
            if (n == 0) break;
            for (batch[0..n]) |k| {
                if (self.buckets.fetchRemove(k)) |removed| {
                    self.allocator.free(removed.key);
                }
            }
        }
    }

    /// Shed entries under IP-spray pressure when all buckets are newer than `idle_evict_ms`.
    /// Evicts ~6% (at least 1) so amortized insertion stays O(1) and count never exceeds `max_buckets`.
    fn evictPressureLocked(self: *RateLimiter, now_ms: i64) void {
        const target: usize = @max(@as(usize, 1), self.max_buckets / 16);
        var evicted: usize = 0;
        var batch: [256][]const u8 = undefined;

        // First prefer buckets idle for at least 1 second.
        while (evicted < target) {
            var n: usize = 0;
            const limit = @min(batch.len, target - evicted);
            var it = self.buckets.iterator();
            while (it.next()) |entry| {
                if (now_ms - entry.value_ptr.last_ms >= 1000) {
                    batch[n] = entry.key_ptr.*;
                    n += 1;
                    if (n == limit) break;
                }
            }
            if (n == 0) break;
            for (batch[0..n]) |k| {
                if (self.buckets.fetchRemove(k)) |removed| {
                    self.allocator.free(removed.key);
                    evicted += 1;
                }
            }
        }

        // If still at capacity (e.g., all buckets hit within the last second), shed hash-order entries.
        while (evicted < target and self.buckets.count() >= self.max_buckets) {
            var n: usize = 0;
            const limit = @min(batch.len, target - evicted);
            var it = self.buckets.keyIterator();
            while (it.next()) |kp| {
                batch[n] = kp.*;
                n += 1;
                if (n == limit) break;
            }
            if (n == 0) break;
            for (batch[0..n]) |k| {
                if (self.buckets.fetchRemove(k)) |removed| {
                    self.allocator.free(removed.key);
                    evicted += 1;
                }
            }
        }
    }
};

/// Resolve the effective client IP for rate limiting.
///
/// - When `!trust_proxy` or `x_forwarded_for == null`: returns `peer_ip`.
/// - When `trust_proxy`: extracts and trims the first comma-separated entry of `X-Forwarded-For`
///   (standard Cloud Run / Fly.io `X-Forwarded-For: client, proxy1` header) after verifying it is
///   non-empty, `<= 64` bytes, and contains only valid IP characters `[0-9a-fA-F.:]`.
///   Falls back to `peer_ip` if validation fails.
pub fn extractClientIp(peer_ip: []const u8, x_forwarded_for: ?[]const u8, trust_proxy: bool) []const u8 {
    if (!trust_proxy) return peer_ip;
    const xff = x_forwarded_for orelse return peer_ip;
    const first_raw = if (std.mem.indexOfScalar(u8, xff, ',')) |comma|
        xff[0..comma]
    else
        xff;
    const candidate = std.mem.trim(u8, first_raw, " \t\r\n");
    if (candidate.len == 0 or candidate.len > 64) return peer_ip;
    for (candidate) |c| {
        const valid = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F') or
            c == '.' or c == ':';
        if (!valid) return peer_ip;
    }
    return candidate;
}

test "rate limiter allows burst then throttles with retry_after_secs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var rl = RateLimiter.init(allocator, io, 5, 3);
    defer rl.deinit();

    // Burst of 3 succeeds immediately at t=1000ms.
    for (0..3) |_| {
        const d = rl.checkAt("203.0.113.10", 1000);
        try std.testing.expect(d.allowed);
        try std.testing.expectEqual(@as(u32, 0), d.retry_after_secs);
    }

    // 4th request at the same timestamp is rejected with retry_after_secs >= 1.
    const denied = rl.checkAt("203.0.113.10", 1000);
    try std.testing.expect(!denied.allowed);
    try std.testing.expect(denied.retry_after_secs >= 1);

    // Distinct IP has its own independent bucket.
    const other = rl.checkAt("203.0.113.11", 1000);
    try std.testing.expect(other.allowed);
}

test "rate limiter live check uses monotonic clock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var rl = RateLimiter.init(allocator, io, 1, 2);
    defer rl.deinit();

    try std.testing.expect(rl.check("198.51.100.7").allowed);
    try std.testing.expect(rl.check("198.51.100.7").allowed);
    const d3 = rl.check("198.51.100.7");
    try std.testing.expect(!d3.allowed);
    try std.testing.expectEqual(@as(u32, 1), d3.retry_after_secs);
}

test "rate limiter refills tokens over time and caps at burst" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 2 rps (1 token every 500ms), burst 2.
    var rl = RateLimiter.init(allocator, io, 2, 2);
    defer rl.deinit();

    try std.testing.expect(rl.checkAt("10.0.0.1", 0).allowed);
    try std.testing.expect(rl.checkAt("10.0.0.1", 0).allowed);
    try std.testing.expect(!rl.checkAt("10.0.0.1", 0).allowed);

    // After 400ms: only 0.8 tokens refilled -> still throttled.
    try std.testing.expect(!rl.checkAt("10.0.0.1", 400).allowed);

    // After 500ms total: 1.0 token refilled -> 1 request allowed, then throttled again.
    try std.testing.expect(rl.checkAt("10.0.0.1", 500).allowed);
    try std.testing.expect(!rl.checkAt("10.0.0.1", 500).allowed);

    // After 10 seconds idle: refilled tokens are capped at burst (2), not 20!
    try std.testing.expect(rl.checkAt("10.0.0.1", 10_500).allowed);
    try std.testing.expect(rl.checkAt("10.0.0.1", 10_500).allowed);
    try std.testing.expect(!rl.checkAt("10.0.0.1", 10_500).allowed);
}

test "rate limiter disabled when rps == 0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var rl = RateLimiter.init(allocator, io, 0, 0);
    defer rl.deinit();

    for (0..100) |_| {
        const d = rl.check("198.51.100.42");
        try std.testing.expect(d.allowed);
        try std.testing.expectEqual(@as(u32, 0), d.retry_after_secs);
    }
    try std.testing.expectEqual(@as(usize, 0), rl.bucketCount());
}

test "rate limiter evicts idle buckets and enforces max_buckets cap under IP spray" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var rl = RateLimiter.init(allocator, io, 10, 10);
    rl.max_buckets = 16;
    defer rl.deinit();

    var ip_buf: [32]u8 = undefined;

    // 1. Insert 10 buckets at t=1000ms.
    for (0..10) |i| {
        const ip = try std.fmt.bufPrint(&ip_buf, "10.0.0.{d}", .{i});
        try std.testing.expect(rl.checkAt(ip, 1000).allowed);
    }
    try std.testing.expectEqual(@as(usize, 10), rl.bucketCount());

    // 2. Advance past idle_evict_ms (60s) -> periodic eviction reclaims all 10 old buckets.
    const fresh_t = 1000 + RateLimiter.IDLE_EVICT_MS + 1;
    try std.testing.expect(rl.checkAt("10.0.1.1", fresh_t).allowed);
    try std.testing.expectEqual(@as(usize, 1), rl.bucketCount());

    // 3. Simulate an active IP-spray attack of 64 distinct IPs at the same millisecond.
    //    Map size must stay strictly <= max_buckets (16) with zero leaks!
    for (0..64) |i| {
        const ip = try std.fmt.bufPrint(&ip_buf, "192.0.2.{d}", .{i});
        try std.testing.expect(rl.checkAt(ip, fresh_t).allowed);
        try std.testing.expect(rl.bucketCount() <= rl.max_buckets);
    }
}

test "extractClientIp respects trust_proxy and validates X-Forwarded-For" {
    // Untrusted proxy always ignores X-Forwarded-For.
    try std.testing.expectEqualStrings(
        "10.0.0.5",
        extractClientIp("10.0.0.5", "203.0.113.9, 10.0.0.1", false),
    );

    // Trusted proxy with null header falls back to peer_ip.
    try std.testing.expectEqualStrings(
        "10.0.0.5",
        extractClientIp("10.0.0.5", null, true),
    );

    // Trusted proxy extracts first trimmed IPv4 from chain.
    try std.testing.expectEqualStrings(
        "203.0.113.9",
        extractClientIp("10.0.0.5", "  203.0.113.9 , 10.0.0.1", true),
    );

    // Trusted proxy accepts valid IPv6.
    try std.testing.expectEqualStrings(
        "2001:db8::1",
        extractClientIp("10.0.0.5", "2001:db8::1, 10.0.0.1", true),
    );

    // Rejects invalid characters (injection attempt / hostname / spaces) and falls back to peer_ip.
    try std.testing.expectEqualStrings(
        "10.0.0.5",
        extractClientIp("10.0.0.5", "evil.example.com, 10.0.0.1", true),
    );
    try std.testing.expectEqualStrings(
        "10.0.0.5",
        extractClientIp("10.0.0.5", "1.2.3.4; DROP TABLE, 10.0.0.1", true),
    );

    // Rejects empty or >64-char entries and falls back to peer_ip.
    try std.testing.expectEqualStrings(
        "10.0.0.5",
        extractClientIp("10.0.0.5", " , 10.0.0.1", true),
    );
    const too_long: [65]u8 = @splat('1');
    try std.testing.expectEqualStrings(
        "10.0.0.5",
        extractClientIp("10.0.0.5", &too_long, true),
    );
}
