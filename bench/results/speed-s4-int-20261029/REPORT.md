# S4 remote-fork integration (2026-10-29; finalized 2026-10-30)

**KEEP — the requested parity and performance gates pass.** Two complete ABBA cycles compare the existing fresh upstream 0.32.3 build against remote fork `megasoft1978/mlx-swift` `0.32.3-strim.1` (qmv_wide tile cap 8). Decode c=8 aggregate changes **+10.28%**; c=1 changes **-0.01%**, against measured same-arm noise **0.34%**. No commit was made. This finishing slice did not change `Package.swift`, `Package.resolved`, or `docs/SWIFT-PERF.md`; their existing uncommitted edits remain for owner review.

The final machine-readable parity results, complete ABBA samples, block medians, per-cycle effects, output hashes, and peak MLX bytes are in [final-result.json](raw/fin/final-result.json). Commands and initial input/binary SHA-256 hashes are retained in [raw/fin](raw/fin/). The original [result.json](result.json) and `raw/gates.json` describe the historical stopped run and are superseded by this final report for the requested finishing gates.

## Parity results

| Gate | Result |
|---|---|
| Fork resolution / nested patch provenance | Prior PASS; existing binaries reused unchanged |
| Fresh release builds, upstream and fork | Prior PASS |
| gen 16 | Prior PASS, identical token IDs |
| depth-0 benchspec | Prior PASS, EXACT and identical verdict |
| checkprefix 4096 / 8192 + MTP | Prior PASS, identical hashes/tokens/margins/verdicts |
| Batched decode logits/hashes, c=1/4/6/7/8 | Prior PASS, 208 full-vocab rows and 1,664 choices |
| Verify logits/hashes, widths 3/5/8 | Prior PASS; fresh finishing check also PASS, 3,973,120 float32 values with zero different bits, max absolute difference 0, all 16 choices equal |
| Eight-prompt corpus | Prior PASS, 64 full-vocab rows, 512 choices, all 8 independent greedy outputs |
| Concurrent-decode engine case 242 | Pre-existing sampled B>1 nondeterminism; controlled upstream/fork variants match, see below |
| checkbatchparity c=6 | PASS, complete upstream/fork CLI logs identical; 93/96 B=1-vs-batch token choices equal, 3 existing explainable near-ties |
| checkbatchparity c=7 | PASS, complete upstream/fork CLI logs identical; 109/112 B=1-vs-batch token choices equal, 3 existing explainable near-ties |
| checkbatchparity c=8 | PASS, complete upstream/fork CLI logs identical; 124/128 B=1-vs-batch token choices equal, 4 existing explainable near-ties |
| Timed decode / verify outputs | PASS, every warmup and measured rep matches across all 8 ABBA blocks |

Fresh CLI checks use context 512 and 16 teacher-forced steps. They compare identical policies **between builds**: the reported B=1-versus-batch numerical drift and near-tie flips are the same in both arms. No fresh parity difference required an upstream repeat. CLI c=1/4 were outside this finishing request and were not run; their earlier in-process logit gates remain recorded above. The prior exact-logit total was 288 rows / 71,516,160 float32 values. These measurements establish equality only for the sampled rows and observed outputs.

## Known issue: pre-existing sampled B>1 nondeterminism

The original engine run stopped at zero-based case 242 (sampled / auto / B=3 / mixed prompts, seeds 100/101/102). The [determinism control](divergence/REPORT.md) subsequently reproduced the same two complete token-array variants in two upstream and two fork processes. Upstream differs from itself at exactly the original first differing indices (23/14/36); upstream 1 vs fork 2 and upstream 2 vs fork 1 each match **480/480 tokens**. This is classified as pre-existing run-to-run nondeterminism, not a fork regression. Its internal cause and frequency remain unmeasured. The full engine matrix was not replayed by this finishing slice, and the prior interrupted matrix is not represented as a new complete pass.

## ABBA performance

Each cycle runs upstream → fork → fork → upstream. Each cell uses a fresh existing release `S4IntegrationBench` process, one excluded warmup, and three measured reps. Decode uses 64 lockstep steps; verify widths 3/5/8 use 12 fixed-state target passes per rep with verify rollback state. Rates exclude model loading and initial prefill. Verify time is milliseconds per target verify pass; lower is better. Per-request decode rates are aggregate rates divided by concurrency, with all requests advancing in lockstep. This is in-process throughput.

The table uses the median of four block medians per arm (12 measured samples per arm/workload). Cycle effects use ratios of the geometric means of the two arm block medians. No additional prefill workload was requested or run in this finishing slice.

| Workload | Unit | Upstream | Fork | Change | Cycle 1 | Cycle 2 |
|---|---|---:|---:|---:|---:|---:|
| decode c=1 | aggregate tok/s | 32.35 | 32.35 | -0.01% | +0.29% | -0.21% |
| decode c=1, per request | tok/s | 32.35 | 32.35 | -0.01% | +0.29% | -0.21% |
| decode c=4 | aggregate tok/s | 102.28 | 102.28 | -0.01% | -0.07% | +0.04% |
| decode c=4, per request | tok/s | 25.57 | 25.57 | -0.01% | -0.07% | +0.04% |
| decode c=8 | aggregate tok/s | 118.88 | 131.09 | +10.28% | +10.27% | +10.25% |
| decode c=8, per request | tok/s | 14.86 | 16.39 | +10.28% | +10.27% | +10.25% |
| verify width=3 | ms/verify step | 36.61 | 36.63 | +0.06% | -0.26% | +0.10% |
| verify width=5 | ms/verify step | 43.91 | 43.97 | +0.14% | +0.42% | -0.15% |
| verify width=8 | ms/verify step | 66.73 | 61.14 | -8.38% | -8.30% | -8.41% |

**Keep rule:** c=8 aggregate >= +2%: **PASS** (+10.28%). c=1 regression no greater than measured noise: **PASS** (-0.01%) versus 0.34% noise. Noise is the maximum absolute within-cycle same-arm block change, across both cycles and both arms. All timed output hashes are identical. Final verdict: **KEEP**. Results apply to this measured M5 Max and these workloads.

## Existing full test result and execution safety

The prior full `swift test --package-path /tmp/s4/src-int --scratch-path /tmp/s4/build-int` run exited 0: **1,790 passed, 45 skipped, zero failures** (XCTest 113 passed/14 skipped; Swift Testing 1,677 passed/31 skipped). It used default debug configuration; the preceding failed release test-build preparation ran no tests. See [raw/tests.json](raw/tests.json) and [raw/swift-test.log](raw/swift-test.log). No test, threshold, oracle, skip condition, or golden was changed. Tests were not rerun for this benchmark/report-only finish.

Every fresh GPU invocation held `/tmp/strim-bench.lock` via `lockf -k`; it was retained. No HTTP servers or ports (including 8203), GUI sessions, or logins were used. Models were read-only; scratch helpers and saved verify tensors stayed under `/tmp/s4/fin`. All started GPU processes completed normally. No unowned process was stopped, no recursive delete was performed, and no commit was made. Initial and final hashes plus the owned-process cleanup check are retained under `raw/fin`. Checks were headless; GUI behavior was not tested by this slice.
