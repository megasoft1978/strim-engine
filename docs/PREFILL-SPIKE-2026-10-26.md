# Prefill GEMM spike (2026-10-26): is there headroom beyond MLX matmul?

Verdict: **NO-GO** for a custom 4-bit prefill GEMM kernel. Step 3 not built (gate not met).
Machine: M5 Max, 40 GPU cores (`applegpu_g17s`), macOS 27.0.1, MLX Swift 0.32.3 (Cmlx), Python MLX 0.32.4.
All GPU runs under `lockf -k /tmp/strim-bench.lock`; load average 2.7-5.0 (another agent benchmarking, serialized by the lock).

## 1. Dispatch: MLX already uses NAX here

- `Cmlx/mlx/mlx/backend/metal/device.cpp:947-965` `is_nax_available()`: runtime check
  `__builtin_available(macOS 26.2)` AND arch gen >= 17 (non-'p' arch). Only compile-time off-switch is
  `MLX_METAL_NO_NAX`; it is not defined anywhere in the mlx-swift package (only in MLX CMake files), and NAX JIT
  sources exist in `Source/Cmlx/mlx-generated/{gemm_nax,quantized_nax,steel_attention_nax,...}.cpp`.
  This machine: gen 17, arch suffix 's', macOS 27 -> NAX on.
- bf16 matmul: `matmul.cpp:917` `use_nax` -> `steel_matmul_regular_axpby_nax` (matmul.cpp:985) / NAX split-K (948).
- Affine qmm: `quantized.cpp:1039-1043` (`qmm_nax`, tile bm=64 bn=64 bk=64, 2x2 simdgroups, `quantized.cpp:814-`),
  requires transpose and K % 64 == 0 (true for all our shapes).
- SDPA prefill: `scaled_dot_product_attention.cpp:218` NAX full-attention kernel for D in {64,96,128,256}.
- Why the "macOS 26.2 deployment target bump changed nothing": the gate is a runtime availability check, not the
  package deployment target, so NAX was already active at macOS 14 target. Not empirically toggled off (no runtime switch);
  inference from code plus the ~60 TF/s plateau below, far above non-tensor simdgroup rates.

## 2. Measured (bench/spike/qmm_shapes.py, best of 8)

| shape (K->N) | M | MLX bf16 TF/s | MLX qmm4 g64 TF/s | qmm/bf16 | dequant+mm TF/s |
|---|---|---|---|---|---|
| gate/up 5120->17408 | 512 | 55.2 | 51.9 | 0.94 | 44.5 |
| | 1024 | 59.3 | 55.2 | 0.93 | 53.0 |
| | 4096 | 63.1 | 57.8 | 0.92 | 60.7 |
| down 17408->5120 | 512 | 51.3 | 49.0 | 0.96 | 42.6 |
| | 1024 | 54.6 | 52.1 | 0.95 | 48.9 |
| | 4096 | 58.0 | 55.1 | 0.95 | 56.3 |
| qkv-ish 5120->12288 | 512 | 51.3 | 50.4 | 0.98 | 42.2 |
| | 1024 | 57.5 | 53.3 | 0.93 | 51.5 |
| | 4096 | 62.3 | 57.1 | 0.92 | 60.3 |
| proj 5120->5120 | 512 | 46.8 | 43.5 | 0.93 | 37.0 |
| | 1024 | 53.7 | 48.5 | 0.90 | 48.0 |
| | 4096 | 60.9 | 55.2 | 0.91 | 58.2 |

Note: qmm here is 51-58 TF/s, higher than the 38-55 recorded in SWIFT-NEXT (that was an older build/idle state).

Ceiling probe (bench/spike/peak_probe.py, fp16/bf16 dense, many shapes incl. batched): 58-63 TF/s everywhere
(8192^3: 61.1-61.9; 4096x17408x5120: 62.9). A flat plateau independent of shape and dtype = a hardware/clock/power
ceiling of ~62-63 TF/s sustained that MLX's NAX GEMM already reaches. qmm at M=4096 is 87-92% of that.

Theoretical peak: not derivable from public data I could verify. If one assumes 2048 FLOP/clk/core x 40 cores x ~1.5 GHz
it would be ~120 TF/s, i.e. MLX at ~50%; but the flat plateau across 6 very different shapes argues against a software-
tile limitation, and I could not confirm the per-core rate or sustained clock. Treat peak fraction as UNVERIFIED;
fraction of best-measured dense GEMM is the defensible number (qmm 0.90-0.98 of bf16, bf16 ~ plateau).

## 3. Where 4K prefill time goes (bench: `strim benchprefill models/qwen38-4bit 4096 3 <chunk>`)

| chunk | tok/s (3 reps) | uptime load |
|---|---|---|
| 4096 (single pass) | 936 / 947 / 944 | 5.0->2.7 |
| 2048 | 932 / 939 / 937 | |
| 1024 | 923 / 923 / 924 | |
| 512 | 886 / 897 / 893 | |

Chunk size: bigger is monotonically (slightly) better; 2048 default costs ~0.7% vs 4096, 512 costs ~5%. No headroom there.
(`benchprefill` gained an optional 5th arg = chunk size to measure this; default behavior unchanged.)

Effective throughput: 944 tok/s x 54 GFLOP/token = 51 TF/s end-to-end, vs qmm 55-58 at M=4096. GEMM-at-qmm-rate ceiling
= ~1,000-1,070 tok/s, so the model is ~90-94% GEMM-bound already.

Attention core (bench/spike/sdpa_probe.py, 24q/4kv, d=256, causal, NAX SDPA): S=4096 5.0 ms/layer, 81 ms for 16 layers
= ~1.9% of the 4.34 s prefill (41 TF/s useful). Even a 2x faster flash kernel is worth ~+1%. S=1024: 13 ms of 1.2 s.
(HANDOFF's attention 9% at 1K includes q/k/v/o projections, norms, rope.)

## 4. Gain bound

Upper bound only if a custom kernel matched MLX's dense bf16 rate with 4-bit dequant for free (optimistic; dequant ALU
competes with the tensor pipe): qmm->bf16 parity = +6-9% on GEMM time. GEMM share at 4K ~90% -> end-to-end
**+5-8% => ~990-1,020 tok/s at 4K** (from 944). Flash attention: <= +1-2%. GDN (~30% at 1K, recurrent/elementwise, not
GEMM) is outside this spike. Isolated qmm headroom is ~1.07-1.1x, well below the 1.3x gate in the plan -> step 3 skipped.

## 5. Not verified / caveats

- BaseRT 3.9x claim is almost certainly vs MLX before NAX dispatch (M5 Pro, older MLX/macOS); not reproducible here and
  the measured plateau says MLX is already on the tensor path. Could not check their claim directly.
- True hardware tensor peak and sustained GPU clock/power state unknown; a hand-written Metal 4 tensor_ops kernel could
  in principle exceed 63 TF/s only if the plateau is a tiling artifact. Tile sizes of qmm_nax (64x64x64, 4 simdgroups) are
  small vs. what a large-tile kernel might use; this is the only plausible source of headroom and was not tested.
- Did not force NAX off, no Metal capture of kernel names (dispatch inferred from source + throughput).
- GDN share at 4K not re-measured; the bound uses a ~90% GEMM share derived from effective TF/s, not a profile.

> Note (2026-10-27): `bench/spike/*.py` (qmm_shapes, peak_probe, sdpa_probe) were removed 2026-10-27; in the history bundle. Results above stand as recorded.
