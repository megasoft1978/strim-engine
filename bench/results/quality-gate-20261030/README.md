# Quality gate: thinking on every turn vs. shipped default, 2026-10-30

Full 51-task corpus (bench/agenttasks, 9 languages), 1 rep per arm, same seed per pair, M5 Max 64 GB, Qwen3.8-27B 4-bit + MTP head.

| | pass | median wall | total wall | mean local tokens | false-done |
|---|---:|---:|---:|---:|---:|
| A `010498d957b46c4f` baseline (thinking off) | 45/51 (88.2%) | 29 s | 2631 s | 103.6k | 0 |
| B `45e18dfdad89bb8c` thinking all turns, medium | 46/51 (90.2%) | 72 s | 7760 s | 80.8k | 0 |

Discordant pairs: only B rx-01, tf-19; only A tf-04. Both fail rb-03, tf-02, tf-03, tf-05.

Decision: not adopted as the shipped default. +1 task (2 vs 1 discordant pairs) is within noise and B costs about 3x the wall time. The hard-pool result (bench/results/release-eval-20261030: 4/4 vs 3/4) does not carry over to the full corpus. The parked default change is kept as artifacts/shipped-thinking-default.patch (not committed).

failure-analysis.md: why the remaining failures happen (the agent reruns the failing suite without reading or editing the source). Follow-up: the opt-in progress_gate / test_status / thinking on_stall knobs (commit 5290196f), to be paired against this baseline.
