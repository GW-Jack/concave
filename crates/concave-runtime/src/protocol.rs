use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::auth::AuthIdentity;

/// Client -> Server WebSocket frames.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Authenticate {
        token: Option<String>,
    },
    Subscribe {
        sub_id: String,
        name: String,
        #[serde(default)]
        args: Value,
    },
    Unsubscribe {
        sub_id: String,
    },
    Mutation {
        req_id: String,
        name: String,
        #[serde(default)]
        args: Value,
    },
    Action {
        req_id: String,
        name: String,
        #[serde(default)]
        args: Value,
    },
    Ping {
        #[serde(default)]
        ts: i64,
    },
}

/// Server -> Client WebSocket frames.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    AuthResult {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        identity: Option<AuthIdentity>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    /// Consistent snapshot transition advancing one or more active subscriptions to `to_ts`.
    Transition {
        to_ts: i64,
        updates: Vec<QueryUpdate>,
    },
    MutationResult {
        req_id: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        value: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        commit_ts: Option<i64>,
    },
    ActionResult {
        req_id: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        value: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Pong {
        ts: i64,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryUpdate {
    pub sub_id: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
