# evolve run 2 (2026-10-30), 13-task React/Node/TS pool

Round 1, coordinate `thinking` only, then stopped by hand (remaining coordinates temperature,
result_cap, compaction_threshold had no supporting evidence; see bench/results/harness-failures-20261030).

| candidate | train pass (9) | val pass (4) |
|---|---|---|
| baseline 010498d957b46c4f | 44% | 75% |
| thinking=first_planning_turn | 44% | - |
| thinking=all_turns_medium 45e18dfdad89bb8c | 89% | 100% |

Decision: ADOPT all_turns_medium (val +25 pp, per rep +50/+0, false-done 0%). Test split untouched.
Cost: ~3x wall per task (align-thinking-20261029). Local token counts here are 0 for limit/failed jobs
(fixed later in a8c2b9d; this run used the older binary).

Run stopped during the round-1 temperature step (candidate 2533bfa0c5e449bd = all_turns_medium + warm, 1 partial train rows; not a decision).
