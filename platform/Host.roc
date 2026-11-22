## Low-level hosted C-ABI functions implemented by Concave's zero-dependency Zig host (`zig/host/host.zig`).
## Application code should use `concave-sdk` (`Ctx`, `Db`, `App`) instead of calling `Host` directly.

Host := [Host].{
    db_get! : Str, Str, Str => Str
    db_query! : Str => Str
    db_insert! : Str, Str, Str => Str
    db_patch! : Str, Str, Str, Str => Str
    db_replace! : Str, Str, Str, Str => Str
    db_delete! : Str, Str, Str => Str
    auth_identity! : () => Str
    http_fetch! : Str, Str, Str => Str
    run_query! : Str, Str => Str
    run_mutation! : Str, Str => Str
    now_ms! : () => I64
}
