use crate::{Expr, SortKey, Table};

/// A tree of relational operators. Operators run from leaves toward the root.
#[derive(Clone, Debug)]
pub enum Plan {
    Scan(Table),
    Filter { input: Box<Plan>, predicate: Expr },
    Join { left: Box<Plan>, right: Box<Plan>, left_key: String, right_key: String },
    Order { input: Box<Plan>, keys: Vec<SortKey> },
    Window { input: Box<Plan>, offset: usize, limit: Option<usize> },
}

impl Plan {
    pub fn scan(table: Table) -> Self { Self::Scan(table) }
    pub fn filter(self, predicate: Expr) -> Self {
        Self::Filter { input: Box::new(self), predicate }
    }
    pub fn join(self, other: Plan, left_key: &str, right_key: &str) -> Self {
        Self::Join { left: Box::new(self), right: Box::new(other),
            left_key: left_key.into(), right_key: right_key.into() }
    }
    pub fn order(self, keys: Vec<SortKey>) -> Self {
        Self::Order { input: Box::new(self), keys }
    }
    pub fn window(self, offset: usize, limit: Option<usize>) -> Self {
        Self::Window { input: Box::new(self), offset, limit }
    }
}
