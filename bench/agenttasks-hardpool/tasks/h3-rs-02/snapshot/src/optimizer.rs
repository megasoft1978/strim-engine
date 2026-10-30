use crate::Plan;

/// Build an equivalent plan for execution. Child plans are optimized first.
pub fn optimize(plan: Plan) -> Plan {
    match plan {
        Plan::Scan(_) => plan,
        Plan::Filter { input, predicate } => Plan::Filter {
            input: Box::new(optimize(*input)), predicate,
        },
        Plan::Join { left, right, left_key, right_key } => Plan::Join {
            left: Box::new(optimize(*left)), right: Box::new(optimize(*right)),
            left_key, right_key,
        },
        Plan::Order { input, keys } => Plan::Order {
            input: Box::new(optimize(*input)), keys,
        },
        Plan::Window { input, offset, limit } => {
            let input = optimize(*input);
            // Move the row budget closer to the source to reduce join work.
            match input {
                Plan::Join { left, right, left_key, right_key } => Plan::Join {
                    left: Box::new(Plan::Window { input: left, offset, limit }),
                    right, left_key, right_key,
                },
                input => Plan::Window { input: Box::new(input), offset, limit },
            }
        }
    }
}
