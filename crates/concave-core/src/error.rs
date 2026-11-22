use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("optimistic concurrency conflict at snapshot_ts={snapshot_ts}, latest_ts={latest_ts}")]
    Conflict { snapshot_ts: i64, latest_ts: i64 },

    #[error("document not found: {namespace}::{table}/{doc_id}")]
    NotFound {
        namespace: String,
        table: String,
        doc_id: String,
    },

    #[error("unknown table: {namespace}::{table}")]
    UnknownTable { namespace: String, table: String },

    #[error("unknown index: {namespace}::{table}.{index}")]
    UnknownIndex {
        namespace: String,
        table: String,
        index: String,
    },

    #[error("invalid index key: {0}")]
    InvalidKey(String),

    #[error("serialization error: {0}")]
    Serialization(String),

    #[error("storage error: {0}")]
    Storage(String),
}

pub type CoreResult<T> = Result<T, CoreError>;
