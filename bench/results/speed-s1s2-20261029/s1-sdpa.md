# S1: long-context prefill SDPA microbench (2026-10-29)

`strim benchsdpa 7 8` (Sources/StrimCLI/Cmd_SdpaMicro.swift): Hq=24, Hkv=4, D=256, bf16, q chunk 1024 vs kv length (bottom-right causal, queries = last 1024 positions), MLX fast SDPA. 8 chained layers per iteration, min of 7 after warm-up, 2 passes. Run under /tmp/strim-bench.lock; shared machine (load 7-10). Raw: raw/sdpa-run2.txt (run1 had a lazy-evaluation bug in the PV reference; its SDPA rows agree with run2).

| kv | MLX SDPA causal ms | TF/s (causal flops) | % of 62.7 | SDPA no mask ms | TF/s (full flops) | GEMM QK TF/s | GEMM PV TF/s | QK+PV full TF/s | ideal causal-skipping time ms |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096 | 2.21 | 40.8 | 65 | 2.53 | 40.7 | 56.1 | 51.0 | 53.4 | 1.69 |
| 16384 | 9.53 | 41.9 | 67 | 10.57 | 39.0 | 56.5 | 51.1 | 53.7 | 7.44 |
| 32768 | 19.21 | 42.3 | 67 | 22.18 | 37.2 | 57.2 | 52.0 | 54.5 | 14.90 |

Reads: the existing kernel runs at 41-42 TF/s (65-67% of the 62.7 dense plateau), matching the 42.5 TF/s of table16k. GEMM reference = the two matrix products of a flash loop (grouped GQA q rows 6x1024, K=256 contraction, 4096-wide kv tiles) with no softmax: 51-57 TF/s, because K=256 / N=256 products sit below the 62.7 plateau (which needs large K). Even a perfect flash kernel with free softmax and perfect causal skipping reaches ~54 TF/s equivalent; with online softmax work (exp, rescale) 40-48 is realistic.

Decision: S5 SDPA kernel = NO-GO. >=55 TF/s is not plausible (the matrix-pipe ceiling for these shapes is ~54 before softmax). Realistic best 46-48 TF/s saves 9-13% of SDPA time = 0.6-0.9% of 16K prefill (7.1% share) and ~1-1.5% at 32K, below the 2x-noise bar of the bench protocol, for a large custom-kernel effort. Pursue idea 2 (macro-chunk GEMM) or decode work instead.
