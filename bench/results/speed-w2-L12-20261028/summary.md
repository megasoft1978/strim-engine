# Speed wave 2, L12: tensor-unit (Metal 4 MPP matmul2d) feasibility (2026-10-28) -- KILLED at the step-2 gate

New: `strim benchtensormicro [probe|fp16] [Ms] [reps]` (`Sources/StrimCLI/Cmd_TensorMicro.swift`, one dispatch line in `Commands.swift`). Standalone Metal API, no MLX internals; MLX only as the fp16 baseline. M5 Max, macOS 27.0.1 (26A434), Xcode SDK 27.0, Metal 32023.921. Idea only taken from rapid-mlx (opt-in small-M lane matmul); no code copied. Raw: `raw/`.

## Step 1: PASS (compiles, dispatches, correct)
- `MTLDevice.makeLibrary(source:)` with `languageVersion = .version4_0` compiles `#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>` at runtime (no flags, no offline metallib). Needs `@available(macOS 26.0)` in Swift (package floor is macOS 14).
- Device-pointer tensors need `tensor<device half, dextents<int32_t,2>, tensor_inline>(ptr, extents)`; the default (`tensor_handle`) tag has no pointer constructor (first compile error). `matmul2d_descriptor(mt, nt, dynamic_extent, false, true)` = NT (W[N,K] row-major), `execution_simdgroups<2|4|8|16>`, grid (N/nt, M/mt). All tile configs 8x32 .. 256x128 compile and run; max abs err vs CPU fp32 2.4e-4 (fp16 out, K=128, `raw/probe.txt`).
- Not tried: MLXFast.metalKernel (its header/language-version surface is MLX-controlled; the direct Metal path made it unnecessary). An engine integration would therefore need its own MTLDevice/queue interop with MLX buffers (or an mlx-swift fork), itself non-trivial.

## Step 2: FAIL the gate (fp16, y[M,N]=x[M,K]W[N,K]^T, 20 dispatches rotating 1.2 GB of weights, GPU time, best tile config; `raw/fp16.txt`, `raw/fp16_m1024_wide.txt`)

| shape (K x N) | M | MLX fp16 ms (GB/s) | best tensor-op ms (GB/s) | tensor / MLX |
|---|---:|---|---|---:|
| gate+up 5120x34816 | 8 | 1.451 (246) | 0.886 (402) | 1.64x |
| | 16 | 0.898 (397) | 0.892 (400) | 1.01x |
| | 32 | 0.906 (394) | 0.957 (372) | 0.95x |
| | 1024 | 6.49 (56.3 TF/s) | 5.61 (65.0 TF/s) | 1.15x |
| down 17408x5120 | 8 / 16 / 32 | 0.461 / 0.538 / 0.615 | 0.551 / 0.537 / 0.549 | 0.84x / 1.00x / 1.12x |
| | 1024 | 3.74 (48.8 TF/s) | 2.77 (65.9 TF/s) | 1.35x |
| 5120x14336 | 8 / 16 / 32 | 0.601 / 0.448 / 0.450 | 0.422 / 0.423 / 0.460 | 1.42x / 1.06x / 0.98x |
| | 1024 | 2.68 (56.1 TF/s) | 2.34 (64.3 TF/s) | 1.12x |
| 5120x16384 | 8 / 16 / 32 | 0.559 / 0.484 / 0.506 | 0.466 / 0.462 / 0.511 | 1.20x / 1.05x / 0.99x |
| | 1024 | 3.04 (56.6 TF/s) | 2.66 (64.6 TF/s) | 1.13x |

- M=1024: tensor ops plateau at **~65 TF/s for every tile config tried (64x64 .. 256x128, 2-16 simdgroups)**, +12..15% over MLX fp16 (down: +27..35%, a weak MLX shape) and only **+4% over the 62.7 TF/s quantized plateau that prefill already runs at**. A dequant kernel can only be slower than the fp16 ceiling. Gate was >= 1.3x: FAIL. Prefill is dead (same story for the MLP at 63% of 4K prefill: ceiling gain <= ~4% of those GEMMs).
- M=8..32: at M>=16 MLX fp16 is already at the bandwidth ceiling (~330-400 GB/s) and the tensor kernel equals it (0.92-1.06x). The M=8 "wins" are MLX fp16's weak small-M path (246 GB/s), not a tensor-unit advantage. Gate was >= +20% over MLX bandwidth-limited rates: FAIL.

## Caveat for the lead (not tested, outside the gate as written)
The fp16 numbers prove the tensor unit is not a compute lever (decode is bandwidth bound; 6.4 TF/s used at M=16 of 65 available). They do not prove a 4-bit tensor-op kernel is impossible: the real M=8..32 problem (L8: qmv_wide ALU-bound at ~275 GB/s, qmm ~170 GB/s vs ~450 GB/s at M=1) is the dequant ALU cost, which is independent of the matmul unit. A kernel that dequantizes 4-bit g64 into threadgroup memory and feeds matmul2d could in principle approach the M=1 bandwidth for all M<=32 (upper bound: whole-model projections ~27 ms instead of 56 (M=8) / 84 (M>=13), i.e. up to ~-29 / -57 ms of the 83 ms B=8 step), but that is a hand-written-kernel bet (SWIFT-PERF: hand GEMV was 5x slower), numerically different from MLX (opt-in per quality gate), and needs an MLX-buffer/queue interop. Per the brief, step 3 was not started. If wanted, the cheaper proxy first: dequant-to-threadgroup + matmul2d at M=16 on one gate+up shape, reading 4-bit packed from the same buffers, compare against 1.0 ms at 170 GB/s; kill if > 0.35 ms (100 MB / 0.35 ms = 290 GB/s).

## Follow-ups (coordinator request, same day)

### (1) INT8 vs FP16 matmul2d, M=1024 (`benchtensormicro int8`, `raw/int8.txt`, rotating 1.2 GB of weights, best of 6 tile configs)
| shape | fp16xfp16->fp16 | int8xint8->int32 | fp16xint8->fp16 | int8 / fp16 |
|---|---|---|---|---:|
| gate+up 5120x34816 | 5.60 ms, 65.2 TF/s | 2.99 ms, **122.3 TOPS** | 5.77 ms, 63.3 | **1.88x** |
| down 17408x5120 | 2.77 ms, 65.9 TF/s | 1.54 ms, **118.9 TOPS** | 2.91 ms, 62.8 | **1.80x** |

Apple10 tensor hardware runs int8 x int8 -> int32 at ~1.8-1.9x fp16 (>= 1.4x: W4A8 NOT killed on throughput). Mixed fp16 x int8 -> fp16 compiles but gives no speedup (it converts), so only true A8W8 helps. Caveat: operands were constant/low-entropy fill (power/data-dependent throttling not measured), int32 output written to device.
Prefill estimate for W4A8 (per-token int8 activations, W4 dequantized to int8 in tile): GEMM ceiling -45% of time. Costs that eat into it: affine g64 means a separate int32 accumulate per 64-wide K group followed by an fp32 scale/bias fold (the `b*sum(A_g)` term needs per-group activation sums), plus the W4->int8 unpack per tile and the per-token activation quantization pass. Realistic 25-35% off the GEMMs, MLP is 63% of 4K prefill and projections ~85% overall => roughly 15-25% off prefill time, an estimate, not measured. Lossy (activation int8 quantization) so opt-in only, needs a logit-level/checkprefix check and a long-agent quality run. Effort: large (new tiled kernel with group-wise rescale, MLX-buffer interop, quant pass, parity and quality gates).

### (2) Dequant-in-tile proxy, gate+up K=5120 N=34816, 4-bit g64 affine in MLX packing (`benchtensormicro dq 8,16`, `raw/dq_run1.txt`, `raw/dq_run2.txt`)
Kernel: 4 simdgroups per threadgroup, dequantize a (NT x KT) weight tile from the packed uint32 + fp16 scales/biases into threadgroup fp16, barrier, `matmul2d` (multiply_accumulate into a cooperative fp32 tensor), barrier; no double buffering (deliberately straightforward). MLX packed weights (from `quantized(w, 64, 4)`, fp16 scales), 8 rotated copies (800 MB), same weight buffers for both sides. Both sides chained-serial (MLX: x_{i+1} = (x_i W_i)[:, :K]; Metal: in-order encoder), 24 per run.

| M | MLX quantizedMatmul | best proxy tile (run1 / run2) | ratio | GB/s |
|---:|---|---|---:|---:|
| 8 | 0.390 ms (257 GB/s) | 16x16xKT128: 0.334 / 0.330 ms | 1.17-1.18x | 300 |
| 16 | 0.364 ms (276 GB/s) | 16x16xKT128: 0.360 / 0.348 ms | 1.01-1.04x | 278-288 |

Result vs the 0.35 ms kill line at M=16: 0.348-0.360, i.e. on the line, and equal to MLX qmm (0.364); not a win as-is. M=8: -15% (0.06 ms/layer) vs MLX, not the tile-cap-8 route's gain scaled up. Larger KT (512) or bigger NT is much worse (0.55-0.75 ms: threadgroup memory/occupancy). Numerics: M=16 output bit-identical to MLX (max abs 0 over 557k outputs), M=8 max abs 0.25 at |ref| ~336 (1 fp16 ulp, rare); fp32 accumulation order differs only slightly, but not guaranteed identical, so any use stays opt-in. Memory: reads the same packed buffers, no extra weight copy, 16-32 KB threadgroup scratch.
Note: this shape in a chain already runs at 257-276 GB/s in MLX (vs ~450 GB/s at M=1), so the headroom is up to ~0.23 ms at M=16 if a kernel reached M=1 bandwidth; the naive proxy recovers none of it at M=16. Closing the gap needs double-buffered/async dequant overlapped with the matmul, a real engineering bet (SWIFT-PERF caution) with ~0.1 ms/layer-shape upside at best; decision: do not productionize on this evidence, revisit only if a double-buffered version of this proxy reaches <= 0.28 ms at M=16.
