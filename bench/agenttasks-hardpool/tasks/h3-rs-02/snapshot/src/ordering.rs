use crate::data::Row;
use std::cmp::Ordering;

/// Missing values sort before present values in ascending order.
#[derive(Clone, Debug)]
pub struct SortKey {
    pub column: String,
    pub descending: bool,
}
impl SortKey {
    pub fn asc(column: &str) -> Self {
        Self { column: column.into(), descending: false }
    }
    pub fn desc(column: &str) -> Self {
        Self { column: column.into(), descending: true }
    }
}

pub fn compare(a: &Row, b: &Row, keys: &[SortKey]) -> Ordering {
    for key in keys {
        let order = a.get(&key.column).cmp(&b.get(&key.column));
        let order = if key.descending { order.reverse() } else { order };
        if order != Ordering::Equal { return order; }
    }
    Ordering::Equal
}

/// Stable sorting retains the incoming order for equal keys.
pub fn sort(rows: &mut [Row], keys: &[SortKey]) {
    rows.sort_by(|a, b| compare(a, b, keys));
}
