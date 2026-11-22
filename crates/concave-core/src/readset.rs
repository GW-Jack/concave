use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

/// Fully qualified table identifier scoped by component namespace (`""` for root app).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct TableRef {
    pub namespace: String,
    pub table: String,
}

impl TableRef {
    pub fn new(namespace: impl Into<String>, table: impl Into<String>) -> Self {
        Self {
            namespace: namespace.into(),
            table: table.into(),
        }
    }

    pub fn root(table: impl Into<String>) -> Self {
        Self::new("", table)
    }
}

/// Fully qualified document identifier scoped by component namespace and table.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct DocRef {
    pub namespace: String,
    pub table: String,
    pub doc_id: String,
}

impl DocRef {
    pub fn new(
        namespace: impl Into<String>,
        table: impl Into<String>,
        doc_id: impl Into<String>,
    ) -> Self {
        Self {
            namespace: namespace.into(),
            table: table.into(),
            doc_id: doc_id.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "bound", content = "key", rename_all = "snake_case")]
pub enum KeyBound {
    Unbounded,
    Included(Vec<u8>),
    Excluded(Vec<u8>),
}

/// Contiguous byte-range scanned over an index during a query or mutation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexRangeRead {
    pub namespace: String,
    pub table: String,
    pub index_name: String,
    pub start: KeyBound,
    pub end: KeyBound,
}

impl IndexRangeRead {
    /// Returns `true` if `key` lies within `[start, end]`.
    pub fn contains_key(&self, key: &[u8]) -> bool {
        let above_start = match &self.start {
            KeyBound::Unbounded => true,
            KeyBound::Included(lo) => key >= lo.as_slice(),
            KeyBound::Excluded(lo) => key > lo.as_slice(),
        };
        if !above_start {
            return false;
        }
        match &self.end {
            KeyBound::Unbounded => true,
            KeyBound::Included(hi) => key <= hi.as_slice(),
            KeyBound::Excluded(hi) => key < hi.as_slice(),
        }
    }
}

/// Exact set of point document reads and index-range scans observed during execution.
///
/// Powers both:
/// 1. Surgical reactive query invalidation
/// 2. Serializable Optimistic Concurrency Control (OCC) for mutations
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadSet {
    pub doc_reads: BTreeSet<DocRef>,
    pub index_ranges: Vec<IndexRangeRead>,
}

impl ReadSet {
    pub fn record_doc_read(&mut self, doc_ref: DocRef) {
        self.doc_reads.insert(doc_ref);
    }

    pub fn record_index_range(&mut self, range: IndexRangeRead) {
        self.index_ranges.push(range);
    }

    pub fn merge(&mut self, other: ReadSet) {
        self.doc_reads.extend(other.doc_reads);
        self.index_ranges.extend(other.index_ranges);
    }

    /// Returns `true` iff any write in `writes` invalidates a point lookup or index range
    /// recorded in this `ReadSet`.
    pub fn intersects(&self, writes: &WriteSet) -> bool {
        for doc in &writes.docs {
            if self.doc_reads.contains(doc) {
                return true;
            }
        }
        for written_key in &writes.index_keys {
            for range in &self.index_ranges {
                if range.namespace == written_key.namespace
                    && range.table == written_key.table
                    && range.index_name == written_key.index_name
                    && range.contains_key(&written_key.encoded_key)
                {
                    return true;
                }
            }
        }
        false
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct WrittenIndexKey {
    pub namespace: String,
    pub table: String,
    pub index_name: String,
    pub encoded_key: Vec<u8>,
}

/// Exact set of documents and index keys (both pre-image and post-image) mutated by a commit.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WriteSet {
    pub docs: BTreeSet<DocRef>,
    pub index_keys: BTreeSet<WrittenIndexKey>,
}

impl WriteSet {
    pub fn record_doc(&mut self, doc_ref: DocRef) {
        self.docs.insert(doc_ref);
    }

    pub fn record_index_key(
        &mut self,
        namespace: impl Into<String>,
        table: impl Into<String>,
        index_name: impl Into<String>,
        encoded_key: Vec<u8>,
    ) {
        self.index_keys.insert(WrittenIndexKey {
            namespace: namespace.into(),
            table: table.into(),
            index_name: index_name.into(),
            encoded_key,
        });
    }

    pub fn is_empty(&self) -> bool {
        self.docs.is_empty() && self.index_keys.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::key::{encode_key, encode_prefix_upper_bound, IndexValue};

    #[test]
    fn index_range_isolates_rooms_and_namespaces() {
        let mut read_room_a = ReadSet::default();
        read_room_a.record_index_range(IndexRangeRead {
            namespace: "".into(),
            table: "messages".into(),
            index_name: "by_room".into(),
            start: KeyBound::Included(encode_key(&[IndexValue::Str("room-a".into())]).unwrap()),
            end: KeyBound::Excluded(
                encode_prefix_upper_bound(&[IndexValue::Str("room-a".into())]).unwrap(),
            ),
        });

        let mut write_room_b = WriteSet::default();
        write_room_b.record_doc(DocRef::new("", "messages", "msg-2"));
        write_room_b.record_index_key(
            "",
            "messages",
            "by_room",
            encode_key(&[IndexValue::Str("room-b".into()), IndexValue::Int(100)]).unwrap(),
        );
        assert!(
            !read_room_a.intersects(&write_room_b),
            "write in room-b must not invalidate room-a subscriber"
        );

        let mut write_other_namespace = WriteSet::default();
        write_other_namespace.record_index_key(
            "presence",
            "messages",
            "by_room",
            encode_key(&[IndexValue::Str("room-a".into()), IndexValue::Int(100)]).unwrap(),
        );
        assert!(
            !read_room_a.intersects(&write_other_namespace),
            "write in another component namespace must not invalidate root table"
        );

        let mut write_room_a = WriteSet::default();
        write_room_a.record_index_key(
            "",
            "messages",
            "by_room",
            encode_key(&[IndexValue::Str("room-a".into()), IndexValue::Int(101)]).unwrap(),
        );
        assert!(read_room_a.intersects(&write_room_a));
    }

    #[test]
    fn point_read_matches_only_exact_doc() {
        let mut read = ReadSet::default();
        read.record_doc_read(DocRef::new("presence", "sessions", "s1"));

        let mut other = WriteSet::default();
        other.record_doc(DocRef::new("presence", "sessions", "s2"));
        assert!(!read.intersects(&other));

        let mut same = WriteSet::default();
        same.record_doc(DocRef::new("presence", "sessions", "s1"));
        assert!(read.intersects(&same));
    }
}
