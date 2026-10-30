# S4 — qmv cap and GDN projection fusion (2026-10-29)

**4a KEEP as a local patch and vendor plan only. 4b KILL; no engine code changed in the real repository.**

Base a112d0d, mlx-swift exact 0.32.3, Apple M5 Max. Two independent ABBA cycles per part; three measured repetitions per block (12 per arm/cell), plus excluded warmups. All GPU runs held `/tmp/strim-bench.lock`. Headless in-process measurements; no servers or GUI actions. Models were read-only. See [method.md](method.md) and [raw/analysis.json](raw/analysis.json) for workload/timing definitions, every sample, noise and per-cycle ratios.

## 4a — M5-family qmv_wide tile cap 5 → 8

The cap is in `qmv_wide`'s tile calculation, **not** `get_qmv_batch_limit`; the latter's dispatch thresholds are unchanged. The predicate matches the M5 Max dispatch path (architecture generation >=17, size != 'd'); other paths retain cap 5. This reduces M=8 from two four-vector tiles to one eight-vector tile. Both arms keep Swift fusion OFF.

| c | Base aggregate tok/s | Cap-8 aggregate tok/s | Change | Base per-request decode tok/s | Cap-8 per-request decode tok/s |
|---:|---:|---:|---:|---:|---:|
| 1 | 32.34 | 32.29 | -0.13% | 32.34 | 32.29 |
| 4 | 101.91 | 101.90 | -0.00% | 25.48 | 25.48 |
| 8 | 118.24 | 130.43 | 10.30% | 14.78 | 16.30 |

Rates exclude prefill and count fixed 64-step lockstep decode. They are not HTTP request throughput.

| Verify width | Base ms/pass | Cap-8 ms/pass | Time change |
|---:|---:|---:|---:|
| 3 | 36.59 | 36.61 | 0.06% |
| 5 | 43.86 | 44.02 | 0.37% |
| 8 | 66.88 | 61.31 | -8.32% |

Verify timing isolates the target pass with rollback-state recording, not drafting or MTP head replay. Widths 3/5 (normal depth 2/4) do not change tiles and show no supported improvement; width 8 exercises the patch.

| Metric | ABBA cycle 1 change | Cycle 1 same-arm drift | ABBA cycle 2 change | Cycle 2 same-arm drift |
|---|---:|---:|---:|---:|
| decode 1 | -0.21% | 0.55% | -0.14% | 0.06% |
| decode 4 | 3.92% | 8.26% | -0.00% | 0.09% |
| decode 8 | 9.64% | 1.35% | 10.29% | 0.09% |
| verify 3 | 0.43% | 0.84% | -0.02% | 0.31% |
| verify 5 | 0.85% | 1.77% | 0.30% | 0.20% |
| verify 8 | -7.03% | 2.84% | -8.48% | 0.37% |

Cycle changes are ratios of geometric arm means; main tables use medians of block medians. Drift is the maximum A-to-A or B-to-B change within the cycle. The initial c=4 control was noisy (unchanged kernel), so no c=4 benefit is inferred.

Keep gate: c=8 aggregate **10.30%**, above +2% in each cycle; c=1 **-0.13%**, within its measured **0.55%** drift floor. Every c=1/4/8 timed row and every verify-width row has the same greedy hashes across both arms and all repeats. All eight corpus greedy outputs match (512 tokens), all 512 teacher-forced choices agree, and all 64 sampled full-vocab logit rows have zero bit differences. These sampled logit checks do not establish bit identity of every internal value in the changed c=8 kernel.

Exact patch: [qmv-cap8.patch](qmv-cap8.patch). Source matched the pinned MLX submodule before editing; reverse dry-run succeeds ([patch validation](raw/patch-validation.txt)). [vendor-plan.md](vendor-plan.md) describes follow-up integration. **No fork, push, real Package.swift change or vendoring was performed.**

## 4b — one qkv/z/b/a quantized projection

Scratch-only, on the **unpatched cap-5** binary: concatenate 10240+6144+48+48 output rows, validate equal quantization specs, materialize once, replace original resident weights, run one quantized matmul and split.

| Prefill | Base tok/s | Fused tok/s | Change | Cycle 1 change / drift | Cycle 2 change / drift |
|---|---:|---:|---:|---:|---:|
| 4K | 1035.12 | 1032.27 | -0.27% | 1.86% / 4.00% | -0.36% / 0.02% |
| 16K | 977.29 | 972.66 | -0.47% | -0.47% / 0.09% | -0.50% / 0.06% |

Target prefill only, fixed 1024-token chunks, no MTP head seeding. The +0.3% beyond-noise speed gate is not met.

| Bench prompt | Max absolute logit difference | Teacher-forced greedy agreement | Independent 64-token greedy output identical |
|---|---:|---:|---|
| code | 0.375 | 62/64 | no |
| csvpy | 0.6875 | 63/64 | no |
| json | 0.3125 | 63/64 | no |
| math | 0.375 | 64/64 | yes |
| natural | 0.251953125 | 63/64 | no |
| prose | 0.34375 | 63/64 | no |
| rust | 0.60546875 | 64/64 | yes |
| sql | 0.375 | 63/64 | no |

Overall: max absolute logit difference **0.6875**, **13986964** differing float32 bit patterns across 64 sampled vocab rows; **505/512** teacher-forced choices agree; only **2/8** independent greedy outputs match. **Not exact.** The narrow reference b/a matmuls use split-K at prefill sizes; merging into the wide projection changes reduction association. This is consistent with the observed drift, rather than an exact-preserving dispatch reduction.

**KILL**: speed gate fails and bit identity fails. No near-exact-tier claim or opt-in production flag is shipped; checkbatchparity/agentbench promotion gates were not run because the speed candidate is rejected. Scratch patches and harness remain in raw results for reproduction. No real Qwen/GDN/WeightStore source or tests were edited, so no new repository tests are needed for the rejected candidate.

## Validation and artifacts

Both release builds succeeded. [raw/validation.json](raw/validation.json) checks 24 measured rows per cell, complete two-cycle schedules, hash consistency and all eight quality prompts per arm. Token sequences, JSONL, system/load samples, compiler logs, source patches, harness and analysis scripts are retained under [raw/](raw/). Full reference/candidate logit tensors are scratch artifacts under `/tmp/s4/quality`; no large tensor binaries were added to the repo. No GPU processes or servers started by S4 remain after completion. No commits were made. Existing unrelated working-tree changes were left untouched.
