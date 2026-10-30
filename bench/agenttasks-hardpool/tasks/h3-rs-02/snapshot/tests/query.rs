use tablecraft::{data::row, execute, Expr, Plan, SortKey, Table, Value};
use tablecraft::{execute::evaluate, optimizer::optimize};

fn people() -> Plan {
    Plan::scan(Table::new("people", vec![
        row(&[("p.id", 1.into()), ("p.group", "b".into())]),
        row(&[("p.id", 2.into()), ("p.group", "a".into())]),
        row(&[("p.id", 3.into()), ("p.group", "a".into())]),
        row(&[("p.id", 4.into()), ("p.group", "b".into())]),
        row(&[("p.id", 5.into()), ("p.group", "a".into())]),
    ]))
}
fn orders() -> Plan {
    Plan::scan(Table::new("orders", vec![
        row(&[("o.person", 2.into()), ("o.id", 20.into())]),
        row(&[("o.person", 2.into()), ("o.id", 21.into())]),
        row(&[("o.person", 4.into()), ("o.id", 40.into())]),
        row(&[("o.person", 5.into()), ("o.id", 50.into())]),
        row(&[("o.person", 5.into()), ("o.id", 51.into())]),
    ]))
}
fn ids(rows: &[tablecraft::Row], key: &str) -> Vec<i64> {
    rows.iter().map(|row| match &row[key] { Value::Int(n) => *n, _ => panic!("expected integer") }).collect()
}

#[test]
fn ordered_pages_keep_ties_in_input_order() {
    let ordered = people().order(vec![SortKey::asc("p.group")]);
    assert_eq!(ids(&execute(&ordered.clone().window(1, Some(3))), "p.id"), vec![3, 5, 1]);
    assert_eq!(ids(&execute(&ordered.window(3, None)), "p.id"), vec![1, 4]);
}

#[test]
fn selection_precedes_page_and_multiple_keys_work() {
    let plan = people().filter(Expr::Eq("p.group".into(), "a".into()))
        .order(vec![SortKey::asc("p.group"), SortKey::desc("p.id")])
        .window(1, Some(1));
    assert_eq!(ids(&execute(&plan), "p.id"), vec![3]);
}

#[test]
fn joined_rows_are_paginated_after_matching() {
    let joined = people().join(orders(), "p.id", "o.person");
    assert_eq!(ids(&execute(&joined.clone().window(1, Some(3))), "o.id"), vec![21, 40, 50]);
    assert_eq!(ids(&evaluate(&joined.clone().window(1, Some(3))), "o.id"), vec![21, 40, 50]);
    assert_eq!(execute(&joined.clone().window(1, Some(3))), evaluate(&optimize(joined.window(1, Some(3)))));
}

#[test]
fn a_window_inside_join_is_applied_to_that_input() {
    let plan = people().window(1, Some(2)).join(orders(), "p.id", "o.person");
    assert_eq!(ids(&execute(&plan), "o.id"), vec![20, 21]);
}

#[test]
fn nested_windows_apply_in_sequence() {
    let plan = people().window(1, Some(3)).window(1, Some(1));
    assert_eq!(ids(&execute(&plan), "p.id"), vec![3]);
}

#[test]
fn empty_and_extreme_pages_do_not_overflow() {
    for plan in [people().window(0, Some(0)), people().window(99, None),
                 people().window(usize::MAX, Some(usize::MAX))] {
        assert!(execute(&plan).is_empty());
    }
    assert_eq!(ids(&execute(&people().window(2, Some(usize::MAX))), "p.id"), vec![3, 4, 5]);
}

#[test]
fn ordinary_queries_and_stats_remain_available() {
    let p = people();
    let rows = execute(&p.clone().filter(Expr::Greater("p.id".into(), 3.into())));
    assert_eq!(ids(&rows, "p.id"), vec![4, 5]);
    let stats = tablecraft::stats::column(&execute(&p), "p.group");
    assert_eq!((stats.present, stats.distinct), (5, 2));
    assert!(tablecraft::describe::explain(&p).contains("scan people"));
}

#[test]
fn report_escapes_text_and_handles_missing_columns() {
    let rows = vec![row(&[("name", "a\tb".into()), ("id", 7.into())])];
    assert_eq!(tablecraft::render::tabular(&rows, &["id", "name", "missing"]), "id\tname\tmissing\n7\ta\\tb\t");
}
