comptime {
    _ = @import("core/key.zig");
    _ = @import("core/manifest.zig");
    _ = @import("core/readset.zig");
    _ = @import("core/storage.zig");
    _ = @import("core/wal_store.zig");
    _ = @import("core/pg_wire.zig");
    _ = @import("codegen/codegen.zig");
    _ = @import("runtime/auth.zig");
    _ = @import("runtime/ws.zig");
    _ = @import("runtime/http_client.zig");
    _ = @import("runtime/tx.zig");
    _ = @import("runtime/engine.zig");
}
