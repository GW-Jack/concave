pub mod postgres;
pub mod sqlite;

use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

use crate::error::CoreResult;
use crate::key::{encode_key, IndexValue};
use crate::manifest::{AppManifest, IndexSpec};
use crate::readset::{KeyBound, ReadSet, WriteSet};

pub const BY_CREATION_TIME_INDEX: &str = "by_creation_time";

/// Stored document record including Convex-style system fields (`_id`, `_creationTime`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Document {
    pub id: String,
    pub creation_time_ms: i64,
    pub body: Value,
}

impl Document {
    /// Merge system fields (`id`, `created_at`) into the document's JSON object representation.
    pub fn to_wire_json(&self) -> Value {
        let mut obj = match &self.body {
            Value::Object(map) => map.clone(),
            other => {
                let mut m = Map::new();
                m.insert("value".into(), other.clone());
                m
            }
        };
        obj.insert("id".into(), Value::String(self.id.clone()));
        obj.insert(
            "created_at".into(),
            Value::Number(self.creation_time_ms.into()),
        );
        Value::Object(obj)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QueryOrder {
    Asc,
    Desc,
}

impl Default for QueryOrder {
    fn default() -> Self {
        Self::Asc
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexQuery {
    pub namespace: String,
    pub table: String,
    pub index_name: String,
    pub start: KeyBound,
    pub end: KeyBound,
    pub order: QueryOrder,
    pub limit: Option<usize>,
}

/// Write operation buffered inside a mutation transaction.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum WriteOp {
    Insert {
        namespace: String,
        table: String,
        doc_id: String,
        creation_time_ms: i64,
        body: Value,
    },
    Replace {
        namespace: String,
        table: String,
        doc_id: String,
        body: Value,
    },
    Patch {
        namespace: String,
        table: String,
        doc_id: String,
        patch: Map<String, Value>,
    },
    Delete {
        namespace: String,
        table: String,
        doc_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CommitEntry {
    pub commit_ts: i64,
    pub write_set: WriteSet,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitResult {
    pub commit_ts: i64,
    pub write_set: WriteSet,
}

/// Pluggable persistence layer implemented for SQLite (local dev) and PostgreSQL (cloud/sharded).
#[async_trait]
pub trait StorageBackend: Send + Sync {
    /// Ensure core tables (`documents`, `index_entries`, `commit_log`) exist and sync manifest indexes.
    async fn init_schema(&self, manifest: &AppManifest) -> CoreResult<()>;

    /// Return the current monotonic `commit_ts` for this deployment.
    async fn latest_commit_ts(&self) -> CoreResult<i64>;

    /// Fetch a single document by `(namespace, table, doc_id)`.
    async fn get_doc(
        &self,
        namespace: &str,
        table: &str,
        doc_id: &str,
    ) -> CoreResult<Option<Document>>;

    /// Scan documents matching an encoded index range in ascending or descending order.
    async fn scan_index(&self, query: &IndexQuery) -> CoreResult<Vec<Document>>;

    /// Atomically validate OCC (`read_set` vs commits after `snapshot_ts`), apply `writes`,
    /// maintain index entries, and append the resulting `WriteSet` to `commit_log`.
    async fn commit_tx(
        &self,
        manifest: &AppManifest,
        snapshot_ts: i64,
        read_set: &ReadSet,
        writes: &[WriteOp],
    ) -> CoreResult<CommitResult>;

    /// Fetch commit log entries strictly after `since_ts` (used for cache coherence & multi-node tailing).
    async fn commits_since(&self, since_ts: i64) -> CoreResult<Vec<CommitEntry>>;
}

pub fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn new_doc_id() -> String {
    Uuid::now_v7().to_string()
}

/// Compute all `(index_name, encoded_key_bytes)` pairs for a document according to `manifest`.
///
/// Every table automatically maintains `by_creation_time` (`[_creationTime]`), and every
/// user-declared index appends `_creationTime` as a deterministic tie-breaker (matching Convex).
pub fn compute_index_entries(
    manifest: &AppManifest,
    namespace: &str,
    table: &str,
    doc: &Document,
) -> CoreResult<Vec<(String, Vec<u8>)>> {
    let mut entries = Vec::new();

    // Built-in `by_creation_time` index for every table.
    let ct_key = encode_key(&[IndexValue::Int(doc.creation_time_ms)])?;
    entries.push((BY_CREATION_TIME_INDEX.to_string(), ct_key));

    if let Some(table_spec) = manifest.find_table(namespace, table) {
        for idx in &table_spec.indexes {
            if idx.name == BY_CREATION_TIME_INDEX {
                continue;
            }
            let encoded = encode_doc_for_index(doc, idx)?;
            entries.push((idx.name.clone(), encoded));
        }
    }

    Ok(entries)
}

pub fn encode_doc_for_index(doc: &Document, idx: &IndexSpec) -> CoreResult<Vec<u8>> {
    let mut vals = Vec::with_capacity(idx.fields.len() + 1);
    let mut has_creation_time = false;
    for field in &idx.fields {
        match field.as_str() {
            "id" | "_id" => vals.push(IndexValue::Id(doc.id.clone())),
            "created_at" | "_creationTime" => {
                has_creation_time = true;
                vals.push(IndexValue::Int(doc.creation_time_ms));
            }
            path => {
                let extracted = extract_json_path(&doc.body, path);
                vals.push(IndexValue::from_json(&extracted)?);
            }
        }
    }
    if !has_creation_time {
        vals.push(IndexValue::Int(doc.creation_time_ms));
    }
    encode_key(&vals)
}

fn extract_json_path(root: &Value, path: &str) -> Value {
    let mut curr = root;
    for seg in path.split('.') {
        match curr {
            Value::Object(map) => match map.get(seg) {
                Some(v) => curr = v,
                None => return Value::Null,
            },
            _ => return Value::Null,
        }
    }
    curr.clone()
}

pub fn apply_patch(base: &Value, patch: &Map<String, Value>) -> Value {
    let mut obj = match base {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    };
    for (k, v) in patch {
        if k == "id" || k == "created_at" || k == "_id" || k == "_creationTime" {
            continue;
        }
        obj.insert(k.clone(), v.clone());
    }
    Value::Object(obj)
}
