# Speed wave 2, L14: W4A8 prefill prototype (2026-10-28) -- gate 1 PASS, gate 2 FAIL, lane killed

Code: `Sources/StrimCore/TensorKernels.swift` (`W4A8.quantizeActivations`, `W4A8.matmul`; not wired into the engine, no knob added), bench `strim benchtensormicro w4a8 [M] [MTxNTxSG,...]` (`Sources/StrimCLI/Cmd_TensorMicro.swift`; `STRIM_W4A8_VAR=0..3` ablations). M5 Max, macOS 27.0.1. Raw: `raw/`. All GPU runs under `/tmp/strim-bench.lock`.

## Gate 1 interop: PASS via (a) MLXFast.metalKernel, nothing else needed
- MLX's custom-kernel path JIT-compiles with `MTL::LanguageVersion4_0` (4.1 on macOS 27; `backend/metal/device.cpp:65-79`), source = MLX utils + generated signature + `header` + body, so a header containing `#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>` compiles with no flags. The kernel body builds `tensor<device int8_t, dextents<int32_t,2>, tensor_inline>` over the MLX input pointers, `matmul2d<..., execution_simdgroups<N>>`, threadgroup-memory tensor for the unpacked weight tile, cooperative int32 destination tensor. Inputs/outputs are ordinary MLXArrays, the kernel is part of the lazy graph (grid is in threads; `threadgroup_position_in_grid`, `thread_index_in_threadgroup`, `<name>_shape` all work).
- Numerics check against an exact reference (dequantized int8-quantized activations x dequantized weights, fp32): relRMS 4.7e-4 (fp16 output rounding), i.e. the kernel is correct. Versus the MLX 4-bit qmm: relRMS 5.9e-3 (activation int8 quantization per 64-group; max abs 2.6 at |y| ~ hundreds).
- No custom queue / MTLBuffer sharing needed (b not explored).

## Gate 2 speed on MLX-packed 4-bit g64 weights, M=1024, fp16 scales, 4 rotated weight copies, quantize + matmul + epilogue included (`raw/w4a8_v2.txt`, `raw/w4a8_v3.txt`): FAIL
Kernel: per 64-group K step: unpack the NT x 64 nibbles to int8 in threadgroup memory, stage a[m], a2[m], s[n], b[n] for the group, `matmul2d` int8xint8->int32 (K=64), fold `acc += a*s*P + b*a2` in fp32 registers, write fp16. Activation quantizer = separate kernel, 0.05 ms (gate+up) / 0.11 ms (down), negligible.

| shape | MLX qmm | best full kernel (tile) | ratio | gate |
|---|---:|---:|---:|---|
| gate+up 5120x34816 | 6.34 ms | 8.19 ms (64x64, 8 simdgroups) | **1.29x** | needs <= 0.75x |
| down 17408x5120 | 3.40 ms | 4.22 ms (64x64, 8 sg) | **1.24x** | needs <= 0.85x |

Where the time goes (gate+up, ms): bare int8 matmul with K=64 steps, no unpack/staging/epilogue 3.7 (0.58x, `raw/variants.txt`, VAR=3); + weight unpack and staging 5.96 (0.93x, VAR=2, trivial accumulate); + real scale fold 8.2 (1.29x). So even with a FREE epilogue the unpack+staging+per-group barrier structure sits at 0.89-0.93x MLX, above the 0.75x/0.85x bar; the epilogue (the group-wise fp32 scale/bias fold, which is unavoidable because s[n,g] differs per 64-group so every group needs its own int32 accumulator) adds 2.3 ms. Register pressure is the other cliff: per-thread accumulator arrays (tile elements / threads) spill when > 16 (64x64 with 4 sg: 32 B... 31-37 ms; 128-wide tiles 34-105 ms); the 8-simdgroup 64x64 tile is the sweet spot. Per-token (single scale per row) activation quantization does not change this structure: the weight group scales force the per-group integer accumulate regardless.
Avoiding the per-group fold would need weights requantized to a per-row int8 scale (W8: an extra 2x-size weight copy and extra weight error) -- excluded by the no-extra-weight-copy rule.

Verdict: kill. Gates 3 (quality) and the benchprefill ABAB were not started. Productionizing would need async/double-buffered unpack + fold hidden under the tensor op (not expressible with cooperative matmul2d + barriers as used here); no evidence it gets from 1.29x to <= 0.75x, and the ceiling with these primitives (pure int8 GEMM 0.58x MLX on gate+up) leaves only ~0.1-0.2 ms slack for everything else.
