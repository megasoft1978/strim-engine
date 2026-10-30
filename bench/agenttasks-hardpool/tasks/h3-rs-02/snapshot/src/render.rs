use crate::{Row, Value};

/// Render selected columns as a tab-separated diagnostic report. Missing fields
/// are empty; tabs and newlines in text are escaped to keep each row on one line.
pub fn tabular(rows: &[Row], columns: &[&str]) -> String {
    let mut lines = Vec::with_capacity(rows.len() + 1);
    lines.push(columns.iter().map(|s| escape(s)).collect::<Vec<_>>().join("\t"));
    for row in rows {
        let cells: Vec<String> = columns.iter().map(|name| {
            match row.get(*name) {
                Some(Value::Int(value)) => value.to_string(),
                Some(Value::Text(value)) => escape(value),
                None => String::new(),
            }
        }).collect();
        lines.push(cells.join("\t"));
    }
    lines.join("\n")
}

fn escape(text: &str) -> String {
    let mut out = String::new();
    for ch in text.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            other => out.push(other),
        }
    }
    out
}
