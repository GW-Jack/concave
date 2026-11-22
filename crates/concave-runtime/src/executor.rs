use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use concave_core::{AppManifest, Document, IndexQuery};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::auth::AuthIdentity;
use crate::tx::TxContext;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpFetchRequest {
    pub method: String,
    pub url: String,
    #[serde(default)]
    pub headers: HashMap<String, String>,
    #[serde(default)]
    pub body: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpFetchResponse {
    pub status: u16,
    pub headers: HashMap<String, String>,
    pub body: String,
}

/// Callback bridge enabling Actions to run queries, mutations, and external HTTP requests.
#[async_trait]
pub trait ActionBridge: Send + Sync {
    async fn run_query(
        &self,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> Result<Value, String>;

    async fn run_mutation(
        &self,
        name: &str,
        args: Value,
        auth: Option<AuthIdentity>,
    ) -> Result<(Value, i64), String>;

    async fn http_fetch(&self, req: HttpFetchRequest) -> Result<HttpFetchResponse, String>;
}

/// Live capability environment available during a single Query, Mutation, or Action invocation.
pub enum ExecutionEnv {
    QueryOrMutation {
        tx: TxContext,
        auth: Option<AuthIdentity>,
    },
    Action {
        bridge: Arc<dyn ActionBridge>,
        auth: Option<AuthIdentity>,
    },
}

impl ExecutionEnv {
    pub fn auth(&self) -> Option<&AuthIdentity> {
        match self {
            ExecutionEnv::QueryOrMutation { auth, .. } => auth.as_ref(),
            ExecutionEnv::Action { auth, .. } => auth.as_ref(),
        }
    }

    pub async fn db_get(
        &mut self,
        namespace: &str,
        table: &str,
        doc_id: &str,
    ) -> Result<Option<Document>, String> {
        match self {
            ExecutionEnv::QueryOrMutation { tx, .. } => tx
                .get(namespace, table, doc_id)
                .await
                .map_err(|e| e.to_string()),
            ExecutionEnv::Action { .. } => Err(
                "direct db_get is not allowed inside an Action; use run_query/run_mutation".into(),
            ),
        }
    }

    pub async fn db_query(&mut self, query: IndexQuery) -> Result<Vec<Document>, String> {
        match self {
            ExecutionEnv::QueryOrMutation { tx, .. } => {
                tx.scan_index(query).await.map_err(|e| e.to_string())
            }
            ExecutionEnv::Action { .. } => Err(
                "direct db_query is not allowed inside an Action; use run_query/run_mutation"
                    .into(),
            ),
        }
    }

    pub fn db_insert(
        &mut self,
        namespace: &str,
        table: &str,
        body: Value,
    ) -> Result<String, String> {
        match self {
            ExecutionEnv::QueryOrMutation { tx, .. } => {
                tx.insert(namespace, table, body).map_err(|e| e.to_string())
            }
            ExecutionEnv::Action { .. } => Err(
                "direct db_insert is not allowed inside an Action; use run_mutation".into(),
            ),
        }
    }

    pub async fn db_patch(
        &mut self,
        namespace: &str,
        table: &str,
        doc_id: &str,
        patch: Map<String, Value>,
    ) -> Result<(), String> {
        match self {
            ExecutionEnv::QueryOrMutation { tx, .. } => tx
                .patch(namespace, table, doc_id, patch)
                .await
                .map_err(|e| e.to_string()),
            ExecutionEnv::Action { .. } => {
                Err("direct db_patch is not allowed inside an Action; use run_mutation".into())
            }
        }
    }

    pub async fn db_replace(
        &mut self,
        namespace: &str,
        table: &str,
        doc_id: &str,
        body: Value,
    ) -> Result<(), String> {
        match self {
            ExecutionEnv::QueryOrMutation { tx, .. } => tx
                .replace(namespace, table, doc_id, body)
                .await
                .map_err(|e| e.to_string()),
            ExecutionEnv::Action { .. } => {
                Err("direct db_replace is not allowed inside an Action; use run_mutation".into())
            }
        }
    }

    pub async fn db_delete(
        &mut self,
        namespace: &str,
        table: &str,
        doc_id: &str,
    ) -> Result<(), String> {
        match self {
            ExecutionEnv::QueryOrMutation { tx, .. } => tx
                .delete(namespace, table, doc_id)
                .await
                .map_err(|e| e.to_string()),
            ExecutionEnv::Action { .. } => {
                Err("direct db_delete is not allowed inside an Action; use run_mutation".into())
            }
        }
    }

    pub async fn http_fetch(&self, req: HttpFetchRequest) -> Result<HttpFetchResponse, String> {
        match self {
            ExecutionEnv::Action { bridge, .. } => bridge.http_fetch(req).await,
            ExecutionEnv::QueryOrMutation { .. } => {
                Err("external http_fetch is only allowed inside an Action".into())
            }
        }
    }

    pub async fn run_query(&self, name: &str, args: Value) -> Result<Value, String> {
        match self {
            ExecutionEnv::Action { bridge, auth } => {
                bridge.run_query(name, args, auth.clone()).await
            }
            ExecutionEnv::QueryOrMutation { .. } => {
                Err("run_query via ActionBridge is only available inside an Action".into())
            }
        }
    }

    pub async fn run_mutation(&self, name: &str, args: Value) -> Result<Value, String> {
        match self {
            ExecutionEnv::Action { bridge, auth } => bridge
                .run_mutation(name, args, auth.clone())
                .await
                .map(|(v, _)| v),
            ExecutionEnv::QueryOrMutation { .. } => {
                Err("run_mutation via ActionBridge is only available inside an Action".into())
            }
        }
    }
}

/// Execution adapter implemented by `concave-host` (bridging into compiled Roc 0.1.0_RC1 code)
/// and by Rust test harnesses.
#[async_trait]
pub trait AppExecutor: Send + Sync {
    fn manifest(&self) -> Arc<AppManifest>;

    async fn execute_query(
        &self,
        name: &str,
        args: Value,
        env: &mut ExecutionEnv,
    ) -> Result<Value, String>;

    async fn execute_mutation(
        &self,
        name: &str,
        args: Value,
        env: &mut ExecutionEnv,
    ) -> Result<Value, String>;

    async fn execute_action(
        &self,
        name: &str,
        args: Value,
        env: &mut ExecutionEnv,
    ) -> Result<Value, String>;
}
