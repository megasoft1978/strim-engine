use std::collections::BTreeSet;
use crate::{Row, Value};

/// Summary information for diagnostics, not used to change query results.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ColumnStats {
    pub present: usize,
    pub distinct: usize,
    pub min: Option<Value>,
    pub max: Option<Value>,
}

pub fn column(rows: &[Row], name: &str) -> ColumnStats {
    let values: Vec<Value> = rows.iter().filter_map(|r| r.get(name).cloned()).collect();
    let distinct: BTreeSet<_> = values.iter().cloned().collect();
    ColumnStats {
        present: values.len(),
        distinct: distinct.len(),
        min: distinct.first().cloned(),
        max: distinct.last().cloned(),
    }
}
