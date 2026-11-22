use serde::{Deserialize, Serialize};

/// Complete machine-readable IR emitted by `<app> --introspect`.
///
/// Drives:
/// - Storage schema & index synchronization
/// - Runtime component namespace enforcement
/// - Typed client codegen (`api.ts`, `dataModel.ts`)
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppManifest {
    pub app_name: String,
    #[serde(default)]
    pub tables: Vec<TableSpec>,
    #[serde(default)]
    pub components: Vec<ComponentSpec>,
    #[serde(default)]
    pub functions: Vec<FunctionSpec>,
}

impl AppManifest {
    /// Look up all table definitions across the root app namespace (`""`) and mounted components.
    pub fn all_tables(&self) -> Vec<(String, &TableSpec)> {
        let mut out = Vec::new();
        for t in &self.tables {
            out.push((String::new(), t));
        }
        for comp in &self.components {
            for t in &comp.tables {
                out.push((comp.namespace.clone(), t));
            }
        }
        out
    }

    /// Look up a specific table by `(namespace, table_name)`.
    pub fn find_table(&self, namespace: &str, table_name: &str) -> Option<&TableSpec> {
        if namespace.is_empty() {
            self.tables.iter().find(|t| t.name == table_name)
        } else {
            self.components
                .iter()
                .find(|c| c.namespace == namespace)
                .and_then(|c| c.tables.iter().find(|t| t.name == table_name))
        }
    }

    pub fn find_function(&self, name: &str) -> Option<&FunctionSpec> {
        self.functions.iter().find(|f| f.name == name)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ComponentSpec {
    pub namespace: String,
    pub package: String,
    #[serde(default)]
    pub tables: Vec<TableSpec>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TableSpec {
    pub name: String,
    pub document_schema: SchemaType,
    #[serde(default)]
    pub indexes: Vec<IndexSpec>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IndexSpec {
    pub name: String,
    /// Dot-separated JSON field paths extracted from each document to build the composite key.
    /// System fields `_id` and `_creationTime` are also supported.
    pub fields: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FunctionKind {
    Query,
    Mutation,
    Action,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FunctionSpec {
    /// Dotted wire name, e.g. `"messages.list"`, `"rooms.create"`, `"presence.heartbeat"`.
    pub name: String,
    pub kind: FunctionKind,
    /// Optional mounted component namespace that owns this endpoint (empty for root app).
    #[serde(default)]
    pub namespace: String,
    pub args_schema: SchemaType,
    pub returns_schema: SchemaType,
}

/// Language-agnostic structural schema IR used for validation and client codegen.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SchemaType {
    Null,
    Bool,
    Int,
    Float,
    Str,
    Id {
        table: String,
        #[serde(default)]
        namespace: String,
    },
    List {
        item: Box<SchemaType>,
    },
    Optional {
        inner: Box<SchemaType>,
    },
    Record {
        fields: Vec<FieldSpec>,
    },
    Union {
        variants: Vec<VariantSpec>,
    },
    Any,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FieldSpec {
    pub name: String,
    pub schema: SchemaType,
    #[serde(default)]
    pub optional: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VariantSpec {
    pub tag: String,
    #[serde(default)]
    pub payload: Option<SchemaType>,
}
