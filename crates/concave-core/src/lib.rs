pub mod error;
pub mod key;
pub mod manifest;
pub mod readset;
pub mod storage;

pub use error::{CoreError, CoreResult};
pub use key::{decode_key, encode_key, encode_prefix_upper_bound, IndexValue};
pub use manifest::{
    AppManifest, ComponentSpec, FieldSpec, FunctionKind, FunctionSpec, IndexSpec, SchemaType,
    TableSpec, VariantSpec,
};
pub use readset::{DocRef, IndexRangeRead, KeyBound, ReadSet, TableRef, WriteSet, WrittenIndexKey};
pub use storage::postgres::PostgresStorage;
pub use storage::sqlite::SqliteStorage;
pub use storage::{
    apply_patch, compute_index_entries, new_doc_id, now_millis, CommitEntry, CommitResult,
    Document, IndexQuery, QueryOrder, StorageBackend, WriteOp, BY_CREATION_TIME_INDEX,
};
