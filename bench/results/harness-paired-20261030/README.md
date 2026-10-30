# Paired harness test, 2026-10-30

Same seed per run for both arms, ABBA order, 13-task React/Node/TS pool (split.json), 2 train reps + 2 val reps, one machine (M5 Max 64 GB), Qwen3.8-27B 4-bit + MTP head.

- A `45e18dfdad89bb8c`: `thinking=all_turns_medium` (adopted by evolve run 2)
- B `18f91c5411914986`: A + `tool_guidance=strict`, `playbook_test_fix=converge`, `stall_nudge=on`, `result_shape=errors_first`

| | A train | B train | A val | B val |
|---|---:|---:|---:|---:|
| pass | 14/18 (77.8%) | 16/18 (88.9%) | 4/4 (100%) | 3/4 (75%) |
| mean wall (s) | 369 | 388 | 306 | 499 |
| mean local tokens | 129.6k | 167.8k | 157.4k | 191.6k |
| false-done | 0 | 0 | 0 | 0 |

Pairs over all 22 task-reps: both pass 16, only B 3 (hd-js-02, hd-ts-02, hd2-rx-02), only A 2 (hd2-rx-01, hd2-js-01 val), neither 1.

Decision: B is not adopted. +11 pp on train is 3 vs 2 discordant pairs (not significant), it loses one val pair, and costs +29% tokens and more wall time. A (thinking on every turn) stays the candidate for the app default, pending the frozen test-split release evaluation. B's options stay opt-in; worth retesting one at a time (the converge playbook is the likely contributor to the 3 B-only wins).

Files: `ledger.jsonl` (44 rows), `paired.json`, `config.json`, `split.json`, `report.txt` (`strim evolve report`).
