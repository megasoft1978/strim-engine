use std::collections::BTreeMap;

/// A scalar with a deterministic order across types.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Value {
    Int(i64),
    Text(String),
}

impl From<i64> for Value {
    fn from(value: i64) -> Self { Self::Int(value) }
}
impl From<&str> for Value {
    fn from(value: &str) -> Self { Self::Text(value.to_owned()) }
}

/// Qualified names are used for joined tables.
pub type Row = BTreeMap<String, Value>;

/// Construct a row from named values. Later entries replace earlier ones.
pub fn row(fields: &[(&str, Value)]) -> Row {
    fields.iter().map(|(k, v)| ((*k).to_owned(), v.clone())).collect()
}

/// Merge non-overlapping schemas. Right-hand values win for duplicate names.
pub fn merge(left: &Row, right: &Row) -> Row {
    let mut result = left.clone();
    result.extend(right.clone());
    result
}
