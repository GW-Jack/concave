use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, Uri};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tower_http::cors::CorsLayer;
use tracing::{info, warn};

use crate::auth::AuthIdentity;
use crate::engine::ConcaveEngine;
use crate::protocol::{ClientMessage, ServerMessage};
use crate::ts::transpile_ts;

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub bind_addr: SocketAddr,
    pub static_dir: Option<PathBuf>,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            bind_addr: SocketAddr::from(([127, 0, 0, 1], 3210)),
            static_dir: None,
        }
    }
}

pub fn build_router(engine: Arc<ConcaveEngine>, static_dir: Option<PathBuf>) -> Router {
    let mut app = Router::new()
        .route("/health", get(health))
        .route("/ready", get(ready))
        .route("/api/manifest", get(get_manifest))
        .route("/api/query/{name}", post(http_query))
        .route("/api/mutation/{name}", post(http_mutation))
        .route("/api/action/{name}", post(http_action))
        .route("/ws", get(ws_upgrade))
        .route("/_concave/{file}", get(serve_builtin_client))
        .layer(CorsLayer::permissive())
        .with_state(engine);

    if let Some(dir) = static_dir {
        let dir = Arc::new(dir);
        app = app.fallback(move |uri: Uri| {
            let dir = dir.clone();
            async move { serve_static_with_ts(dir, uri).await }
        });
    }

    app
}

async fn serve_builtin_client(Path(file): Path<String>) -> impl IntoResponse {
    const INDEX_TS: &str = include_str!("../../../client/concave-client/src/index.ts");
    const SIGNALS_TS: &str = include_str!("../../../client/concave-client/src/signals.ts");
    const CLIENT_TS: &str = include_str!("../../../client/concave-client/src/client.ts");
    const DOM_TS: &str = include_str!("../../../client/concave-client/src/dom.ts");

    let source = match file.as_str() {
        "index.ts" => Some(("index.ts", INDEX_TS)),
        "signals.ts" => Some(("signals.ts", SIGNALS_TS)),
        "client.ts" => Some(("client.ts", CLIENT_TS)),
        "dom.ts" => Some(("dom.ts", DOM_TS)),
        _ => None,
    };

    match source {
        Some((name, ts_src)) => match transpile_ts(name, ts_src) {
            Ok(js) => (
                StatusCode::OK,
                [(
                    axum::http::header::CONTENT_TYPE,
                    "text/javascript; charset=utf-8",
                )],
                js,
            )
                .into_response(),
            Err(err) => (StatusCode::INTERNAL_SERVER_ERROR, err).into_response(),
        },
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn serve_static_with_ts(root: Arc<PathBuf>, uri: Uri) -> impl IntoResponse {
    let raw_path = uri.path().trim_start_matches('/');
    let rel_path = if raw_path.is_empty() {
        "index.html"
    } else {
        raw_path
    };

    let Ok(canonical_root) = std::fs::canonicalize(root.as_ref()) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let candidate = canonical_root.join(rel_path);
    let Ok(canonical_file) = std::fs::canonicalize(&candidate) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !canonical_file.starts_with(&canonical_root) || !canonical_file.is_file() {
        return StatusCode::FORBIDDEN.into_response();
    }

    let ext = canonical_file
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");

    if ext == "ts" || ext == "tsx" {
        let Ok(src) = tokio::fs::read_to_string(&canonical_file).await else {
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        };
        let filename = canonical_file
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("module.ts");
        return match transpile_ts(filename, &src) {
            Ok(js) => (
                StatusCode::OK,
                [(
                    axum::http::header::CONTENT_TYPE,
                    "text/javascript; charset=utf-8",
                )],
                js,
            )
                .into_response(),
            Err(err) => (StatusCode::INTERNAL_SERVER_ERROR, err).into_response(),
        };
    }

    let Ok(bytes) = tokio::fs::read(&canonical_file).await else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let mime = match ext {
        "html" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "ico" => "image/x-icon",
        "wasm" => "application/wasm",
        _ => "application/octet-stream",
    };

    (
        StatusCode::OK,
        [(axum::http::header::CONTENT_TYPE, mime)],
        bytes,
    )
        .into_response()
}

pub async fn serve(engine: Arc<ConcaveEngine>, config: ServerConfig) -> Result<(), String> {
    let app = build_router(engine, config.static_dir);
    let listener = tokio::net::TcpListener::bind(config.bind_addr)
        .await
        .map_err(|e| format!("failed to bind {}: {e}", config.bind_addr))?;
    info!("Concave server listening on http://{}", config.bind_addr);
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|e| format!("server error: {e}"))
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut sig) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            sig.recv().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => info!("received SIGINT, draining Concave server..."),
        _ = terminate => info!("received SIGTERM, draining Concave server..."),
    }
}

async fn health() -> impl IntoResponse {
    Json(json!({ "status": "ok" }))
}

async fn ready(State(engine): State<Arc<ConcaveEngine>>) -> impl IntoResponse {
    match engine.ready_check().await {
        Ok(commit_ts) => (
            StatusCode::OK,
            Json(json!({ "status": "ready", "commit_ts": commit_ts })),
        ),
        Err(err) => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "status": "unavailable", "error": err.to_string() })),
        ),
    }
}

async fn get_manifest(State(engine): State<Arc<ConcaveEngine>>) -> impl IntoResponse {
    Json((*engine.manifest()).clone())
}

fn extract_http_auth(
    engine: &ConcaveEngine,
    headers: &HeaderMap,
) -> Result<Option<AuthIdentity>, (StatusCode, Json<Value>)> {
    let Some(raw) = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
    else {
        return Ok(None);
    };
    engine
        .verify_auth_token(raw)
        .map(Some)
        .map_err(|err| (StatusCode::UNAUTHORIZED, Json(json!({ "error": err }))))
}

async fn http_query(
    State(engine): State<Arc<ConcaveEngine>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    Json(args): Json<Value>,
) -> impl IntoResponse {
    let auth = match extract_http_auth(&engine, &headers) {
        Ok(a) => a,
        Err(resp) => return resp,
    };
    match engine.execute_query(&name, args, auth).await {
        Ok(value) => (StatusCode::OK, Json(json!({ "ok": true, "value": value }))),
        Err(error) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": error })),
        ),
    }
}

async fn http_mutation(
    State(engine): State<Arc<ConcaveEngine>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    Json(args): Json<Value>,
) -> impl IntoResponse {
    let auth = match extract_http_auth(&engine, &headers) {
        Ok(a) => a,
        Err(resp) => return resp,
    };
    match engine.execute_mutation(&name, args, auth).await {
        Ok((value, commit_ts)) => (
            StatusCode::OK,
            Json(json!({ "ok": true, "value": value, "commit_ts": commit_ts })),
        ),
        Err(error) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": error })),
        ),
    }
}

async fn http_action(
    State(engine): State<Arc<ConcaveEngine>>,
    Path(name): Path<String>,
    headers: HeaderMap,
    Json(args): Json<Value>,
) -> impl IntoResponse {
    let auth = match extract_http_auth(&engine, &headers) {
        Ok(a) => a,
        Err(resp) => return resp,
    };
    match engine.execute_action(&name, args, auth).await {
        Ok(value) => (StatusCode::OK, Json(json!({ "ok": true, "value": value }))),
        Err(error) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": error })),
        ),
    }
}

async fn ws_upgrade(
    ws: WebSocketUpgrade,
    State(engine): State<Arc<ConcaveEngine>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, engine))
}

async fn handle_ws(socket: WebSocket, engine: Arc<ConcaveEngine>) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<ServerMessage>();
    let client_id = engine.register_client(out_tx.clone()).await;

    let writer = tokio::spawn(async move {
        while let Some(msg) = out_rx.recv().await {
            match serde_json::to_string(&msg) {
                Ok(text) => {
                    if ws_tx.send(Message::Text(text.into())).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    warn!("failed to serialize ServerMessage: {e}");
                }
            }
        }
    });

    while let Some(Ok(frame)) = ws_rx.next().await {
        let text = match frame {
            Message::Text(t) => t.to_string(),
            Message::Close(_) => break,
            Message::Ping(_) | Message::Pong(_) | Message::Binary(_) => continue,
        };

        let parsed: ClientMessage = match serde_json::from_str(&text) {
            Ok(m) => m,
            Err(e) => {
                let _ = out_tx.send(ServerMessage::Error {
                    message: format!("invalid client message: {e}"),
                });
                continue;
            }
        };

        match parsed {
            ClientMessage::Authenticate { token } => {
                let res = engine.authenticate_client(client_id, token).await;
                let _ = out_tx.send(res);
            }
            ClientMessage::Subscribe { sub_id, name, args } => {
                engine.subscribe(client_id, sub_id, name, args).await;
            }
            ClientMessage::Unsubscribe { sub_id } => {
                engine.unsubscribe(client_id, &sub_id).await;
            }
            ClientMessage::Mutation { req_id, name, args } => {
                let auth = engine.client_auth(client_id).await;
                let msg = match engine.execute_mutation(&name, args, auth).await {
                    Ok((value, commit_ts)) => ServerMessage::MutationResult {
                        req_id,
                        ok: true,
                        value: Some(value),
                        error: None,
                        commit_ts: Some(commit_ts),
                    },
                    Err(error) => ServerMessage::MutationResult {
                        req_id,
                        ok: false,
                        value: None,
                        error: Some(error),
                        commit_ts: None,
                    },
                };
                let _ = out_tx.send(msg);
            }
            ClientMessage::Action { req_id, name, args } => {
                let auth = engine.client_auth(client_id).await;
                let engine_clone = engine.clone();
                let out_clone = out_tx.clone();
                tokio::spawn(async move {
                    let msg = match engine_clone.execute_action(&name, args, auth).await {
                        Ok(value) => ServerMessage::ActionResult {
                            req_id,
                            ok: true,
                            value: Some(value),
                            error: None,
                        },
                        Err(error) => ServerMessage::ActionResult {
                            req_id,
                            ok: false,
                            value: None,
                            error: Some(error),
                        },
                    };
                    let _ = out_clone.send(msg);
                });
            }
            ClientMessage::Ping { ts } => {
                let _ = out_tx.send(ServerMessage::Pong { ts });
            }
        }
    }

    engine.unregister_client(client_id).await;
    writer.abort();
}
