use std::collections::HashMap;
use std::sync::Arc;

use concave_core::{
    apply_patch, compute_index_entries, new_doc_id, now_millis, AppManifest, CoreError, CoreResult,
    DocRef, Document, IndexQuery, IndexRangeRead, QueryOrder, ReadSet, StorageBackend, WriteOp,
};
use serde_json::{Map, Value};

/// Transaction state with read-set tracking and read-your-own-writes overlay.
pub struct TxContext {
    storage: Arc<dyn StorageBackend>,
    manifest: Arc<AppManifest>,
    snapshot_ts: i64,
    read_only: bool,
    read_set: ReadSet,
    writes: Vec<WriteOp>,
    /// Overlay of in-transaction mutations: `Some(doc)` = inserted/updated, `None` = deleted.
    pending_docs: HashMap<DocRef, Option<Document>>,
}

impl TxContext {
    pub fn new(
        storage: Arc<dyn StorageBackend>,
        manifest: Arc<AppManifest>,
        snapshot_ts: i64,
        read_only: bool,
    ) -> Self {
        Self {
            storage,
            manifest,
            snapshot_ts,
            read_only,
            read_set: ReadSet::default(),
            writes: Vec::new(),
            pending_docs: HashMap::new(),
        }
    }

    pub fn snapshot_ts(&self) -> i64 {
        self.snapshot_ts
    }

    pub fn is_read_only(&self) -> bool {
        self.read_only
    }

    pub fn into_parts(self) -> (ReadSet, Vec<WriteOp>) {
        (self.read_set, self.writes)
    }

    pub fn read_set(&self) -> &ReadSet {
        &self.read_set
    }

    pub async fn get(
        &mut self,
        namespace: &str,
        table: &str,
        doc_id: &str,
    ) -> CoreResult<Option<Document>> {
        let doc_ref = DocRef::new(namespace, table, doc_id);
        self.read_set.record_doc_read(doc_ref.clone());

        if let Some(overlay) = self.pending_docs.get(&doc_ref) {
            return Ok(overlay.clone());
        }
        self.storage.get_doc(namespace, table, doc_id).await
    }

    pub async fn scan_index(&mut self, query: IndexQuery) -> CoreResult<Vec<Document>> {
        let range = IndexRangeRead {
            namespace: query.namespace.clone(),
            table: query.table.clone(),
            index_name: query.index_name.clone(),
            start: query.start.clone(),
            end: query.end.clone(),
        };
        self.read_set.record_index_range(range.clone());

        let has_pending_for_table = self
            .pending_docs
            .keys()
            .any(|k| k.namespace == query.namespace && k.table == query.table);

        if !has_pending_for_table {
            return self.storage.scan_index(&query).await;
        }

        // Read-your-own-writes merge when this transaction has already mutated the same table.
        let mut unbounded_query = query.clone();
        unbounded_query.limit = None;
        let base_docs = self.storage.scan_index(&unbounded_query).await?;

        let mut merged: HashMap<String, Document> =
            base_docs.into_iter().map(|d| (d.id.clone(), d)).collect();

        for (doc_ref, maybe_doc) in &self.pending_docs {
            if doc_ref.namespace == query.namespace && doc_ref.table == query.table {
                match maybe_doc {
                    Some(doc) => {
                        merged.insert(doc.id.clone(), doc.clone());
                    }
                    None => {
                        merged.remove(&doc_ref.doc_id);
                    }
                }
            }
        }

        // Re-filter and sort by the queried index key.
        let mut keyed: Vec<(Vec<u8>, Document)> = Vec::new();
        for doc in merged.into_values() {
            let entries =
                compute_index_entries(&self.manifest, &query.namespace, &query.table, &doc)?;
            if let Some((_, key)) = entries.into_iter().find(|(name, _)| name == &query.index_name)
            {
                if range.contains_key(&key) {
                    keyed.push((key, doc));
                }
            }
        }

        match query.order {
            QueryOrder::Asc => keyed.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.id.cmp(&b.1.id))),
            QueryOrder::Desc => keyed.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.id.cmp(&a.1.id))),
        }

        if let Some(limit) = query.limit {
            keyed.truncate(limit);
        }

        Ok(keyed.into_iter().map(|(_, doc)| doc).collect())
    }

    pub fn insert(
        &mut self,
        namespace: &str,
        table: &str,
        mut body: Value,
    ) -> CoreResult<String> {
        if self.read_only {
            return Err(CoreError::Storage(
                "cannot insert inside a read-only query".into(),
            ));
        }
        if let Value::Object(ref mut map) = body {
            map.remove("id");
            map.remove("created_at");
            map.remove("_id");
            map.remove("_creationTime");
        }
        let doc_id = new_doc_id();
        let creation_time_ms = now_millis();
        let doc = Document {
            id: doc_id.clone(),
            creation_time_ms,
            body: body.clone(),
        };
        self.pending_docs
            .insert(DocRef::new(namespace, table, &doc_id), Some(doc));
        self.writes.push(WriteOp::Insert {
            namespace: namespace.to_string(),
            table: table.to_string(),
            doc_id: doc_id.clone(),
            creation_time_ms,
            body,
        });
        Ok(doc_id)
    }

    pub async fn patch(
        &mut self,
        namespace: &str,
        table: &str,
        doc_id: &str,
        patch: Map<String, Value>,
    ) -> CoreResult<()> {
        if self.read_only {
            return Err(CoreError::Storage(
                "cannot patch inside a read-only query".into(),
            ));
        }
        let existing = self.get(namespace, table, doc_id).await?;
        let Some(mut doc) = existing else {
            return Err(CoreError::NotFound {
                namespace: namespace.to_string(),
                table: table.to_string(),
                doc_id: doc_id.to_string(),
            });
        };
        doc.body = apply_patch(&doc.body, &patch);
        self.pending_docs
            .insert(DocRef::new(namespace, table, doc_id), Some(doc));
        self.writes.push(WriteOp::Patch {
            namespace: namespace.to_string(),
            table: table.to_string(),
            doc_id: doc_id.to_string(),
            patch,
        });
        Ok(())
    }

    pub async fn replace(
        &mut self,
        namespace: &str,
        table: &str,
        doc_id: &str,
        mut body: Value,
    ) -> CoreResult<()> {
        if self.read_only {
            return Err(CoreError::Storage(
                "cannot replace inside a read-only query".into(),
            ));
        }
        if let Value::Object(ref mut map) = body {
            map.remove("id");
            map.remove("created_at");
            map.remove("_id");
            map.remove("_creationTime");
        }
        let existing = self.get(namespace, table, doc_id).await?;
        let Some(mut doc) = existing else {
            return Err(CoreError::NotFound {
                namespace: namespace.to_string(),
                table: table.to_string(),
                doc_id: doc_id.to_string(),
            });
        };
        doc.body = body.clone();
        self.pending_docs
            .insert(DocRef::new(namespace, table, doc_id), Some(doc));
        self.writes.push(WriteOp::Replace {
            namespace: namespace.to_string(),
            table: table.to_string(),
            doc_id: doc_id.to_string(),
            body,
        });
        Ok(())
    }

    pub async fn delete(&mut self, namespace: &str, table: &str, doc_id: &str) -> CoreResult<()> {
        if self.read_only {
            return Err(CoreError::Storage(
                "cannot delete inside a read-only query".into(),
            ));
        }
        let _ = self.get(namespace, table, doc_id).await?;
        self.pending_docs
            .insert(DocRef::new(namespace, table, doc_id), None);
        self.writes.push(WriteOp::Delete {
            namespace: namespace.to_string(),
            table: table.to_string(),
            doc_id: doc_id.to_string(),
        });
        Ok(())
    }
}
