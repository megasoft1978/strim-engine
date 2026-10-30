//! A compact relational engine for small in-memory datasets.
pub mod data;
pub mod expr;
pub mod table;
pub mod join;
pub mod ordering;
pub mod plan;
pub mod optimizer;
pub mod execute;
pub mod stats;

pub use data::{Row, Value};
pub use expr::Expr;
pub use table::Table;
pub use ordering::SortKey;
pub use plan::Plan;
pub use execute::execute;
pub mod describe;
pub mod render;
