# Case 242 determinism control

**DONE: pre-existing nondeterminism reproduced. Stopped after step 1 as requested. Recommendation: keep the uncommitted candidate; promotion remains unevaluated.**

Two fresh upstream processes and two fresh fork processes ran the sampled / auto / B=3 / mixed case with the original seeds 100/101/102, temperature 1.0, top-p 0.95, top-k 20, thinking disabled, and 160 tokens per sequence. Every process completed normally with `enginebench: ALL PASS`.

| Sequence | First difference (zero-based) | Upstream 1 → 2 | Fork 1 → 2 |
|---:|---:|---:|---:|
| 0 | 23 | 17782 → 32 | 32 → 17782 |
| 1 | 14 | 26 → 314 | 314 → 26 |
| 2 | 36 | 271 → 198 | 198 → 271 |

The upstream self-comparison reproduces the original upstream-vs-fork divergence exactly, including **all three complete token arrays**, not merely their first differences. Both builds produced the same two variants:

| Comparison | Identical token positions | Complete sequences identical |
|---|---:|---:|
| upstream 1 vs upstream 2 | 85/480 | 0/3 |
| fork 1 vs fork 2 | 85/480 | 0/3 |
| upstream 1 vs fork 2 | 480/480 | 3/3 |
| upstream 2 vs fork 1 | 480/480 | 3/3 |
| original upstream vs upstream 1 | 480/480 | 3/3 |
| original fork vs fork 1 | 480/480 | 3/3 |

Classification: **bit-identical except nondeterminism**, scoped to these observed variants and the prior integration measurements. The prior 288 full-vocab rows / 71,516,160 float32 values had zero different bits and max absolute difference 0. No new logit metrics, KL, or B=1-vs-B=3 reference metrics were collected: the upstream self-consistency prerequisite for step 2 failed. This does not establish bitwise equality of every unmeasured tensor, identify the internal source of nondeterminism, or measure the frequency of either variant.

The existing, unchanged release `S4IntegrationBench` binaries were used. Existing environment filters select the exact case settings with one measured round per fresh process; each process also runs the harness's three solo references and one warmup. The complete preceding matrix was not replayed. The unchanged harness resets prefix cache before each generation and closes all sessions afterward. SHA-256 provenance, commands, helper sources, full logs, tokens, and comparisons are retained in `raw/`, `control.json`, and `result.json`.

## Performance table

| Workload | Upstream | Fork | Change | Status |
|---|---:|---:|---:|---|
| decode c=1 | — | — | — | NOT RUN |
| decode c=4 | — | — | — | NOT RUN |
| decode c=8 | — | — | — | NOT RUN |
| verify width=3 | — | — | — | NOT RUN |
| verify width=5 | — | — | — | NOT RUN |
| verify width=8 | — | — | — | NOT RUN |
| prefill 4096 | — | — | — | NOT RUN |
| prefill 16384 | — | — | — | NOT RUN |

Zero ABBA cycles; c=8 >= +2% and c=1 noise gates not evaluated. Remaining CLI parity cases were not run because the explicit step-1 stop condition was met. Earlier performance results are not substituted.

## Quality gate table

| Planned gate | Tasks run | Both pass | Only upstream | Only fork | Both fail | Verdict |
|---|---:|---:|---:|---:|---:|---|
| Paired arm H, default knobs, thinking off, same 21 verified tasks | 0/21 | — | — | — | — | NOT RUN |

Conditional rule supplied by the task: only-upstream <= only-fork and no more than one pass-to-fail task drop. It was not evaluated. `../quality/result.json` records the explicit stop reason; no agentbench processes or task workspaces were started.

All GPU processes held `/tmp/strim-bench.lock` through `lockf -k`; the lock was retained. All four processes exited normally. No servers, ports, GUI sessions, or logins were used. Models were read-only; state remained in memory. Helpers and scratch directories are under `/tmp/s4/divergence`. No dependency/source edits, commits, or unowned process termination occurred.
