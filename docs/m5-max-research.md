# M5 Max / Metal 4 / language choice — research memo (2026-10-25)

## 1. M5 Max spec table (target: Mac Studio Mac17,14, 64 GB)

| Item | Value | Source type |
|---|---|---|
| Chip | Apple M5 Max, "Fusion Architecture" (two dies, one SoC) | Apple newsroom 2026-03-03 |
| CPU | 18 cores = **6 "super" + 12 performance** | Apple specs; matches local `system_profiler` |
| GPU | **40 cores**, 1 Neural Accelerator per GPU core (~40 NAs) | Apple specs / newsroom |
| Memory | 64 GB unified, LPDDR5X-9600 | Apple specs; HW-Corner 2026-03-04 |
| **Bandwidth** | **614 GB/s** (40-core SKU) / 460 GB/s (32-core SKU) | Apple Mac Studio specs |
| Neural Engine | 16-core | Apple specs |
| Ray tracing | Hardware-accelerated, "up to 35% faster than M4 Pro/Max" | Apple claim, unverified independently |
| Media engine | 1 video decode, 2 video encode, 2 ProRes enc+dec, AV1 decode | Apple specs |
| Announcement | M5 Pro/Max **2026-03-03**, ship 2026-03-11 (MacBook Pro); **Mac Studio M5 Max/Ultra 2026-08-25** | Apple newsroom; 9to5Mac |
| Base M5 (for reference) | announced 2025-10-15, 153 GB/s | Apple newsroom 2025-10 |

**Bandwidth ladder:** M4 Max 546 GB/s (2024-10-30) → M5 Max 614 GB/s → M3 Ultra 819 GB/s → M5 Ultra 1.2 TB/s. M5 Max is only **+12.5% over M4 Max** — the generation's real jump is compute (TensorOps), not bandwidth.

**Realistic achievable bandwidth:** independent MLX-based measurement on an M5 Max 40-core/48 GB (2026-09-27) reports **550–552 GB/s** DRAM-bound copy = **~90% of peak**, and **528 GB/s** for matrix–vector (the decode-shaped op) = **86%**. Measured 4-bit decode lands at 0.92–0.94 of the bandwidth-implied ceiling (Qwen3-8B 111.9 tok/s vs 121.9 bound). **Plan on 85–90% of 614 GB/s ≈ 520–550 GB/s.**

## 2. Findings

1. **The 40-core M5 Max is a 614 GB/s part; the 32-core is 460 GB/s.** Apple lists both; most press coverage quoted 460. Verify SKU before quoting. ([Apple specs](https://www.apple.com/mac-studio/specs/), 2026-08)
2. **~90% of peak is reachable, and decode is genuinely bandwidth-bound.** 550–552 GB/s copy, 528 GB/s matvec, 0.92–0.94 of the bound. A 64 GB machine therefore caps around ~120 tok/s on an 8B-4bit and ~25–30 tok/s on a 70B-4bit. ([emihiggins bench](https://emihiggins.github.io/projects/m5-max-llm-bench/), 2026-09-27)
3. **Apple's own MLX-on-M5 numbers split cleanly: prefill 3.33–4.06×, decode 1.19–1.27× vs M4.** Decode gain ≈ the 120→153 GB/s bandwidth delta alone. Neural Accelerators help compute-bound prefill and contribute ~nothing to decode. ([Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5), 2025-11-19; needs macOS 26.2+)
4. **Metal 4's inference-relevant additions:** `MTL4CommandQueue`/`CommandBuffer`/`Allocator` (buffers decoupled from queues → parallel encoding), unified compute encoder, `MTL4ArgumentTable` (bindless), **residency sets** (replace scattered `useResource`/`makeResident`), placement-sparse resources, stage-to-stage barrier API, `MTL4Compiler` (device-independent, QoS-aware), tensor as a first-class resource, and an **ML command encoder that inserts a whole CoreML network as one command** sharing barriers with render/compute. ([WWDC25-205](https://developer.apple.com/videos/play/wwdc2025/205/))
5. **TensorOps (`mpp::tensor_ops::matmul2d`) is the sanctioned quantized-matmul path** — hardware matmul over `cooperative_tensor`, 16×32×16 tiles, `INT8×INT8→INT32` and `half × int4/int8 → half` with **dequant inside the op**. OS gating matters: int4/int8 = macOS 26; **fp4/fp8/int2, MX·E8M0 block-scale planes, and cooperative-tensor-as-matmul-input = macOS 27** (which you have). Requires `-std=metal4.0`; blockwise scales need `metal4.1`. Trap: the native scale plane is **E8M0-only, block-32, transposed-right**; arbitrary fp16 scales must be applied manually per K-block. ([WWDC26-330 notes](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/tensorops-quantized-kernels.md), 2026-07-01; [cider INT8 GEMM tutorial](https://github.com/Mininglamp-AI/cider/blob/main/tutorial/how_to_write_efficient_int_gemm_m5_en.md))
6. **MPSMatrix is not the quantized path; MPSGraph is the tuned baseline to beat.** MPP/TensorOps is what Apple itself uses ("MLX leverages the TensorOps and Metal Performance Primitives framework introduced with Metal 4"). On A19, a hand-written `matmul2d` reached at best ~5.4 TFLOP/s vs MPSGraph's 5.1–6.3 TFLOP/s — parity, not a win. ([tensorops notes](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/tensorops-quantized-kernels.md))
7. **BaseRT proves the ceiling is much higher than MLX/llama.cpp on M5:** +up to **6.4× prompt processing vs llama.cpp, 3.9× vs MLX**, decode +1.75×/+1.33×, on M5 Pro, via hand-written Metal 4 tensor-core GEMM + flash-attention prefill kernels, leaving decode on memory-bound kernels. ([arXiv 2607.19438](https://arxiv.org/abs/2607.19438), 2026-07-21)
8. **ANE is not a decode accelerator for third-party code.** Public path is CoreML only; private path is `dlopen`ing `AppleNeuralEngine.framework` (`_ANEInMemoryModel*`, `_ANERequest`, `_ANEIOSurfaceObject`) with hard constraints: single packed input (violations fail *silently*), ~**100 runtime compiles per process**, internal fp16, IOSurface `[1,C,1,S]`, fp32 I/O. Critically, **ANE per-step decode cost is O(state_length), not weight bandwidth** — halving context gave 2.56×, halving weight precision only +12%. Measured ANE ≈34 tok/s class vs GPU ≈55 on M4 Max: **ANE's edge is energy, not speed**. No 2026 evidence of ANE beating GPU at LLM decode on Mac. ([ANE private-API constraints](https://github.com/john-rocky/CoreML-LLM/blob/main/docs/ANE_PRIVATE_API_CONSTRAINTS.md), 2026-04-22; [survey](https://github.com/john-rocky/CoreML-LLM/blob/main/docs/ANE_OPTIMIZATION_SURVEY.md), 2026-04-14)
9. **The biggest Apple-silicon kernel lesson: delete threadgroup staging.** On unified memory, device→threadgroup→register added nothing; going direct to registers gave **2.3–2.8×** — the single largest win in a 5-step INT8 GEMM optimization (2.78× total, bit-exact). ([cider](https://github.com/Mininglamp-AI/cider/blob/main/tutorial/how_to_write_efficient_int_gemm_m5_en.md))
10. **Decode is dispatch-bound, not kernel-bound.** A hand-rolled Swift/MPSGraph path ran ~**1000 Metal dispatches per token** and hit only 127 GB/s ≈ 23% of M4 Max peak; whole-layer fusion did *not* beat MPSGraph (SDPA fold was 3.6× slower). Custom kernels win **only for big memory-bound matmuls** (FFN, vocab head); per-op kernelization of small ops is futile. ~80% of MLX is the realistic in-design ceiling for that style of engine. ([performance-ceiling](https://github.com/john-rocky/coreai-model-zoo/blob/main/knowledge/performance-ceiling.md), 2026-06-11)
11. **Honest bar for a hand-written GEMM: parity with Apple's bf16.** A 39-file / 303-entrypoint MSL kernel library plus a Rust host measured **1.03× vs PyTorch MPS bf16** and explicitly retracted earlier inflated numbers. ([tessl](https://github.com/bharathvbcr/tessl), re-measured 2026-09-01)
12. **Rust bindings are alive; `metal-rs` is not.** `objc2-metal` 0.3.2 (2025-10, 18.6M recent downloads), `metal` 0.33.0 (2025-12, 8.2M recent); the actual `metal-rs` crate has been dead since **2018**. Zig has no ObjC story: real projects (`cara`) hand-roll `objc_msgSend` + `sel_registerName` to get a `CAMetalLayer`, then use WebGPU rather than raw Metal.

## 3. Language recommendation matrix (5 = best)

| | Perf ceiling | Iteration speed | Ecosystem (tok/safetensors/GGUF) | Safety | Hiring / maintenance | Total |
|---|---|---|---|---|---|---|
| **Swift** | 5 | 5 | 4 | 4 | 5 (Mac) | **23** |
| **Rust** | 4 | 3 | 5 | 5 | 4 | **21** |
| **C++** | 5 | 3 | 5 | 1 | 3 | **17** |
| **Zig** | 3 | 2 | 1 | 3 | 1 | **10** |

**Key insight: the performance ceiling lives in the `.metal` source, which is identical for all four.** Host language moves iteration speed, dispatch overhead and ecosystem, not peak FLOPS. Choose on those.

**Recommendation: Swift for the host engine + MSL for all kernels.**
- No FFI at the Metal boundary (Rust/C++ pay `objc_msgSend`/pointer-marshalling friction on every dispatch — costly when decode is dispatch-bound at ~1000 dispatches/token).
- Best-in-class tooling: Metal Debugger, GPU frame capture, shader debugging, Metal System Trace / Performance HUD, all Metal 4-aware; `MTL4Compiler` + Swift 6 concurrency/actors make multi-threaded encoding and KV-cache ownership clean.
- `swift-transformers` (tokenizers), MLX Swift for reference/fallback, CoreML when you want the ANE as an energy play.
- Escalate to **Rust** if you need GGUF/safetensors breadth and a CLI/server ecosystem fast (BaseRT and tessl are both Rust host + MSL kernels — the strongest 2026 precedent), or if the team is already Rust. Use **C++** only to graft onto llama.cpp/MLX internals. Avoid **Zig** in 2026: no Objective-C interop, no Metal ecosystem, and the Metal API is Objective-C.

**Flagged / unverified:** M5 Max ray-tracing "+35%" is a vendor claim with no independent bench found. BaseRT's engine is shipped as a **prebuilt binary** and its repo contains **no `.metal` files** — the Rust label describes the CLI/converter/bindings, not proven engine internals. Apple's 3.33–4.06× TTFT figure is vs *base* M4 (153 vs 120 GB/s), not vs M4 Max; do not transfer it to 614 GB/s SKUs. `emihiggins` data is one machine, one macOS build, MLX-specific kernels. The macOS 26 vs 27 TensorOps dtype split comes from a third-party SDK-header audit, not Apple docs.
