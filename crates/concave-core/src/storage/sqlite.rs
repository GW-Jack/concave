use std::path::Path;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use serde_json::Value;

use crate::error::{CoreError, CoreResult};
use crate::manifest::AppManifest;
use crate::readset::{DocRef, KeyBound, ReadSet, WriteSet};
use crate::storage::{
    apply_patch, compute_index_entries, CommitEntry, CommitResult, Document, IndexQuery,
    QueryOrder, StorageBackend, WriteOp,
};

/// Embedded SQLite implementation of `StorageBackend` (WAL mode, zero-config local dev & tests).
#[derive(Clone)]
pub struct SqliteStorage {
    conn: Arc<Mutex<Connection>>,
    deployment_id: String,
}

impl SqliteStorage {
    pub fn open_file(
        path: impl AsRef<Path>,
        deployment_id: impl Into<String>,
    ) -> CoreResult<Self> {
        let conn = Connection::open(path).map_err(|e| CoreError::Storage(e.to_string()))?;
        Self::configure(conn, deployment_id.into())
    }

    pub fn open_in_memory(deployment_id: impl Into<String>) -> CoreResult<Self> {
        let conn = Connection::open_in_memory().map_err(|e| CoreError::Storage(e.to_string()))?;
        Self::configure(conn, deployment_id.into())
    }

    fn configure(conn: Connection, deployment_id: String) -> CoreResult<Self> {
        conn.execute_batch(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA busy_timeout = 5000;
            ",
        )
        .map_err(|e| CoreError::Storage(e.to_string()))?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            deployment_id,
        })
    }

    fn ensure_tables(conn: &Connection) -> CoreResult<()> {
        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS documents (
                deployment_id TEXT NOT NULL,
                namespace TEXT NOT NULL,
                table_name TEXT NOT NULL,
                doc_id TEXT NOT NULL,
                creation_time_ms INTEGER NOT NULL,
                body_json TEXT NOT NULL,
                PRIMARY KEY (deployment_id, namespace, table_name, doc_id)
            );

            CREATE TABLE IF NOT EXISTS index_entries (
                deployment_id TEXT NOT NULL,
                namespace TEXT NOT NULL,
                table_name TEXT NOT NULL,
                index_name TEXT NOT NULL,
                encoded_key BLOB NOT NULL,
                doc_id TEXT NOT NULL,
                PRIMARY KEY (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
            );

            CREATE INDEX IF NOT EXISTS idx_index_entries_doc
                ON index_entries (deployment_id, namespace, table_name, doc_id);

            CREATE TABLE IF NOT EXISTS commit_log (
                deployment_id TEXT NOT NULL,
                commit_ts INTEGER NOT NULL,
                writes_json TEXT NOT NULL,
                PRIMARY KEY (deployment_id, commit_ts)
            );
            ",
        )
        .map_err(|e| CoreError::Storage(e.to_string()))
    }
}

#[async_trait]
impl StorageBackend for SqliteStorage {
    async fn init_schema(&self, manifest: &AppManifest) -> CoreResult<()> {
        let conn = self.conn.clone();
        let deployment_id = self.deployment_id.clone();
        let manifest = manifest.clone();

        tokio::task::spawn_blocking(move || {
            let mut guard = conn
                .lock()
                .map_err(|e| CoreError::Storage(format!("sqlite mutex poisoned: {e}")))?;
            Self::ensure_tables(&guard)?;

            // Rebuild index entries for all existing documents so newly added/changed manifest
            // indexes are immediately consistent on boot.
            let tx = guard
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|e| CoreError::Storage(e.to_string()))?;

            let mut existing_docs = Vec::new();
            {
                let mut stmt = tx
                    .prepare(
                        "SELECT namespace, table_name, doc_id, creation_time_ms, body_json
                         FROM documents WHERE deployment_id = ?1",
                    )
                    .map_err(|e| CoreError::Storage(e.to_string()))?;
                let rows = stmt
                    .query_map(params![deployment_id], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, i64>(3)?,
                            row.get::<_, String>(4)?,
                        ))
                    })
                    .map_err(|e| CoreError::Storage(e.to_string()))?;
                for row in rows {
                    existing_docs.push(row.map_err(|e| CoreError::Storage(e.to_string()))?);
                }
            }

            tx.execute(
                "DELETE FROM index_entries WHERE deployment_id = ?1",
                params![deployment_id],
            )
            .map_err(|e| CoreError::Storage(e.to_string()))?;

            for (ns, tbl, doc_id, ct, body_json) in existing_docs {
                let body: Value = serde_json::from_str(&body_json)
                    .map_err(|e| CoreError::Serialization(e.to_string()))?;
                let doc = Document {
                    id: doc_id.clone(),
                    creation_time_ms: ct,
                    body,
                };
                for (index_name, encoded_key) in
                    compute_index_entries(&manifest, &ns, &tbl, &doc)?
                {
                    tx.execute(
                        "INSERT INTO index_entries
                         (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                        params![deployment_id, ns, tbl, index_name, encoded_key, doc_id],
                    )
                    .map_err(|e| CoreError::Storage(e.to_string()))?;
                }
            }

            tx.commit().map_err(|e| CoreError::Storage(e.to_string()))?;
            Ok(())
        })
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?
    }

    async fn latest_commit_ts(&self) -> CoreResult<i64> {
        let conn = self.conn.clone();
        let deployment_id = self.deployment_id.clone();

        tokio::task::spawn_blocking(move || {
            let guard = conn
                .lock()
                .map_err(|e| CoreError::Storage(format!("sqlite mutex poisoned: {e}")))?;
            let ts: Option<i64> = guard
                .query_row(
                    "SELECT MAX(commit_ts) FROM commit_log WHERE deployment_id = ?1",
                    params![deployment_id],
                    |row| row.get(0),
                )
                .map_err(|e| CoreError::Storage(e.to_string()))?;
            Ok(ts.unwrap_or(0))
        })
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?
    }

    async fn get_doc(
        &self,
        namespace: &str,
        table: &str,
        doc_id: &str,
    ) -> CoreResult<Option<Document>> {
        let conn = self.conn.clone();
        let deployment_id = self.deployment_id.clone();
        let namespace = namespace.to_string();
        let table = table.to_string();
        let doc_id = doc_id.to_string();

        tokio::task::spawn_blocking(move || {
            let guard = conn
                .lock()
                .map_err(|e| CoreError::Storage(format!("sqlite mutex poisoned: {e}")))?;
            let row: Option<(i64, String)> = guard
                .query_row(
                    "SELECT creation_time_ms, body_json
                     FROM documents
                     WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                    params![deployment_id, namespace, table, doc_id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()
                .map_err(|e| CoreError::Storage(e.to_string()))?;

            match row {
                Some((creation_time_ms, body_json)) => {
                    let body: Value = serde_json::from_str(&body_json)
                        .map_err(|e| CoreError::Serialization(e.to_string()))?;
                    Ok(Some(Document {
                        id: doc_id,
                        creation_time_ms,
                        body,
                    }))
                }
                None => Ok(None),
            }
        })
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?
    }

    async fn scan_index(&self, query: &IndexQuery) -> CoreResult<Vec<Document>> {
        let conn = self.conn.clone();
        let deployment_id = self.deployment_id.clone();
        let query = query.clone();

        tokio::task::spawn_blocking(move || {
            let guard = conn
                .lock()
                .map_err(|e| CoreError::Storage(format!("sqlite mutex poisoned: {e}")))?;

            let mut sql = String::from(
                "SELECT d.doc_id, d.creation_time_ms, d.body_json
                 FROM index_entries ie
                 INNER JOIN documents d
                   ON d.deployment_id = ie.deployment_id
                  AND d.namespace = ie.namespace
                  AND d.table_name = ie.table_name
                  AND d.doc_id = ie.doc_id
                 WHERE ie.deployment_id = ?1
                   AND ie.namespace = ?2
                   AND ie.table_name = ?3
                   AND ie.index_name = ?4",
            );

            let mut bind_params: Vec<rusqlite::types::Value> = vec![
                deployment_id.into(),
                query.namespace.into(),
                query.table.into(),
                query.index_name.into(),
            ];

            match &query.start {
                KeyBound::Unbounded => {}
                KeyBound::Included(k) => {
                    bind_params.push(k.clone().into());
                    sql.push_str(&format!(" AND ie.encoded_key >= ?{}", bind_params.len()));
                }
                KeyBound::Excluded(k) => {
                    bind_params.push(k.clone().into());
                    sql.push_str(&format!(" AND ie.encoded_key > ?{}", bind_params.len()));
                }
            }

            match &query.end {
                KeyBound::Unbounded => {}
                KeyBound::Included(k) => {
                    bind_params.push(k.clone().into());
                    sql.push_str(&format!(" AND ie.encoded_key <= ?{}", bind_params.len()));
                }
                KeyBound::Excluded(k) => {
                    bind_params.push(k.clone().into());
                    sql.push_str(&format!(" AND ie.encoded_key < ?{}", bind_params.len()));
                }
            }

            match query.order {
                QueryOrder::Asc => sql.push_str(" ORDER BY ie.encoded_key ASC, ie.doc_id ASC"),
                QueryOrder::Desc => sql.push_str(" ORDER BY ie.encoded_key DESC, ie.doc_id DESC"),
            }

            if let Some(limit) = query.limit {
                bind_params.push((limit as i64).into());
                sql.push_str(&format!(" LIMIT ?{}", bind_params.len()));
            }

            let mut stmt = guard
                .prepare(&sql)
                .map_err(|e| CoreError::Storage(e.to_string()))?;

            let rows = stmt
                .query_map(rusqlite::params_from_iter(bind_params.iter()), |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })
                .map_err(|e| CoreError::Storage(e.to_string()))?;

            let mut docs = Vec::new();
            for row in rows {
                let (id, creation_time_ms, body_json) =
                    row.map_err(|e| CoreError::Storage(e.to_string()))?;
                let body: Value = serde_json::from_str(&body_json)
                    .map_err(|e| CoreError::Serialization(e.to_string()))?;
                docs.push(Document {
                    id,
                    creation_time_ms,
                    body,
                });
            }
            Ok(docs)
        })
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?
    }

    async fn commit_tx(
        &self,
        manifest: &AppManifest,
        snapshot_ts: i64,
        read_set: &ReadSet,
        writes: &[WriteOp],
    ) -> CoreResult<CommitResult> {
        let conn = self.conn.clone();
        let deployment_id = self.deployment_id.clone();
        let manifest = manifest.clone();
        let read_set = read_set.clone();
        let writes = writes.to_vec();

        tokio::task::spawn_blocking(move || {
            let mut guard = conn
                .lock()
                .map_err(|e| CoreError::Storage(format!("sqlite mutex poisoned: {e}")))?;

            let tx = guard
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|e| CoreError::Storage(e.to_string()))?;

            // 1. OCC conflict check: verify no commit since `snapshot_ts` overlaps `read_set`.
            let latest_ts: i64 = tx
                .query_row(
                    "SELECT COALESCE(MAX(commit_ts), 0) FROM commit_log WHERE deployment_id = ?1",
                    params![deployment_id],
                    |row| row.get(0),
                )
                .map_err(|e| CoreError::Storage(e.to_string()))?;

            if latest_ts > snapshot_ts {
                let mut stmt = tx
                    .prepare(
                        "SELECT writes_json FROM commit_log
                         WHERE deployment_id = ?1 AND commit_ts > ?2
                         ORDER BY commit_ts ASC",
                    )
                    .map_err(|e| CoreError::Storage(e.to_string()))?;
                let rows = stmt
                    .query_map(params![deployment_id, snapshot_ts], |row| {
                        row.get::<_, String>(0)
                    })
                    .map_err(|e| CoreError::Storage(e.to_string()))?;
                for row in rows {
                    let ws_json = row.map_err(|e| CoreError::Storage(e.to_string()))?;
                    let committed_ws: WriteSet = serde_json::from_str(&ws_json)
                        .map_err(|e| CoreError::Serialization(e.to_string()))?;
                    if read_set.intersects(&committed_ws) {
                        return Err(CoreError::Conflict {
                            snapshot_ts,
                            latest_ts,
                        });
                    }
                }
            }

            if writes.is_empty() {
                tx.commit().map_err(|e| CoreError::Storage(e.to_string()))?;
                return Ok(CommitResult {
                    commit_ts: latest_ts,
                    write_set: WriteSet::default(),
                });
            }

            // 2. Apply buffered writes and collect pre-image & post-image WriteSet.
            let mut write_set = WriteSet::default();

            for op in writes {
                match op {
                    WriteOp::Insert {
                        namespace,
                        table,
                        doc_id,
                        creation_time_ms,
                        body,
                    } => {
                        let body_json = serde_json::to_string(&body)
                            .map_err(|e| CoreError::Serialization(e.to_string()))?;
                        tx.execute(
                            "INSERT INTO documents
                             (deployment_id, namespace, table_name, doc_id, creation_time_ms, body_json)
                             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                            params![
                                deployment_id,
                                namespace,
                                table,
                                doc_id,
                                creation_time_ms,
                                body_json
                            ],
                        )
                        .map_err(|e| CoreError::Storage(e.to_string()))?;

                        let doc = Document {
                            id: doc_id.clone(),
                            creation_time_ms,
                            body,
                        };
                        write_set.record_doc(DocRef::new(&namespace, &table, &doc_id));
                        for (index_name, encoded_key) in
                            compute_index_entries(&manifest, &namespace, &table, &doc)?
                        {
                            tx.execute(
                                "INSERT INTO index_entries
                                 (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                                params![
                                    deployment_id,
                                    namespace,
                                    table,
                                    index_name,
                                    encoded_key,
                                    doc_id
                                ],
                            )
                            .map_err(|e| CoreError::Storage(e.to_string()))?;
                            write_set.record_index_key(&namespace, &table, index_name, encoded_key);
                        }
                    }
                    WriteOp::Replace {
                        namespace,
                        table,
                        doc_id,
                        body,
                    } => {
                        let existing: Option<(i64, String)> = tx
                            .query_row(
                                "SELECT creation_time_ms, body_json FROM documents
                                 WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                                params![deployment_id, namespace, table, doc_id],
                                |row| Ok((row.get(0)?, row.get(1)?)),
                            )
                            .optional()
                            .map_err(|e| CoreError::Storage(e.to_string()))?;

                        let Some((creation_time_ms, old_body_json)) = existing else {
                            return Err(CoreError::NotFound {
                                namespace,
                                table,
                                doc_id,
                            });
                        };

                        let old_body: Value = serde_json::from_str(&old_body_json)
                            .map_err(|e| CoreError::Serialization(e.to_string()))?;
                        let old_doc = Document {
                            id: doc_id.clone(),
                            creation_time_ms,
                            body: old_body,
                        };
                        for (index_name, old_key) in
                            compute_index_entries(&manifest, &namespace, &table, &old_doc)?
                        {
                            write_set.record_index_key(&namespace, &table, index_name, old_key);
                        }

                        tx.execute(
                            "DELETE FROM index_entries
                             WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                            params![deployment_id, namespace, table, doc_id],
                        )
                        .map_err(|e| CoreError::Storage(e.to_string()))?;

                        let new_body_json = serde_json::to_string(&body)
                            .map_err(|e| CoreError::Serialization(e.to_string()))?;
                        tx.execute(
                            "UPDATE documents SET body_json = ?5
                             WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                            params![deployment_id, namespace, table, doc_id, new_body_json],
                        )
                        .map_err(|e| CoreError::Storage(e.to_string()))?;

                        let new_doc = Document {
                            id: doc_id.clone(),
                            creation_time_ms,
                            body,
                        };
                        write_set.record_doc(DocRef::new(&namespace, &table, &doc_id));
                        for (index_name, new_key) in
                            compute_index_entries(&manifest, &namespace, &table, &new_doc)?
                        {
                            tx.execute(
                                "INSERT INTO index_entries
                                 (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                                params![
                                    deployment_id,
                                    namespace,
                                    table,
                                    index_name,
                                    new_key,
                                    doc_id
                                ],
                            )
                            .map_err(|e| CoreError::Storage(e.to_string()))?;
                            write_set.record_index_key(&namespace, &table, index_name, new_key);
                        }
                    }
                    WriteOp::Patch {
                        namespace,
                        table,
                        doc_id,
                        patch,
                    } => {
                        let existing: Option<(i64, String)> = tx
                            .query_row(
                                "SELECT creation_time_ms, body_json FROM documents
                                 WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                                params![deployment_id, namespace, table, doc_id],
                                |row| Ok((row.get(0)?, row.get(1)?)),
                            )
                            .optional()
                            .map_err(|e| CoreError::Storage(e.to_string()))?;

                        let Some((creation_time_ms, old_body_json)) = existing else {
                            return Err(CoreError::NotFound {
                                namespace,
                                table,
                                doc_id,
                            });
                        };

                        let old_body: Value = serde_json::from_str(&old_body_json)
                            .map_err(|e| CoreError::Serialization(e.to_string()))?;
                        let old_doc = Document {
                            id: doc_id.clone(),
                            creation_time_ms,
                            body: old_body.clone(),
                        };
                        for (index_name, old_key) in
                            compute_index_entries(&manifest, &namespace, &table, &old_doc)?
                        {
                            write_set.record_index_key(&namespace, &table, index_name, old_key);
                        }

                        tx.execute(
                            "DELETE FROM index_entries
                             WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                            params![deployment_id, namespace, table, doc_id],
                        )
                        .map_err(|e| CoreError::Storage(e.to_string()))?;

                        let merged = apply_patch(&old_body, &patch);
                        let new_body_json = serde_json::to_string(&merged)
                            .map_err(|e| CoreError::Serialization(e.to_string()))?;
                        tx.execute(
                            "UPDATE documents SET body_json = ?5
                             WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                            params![deployment_id, namespace, table, doc_id, new_body_json],
                        )
                        .map_err(|e| CoreError::Storage(e.to_string()))?;

                        let new_doc = Document {
                            id: doc_id.clone(),
                            creation_time_ms,
                            body: merged,
                        };
                        write_set.record_doc(DocRef::new(&namespace, &table, &doc_id));
                        for (index_name, new_key) in
                            compute_index_entries(&manifest, &namespace, &table, &new_doc)?
                        {
                            tx.execute(
                                "INSERT INTO index_entries
                                 (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                                params![
                                    deployment_id,
                                    namespace,
                                    table,
                                    index_name,
                                    new_key,
                                    doc_id
                                ],
                            )
                            .map_err(|e| CoreError::Storage(e.to_string()))?;
                            write_set.record_index_key(&namespace, &table, index_name, new_key);
                        }
                    }
                    WriteOp::Delete {
                        namespace,
                        table,
                        doc_id,
                    } => {
                        let existing: Option<(i64, String)> = tx
                            .query_row(
                                "SELECT creation_time_ms, body_json FROM documents
                                 WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                                params![deployment_id, namespace, table, doc_id],
                                |row| Ok((row.get(0)?, row.get(1)?)),
                            )
                            .optional()
                            .map_err(|e| CoreError::Storage(e.to_string()))?;

                        if let Some((creation_time_ms, old_body_json)) = existing {
                            let old_body: Value = serde_json::from_str(&old_body_json)
                                .map_err(|e| CoreError::Serialization(e.to_string()))?;
                            let old_doc = Document {
                                id: doc_id.clone(),
                                creation_time_ms,
                                body: old_body,
                            };
                            for (index_name, old_key) in
                                compute_index_entries(&manifest, &namespace, &table, &old_doc)?
                            {
                                write_set.record_index_key(&namespace, &table, index_name, old_key);
                            }

                            tx.execute(
                                "DELETE FROM index_entries
                                 WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                                params![deployment_id, namespace, table, doc_id],
                            )
                            .map_err(|e| CoreError::Storage(e.to_string()))?;
                            tx.execute(
                                "DELETE FROM documents
                                 WHERE deployment_id = ?1 AND namespace = ?2 AND table_name = ?3 AND doc_id = ?4",
                                params![deployment_id, namespace, table, doc_id],
                            )
                            .map_err(|e| CoreError::Storage(e.to_string()))?;

                            write_set.record_doc(DocRef::new(&namespace, &table, &doc_id));
                        }
                    }
                }
            }

            // 3. Append to commit_log with monotonic commit_ts.
            let next_ts = latest_ts + 1;
            let writes_json = serde_json::to_string(&write_set)
                .map_err(|e| CoreError::Serialization(e.to_string()))?;
            tx.execute(
                "INSERT INTO commit_log (deployment_id, commit_ts, writes_json)
                 VALUES (?1, ?2, ?3)",
                params![deployment_id, next_ts, writes_json],
            )
            .map_err(|e| CoreError::Storage(e.to_string()))?;

            tx.commit().map_err(|e| CoreError::Storage(e.to_string()))?;

            Ok(CommitResult {
                commit_ts: next_ts,
                write_set,
            })
        })
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?
    }

    async fn commits_since(&self, since_ts: i64) -> CoreResult<Vec<CommitEntry>> {
        let conn = self.conn.clone();
        let deployment_id = self.deployment_id.clone();

        tokio::task::spawn_blocking(move || {
            let guard = conn
                .lock()
                .map_err(|e| CoreError::Storage(format!("sqlite mutex poisoned: {e}")))?;
            let mut stmt = guard
                .prepare(
                    "SELECT commit_ts, writes_json FROM commit_log
                     WHERE deployment_id = ?1 AND commit_ts > ?2
                     ORDER BY commit_ts ASC",
                )
                .map_err(|e| CoreError::Storage(e.to_string()))?;
            let rows = stmt
                .query_map(params![deployment_id, since_ts], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })
                .map_err(|e| CoreError::Storage(e.to_string()))?;
            let mut entries = Vec::new();
            for row in rows {
                let (commit_ts, writes_json) =
                    row.map_err(|e| CoreError::Storage(e.to_string()))?;
                let write_set: WriteSet = serde_json::from_str(&writes_json)
                    .map_err(|e| CoreError::Serialization(e.to_string()))?;
                entries.push(CommitEntry {
                    commit_ts,
                    write_set,
                });
            }
            Ok(entries)
        })
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::key::{encode_key, encode_prefix_upper_bound, IndexValue};
    use crate::manifest::{IndexSpec, SchemaType, TableSpec};
    use crate::readset::IndexRangeRead;
    use crate::storage::BY_CREATION_TIME_INDEX;

    fn sample_manifest() -> AppManifest {
        AppManifest {
            app_name: "test".into(),
            tables: vec![TableSpec {
                name: "messages".into(),
                document_schema: SchemaType::Any,
                indexes: vec![IndexSpec {
                    name: "by_room".into(),
                    fields: vec!["room_id".into()],
                }],
            }],
            components: vec![],
            functions: vec![],
        }
    }

    #[tokio::test]
    async fn sqlite_insert_index_scan_patch_delete_and_occ() {
        let storage = SqliteStorage::open_in_memory("dep-1").unwrap();
        let manifest = sample_manifest();
        storage.init_schema(&manifest).await.unwrap();

        assert_eq!(storage.latest_commit_ts().await.unwrap(), 0);

        let c1 = storage
            .commit_tx(
                &manifest,
                0,
                &ReadSet::default(),
                &[
                    WriteOp::Insert {
                        namespace: "".into(),
                        table: "messages".into(),
                        doc_id: "m1".into(),
                        creation_time_ms: 1000,
                        body: json!({ "room_id": "general", "body": "hello" }),
                    },
                    WriteOp::Insert {
                        namespace: "".into(),
                        table: "messages".into(),
                        doc_id: "m2".into(),
                        creation_time_ms: 2000,
                        body: json!({ "room_id": "roc", "body": "functional" }),
                    },
                    WriteOp::Insert {
                        namespace: "".into(),
                        table: "messages".into(),
                        doc_id: "m3".into(),
                        creation_time_ms: 3000,
                        body: json!({ "room_id": "general", "body": "world" }),
                    },
                ],
            )
            .await
            .unwrap();
        assert_eq!(c1.commit_ts, 1);

        // Scan only "general" in descending chronological order.
        let general_docs = storage
            .scan_index(&IndexQuery {
                namespace: "".into(),
                table: "messages".into(),
                index_name: "by_room".into(),
                start: KeyBound::Included(
                    encode_key(&[IndexValue::Str("general".into())]).unwrap(),
                ),
                end: KeyBound::Excluded(
                    encode_prefix_upper_bound(&[IndexValue::Str("general".into())]).unwrap(),
                ),
                order: QueryOrder::Desc,
                limit: Some(10),
            })
            .await
            .unwrap();
        assert_eq!(general_docs.len(), 2);
        assert_eq!(general_docs[0].id, "m3");
        assert_eq!(general_docs[1].id, "m1");

        // OCC: A stale transaction reading m1 at snapshot_ts=0 must fail with Conflict!
        let mut stale_read = ReadSet::default();
        stale_read.record_doc_read(DocRef::new("", "messages", "m1"));
        let conflict = storage
            .commit_tx(
                &manifest,
                0,
                &stale_read,
                &[WriteOp::Patch {
                    namespace: "".into(),
                    table: "messages".into(),
                    doc_id: "m1".into(),
                    patch: serde_json::from_value(json!({ "body": "edited" })).unwrap(),
                }],
            )
            .await;
        assert!(matches!(conflict, Err(CoreError::Conflict { .. })));

        // OCC: A stale transaction reading an unrelated room ("random") at snapshot_ts=0 SUCCEEDS!
        let mut unrelated_read = ReadSet::default();
        unrelated_read.record_index_range(IndexRangeRead {
            namespace: "".into(),
            table: "messages".into(),
            index_name: "by_room".into(),
            start: KeyBound::Included(encode_key(&[IndexValue::Str("random".into())]).unwrap()),
            end: KeyBound::Excluded(
                encode_prefix_upper_bound(&[IndexValue::Str("random".into())]).unwrap(),
            ),
        });
        let c2 = storage
            .commit_tx(
                &manifest,
                0,
                &unrelated_read,
                &[WriteOp::Patch {
                    namespace: "".into(),
                    table: "messages".into(),
                    doc_id: "m1".into(),
                    patch: serde_json::from_value(json!({ "room_id": "roc", "body": "moved" }))
                        .unwrap(),
                }],
            )
            .await
            .unwrap();
        assert_eq!(c2.commit_ts, 2);

        // Patch moving m1 from "general" to "roc" MUST include both old and new index keys in WriteSet!
        let mut general_watcher = ReadSet::default();
        general_watcher.record_index_range(IndexRangeRead {
            namespace: "".into(),
            table: "messages".into(),
            index_name: "by_room".into(),
            start: KeyBound::Included(encode_key(&[IndexValue::Str("general".into())]).unwrap()),
            end: KeyBound::Excluded(
                encode_prefix_upper_bound(&[IndexValue::Str("general".into())]).unwrap(),
            ),
        });
        assert!(
            general_watcher.intersects(&c2.write_set),
            "moving doc out of general must invalidate general watcher"
        );

        // Verify built-in by_creation_time scan + Delete.
        let c3 = storage
            .commit_tx(
                &manifest,
                c2.commit_ts,
                &ReadSet::default(),
                &[WriteOp::Delete {
                    namespace: "".into(),
                    table: "messages".into(),
                    doc_id: "m2".into(),
                }],
            )
            .await
            .unwrap();
        assert_eq!(c3.commit_ts, 3);

        let all_remaining = storage
            .scan_index(&IndexQuery {
                namespace: "".into(),
                table: "messages".into(),
                index_name: BY_CREATION_TIME_INDEX.into(),
                start: KeyBound::Unbounded,
                end: KeyBound::Unbounded,
                order: QueryOrder::Asc,
                limit: None,
            })
            .await
            .unwrap();
        assert_eq!(all_remaining.len(), 2);
        assert_eq!(all_remaining[0].id, "m1");
        assert_eq!(all_remaining[1].id, "m3");
    }
}
