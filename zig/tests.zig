comptime {
    _ = @import("core/key.zig");
    _ = @import("core/manifest.zig");
    _ = @import("core/readset.zig");
    _ = @import("core/storage.zig");
    _ = @import("core/wal_store.zig");
    _ = @import("core/pg_wire.zig");
    _ = @import("core/sigv4.zig");
    _ = @import("core/blob_store.zig");
    _ = @import("codegen/codegen.zig");
    _ = @import("runtime/auth.zig");
    _ = @import("runtime/compress.zig");
    _ = @import("runtime/http2.zig");
    _ = @import("runtime/ws.zig");
    _ = @import("runtime/http_client.zig");
    _ = @import("runtime/metrics.zig");
    _ = @import("runtime/tx.zig");
    _ = @import("runtime/engine.zig");
    _ = @import("runtime/server.zig");

    // Wave 1 Verification Suites: Property Tests, Crash Recovery, DST, Security/RFC & Fuzz Targets
    _ = @import("verify/key_props.zig");
    _ = @import("verify/wal_crash.zig");
    _ = @import("verify/dst_engine.zig");
    _ = @import("verify/protocol_fuzz.zig");
}
