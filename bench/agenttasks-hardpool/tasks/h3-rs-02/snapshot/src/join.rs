use crate::data::{merge, Row};

/// Inner equijoin. Walk the left rows first and the right rows in their original
/// order. Missing keys do not join; duplicate keys produce every matching pair.
pub fn inner(left: &[Row], right: &[Row], left_key: &str, right_key: &str) -> Vec<Row> {
    let mut output = Vec::new();
    for l in left {
        if let Some(value) = l.get(left_key) {
            for r in right {
                if r.get(right_key) == Some(value) {
                    output.push(merge(l, r));
                }
            }
        }
    }
    output
}
