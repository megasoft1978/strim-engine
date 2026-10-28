# Speed wave 2, L8: quantized matmul M-curve (investigation + proposal, 2026-10-28)

No engine or kernel code changed. New: `strim benchqmmcurve <model> [n]` and `strim benchqmmstep <model> [n]` (`Sources/StrimCLI/Cmd_QmmCurve.swift`, one dispatch line in `Commands.swift`). M5 Max, qwen38-4bit, HEAD 284b848 snapshot build, run under `/tmp/strim-bench.lock` with the 5 s watchdog (`wd_run.sh`; peak footprint 3.2 GB curve, 13.5 GB step, no aborts). Raw: `raw/`.

## Headline

1. **The per-shape isolated microbench (also the L2 "M=8 costs 2.2x M=4") overstates the cliff.** `benchfusedmicro`/`benchqmmcurve` queue 8 independent matmuls in one eval; MLX's concurrent encoder overlaps them and the qmv_wide tile pairs thrash. Chained serially over all 64 layers with real dataflow (`benchqmmstep`), M=8 costs **1.75x** M=4 (56.2 vs 32.0 ms for the whole-model projections), not 2.2-3.6x. The split-M options that looked great in isolation (gate+up M=8: 4+4 = 0.61x) are **slower** in the chain (+4 to +7%).
2. **No cheap exact option exists.** Split-M, other groupings and padding all lose or are inexact (tables below). Do not implement split-M grouping.
3. Real structure of the curve (cause confirmed by source and by the patch experiment): steps at M=6 and M=9/11 (MLX re-streams weights once per 5-row tile) and a flat but slow plateau from M=13 (qmm, ~82-85 ms whole-model projections, ~170 GB/s).
4. One exact, small lever found: raising MLX's qmv_wide tile cap from 5 to 8 vectors (a 1-line change in MLX, needs a mlx-swift fork) gives **M=8: 56.2 -> 50.8 ms (-5.4 ms, -10% of projections, -6.5% of the 83.4 ms B=8 step)**, M=6: 47.5 -> 43.5, bit-identical to today (final hidden state compared equal vs the 4+4 / 4+2 split paths). B=4 unaffected.

## Whole-model serial chain (authoritative): `benchqmmstep`, 64 layers, all projections, 14 GB streamed, min-of-5

Chain per layer: GDN qkv, z, out_proj / attention q, k, v, o_proj, then fused gate+up (N=34816) and down; elementwise glue identical across policies. lm_head (~1.5-3 ms) excluded.

| M | single ms | ms/row | x M=1 | policy tested: split4 all (exact?) | split4 mlp-only | pad16 mlp-only (exact?) | tile-cap-8 single (exact) |
|---:|---:|---:|---:|---|---|---|---|
| 1 | 26.9 | 26.9 | 1.00 | | | | |
| 2 | 27.2 | 13.6 | 1.01 | 27.3 (yes) | 27.7 | 38.0 (no) | |
| 3 | 29.9 | 10.0 | 1.11 | 29.8 (yes) | 29.8 | 39.9 (no) | |
| 4 | 31.9 | 8.0 | 1.19 | 32.1 (yes) | 32.0 | 41.4 (no) | 33.8* |
| 5 | 35.6 | 7.1 | 1.32 | 55.7 (no, 4+1) | 50.3 | 43.1 (no) | |
| 6 | 47.5-47.8 | 7.9 | 1.77 | 56.4-56.8 (yes, 4+2) | 53.6 | 50.1 (no) | 43.5 (yes) |
| 7 | 56.2 | 8.0 | 2.09 | 57.5 (yes) | 56.7 | 54.0 (no) | |
| 8 | 56.2 | 7.0 | 2.09 | 59.9-60.3 (yes, 4+4) | 58.5 | 54.2-54.7 (no) | 50.8 (yes) |
| 9 | 65.1 | 7.2 | 2.42 | 83.0 (no) | 78.4 | 59.2 (no) | 65.5 |
| 10 | 65.4 | 6.5 | 2.43 | 82.9 (yes) | 77.5 | 59.2 (no) | |
| 11 | 81.6 | 7.4 | 3.03 | 84.4 (yes) | 82.8 | 68.0 (no) | 76.1 |
| 12 | 82.2 | 6.8 | 3.05 | 86.0 (yes) | 83.8 | 67.9 (no) | |
| 13-15 | 83.5-84.1 | | 3.1 | 108-110 (no) | 105-107 | 81.8-83 (mlp-only yes) | |
| 16 | 81.2-81.5 | 5.1 | 3.03 | 111.7 (no) | 106.5 | 81.3 | |
| 24 | 84.2 | 3.5 | 3.13 | | | | |
| 32 | 84.6 | 2.6 | 3.14 | | | | |

*tile8 binary was run on a slightly slower machine state (M=1 27.7 vs 26.9, M=4 33.8 vs 31.9): compare the tile8 column to its own M=1/M=4 (x1.83 at M=8 vs x1.76... i.e. -5.4 ms absolute is a lower bound within drift). "exact?" = final hidden state of the chain bit-equal to the single-call result.

Reading: the cost steps by one extra weight stream per 5 rows (M=5 -> 6, 8 -> 9, 10 -> 11); M=7 and M=8 cost the same; M=13+ is flat at ~83 ms (qmm). Cost per extra tile is ~10 ms for 14 GB, i.e. the second tile is nearly free of L2 reuse. Splitting M=8 into 4+4 streams the weights twice (2 x 32 = 64 ms of bandwidth) so it cannot beat one 56 ms call; 4+4 for the MLP only is -0 to +4%. Padding to 16 lands in qmm: +30% at M=4, -3% at M=8, -9% at M=9, -17% at M=11/12 for the MLP only, and not bit-identical to the current outputs (it is row-invariant to filler: verified, `rowinv=YES` in `raw/curve2.txt`).

## Which kernel at which M (source, mlx-swift checkout)

`QuantizedMatmul::eval_gpu` (`mlx/backend/metal/quantized.cpp:1782`): `vector_limit = get_qmv_batch_limit(K, N, d)` (lines 85-143). This GPU is gen 17 'max' ('s' suffix), so for K or N > 4096 the limit is 13 (lines 87-96): M < 13 goes to `dispatch_qmv` (1739), M >= 13 to `qmm_splitk` (B == 1, line 1819) or `qmm`. Within `dispatch_qmv`: K == 64/128 -> `qmv_quad` (n/a here); M >= 2 and gen >= 15 (`use_qmv_wide`, 538) -> `qmv_wide` (544); M == 1 -> `qmv` (461, `qmv_fast` since N % 8 == 0 and K aligned). `qmv_wide` takes `n_tiles = (M + 4) / 5`, `vecs_per_tg = ceil(M / n_tiles)` (quantized.cpp:561-562), k_lanes 8, grid `(n_tiles, N/4, B)`, kernel `affine_qmv_wide` (`kernels/quantized.h:985-1100`), instantiated for 2..5 vectors (`kernels/quantized.metal:128-131`). Hence: M=1 qmv; M=2..5 one tile; M=6..10 two tiles (3+3, 4+3, 4+4, 5+4, 5+5); M=11..12 three tiles; M>=13 qmm (32x32 tiles, regardless of M up to 32+). Each extra tile re-reads the whole weight matrix, which is exactly the measured step at M=6, 9/11. Confirmed by the curve and by the tile-cap-8 experiment (M=6 and M=8 become one tile and drop as predicted; the single-tile kernel is ALU-bound, 275 GB/s at M=8 vs 450+ at M=1).

## Isolated per-shape curves (`raw/curve1.txt`, `raw/curve2.txt`): qualitative only

Weights rotated over 8 layers, queued without dependency, interleaved min-of-8. ms per layer at M = 1 / 4 / 6 / 8 / 12 / 16 (curve2 pad rows give M=16 qmm):

| shape (K x N) | 1 | 4 | 6 | 8 | 12 | 16 | M=8 / M=1 |
|---|---:|---:|---:|---:|---:|---:|---:|
| GDN in_proj_qkv 5120x10240 | 0.071 | 0.086 | 0.124 | 0.151 | 0.229 | 0.133 | 2.13 |
| GDN in_proj_z 5120x6144 | 0.049 | 0.060 | 0.083 | 0.098 | 0.135 | 0.226 | 2.02 |
| GDN out_proj 6144x5120 | 0.051 | 0.060 | 0.082 | 0.098 | 0.137 | 0.221 | 1.93 |
| attn q_proj 5120x12288 | 0.080 | 0.097 | 0.147 | 0.186 | 0.281 | 0.149 | 2.33 |
| attn k_proj 5120x1024 | 0.022 | 0.025 | 0.029 | 0.031 | 0.039 | 0.054 | 1.41 |
| attn o_proj 6144x5120 | 0.050 | 0.060 | 0.085 | 0.100 | 0.137 | 0.221 | 1.99 |
| MLP gate+up 5120x34816 | 0.189 | 0.221 | 0.461 | 0.685 | 1.144 | 0.329 | 3.63 |
| MLP down 17408x5120 | 0.105 | 0.138 | 0.234 | 0.268 | 0.366 | 0.448 | 2.54 |

These isolated numbers (M=8 gate+up 0.68 ms, 3.6x M=1) are **not** what a serial step sees: 64 x (0.685 + 0.268) = 61 ms for the MLP alone would exceed the whole measured B=8 step's MLP (41 ms corrected, `raw/split_B8.txt`). Only the position of the steps (M=6, 9, 11, 13) transfers. Isolated split rows (`SPLIT` lines in `raw/curve1.txt`): bit-identical per op whenever every chunk is >= 2 rows and stays in qmv_wide (3+3, 4+4, 4+2, 5+3, 6+2, 4+4+4, 5+5+2: all YES); any 1-row chunk (qmv) or a split crossing into M=16 (qmm) is NO. Row i of an M-row call never equals the M=1 call of row i (`ROWIDENT` 0/M for every shape and M >= 2: qmv and qmv_wide reduce in different orders), consistent with the known L1 parity drift (B=4 127-128/128, B=8 252-256/256).

## End-to-end estimate

Engine step (`benchbatchsplit` ctx 1024, no per-stage sync): B=1 34.3 ms, B=4 49.7 ms, B=8 83.4 ms (`raw/split_B4.txt`, `raw/split_B8.txt`; the c=4 43.7 ms in PLAN-CONCURRENCY is the 512-ctx figure). The serial-chain projections are 56.2 of 83.4 ms at B=8 (67%) and 31.9 of 49.7 (64%; PLAN's 43.7 ms step implies ~73%) at B=4; the rest is GDN recurrence/conv, attention, lm_head, norms.

| lever | B=4 | B=8 |
|---|---|---|
| split-M / regroup (exact) | 0 (M=4 is one tile; 4+... only adds streams) | -0 (measured +4% to +7%) |
| pad16 on MLP (inexact, qmm) | +30% projections | -1.6 ms (-3%), needs re-baselined parity |
| MLX tile cap 5 -> 8 (exact, needs MLX fork) | 0 | -5.4 ms (-6.5% step) -> c=8 aggregate ~73 -> ~78 tok/s (rival 74): flips the tie to a ~5% win; also B=6/7 -2 to -4 ms |
| ceiling if M=8 cost = M=4 (32 ms) | n/a | -24 ms (-29% step) -> c=8 ~95-100; requires a kernel beating MLX |
| ceiling if M=4 cost = M=1 (26.9 ms) | -5 ms (-10% step); c=4 43.7 -> ~39 | |

## Recommendation

- **Split-M grouping in the batched decode linear: no-go.** The data says it is exactly bit-identical but slower in the serial chain; the isolated microbench that suggested -39% was an overlap artifact. Do not touch `WeightStore.qmm` (Sources/StrimCore/Weights.swift:192) for this. Padding (pad16) is inexact and gains <= 3% at B=8: no-go.
- **B=4 / c=4: no cheap lever.** Projections at M=4 are already within 19% of M=1 (31.9 vs 26.9 ms); the remaining c=4 gap (43.7 vs ~34 ms) is not in this matmul (recurrence, attention loop, glue).
- **B=8 / c=8: the only real lever is the qmv_wide tile cap** (`mlx/backend/metal/quantized.cpp:561` `n_tiles = (M + 7) / 8`, plus instantiations for 6..8 in `kernels/quantized.metal:128-131`; in the JIT build the single-line cpp change alone was enough for this experiment). It is exact (bit-equal to the existing 4+4 / 4+2 results) and measured at -5.4 ms of 56 (B=8). Needs a mlx-swift fork/vendor (owner: whoever owns Package.swift/MLX pinning; not an engine file), a metallib/JIT check, and a `checkbatchparity` B=8 run; the ALU-bound kernel at nv=8 also may hurt M=7 or register pressure on other GPUs, so gate on `arch_gen >= 17`. Expected c=8 +5-6%, i.e. a clear but small win over rival (74). Moderate effort, low numerical risk, medium maintenance risk (carrying an MLX patch).
- **Custom Metal kernel for M in 5..16: no-go as a standalone lane.** Evidence: MLX's own qmm plateaus at ~170 GB/s and its qmv_wide at nv=8 reaches only ~275 GB/s versus 450+ at M=1, so the M>1 regime is ALU/dequant-bound, not stream-bound; a hand GEMV was already 5x slower than MLX (docs/SWIFT-PERF.md, PLAN-CONCURRENCY). Beating 56 ms needs a simdgroup_matrix (8x8) dequant-in-registers kernel; best case ~40-45 ms at M=8 (c=8 ~ +12-15%), realistic odds of beating MLX's tuned qmv_wide low (<25%) given prior results, effort high, and every row would change numerics (parity re-baseline). Revisit only after the tile-cap patch, and only with a microbench gate in a serial chain (not isolated), kill below -8 ms at B=8.
