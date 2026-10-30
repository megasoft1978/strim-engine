# Tablecraft

Tablecraft runs small, immutable relational plans over in-memory tables. Column
names are qualified by the caller to avoid ambiguity in joined rows. Values are
integers or strings, with a deterministic total order. Filters and joins preserve
input order; ordering is stable, so ties retain their input order.

A window selects rows after the operations below it in the plan. Its offset is
applied before its optional limit. An absent limit means all remaining rows;
a zero limit returns no rows. Plans are immutable values and can be executed
multiple times. The optimizer may rearrange operations only when their observable
rows and ordering remain unchanged.

Run `cargo test --offline --quiet` with the local Rust toolchain.
