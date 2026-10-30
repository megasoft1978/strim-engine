# Cart promotions

An offline promotion evaluator. Amounts are integer cents. Rules have stable IDs,
priority, optional exclusive groups, a minimum cart subtotal, and either fixed
or percentage discounts. Higher priorities run first, then ID order. At most one
rule in a group may apply; ungrouped rules stack. Discounts cannot exceed the
remaining subtotal. Quote previews; redeem records a use in the shared store.
Run `./scripts/javatest.sh` with a JDK.
