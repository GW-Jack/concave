use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use concave_core::{AppManifest, CoreError, ReadSet, StorageBackend, WriteSet};
use reqwest::Method;
use serde_json::Value;
use tokio::sync::{mpsc, RwLock};
use tracing::{debug, warn};
use uuid::Uuid;

use crate::auth::{verify_token, AuthConfig, AuthIdentity};
use crate::executor::{ActionBridge, AppExecutor, ExecutionEnv, HttpFetchRequest, HttpFetchResponse};
use crate::protocol::{QueryUpdate, ServerMessage};
use crate::tx::TxContext;

const MAX_OCC_RETRIES: usize = 8;

struct ActiveSubscription {
    sub_id: String,
    name: String,
    args: Value,
    read_set: ReadSet,
    last_payload: Option<Result<Value, String>>,
}

struct ClientSession {
    tx: mpsc::UnboundedSender<ServerMessage>,
    auth: Option<AuthIdentity>,
    subscriptions: HashMap<String, ActiveSubscription>,
}

/// Core reactive execution & subscription coordination engine.
pub struct ConcaveEngine {
    storage: Arc<dyn StorageBackend>,
    executor: Arc<dyn AppExecutor>,
    manifest: Arc<AppManifest>,
    auth_config: AuthConfig,
    http_client: reqwest::Client,
    clients: RwLock<HashMap<Uuid, ClientSession>>,
}

impl ConcaveEngine {
    pub async fn new(
        storage: Arc<dyn StorageBackend>,
        executor: Arc<dyn AppExecutor>,
        auth_config: AuthConfig,
    ) -> Result<Arc<Self>, CoreError> {
        let manifest = executor.manifest();
        storage.init_schema(&manifest).await?;

        Ok(Arc::new(Self {
            storage,
            executor,
            manifest,
            auth_config,
            http_client: reqwest::Client::new(),
            clients: RwLock::new(HashMap::new()),
        }))
    }

    pub fn manifest(&self) -> Arc<AppManifest> {
        self.manifest.clone()
    }

    pub fn verify_auth_token(&self, token: &str) -> Result<AuthIdentity, String> {
        verify_token(&self.auth_config, token)
    }

    pub async fn register_client(&self, tx: mpsc::UnboundedSender<ServerMessage>) -> Uuid {
        let id = Uuid::new_v4();
        self.clients.write().await.insert(
            id,
            ClientSession {
                tx,
                auth: None,
                subscriptions: HashMap::new(),
            },
        );
        id
    }

    pub async fn unregister_client(&self, client_id: Uuid) {
        self.clients.write().await.remove(&client_id);
    }

    pub async fn client_auth(&self, client_id: Uuid) -> Option<AuthIdentity> {
        self.clients
            .read()
            .await
            .get(&client_id)
            .and_then(|c| c.auth.clone())
    }

    /// Authenticate (or de-authenticate) a WebSocket client and re-evaluate its active subscriptions.
    pub async fn authenticate_client(
        &self,
        client_id: Uuid,
        token: Option<String>,
    ) -> ServerMessage {
        let new_auth = match token {
            None => Ok(None),
            Some(tok) => verify_token(&self.auth_config, &tok).map(Some),
        };

        let identity = match new_auth {
            Ok(id) => id,
            Err(err) => {
                return ServerMessage::AuthResult {
                    ok: false,
                    identity: None,
                    error: Some(err),
                };
            }
        };

        // Snapshot active subscriptions to re-run under the new identity.
        let (tx, subs_to_rerun) = {
            let mut guard = self.clients.write().await;
            let Some(session) = guard.get_mut(&client_id) else {
                return ServerMessage::AuthResult {
                    ok: false,
                    identity: None,
                    error: Some("client disconnected".into()),
                };
            };
            session.auth = identity.clone();
            let list: Vec<(String, String, Value)> = session
                .subscriptions
                .values()
                .map(|s| (s.sub_id.clone(), s.name.clone(), s.args.clone()))
                .collect();
            (session.tx.clone(), list)
        };

        if !subs_to_rerun.is_empty() {
            let mut updates = Vec::new();
            let mut to_ts = self.storage.latest_commit_ts().await.unwrap_or(0);

            for (sub_id, name, args) in subs_to_rerun {
                let (result, read_set, ts) =
                    self.run_query_internal(&name, args, identity.clone()).await;
                to_ts = to_ts.max(ts);
                let update = make_query_update(&sub_id, &result);
                if let Some(session) = self.clients.write().await.get_mut(&client_id) {
                    if let Some(sub) = session.subscriptions.get_mut(&sub_id) {
                        sub.read_set = read_set;
                        sub.last_payload = Some(result);
                    }
                }
                updates.push(update);
            }
            let _ = tx.send(ServerMessage::Transition { to_ts, updates });
        }

        ServerMessage::AuthResult {
            ok: true,
            identity,
            error: None,
        }
    }

    /// Subscribe a WebSocket client to a reactive query and immediately send its initial snapshot.
    pub async fn subscribe(&self, client_id: Uuid, sub_id: String, name: String, args: Value) {
        let auth = self.client_auth(client_id).await;
        let (result, read_set, ts) = self.run_query_internal(&name, args.clone(), auth).await;
        let update = make_query_update(&sub_id, &result);

        let tx = {
            let mut guard = self.clients.write().await;
            let Some(session) = guard.get_mut(&client_id) else {
                return;
            };
            session.subscriptions.insert(
                sub_id.clone(),
                ActiveSubscription {
                    sub_id,
                    name,
                    args,
                    read_set,
                    last_payload: Some(result),
                },
            );
            session.tx.clone()
        };

        let _ = tx.send(ServerMessage::Transition {
            to_ts: ts,
            updates: vec![update],
        });
    }

    pub async fn unsubscribe(&self, client_id: Uuid, sub_id: &str) {
        if let Some(session) = self.clients.write().await.get_mut(&client_id) {
            session.subscriptions.remove(sub_id);
        }
    }

    /// One-shot query execution (used by HTTP `/api/query/:name` and ActionBridge).
    pub async fn execute_query(
        &self,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> Result<Value, String> {
        let (res, _, _) = self.run_query_internal(name, args, auth).await;
        res
    }

    async fn run_query_internal(
        &self,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> (Result<Value, String>, ReadSet, i64) {
        let snapshot_ts = match self.storage.latest_commit_ts().await {
            Ok(ts) => ts,
            Err(e) => return (Err(e.to_string()), ReadSet::default(), 0),
        };
        let tx = TxContext::new(
            self.storage.clone(),
            self.manifest.clone(),
            snapshot_ts,
            true,
        );
        let mut env = ExecutionEnv::QueryOrMutation { tx, auth };
        let res = self.executor.execute_query(name, args, &mut env).await;
        let read_set = match env {
            ExecutionEnv::QueryOrMutation { tx, .. } => tx.into_parts().0,
            ExecutionEnv::Action { .. } => ReadSet::default(),
        };
        (res, read_set, snapshot_ts)
    }

    /// Execute a transactional mutation with automatic OCC retries, then surgically notify
    /// all subscribed clients whose `ReadSet` overlaps the committed `WriteSet`.
    pub async fn execute_mutation(
        self: &Arc<Self>,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> Result<(Value, i64), String> {
        for attempt in 0..MAX_OCC_RETRIES {
            let snapshot_ts = self
                .storage
                .latest_commit_ts()
                .await
                .map_err(|e| e.to_string())?;
            let tx = TxContext::new(
                self.storage.clone(),
                self.manifest.clone(),
                snapshot_ts,
                false,
            );
            let mut env = ExecutionEnv::QueryOrMutation {
                tx,
                auth: auth.clone(),
            };

            let value = self
                .executor
                .execute_mutation(name, args.clone(), &mut env)
                .await?;

            let (read_set, writes) = match env {
                ExecutionEnv::QueryOrMutation { tx, .. } => tx.into_parts(),
                ExecutionEnv::Action { .. } => unreachable!(),
            };

            match self
                .storage
                .commit_tx(&self.manifest, snapshot_ts, &read_set, &writes)
                .await
            {
                Ok(commit) => {
                    if !commit.write_set.is_empty() {
                        self.broadcast_invalidation(commit.commit_ts, &commit.write_set)
                            .await;
                    }
                    return Ok((value, commit.commit_ts));
                }
                Err(CoreError::Conflict {
                    snapshot_ts,
                    latest_ts,
                }) => {
                    debug!(
                        mutation = name,
                        attempt, snapshot_ts, latest_ts, "OCC conflict, retrying mutation"
                    );
                    continue;
                }
                Err(e) => return Err(e.to_string()),
            }
        }

        Err(format!(
            "mutation `{name}` exceeded {MAX_OCC_RETRIES} OCC retries due to concurrent conflicts"
        ))
    }

    /// Execute an external Action with HTTP access and transactional query/mutation callbacks.
    pub async fn execute_action(
        self: &Arc<Self>,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> Result<Value, String> {
        let bridge: Arc<dyn ActionBridge> = Arc::new(EngineActionBridge {
            engine: self.clone(),
        });
        let mut env = ExecutionEnv::Action { bridge, auth };
        self.executor.execute_action(name, args, &mut env).await
    }

    async fn broadcast_invalidation(&self, commit_ts: i64, write_set: &WriteSet) {
        // 1. Collect only subscriptions whose ReadSet intersects `write_set`.
        let impacted: Vec<(
            Uuid,
            mpsc::UnboundedSender<ServerMessage>,
            Option<AuthIdentity>,
            Vec<(String, String, Value)>,
        )> = {
            let guard = self.clients.read().await;
            let mut list = Vec::new();
            for (&client_id, session) in guard.iter() {
                let matching: Vec<(String, String, Value)> = session
                    .subscriptions
                    .values()
                    .filter(|sub| sub.read_set.intersects(write_set))
                    .map(|sub| (sub.sub_id.clone(), sub.name.clone(), sub.args.clone()))
                    .collect();
                if !matching.is_empty() {
                    list.push((
                        client_id,
                        session.tx.clone(),
                        session.auth.clone(),
                        matching,
                    ));
                }
            }
            list
        };

        // 2. Re-evaluate only affected subscriptions and emit ONE consistent Transition per client.
        for (client_id, tx, auth, subs) in impacted {
            let mut updates = Vec::new();
            for (sub_id, name, args) in subs {
                let (result, new_read_set, _) =
                    self.run_query_internal(&name, args, auth.clone()).await;

                let changed = {
                    let mut guard = self.clients.write().await;
                    if let Some(session) = guard.get_mut(&client_id) {
                        if let Some(sub) = session.subscriptions.get_mut(&sub_id) {
                            let is_changed = sub.last_payload.as_ref() != Some(&result);
                            sub.read_set = new_read_set;
                            sub.last_payload = Some(result.clone());
                            is_changed
                        } else {
                            false
                        }
                    } else {
                        false
                    }
                };

                if changed {
                    updates.push(make_query_update(&sub_id, &result));
                }
            }

            if !updates.is_empty() {
                if tx
                    .send(ServerMessage::Transition {
                        to_ts: commit_ts,
                        updates,
                    })
                    .is_err()
                {
                    warn!(%client_id, "failed to push transition to disconnected client");
                }
            }
        }
    }
}

fn make_query_update(sub_id: &str, result: &Result<Value, String>) -> QueryUpdate {
    match result {
        Ok(value) => QueryUpdate {
            sub_id: sub_id.to_string(),
            ok: true,
            value: Some(value.clone()),
            error: None,
        },
        Err(err) => QueryUpdate {
            sub_id: sub_id.to_string(),
            ok: false,
            value: None,
            error: Some(err.clone()),
        },
    }
}

struct EngineActionBridge {
    engine: Arc<ConcaveEngine>,
}

#[async_trait]
impl ActionBridge for EngineActionBridge {
    async fn run_query(
        &self,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> Result<Value, String> {
        self.engine.execute_query(name, args, auth).await
    }

    async fn run_mutation(
        &self,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> Result<(Value, i64), String> {
        self.engine.execute_mutation(name, args, auth).await
    }

    async fn http_fetch(&self, req: HttpFetchRequest) -> Result<HttpFetchResponse, String> {
        let method = Method::from_bytes(req.method.to_uppercase().as_bytes())
            .map_err(|e| format!("invalid HTTP method `{}`: {e}", req.method))?;
        let mut builder = self.engine.http_client.request(method, &req.url);
        for (k, v) in &req.headers {
            builder = builder.header(k, v);
        }
        if let Some(body) = req.body {
            builder = builder.body(body);
        }
        let resp = builder
            .send()
            .await
            .map_err(|e| format!("http_fetch failed: {e}"))?;
        let status = resp.status().as_u16();
        let mut headers = HashMap::new();
        for (k, v) in resp.headers() {
            if let Ok(vs) = v.to_str() {
                headers.insert(k.to_string(), vs.to_string());
            }
        }
        let body = resp
            .text()
            .await
            .map_err(|e| format!("failed to read http_fetch body: {e}"))?;
        Ok(HttpFetchResponse {
            status,
            headers,
            body,
        })
    }
}

#[cfg(test)]
mod tests {
    use concave_core::{
        encode_key, encode_prefix_upper_bound, IndexQuery, IndexSpec, IndexValue, KeyBound,
        QueryOrder, SchemaType, SqliteStorage, TableSpec,
    };
    use serde_json::json;

    use super::*;

    struct MockChatExecutor {
        manifest: Arc<AppManifest>,
    }

    #[async_trait]
    impl AppExecutor for MockChatExecutor {
        fn manifest(&self) -> Arc<AppManifest> {
            self.manifest.clone()
        }

        async fn execute_query(
            &self,
            name: &str,
            args: Value,
            env: &mut ExecutionEnv,
        ) -> Result<Value, String> {
            match name {
                "messages.list" => {
                    let room = args["room"].as_str().ok_or("missing room")?;
                    let docs = env
                        .db_query(IndexQuery {
                            namespace: "".into(),
                            table: "messages".into(),
                            index_name: "by_room".into(),
                            start: KeyBound::Included(
                                encode_key(&[IndexValue::Str(room.into())]).unwrap(),
                            ),
                            end: KeyBound::Excluded(
                                encode_prefix_upper_bound(&[IndexValue::Str(room.into())]).unwrap(),
                            ),
                            order: QueryOrder::Asc,
                            limit: None,
                        })
                        .await?;
                    Ok(Value::Array(
                        docs.into_iter().map(|d| d.to_wire_json()).collect(),
                    ))
                }
                _ => Err(format!("unknown query {name}")),
            }
        }

        async fn execute_mutation(
            &self,
            name: &str,
            args: Value,
            env: &mut ExecutionEnv,
        ) -> Result<Value, String> {
            match name {
                "messages.send" => {
                    let room = args["room"].as_str().ok_or("missing room")?;
                    let body = args["body"].as_str().ok_or("missing body")?;
                    let id = env.db_insert(
                        "",
                        "messages",
                        json!({ "room": room, "body": body }),
                    )?;
                    Ok(json!(id))
                }
                _ => Err(format!("unknown mutation {name}")),
            }
        }

        async fn execute_action(
            &self,
            _name: &str,
            _args: Value,
            _env: &mut ExecutionEnv,
        ) -> Result<Value, String> {
            Ok(json!({ "ok": true }))
        }
    }

    #[tokio::test]
    async fn index_range_invalidation_only_notifies_matching_room_subscriber() {
        let manifest = Arc::new(AppManifest {
            app_name: "chat".into(),
            tables: vec![TableSpec {
                name: "messages".into(),
                document_schema: SchemaType::Any,
                indexes: vec![IndexSpec {
                    name: "by_room".into(),
                    fields: vec!["room".into()],
                }],
            }],
            components: vec![],
            functions: vec![],
        });
        let storage = Arc::new(SqliteStorage::open_in_memory("test").unwrap());
        let executor = Arc::new(MockChatExecutor { manifest });
        let engine = ConcaveEngine::new(storage, executor, AuthConfig::default())
            .await
            .unwrap();

        let (tx_a, mut rx_a) = mpsc::unbounded_channel();
        let (tx_b, mut rx_b) = mpsc::unbounded_channel();
        let client_a = engine.register_client(tx_a).await;
        let client_b = engine.register_client(tx_b).await;

        engine
            .subscribe(
                client_a,
                "s1".into(),
                "messages.list".into(),
                json!({ "room": "general" }),
            )
            .await;
        engine
            .subscribe(
                client_b,
                "s2".into(),
                "messages.list".into(),
                json!({ "room": "roc" }),
            )
            .await;

        // Drain initial empty snapshots.
        let _ = rx_a.recv().await.unwrap();
        let _ = rx_b.recv().await.unwrap();

        // Send a message to #general -> ONLY client_a receives a Transition!
        engine
            .execute_mutation(
                "messages.send",
                json!({ "room": "general", "body": "hello general" }),
                None,
            )
            .await
            .unwrap();

        let msg_a = rx_a.try_recv().expect("client_a should get transition");
        match msg_a {
            ServerMessage::Transition { to_ts, updates } => {
                assert_eq!(to_ts, 1);
                assert_eq!(updates.len(), 1);
                assert_eq!(updates[0].value.as_ref().unwrap().as_array().unwrap().len(), 1);
            }
            other => panic!("unexpected frame: {other:?}"),
        }
        assert!(
            rx_b.try_recv().is_err(),
            "client_b watching #roc must NOT be invalidated by #general write"
        );
    }
}
