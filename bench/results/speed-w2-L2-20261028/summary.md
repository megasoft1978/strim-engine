# Speed wave 2, L2 (fused GDN qkv+z / attention q+k+v projections): KILLED at the microbench gate (2026-10-28)

Method: `strim benchfusedmicro models/qwen38-4bit 8` (new, `Sources/StrimCLI/Cmd_FusedMicro.swift`): 8 layers per group so weights are not cache-resident, separate quantized matmuls vs one row-concatenated matmul, interleaved min-of-8, run under `/tmp/strim-bench.lock` with the 5 s memory watchdog (`wd_run.sh`). Snapshot build of HEAD beb302b + the bench file. Raw: `raw/micro1.txt`.

| group | M | separate ms/layer | fused ms/layer | saved ms/layer | saved ms/pass | bit-identical |
|---|---:|---:|---:|---:|---:|---|
| GDN qkv+z (16384 rows) x48 | 1 | 0.106 | 0.105 | 0.002 | 0.08 | yes |
| | 4 | 0.119 | 0.111 | 0.008 | 0.38 | yes |
| | 8 | 0.262 | 0.266 | -0.004 | -0.18 | yes |
| | 1024 | 2.985 | 2.990 | -0.006 | -0.29 | yes |
| attn q+k+v (14336 rows) x16 | 1 | 0.095 | 0.092 | 0.003 | 0.05 | yes |
| | 4 | 0.108 | 0.097 | 0.011 | 0.17 | yes |
| | 8 | 0.222 | 0.223 | -0.002 | -0.02 | yes |
| | 1024 | 2.635 | 2.625 | 0.010 | 0.16 | yes |

Projected end to end: B=1 decode 0.13 ms/pass of ~13 ms (about 1.0% upper bound, within noise); B=4 0.55 ms/step (gate: 2 ms; kill: below 1.5 ms); prefill ~0 (confirmed). Fused slices are bit-identical to the separate matmuls at every M (the kernel variant does not change with N), so the lane is exact but has nothing to gain.

Pad M 4->8 with zero rows: M=8 costs 2.2x M=4 here (qmv regime switches at M>=8: 0.262 vs 0.119 ms for GDN), so padding makes the projection 0.260 ms vs 0.119 ms (GDN) and 0.228 vs 0.108 ms (attention): worse by 2x. Rejected.

Verdict: kill. No engine code changed (no fused weights, no call-site edits, no memory change). Only the microbench command remains for reference. The M=4 -> M=8 cliff (2.2x for 2x the rows) is itself a finding: B=8 decode projections are bandwidth-inefficient relative to B=4, a possible target for a different lane (M=8 kernel regime), not fusion.
