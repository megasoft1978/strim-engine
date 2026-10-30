# Conditional task-quality gate

NOT RUN: the step-1 control reproduced the complete original divergence within the unchanged upstream build. The fork produced exactly the same two complete output variants. The task explicitly requires stopping at that result.

| Arm | Planned tasks | Executed | Both pass | Only upstream | Only fork | Both fail |
|---|---:|---:|---:|---:|---:|---:|
| H, default knobs, thinking off | 21 | 0 | — | — | — | — |

Gate: only-upstream <= only-fork and pass-to-fail drops <= 1. **NOT EVALUATED**, with no inferred pass or fail. See `../divergence/REPORT.md` and `result.json`.
