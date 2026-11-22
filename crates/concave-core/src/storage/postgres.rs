use async_trait::async_trait;
use serde_json::Value;
use sqlx::{PgPool, QueryBuilder, Row};

use crate::error::{CoreError, CoreResult};
use crate::manifest::AppManifest;
use crate::readset::{DocRef, KeyBound, ReadSet, WriteSet};
use crate::storage::{
    apply_patch, compute_index_entries, CommitEntry, CommitResult, Document, IndexQuery,
    QueryOrder, StorageBackend, WriteOp,
};

/// PostgreSQL implementation of `StorageBackend`.
///
/// Designed for standard PostgreSQL, serverless Postgres (Neon), and tenant-sharded
/// PlanetScale Postgres:
/// - Every table leads with `deployment_id` as the shard key so all tables and mounted
///   components for a deployment co-locate on a single shard with full ACID transactions.
/// - Uses an append-only `commit_log` table instead of `LISTEN/NOTIFY` so it works behind
///   transaction-mode connection poolers (PgBouncer/serverless proxies).
#[derive(Clone)]
pub struct PostgresStorage {
    pool: PgPool,
    deployment_id: String,
}

impl PostgresStorage {
    pub async fn connect(
        database_url: &str,
        deployment_id: impl Into<String>,
    ) -> CoreResult<Self> {
        let pool = PgPool::connect(database_url)
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;
        Ok(Self {
            pool,
            deployment_id: deployment_id.into(),
        })
    }

    pub fn from_pool(pool: PgPool, deployment_id: impl Into<String>) -> Self {
        Self {
            pool,
            deployment_id: deployment_id.into(),
        }
    }
}

#[async_trait]
impl StorageBackend for PostgresStorage {
    async fn init_schema(&self, manifest: &AppManifest) -> CoreResult<()> {
        let statements = [
            "CREATE TABLE IF NOT EXISTS documents (
                deployment_id TEXT NOT NULL,
                namespace TEXT NOT NULL,
                table_name TEXT NOT NULL,
                doc_id TEXT NOT NULL,
                creation_time_ms BIGINT NOT NULL,
                body_json JSONB NOT NULL,
                PRIMARY KEY (deployment_id, namespace, table_name, doc_id)
            )",
            "CREATE TABLE IF NOT EXISTS index_entries (
                deployment_id TEXT NOT NULL,
                namespace TEXT NOT NULL,
                table_name TEXT NOT NULL,
                index_name TEXT NOT NULL,
                encoded_key BYTEA NOT NULL,
                doc_id TEXT NOT NULL,
                PRIMARY KEY (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
            )",
            "CREATE INDEX IF NOT EXISTS idx_index_entries_doc
                ON index_entries (deployment_id, namespace, table_name, doc_id)",
            "CREATE TABLE IF NOT EXISTS commit_log (
                deployment_id TEXT NOT NULL,
                commit_ts BIGINT NOT NULL,
                writes_json JSONB NOT NULL,
                PRIMARY KEY (deployment_id, commit_ts)
            )",
        ];

        for stmt in statements {
            sqlx::query(stmt)
                .execute(&self.pool)
                .await
                .map_err(|e| CoreError::Storage(e.to_string()))?;
        }

        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;

        let rows = sqlx::query(
            "SELECT namespace, table_name, doc_id, creation_time_ms, body_json
             FROM documents WHERE deployment_id = $1",
        )
        .bind(&self.deployment_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?;

        sqlx::query("DELETE FROM index_entries WHERE deployment_id = $1")
            .bind(&self.deployment_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;

        for row in rows {
            let ns: String = row.get("namespace");
            let tbl: String = row.get("table_name");
            let doc_id: String = row.get("doc_id");
            let creation_time_ms: i64 = row.get("creation_time_ms");
            let body: Value = row.get("body_json");
            let doc = Document {
                id: doc_id.clone(),
                creation_time_ms,
                body,
            };
            for (index_name, encoded_key) in compute_index_entries(manifest, &ns, &tbl, &doc)? {
                sqlx::query(
                    "INSERT INTO index_entries
                     (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                     VALUES ($1, $2, $3, $4, $5, $6)",
                )
                .bind(&self.deployment_id)
                .bind(&ns)
                .bind(&tbl)
                .bind(&index_name)
                .bind(&encoded_key)
                .bind(&doc_id)
                .execute(&mut *tx)
                .await
                .map_err(|e| CoreError::Storage(e.to_string()))?;
            }
        }

        tx.commit()
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;
        Ok(())
    }

    async fn latest_commit_ts(&self) -> CoreResult<i64> {
        let row = sqlx::query(
            "SELECT COALESCE(MAX(commit_ts), 0) AS ts FROM commit_log WHERE deployment_id = $1",
        )
        .bind(&self.deployment_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?;
        Ok(row.get("ts"))
    }

    async fn get_doc(
        &self,
        namespace: &str,
        table: &str,
        doc_id: &str,
    ) -> CoreResult<Option<Document>> {
        let row = sqlx::query(
            "SELECT creation_time_ms, body_json
             FROM documents
             WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
        )
        .bind(&self.deployment_id)
        .bind(namespace)
        .bind(table)
        .bind(doc_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?;

        Ok(row.map(|r| Document {
            id: doc_id.to_string(),
            creation_time_ms: r.get("creation_time_ms"),
            body: r.get("body_json"),
        }))
    }

    async fn scan_index(&self, query: &IndexQuery) -> CoreResult<Vec<Document>> {
        let mut qb = QueryBuilder::new(
            "SELECT d.doc_id, d.creation_time_ms, d.body_json
             FROM index_entries ie
             INNER JOIN documents d
               ON d.deployment_id = ie.deployment_id
              AND d.namespace = ie.namespace
              AND d.table_name = ie.table_name
              AND d.doc_id = ie.doc_id
             WHERE ie.deployment_id = ",
        );
        qb.push_bind(&self.deployment_id);
        qb.push(" AND ie.namespace = ");
        qb.push_bind(&query.namespace);
        qb.push(" AND ie.table_name = ");
        qb.push_bind(&query.table);
        qb.push(" AND ie.index_name = ");
        qb.push_bind(&query.index_name);

        match &query.start {
            KeyBound::Unbounded => {}
            KeyBound::Included(k) => {
                qb.push(" AND ie.encoded_key >= ");
                qb.push_bind(k);
            }
            KeyBound::Excluded(k) => {
                qb.push(" AND ie.encoded_key > ");
                qb.push_bind(k);
            }
        }
        match &query.end {
            KeyBound::Unbounded => {}
            KeyBound::Included(k) => {
                qb.push(" AND ie.encoded_key <= ");
                qb.push_bind(k);
            }
            KeyBound::Excluded(k) => {
                qb.push(" AND ie.encoded_key < ");
                qb.push_bind(k);
            }
        }

        match query.order {
            QueryOrder::Asc => qb.push(" ORDER BY ie.encoded_key ASC, ie.doc_id ASC"),
            QueryOrder::Desc => qb.push(" ORDER BY ie.encoded_key DESC, ie.doc_id DESC"),
        };

        if let Some(limit) = query.limit {
            qb.push(" LIMIT ");
            qb.push_bind(limit as i64);
        }

        let rows = qb
            .build()
            .fetch_all(&self.pool)
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;

        Ok(rows
            .into_iter()
            .map(|r| Document {
                id: r.get("doc_id"),
                creation_time_ms: r.get("creation_time_ms"),
                body: r.get("body_json"),
            })
            .collect())
    }

    async fn commit_tx(
        &self,
        manifest: &AppManifest,
        snapshot_ts: i64,
        read_set: &ReadSet,
        writes: &[WriteOp],
    ) -> CoreResult<CommitResult> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;

        // Serialize commits per deployment_id using a transaction-scoped advisory lock
        // (avoids cross-shard coordination while giving strict monotonic commit_ts).
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(&self.deployment_id)
            .execute(&mut *tx)
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;

        let latest_row = sqlx::query(
            "SELECT COALESCE(MAX(commit_ts), 0) AS ts FROM commit_log WHERE deployment_id = $1",
        )
        .bind(&self.deployment_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?;
        let latest_ts: i64 = latest_row.get("ts");

        if latest_ts > snapshot_ts {
            let rows = sqlx::query(
                "SELECT writes_json FROM commit_log
                 WHERE deployment_id = $1 AND commit_ts > $2
                 ORDER BY commit_ts ASC",
            )
            .bind(&self.deployment_id)
            .bind(snapshot_ts)
            .fetch_all(&mut *tx)
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;

            for row in rows {
                let ws_val: Value = row.get("writes_json");
                let committed_ws: WriteSet = serde_json::from_value(ws_val)
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
            tx.commit()
                .await
                .map_err(|e| CoreError::Storage(e.to_string()))?;
            return Ok(CommitResult {
                commit_ts: latest_ts,
                write_set: WriteSet::default(),
            });
        }

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
                    sqlx::query(
                        "INSERT INTO documents
                         (deployment_id, namespace, table_name, doc_id, creation_time_ms, body_json)
                         VALUES ($1, $2, $3, $4, $5, $6)",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .bind(*creation_time_ms)
                    .bind(body)
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    let doc = Document {
                        id: doc_id.clone(),
                        creation_time_ms: *creation_time_ms,
                        body: body.clone(),
                    };
                    write_set.record_doc(DocRef::new(namespace, table, doc_id));
                    for (index_name, encoded_key) in
                        compute_index_entries(manifest, namespace, table, &doc)?
                    {
                        sqlx::query(
                            "INSERT INTO index_entries
                             (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                             VALUES ($1, $2, $3, $4, $5, $6)",
                        )
                        .bind(&self.deployment_id)
                        .bind(namespace)
                        .bind(table)
                        .bind(&index_name)
                        .bind(&encoded_key)
                        .bind(doc_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(|e| CoreError::Storage(e.to_string()))?;
                        write_set.record_index_key(namespace, table, index_name, encoded_key);
                    }
                }
                WriteOp::Replace {
                    namespace,
                    table,
                    doc_id,
                    body,
                } => {
                    let existing = sqlx::query(
                        "SELECT creation_time_ms, body_json FROM documents
                         WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    let Some(row) = existing else {
                        return Err(CoreError::NotFound {
                            namespace: namespace.clone(),
                            table: table.clone(),
                            doc_id: doc_id.clone(),
                        });
                    };

                    let creation_time_ms: i64 = row.get("creation_time_ms");
                    let old_body: Value = row.get("body_json");
                    let old_doc = Document {
                        id: doc_id.clone(),
                        creation_time_ms,
                        body: old_body,
                    };
                    for (index_name, old_key) in
                        compute_index_entries(manifest, namespace, table, &old_doc)?
                    {
                        write_set.record_index_key(namespace, table, index_name, old_key);
                    }

                    sqlx::query(
                        "DELETE FROM index_entries
                         WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    sqlx::query(
                        "UPDATE documents SET body_json = $5
                         WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .bind(body)
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    let new_doc = Document {
                        id: doc_id.clone(),
                        creation_time_ms,
                        body: body.clone(),
                    };
                    write_set.record_doc(DocRef::new(namespace, table, doc_id));
                    for (index_name, new_key) in
                        compute_index_entries(manifest, namespace, table, &new_doc)?
                    {
                        sqlx::query(
                            "INSERT INTO index_entries
                             (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                             VALUES ($1, $2, $3, $4, $5, $6)",
                        )
                        .bind(&self.deployment_id)
                        .bind(namespace)
                        .bind(table)
                        .bind(&index_name)
                        .bind(&new_key)
                        .bind(doc_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(|e| CoreError::Storage(e.to_string()))?;
                        write_set.record_index_key(namespace, table, index_name, new_key);
                    }
                }
                WriteOp::Patch {
                    namespace,
                    table,
                    doc_id,
                    patch,
                } => {
                    let existing = sqlx::query(
                        "SELECT creation_time_ms, body_json FROM documents
                         WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    let Some(row) = existing else {
                        return Err(CoreError::NotFound {
                            namespace: namespace.clone(),
                            table: table.clone(),
                            doc_id: doc_id.clone(),
                        });
                    };

                    let creation_time_ms: i64 = row.get("creation_time_ms");
                    let old_body: Value = row.get("body_json");
                    let old_doc = Document {
                        id: doc_id.clone(),
                        creation_time_ms,
                        body: old_body.clone(),
                    };
                    for (index_name, old_key) in
                        compute_index_entries(manifest, namespace, table, &old_doc)?
                    {
                        write_set.record_index_key(namespace, table, index_name, old_key);
                    }

                    sqlx::query(
                        "DELETE FROM index_entries
                         WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    let merged = apply_patch(&old_body, patch);
                    sqlx::query(
                        "UPDATE documents SET body_json = $5
                         WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .bind(&merged)
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    let new_doc = Document {
                        id: doc_id.clone(),
                        creation_time_ms,
                        body: merged,
                    };
                    write_set.record_doc(DocRef::new(namespace, table, doc_id));
                    for (index_name, new_key) in
                        compute_index_entries(manifest, namespace, table, &new_doc)?
                    {
                        sqlx::query(
                            "INSERT INTO index_entries
                             (deployment_id, namespace, table_name, index_name, encoded_key, doc_id)
                             VALUES ($1, $2, $3, $4, $5, $6)",
                        )
                        .bind(&self.deployment_id)
                        .bind(namespace)
                        .bind(table)
                        .bind(&index_name)
                        .bind(&new_key)
                        .bind(doc_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(|e| CoreError::Storage(e.to_string()))?;
                        write_set.record_index_key(namespace, table, index_name, new_key);
                    }
                }
                WriteOp::Delete {
                    namespace,
                    table,
                    doc_id,
                } => {
                    let existing = sqlx::query(
                        "SELECT creation_time_ms, body_json FROM documents
                         WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                    )
                    .bind(&self.deployment_id)
                    .bind(namespace)
                    .bind(table)
                    .bind(doc_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(|e| CoreError::Storage(e.to_string()))?;

                    if let Some(row) = existing {
                        let creation_time_ms: i64 = row.get("creation_time_ms");
                        let old_body: Value = row.get("body_json");
                        let old_doc = Document {
                            id: doc_id.clone(),
                            creation_time_ms,
                            body: old_body,
                        };
                        for (index_name, old_key) in
                            compute_index_entries(manifest, namespace, table, &old_doc)?
                        {
                            write_set.record_index_key(namespace, table, index_name, old_key);
                        }

                        sqlx::query(
                            "DELETE FROM index_entries
                             WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                        )
                        .bind(&self.deployment_id)
                        .bind(namespace)
                        .bind(table)
                        .bind(doc_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(|e| CoreError::Storage(e.to_string()))?;

                        sqlx::query(
                            "DELETE FROM documents
                             WHERE deployment_id = $1 AND namespace = $2 AND table_name = $3 AND doc_id = $4",
                        )
                        .bind(&self.deployment_id)
                        .bind(namespace)
                        .bind(table)
                        .bind(doc_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(|e| CoreError::Storage(e.to_string()))?;

                        write_set.record_doc(DocRef::new(namespace, table, doc_id));
                    }
                }
            }
        }

        let next_ts = latest_ts + 1;
        let writes_val = serde_json::to_value(&write_set)
            .map_err(|e| CoreError::Serialization(e.to_string()))?;
        sqlx::query(
            "INSERT INTO commit_log (deployment_id, commit_ts, writes_json)
             VALUES ($1, $2, $3)",
        )
        .bind(&self.deployment_id)
        .bind(next_ts)
        .bind(writes_val)
        .execute(&mut *tx)
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?;

        tx.commit()
            .await
            .map_err(|e| CoreError::Storage(e.to_string()))?;

        Ok(CommitResult {
            commit_ts: next_ts,
            write_set,
        })
    }

    async fn commits_since(&self, since_ts: i64) -> CoreResult<Vec<CommitEntry>> {
        let rows = sqlx::query(
            "SELECT commit_ts, writes_json FROM commit_log
             WHERE deployment_id = $1 AND commit_ts > $2
             ORDER BY commit_ts ASC",
        )
        .bind(&self.deployment_id)
        .bind(since_ts)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| CoreError::Storage(e.to_string()))?;

        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let commit_ts: i64 = row.get("commit_ts");
            let val: Value = row.get("writes_json");
            let write_set: WriteSet = serde_json::from_value(val)
                .map_err(|e| CoreError::Serialization(e.to_string()))?;
            out.push(CommitEntry {
                commit_ts,
                write_set,
            });
        }
        Ok(out)
    }
}
