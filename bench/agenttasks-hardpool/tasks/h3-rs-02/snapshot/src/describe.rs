use crate::Plan;

/// Render a plan as an indented operator tree for diagnostic output.
/// This deliberately does not optimize the input plan.
pub fn explain(plan: &Plan) -> String {
    let mut lines = Vec::new();
    visit(plan, 0, &mut lines);
    lines.join("\n")
}

fn visit(plan: &Plan, depth: usize, lines: &mut Vec<String>) {
    let indent = "  ".repeat(depth);
    match plan {
        Plan::Scan(table) => {
            lines.push(format!("{indent}scan {} ({} rows)", table.name, table.len()));
        }
        Plan::Filter { input, predicate } => {
            lines.push(format!("{indent}filter {predicate:?}"));
            visit(input, depth + 1, lines);
        }
        Plan::Join { left, right, left_key, right_key } => {
            lines.push(format!("{indent}join {left_key} = {right_key}"));
            visit(left, depth + 1, lines);
            visit(right, depth + 1, lines);
        }
        Plan::Order { input, keys } => {
            lines.push(format!("{indent}order {keys:?}"));
            visit(input, depth + 1, lines);
        }
        Plan::Window { input, offset, limit } => {
            lines.push(format!("{indent}window offset={offset} limit={limit:?}"));
            visit(input, depth + 1, lines);
        }
    }
}
