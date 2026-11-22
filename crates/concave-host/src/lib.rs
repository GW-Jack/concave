#[allow(
    dead_code,
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    unsafe_op_in_unsafe_fn,
    clippy::all
)]
mod roc_platform_abi;

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::ptr::NonNull;
use std::sync::Arc;

use async_trait::async_trait;
use concave_core::{
    encode_key, encode_prefix_upper_bound, now_millis, AppManifest, IndexQuery, IndexValue,
    KeyBound, PostgresStorage, QueryOrder, SqliteStorage, StorageBackend,
};
use concave_runtime::{
    serve, AppExecutor, AuthConfig, ConcaveEngine, ExecutionEnv, HttpFetchRequest, ServerConfig,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot};

use crate::roc_platform_abi::{
    make_roc_host, roc_dispatch_action_owned, roc_dispatch_mutation_owned,
    roc_dispatch_query_owned, roc_introspect_owned, DefaultAllocators, DefaultHandlers, RocHost,
    RocStr,
};

// =============================================================================
// Runtime Symbols required by compiled Roc 0.1.0_RC1 code
// =============================================================================

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> NonNull<c_void> {
    let mut host = make_roc_host(std::ptr::null_mut());
    DefaultAllocators::roc_alloc(&mut host, length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dealloc(ptr: *mut c_void, alignment: usize) {
    let mut host = make_roc_host(std::ptr::null_mut());
    DefaultAllocators::roc_dealloc(&mut host, ptr, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_realloc(
    ptr: *mut c_void,
    new_length: usize,
    alignment: usize,
) -> NonNull<c_void> {
    let mut host = make_roc_host(std::ptr::null_mut());
    DefaultAllocators::roc_realloc(&mut host, ptr, new_length, alignment)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    let mut host = make_roc_host(std::ptr::null_mut());
    DefaultHandlers::roc_dbg(&mut host, bytes, len)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    let mut host = make_roc_host(std::ptr::null_mut());
    DefaultHandlers::roc_expect_failed(&mut host, bytes, len)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    let mut host = make_roc_host(std::ptr::null_mut());
    DefaultHandlers::roc_crashed(&mut host, bytes, len)
}

// =============================================================================
// Thread-local Roc Worker Execution Stack (single-threaded Roc ARC + re-entrancy)
// =============================================================================

struct ActiveFrame {
    env: *mut ExecutionEnv,
    rt: tokio::runtime::Handle,
}

thread_local! {
    static IS_ROC_WORKER: RefCell<bool> = const { RefCell::new(false) };
    static ENV_STACK: RefCell<Vec<ActiveFrame>> = const { RefCell::new(Vec::new()) };
}

fn is_on_roc_worker() -> bool {
    IS_ROC_WORKER.with(|flag| *flag.borrow())
}

struct FrameGuard;

impl FrameGuard {
    fn push(env: &mut ExecutionEnv, rt: tokio::runtime::Handle) -> Self {
        ENV_STACK.with(|stack| {
            stack.borrow_mut().push(ActiveFrame {
                env: env as *mut ExecutionEnv,
                rt,
            });
        });
        Self
    }
}

impl Drop for FrameGuard {
    fn drop(&mut self) {
        ENV_STACK.with(|stack| {
            stack.borrow_mut().pop();
        });
    }
}

/// Safely drive an async future synchronously from a hosted C-ABI callback,
/// even when called re-entrantly inside an outer `Handle::block_on` (e.g., Action -> Mutation -> Db).
fn block_on_safe<F>(rt: &tokio::runtime::Handle, fut: F) -> F::Output
where
    F: std::future::Future + Send,
    F::Output: Send,
{
    if tokio::runtime::Handle::try_current().is_ok() {
        std::thread::scope(|s| s.spawn(|| rt.block_on(fut)).join().expect("scoped future panicked"))
    } else {
        rt.block_on(fut)
    }
}

fn with_active_env<F, R>(f: F) -> Result<R, String>
where
    F: FnOnce(&mut ExecutionEnv, &tokio::runtime::Handle) -> Result<R, String>,
{
    // Clone the top raw pointer & Handle without holding the RefCell borrow across nested re-entry.
    let (env_ptr, rt) = ENV_STACK.with(|stack| {
        let borrow = stack.borrow();
        let top = borrow
            .last()
            .ok_or_else(|| "no active Concave ExecutionEnv on Roc worker thread".to_string())?;
        Ok::<_, String>((top.env, top.rt.clone()))
    })?;

    // SAFETY: `env_ptr` points to a live `ExecutionEnv` pinned on the current call stack
    // (or owned by the active RocJob frame) for the entire duration of this synchronous call.
    let env = unsafe { &mut *env_ptr };
    f(env, &rt)
}

fn host_ctx() -> RocHost {
    make_roc_host(std::ptr::null_mut())
}

fn take_roc_str(s: RocStr, host: &RocHost) -> String {
    let owned = s.as_str().to_owned();
    unsafe {
        s.decref(host);
    }
    owned
}

fn wire_result(res: Result<String, String>, host: &RocHost) -> RocStr {
    match res {
        Ok(payload) => RocStr::from_str(&format!("OK:{payload}"), host),
        Err(err) => RocStr::from_str(&format!("ERR:{err}"), host),
    }
}

fn unwrap_roc_wire(raw: &str) -> Result<Value, String> {
    if let Some(payload) = raw.strip_prefix("OK:") {
        serde_json::from_str(payload)
            .map_err(|e| format!("failed to parse Roc JSON return `{payload}`: {e}"))
    } else if let Some(err) = raw.strip_prefix("ERR:") {
        Err(err.to_string())
    } else {
        Err(format!("malformed Roc wire response: {raw}"))
    }
}

// =============================================================================
// Hosted C-ABI Functions (called by compiled Roc code)
// =============================================================================

#[derive(Debug, Deserialize)]
struct WireQueryRequest {
    namespace: String,
    table: String,
    index_name: String,
    start: WireBound,
    end: WireBound,
    #[serde(default)]
    order: QueryOrder,
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum WireBound {
    Unbounded,
    Included { values: Vec<IndexValue> },
    Excluded { values: Vec<IndexValue> },
    Prefix { values: Vec<IndexValue> },
}

fn decode_wire_bound(bound: WireBound) -> Result<KeyBound, String> {
    match bound {
        WireBound::Unbounded => Ok(KeyBound::Unbounded),
        WireBound::Included { values } => {
            let bytes = encode_key(&values).map_err(|e| e.to_string())?;
            Ok(KeyBound::Included(bytes))
        }
        WireBound::Excluded { values } => {
            let bytes = encode_key(&values).map_err(|e| e.to_string())?;
            Ok(KeyBound::Excluded(bytes))
        }
        WireBound::Prefix { values } => {
            let bytes = encode_prefix_upper_bound(&values).map_err(|e| e.to_string())?;
            Ok(KeyBound::Excluded(bytes))
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_get(ns: RocStr, table: RocStr, doc_id: RocStr) -> RocStr {
    let host = host_ctx();
    let ns = take_roc_str(ns, &host);
    let table = take_roc_str(table, &host);
    let doc_id = take_roc_str(doc_id, &host);

    let res = with_active_env(|env, rt| {
        let doc = block_on_safe(rt, env.db_get(&ns, &table, &doc_id))?;
        match doc {
            Some(d) => serde_json::to_string(&d.to_wire_json()).map_err(|e| e.to_string()),
            None => Ok("null".to_string()),
        }
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_query(req_json: RocStr) -> RocStr {
    let host = host_ctx();
    let req_json = take_roc_str(req_json, &host);

    let res = with_active_env(|env, rt| {
        let parsed: WireQueryRequest =
            serde_json::from_str(&req_json).map_err(|e| format!("invalid query JSON: {e}"))?;
        let query = IndexQuery {
            namespace: parsed.namespace,
            table: parsed.table,
            index_name: parsed.index_name,
            start: decode_wire_bound(parsed.start)?,
            end: decode_wire_bound(parsed.end)?,
            order: parsed.order,
            limit: parsed.limit,
        };
        let docs = block_on_safe(rt, env.db_query(query))?;
        let wire_docs: Vec<Value> = docs.into_iter().map(|d| d.to_wire_json()).collect();
        serde_json::to_string(&wire_docs).map_err(|e| e.to_string())
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_insert(ns: RocStr, table: RocStr, body_json: RocStr) -> RocStr {
    let host = host_ctx();
    let ns = take_roc_str(ns, &host);
    let table = take_roc_str(table, &host);
    let body_json = take_roc_str(body_json, &host);

    let res = with_active_env(|env, _rt| {
        let body: Value =
            serde_json::from_str(&body_json).map_err(|e| format!("invalid insert JSON: {e}"))?;
        env.db_insert(&ns, &table, body)
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_patch(
    ns: RocStr,
    table: RocStr,
    doc_id: RocStr,
    patch_json: RocStr,
) -> RocStr {
    let host = host_ctx();
    let ns = take_roc_str(ns, &host);
    let table = take_roc_str(table, &host);
    let doc_id = take_roc_str(doc_id, &host);
    let patch_json = take_roc_str(patch_json, &host);

    let res = with_active_env(|env, rt| {
        let val: Value =
            serde_json::from_str(&patch_json).map_err(|e| format!("invalid patch JSON: {e}"))?;
        let map = val
            .as_object()
            .cloned()
            .ok_or_else(|| "patch payload must be a JSON object".to_string())?;
        block_on_safe(rt, env.db_patch(&ns, &table, &doc_id, map))?;
        Ok("ok".to_string())
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_replace(
    ns: RocStr,
    table: RocStr,
    doc_id: RocStr,
    body_json: RocStr,
) -> RocStr {
    let host = host_ctx();
    let ns = take_roc_str(ns, &host);
    let table = take_roc_str(table, &host);
    let doc_id = take_roc_str(doc_id, &host);
    let body_json = take_roc_str(body_json, &host);

    let res = with_active_env(|env, rt| {
        let body: Value =
            serde_json::from_str(&body_json).map_err(|e| format!("invalid replace JSON: {e}"))?;
        block_on_safe(rt, env.db_replace(&ns, &table, &doc_id, body))?;
        Ok("ok".to_string())
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_db_delete(ns: RocStr, table: RocStr, doc_id: RocStr) -> RocStr {
    let host = host_ctx();
    let ns = take_roc_str(ns, &host);
    let table = take_roc_str(table, &host);
    let doc_id = take_roc_str(doc_id, &host);

    let res = with_active_env(|env, rt| {
        block_on_safe(rt, env.db_delete(&ns, &table, &doc_id))?;
        Ok("ok".to_string())
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_auth_identity() -> RocStr {
    let host = host_ctx();
    let res = with_active_env(|env, _rt| match env.auth() {
        Some(id) => {
            let payload = json!({
                "subject": id.subject,
                "issuer": id.issuer,
                "name": id.name.clone().unwrap_or_else(|| id.subject.clone()),
            });
            serde_json::to_string(&payload).map_err(|e| e.to_string())
        }
        None => Err("unauthenticated".into()),
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_http_fetch(method: RocStr, url: RocStr, body: RocStr) -> RocStr {
    let host = host_ctx();
    let method = take_roc_str(method, &host);
    let url = take_roc_str(url, &host);
    let body = take_roc_str(body, &host);

    let res = with_active_env(|env, rt| {
        let req = HttpFetchRequest {
            method,
            url,
            headers: HashMap::new(),
            body: if body.is_empty() { None } else { Some(body) },
        };
        let resp = block_on_safe(rt, env.http_fetch(req))?;
        let payload = json!({
            "status": resp.status,
            "body": resp.body,
        });
        serde_json::to_string(&payload).map_err(|e| e.to_string())
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_run_query(name: RocStr, args_json: RocStr) -> RocStr {
    let host = host_ctx();
    let name = take_roc_str(name, &host);
    let args_json = take_roc_str(args_json, &host);

    let res = with_active_env(|env, rt| {
        let args: Value =
            serde_json::from_str(&args_json).map_err(|e| format!("invalid query args: {e}"))?;
        let val = block_on_safe(rt, env.run_query(&name, args))?;
        serde_json::to_string(&val).map_err(|e| e.to_string())
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_run_mutation(name: RocStr, args_json: RocStr) -> RocStr {
    let host = host_ctx();
    let name = take_roc_str(name, &host);
    let args_json = take_roc_str(args_json, &host);

    let res = with_active_env(|env, rt| {
        let args: Value =
            serde_json::from_str(&args_json).map_err(|e| format!("invalid mutation args: {e}"))?;
        let val = block_on_safe(rt, env.run_mutation(&name, args))?;
        serde_json::to_string(&val).map_err(|e| e.to_string())
    });
    wire_result(res, &host)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_host_now_ms() -> i64 {
    now_millis()
}

// =============================================================================
// Dedicated Roc Worker Thread & `AppExecutor` Implementation
// =============================================================================

#[derive(Clone, Copy)]
enum DispatchKind {
    Query,
    Mutation,
    Action,
}

struct RocJob {
    kind: DispatchKind,
    name: String,
    args_json: String,
    env: ExecutionEnv,
    rt: tokio::runtime::Handle,
    reply: oneshot::Sender<(Result<Value, String>, ExecutionEnv)>,
}

fn dispatch_on_current_thread(
    kind: DispatchKind,
    name: &str,
    args_json: &str,
    env: &mut ExecutionEnv,
    rt: tokio::runtime::Handle,
) -> Result<Value, String> {
    let _guard = FrameGuard::push(env, rt);
    let host = host_ctx();
    let roc_name = RocStr::from_str(name, &host);
    let roc_args = RocStr::from_str(args_json, &host);

    let owned_res = unsafe {
        match kind {
            DispatchKind::Query => roc_dispatch_query_owned(roc_name, roc_args),
            DispatchKind::Mutation => roc_dispatch_mutation_owned(roc_name, roc_args),
            DispatchKind::Action => roc_dispatch_action_owned(roc_name, roc_args),
        }
    };
    unwrap_roc_wire(owned_res.as_str())
}

struct RocAppExecutor {
    manifest: Arc<AppManifest>,
    tx: mpsc::UnboundedSender<RocJob>,
}

impl RocAppExecutor {
    fn spawn() -> Result<Arc<Self>, String> {
        let (tx, mut rx) = mpsc::unbounded_channel::<RocJob>();
        let (init_tx, init_rx) = std::sync::mpsc::channel::<Result<AppManifest, String>>();

        std::thread::Builder::new()
            .name("concave-roc-worker".into())
            .stack_size(16 * 1024 * 1024)
            .spawn(move || {
                IS_ROC_WORKER.with(|f| *f.borrow_mut() = true);

                let manifest_res = (|| {
                    let owned = unsafe { roc_introspect_owned() };
                    let json_str = owned.as_str();
                    serde_json::from_str::<AppManifest>(json_str)
                        .map_err(|e| format!("failed to parse Roc manifest `{json_str}`: {e}"))
                })();

                let ok = manifest_res.is_ok();
                let _ = init_tx.send(manifest_res);
                if !ok {
                    return;
                }

                while let Some(mut job) = rx.blocking_recv() {
                    let result = dispatch_on_current_thread(
                        job.kind,
                        &job.name,
                        &job.args_json,
                        &mut job.env,
                        job.rt,
                    );
                    let _ = job.reply.send((result, job.env));
                }
            })
            .map_err(|e| format!("failed to spawn Roc worker thread: {e}"))?;

        let manifest = init_rx
            .recv()
            .map_err(|e| format!("Roc worker exited before introspect: {e}"))??;

        Ok(Arc::new(Self {
            manifest: Arc::new(manifest),
            tx,
        }))
    }

    async fn dispatch(
        &self,
        kind: DispatchKind,
        name: &str,
        args: Value,
        env: &mut ExecutionEnv,
    ) -> Result<Value, String> {
        let args_json = serde_json::to_string(&args).map_err(|e| e.to_string())?;
        let rt = tokio::runtime::Handle::current();

        // Re-entrant call (e.g., an Action calling run_query / run_mutation on the Roc worker):
        // execute directly on the current thread to avoid self-deadlock while preserving single-threaded ARC.
        if is_on_roc_worker() {
            return dispatch_on_current_thread(kind, name, &args_json, env, rt);
        }

        // Move `env` temporarily to the Roc worker thread and restore it upon completion.
        let dummy_auth = None;
        let placeholder_env = ExecutionEnv::Action {
            bridge: Arc::new(DummyBridge),
            auth: dummy_auth,
        };
        let owned_env = std::mem::replace(env, placeholder_env);

        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send(RocJob {
                kind,
                name: name.to_string(),
                args_json,
                env: owned_env,
                rt,
                reply: reply_tx,
            })
            .map_err(|_| "Roc worker thread terminated".to_string())?;

        let (result, returned_env) = reply_rx
            .await
            .map_err(|_| "Roc worker dropped response channel".to_string())?;
        *env = returned_env;
        result
    }
}

struct DummyBridge;

#[async_trait]
impl concave_runtime::ActionBridge for DummyBridge {
    async fn run_query(
        &self,
        _name: &str,
        _args: Value,
        _auth: Option<concave_runtime::AuthIdentity>,
    ) -> Result<Value, String> {
        Err("uninitialized bridge".into())
    }
    async fn run_mutation(
        &self,
        _name: &str,
        _args: Value,
        _auth: Option<concave_runtime::AuthIdentity>,
    ) -> Result<(Value, i64), String> {
        Err("uninitialized bridge".into())
    }
    async fn http_fetch(
        &self,
        _req: HttpFetchRequest,
    ) -> Result<concave_runtime::HttpFetchResponse, String> {
        Err("uninitialized bridge".into())
    }
}

#[async_trait]
impl AppExecutor for RocAppExecutor {
    fn manifest(&self) -> Arc<AppManifest> {
        self.manifest.clone()
    }

    async fn execute_query(
        &self,
        name: &str,
        args: Value,
        env: &mut ExecutionEnv,
    ) -> Result<Value, String> {
        self.dispatch(DispatchKind::Query, name, args, env).await
    }

    async fn execute_mutation(
        &self,
        name: &str,
        args: Value,
        env: &mut ExecutionEnv,
    ) -> Result<Value, String> {
        self.dispatch(DispatchKind::Mutation, name, args, env).await
    }

    async fn execute_action(
        &self,
        name: &str,
        args: Value,
        env: &mut ExecutionEnv,
    ) -> Result<Value, String> {
        self.dispatch(DispatchKind::Action, name, args, env).await
    }
}

// =============================================================================
// Native Executable Entrypoint (`--introspect` / `--serve`)
// =============================================================================

struct HostCli {
    introspect: bool,
    host: IpAddr,
    port: u16,
    db_path: PathBuf,
    database_url: Option<String>,
    deployment_id: String,
    static_dir: Option<PathBuf>,
    commit_poll_ms: u64,
}

fn parse_cli(args: &[String]) -> Result<HostCli, String> {
    // Cloud Run injects `PORT` (typically 8080) and expects binding on `0.0.0.0`.
    let env_port = std::env::var("PORT")
        .ok()
        .and_then(|v| v.parse::<u16>().ok());
    let default_host: IpAddr = std::env::var("CONCAVE_HOST")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| {
            if env_port.is_some() {
                IpAddr::from([0, 0, 0, 0])
            } else {
                IpAddr::from([127, 0, 0, 1])
            }
        });

    let mut cli = HostCli {
        introspect: false,
        host: default_host,
        port: env_port.unwrap_or(3210),
        db_path: PathBuf::from(
            std::env::var("CONCAVE_DB_PATH").unwrap_or_else(|_| ".concave/dev.db".to_string()),
        ),
        database_url: std::env::var("DATABASE_URL").ok().filter(|s| !s.is_empty()),
        deployment_id: std::env::var("CONCAVE_DEPLOYMENT_ID")
            .unwrap_or_else(|_| "default".to_string()),
        static_dir: std::env::var("CONCAVE_STATIC_DIR")
            .ok()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from),
        commit_poll_ms: std::env::var("CONCAVE_COMMIT_POLL_MS")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(100),
    };

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--introspect" => cli.introspect = true,
            "--serve" => {}
            "--host" => {
                i += 1;
                let v = args.get(i).ok_or("--host requires a value")?;
                cli.host = v.parse().map_err(|e| format!("invalid --host `{v}`: {e}"))?;
            }
            "--port" => {
                i += 1;
                let v = args.get(i).ok_or("--port requires a value")?;
                cli.port = v.parse().map_err(|e| format!("invalid --port `{v}`: {e}"))?;
            }
            "--db" => {
                i += 1;
                let v = args.get(i).ok_or("--db requires a value")?;
                cli.db_path = PathBuf::from(v);
            }
            "--database-url" => {
                i += 1;
                let v = args.get(i).ok_or("--database-url requires a value")?;
                cli.database_url = Some(v.clone());
            }
            "--deployment-id" => {
                i += 1;
                let v = args.get(i).ok_or("--deployment-id requires a value")?;
                cli.deployment_id = v.clone();
            }
            "--static-dir" => {
                i += 1;
                let v = args.get(i).ok_or("--static-dir requires a value")?;
                cli.static_dir = Some(PathBuf::from(v));
            }
            "--commit-poll-ms" => {
                i += 1;
                let v = args.get(i).ok_or("--commit-poll-ms requires a value")?;
                cli.commit_poll_ms = v
                    .parse()
                    .map_err(|e| format!("invalid --commit-poll-ms `{v}`: {e}"))?;
            }
            "--help" | "-h" => {
                println!(
                    "Concave Roc App Server\n\n\
                     Options:\n\
                       --introspect              Print JSON AppManifest IR and exit\n\
                       --serve                   Run the Concave HTTP/WebSocket server (default)\n\
                       --host <ip>               Bind IP address [default: 127.0.0.1]\n\
                       --port <port>             Bind port [default: 3210]\n\
                       --db <path>               SQLite database file [default: .concave/dev.db]\n\
                       --database-url <url>      PostgreSQL URL (overrides --db; also reads DATABASE_URL)\n\
                       --deployment-id <id>      Tenant/deployment shard key [default: default]\n\
                       --static-dir <dir>        Optional static directory to serve frontend assets"
                );
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument `{other}`")),
        }
        i += 1;
    }

    Ok(cli)
}

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: c_int, argv: *const *const c_char) -> c_int {
    let mut args = Vec::with_capacity(argc.max(0) as usize);
    for i in 0..argc.max(0) {
        let ptr = unsafe { *argv.add(i as usize) };
        if !ptr.is_null() {
            let s = unsafe { CStr::from_ptr(ptr) }
                .to_string_lossy()
                .into_owned();
            args.push(s);
        }
    }

    let cli = match parse_cli(&args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("error: {e}");
            return 2;
        }
    };

    if cli.introspect {
        let owned = unsafe { roc_introspect_owned() };
        println!("{}", owned.as_str());
        return 0;
    }

    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .try_init();

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("failed to initialize tokio runtime: {e}");
            return 1;
        }
    };

    let result: Result<(), String> = rt.block_on(async move {
        let executor = RocAppExecutor::spawn()?;

        let storage: Arc<dyn StorageBackend> = if let Some(url) = &cli.database_url {
            Arc::new(
                PostgresStorage::connect(url, &cli.deployment_id)
                    .await
                    .map_err(|e| format!("failed to connect PostgreSQL: {e}"))?,
            )
        } else {
            if let Some(parent) = cli.db_path.parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent)
                        .map_err(|e| format!("failed to create db directory: {e}"))?;
                }
            }
            Arc::new(
                SqliteStorage::open_file(&cli.db_path, &cli.deployment_id)
                    .map_err(|e| format!("failed to open SQLite db: {e}"))?,
            )
        };

        let allow_dev_tokens = std::env::var("CONCAVE_ALLOW_DEV_TOKENS")
            .map(|v| v != "false" && v != "0")
            .unwrap_or(true);
        let auth_config = AuthConfig {
            jwt_secret: std::env::var("CONCAVE_JWT_SECRET")
                .ok()
                .filter(|s| !s.is_empty()),
            allow_dev_tokens,
        };

        let engine = ConcaveEngine::new(storage, executor, auth_config)
            .await
            .map_err(|e| format!("failed to start ConcaveEngine: {e}"))?;

        let _tailer = if cli.commit_poll_ms > 0 {
            Some(engine.spawn_commit_tailer(std::time::Duration::from_millis(cli.commit_poll_ms)))
        } else {
            None
        };

        serve(
            engine,
            ServerConfig {
                bind_addr: SocketAddr::new(cli.host, cli.port),
                static_dir: cli.static_dir,
            },
        )
        .await
    });

    if let Err(e) = result {
        eprintln!("concave host error: {e}");
        return 1;
    }
    0
}
