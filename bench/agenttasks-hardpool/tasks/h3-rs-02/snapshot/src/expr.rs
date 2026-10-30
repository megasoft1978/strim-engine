use crate::data::{Row, Value};

/// Predicates only match present columns; missing columns are not equal to null.
#[derive(Clone, Debug)]
pub enum Expr {
    Eq(String, Value),
    Greater(String, Value),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Not(Box<Expr>),
}

impl Expr {
    pub fn matches(&self, row: &Row) -> bool {
        match self {
            Self::Eq(key, expected) => row.get(key) == Some(expected),
            Self::Greater(key, expected) => row.get(key).map_or(false, |v| v > expected),
            Self::And(a, b) => a.matches(row) && b.matches(row),
            Self::Or(a, b) => a.matches(row) || b.matches(row),
            Self::Not(a) => !a.matches(row),
        }
    }
}
