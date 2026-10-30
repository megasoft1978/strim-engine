use crate::{join, optimizer, ordering, Plan, Row};

/// Optimize and execute a plan, producing independent output rows.
pub fn execute(plan: &Plan) -> Vec<Row> {
    evaluate(&optimizer::optimize(plan.clone()))
}

/// Interpret a plan exactly as written, without optimization.
pub fn evaluate(plan: &Plan) -> Vec<Row> {
    match plan {
        Plan::Scan(table) => table.rows.clone(),
        Plan::Filter { input, predicate } => evaluate(input).into_iter()
            .filter(|row| predicate.matches(row)).collect(),
        Plan::Join { left, right, left_key, right_key } => {
            join::inner(&evaluate(left), &evaluate(right), left_key, right_key)
        }
        Plan::Order { input, keys } => {
            let mut rows = evaluate(input);
            ordering::sort(&mut rows, keys);
            rows
        }
        Plan::Window { input, .. } => evaluate(input),
    }
}
