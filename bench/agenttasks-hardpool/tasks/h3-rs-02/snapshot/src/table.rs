use crate::data::Row;

/// A named snapshot. Cloning a table copies its rows, keeping execution isolated.
#[derive(Clone, Debug)]
pub struct Table {
    pub name: String,
    pub rows: Vec<Row>,
}

impl Table {
    pub fn new(name: impl Into<String>, rows: Vec<Row>) -> Self {
        Self { name: name.into(), rows }
    }

    pub fn len(&self) -> usize { self.rows.len() }
    pub fn is_empty(&self) -> bool { self.rows.is_empty() }

    /// Return a fresh table without changing the original snapshot.
    pub fn select(&self, predicate: &crate::expr::Expr) -> Self {
        Self::new(&self.name, self.rows.iter().filter(|r| predicate.matches(r)).cloned().collect())
    }
}
