# Strim Engine — exploration before planning

**Date:** 2026-10-25 · **Machine:** Mac Studio Mac17,14 · M5 Max · 64 GB · macOS 27.0.1
**Status:** research + measurements. No architecture committed, no code written.
**Companion files:** [M5 Max research](m5-max-research.md) · [model selection](model-selection-2026-10.md)

---

## 0. TL;DR

1. **Do not write the GPU kernels from scratch.** On this machine MLX already runs dense decode at
   83–97% of the measured memory-bandwidth ceiling. A hand-written Metal engine has a documented
   track record of **0.5–0.8× MLX**, and our own previous Rust engine is **2.6× slower** than MLX on
   the same model. The realistic upside of a from-scratch kernel engine is +20–35% decode after
   months of work; the downside is losing 2–3×.
2. **Build "from scratch" one layer up:** our own model graph, KV/prefix cache, MTP speculative
   decoder, memory governor, server and agent harness — on top of MLX as the kernel substrate.
   That is where every reproducible win of the last year came from.
3. **The model decision is the biggest single lever.** On 64 GB the real choice is
   **Qwen3.8-27B** (quality) vs **Qwen3.6-35B-A3B** (speed). Both fit, both have MTP heads.
   My lean: **Qwen3.8-27B at 8-bit** as the default, 6-bit for long context; A3B as a speed mode
   only if a quality bake-off says it is close.
4. **MTP / speculative decoding is the biggest speed lever** — measured 2.1–2.4× on M5 Max.
   `mlx-lm` currently *drops* the MTP weights; implementing the MTP head + verifier is the single
   most valuable thing we can own.
5. **Adaptive memory = quantisation ladder + context budget**, not SSD expert streaming.
   Streaming measured ~5 tok/s on a 16 GB M1; it is a dead end for a product.
6. **Language: Swift** for the product layer (MLX Swift, Metal 4 tooling, Swift 6 actors,
   swift-transformers), with a small C++/MSL module only where a measured hotspot justifies it.
   Rust is the runner-up if the product is a headless daemon; it buys safety, not speed.
7. **Before committing: a 10-day measurement sprint** (§9). The decisions above are cheap to test
   and expensive to assume.

---

## 1. The machine, measured

| Property | Value | Source |
|---|---|---|
| Chip | Apple M5 Max, "Fusion Architecture" | `system_profiler` |
| CPU | 18 cores = 6 super + 12 performance | `sysctl hw.perflevel*` |
| GPU | 40 cores, 1 Neural Accelerator per core, Metal 4 | `system_profiler` |
| Neural Engine | 16 cores | Apple specs |
| Unified memory | 64 GiB (68.7 GB) | `hw.memsize` |
| MLX max working set | **60.1 GB** (87.5% of RAM) | `mx.device_info()` |
| Memory bandwidth (spec) | **614 GB/s** | Apple Mac Studio specs |
| Memory bandwidth (measured copy) | **515 GB/s** (~84% of spec) | this session |
| Memory bandwidth (measured matvec) | 528 GB/s (~86%) | independent, 2026-09-27 |
| FP16 matmul (measured) | **57 TFLOPS** (4096³) | this session |
| Disk free | 714 GB | `df` |
| Toolchain | Xcode 27.1, Swift 6.4, Rust 1.99, MLX 0.31.1 installed / 0.32.4 latest, mlx-lm 0.31.2 / 0.32.2 latest | local |

**The roofline that governs everything.** For a single user, decoding is a memory-streaming
problem: each token reads the active weights once.

```
decode tok/s  ≈  effective_bandwidth / bytes_read_per_token
```

At 515 GB/s:

| Model | Bits | Weight bytes | Bandwidth ceiling | Measured | Efficiency |
|---|---:|---:|---:|---:|---:|
| 27B dense | 4 | ~15 GB | 34 tok/s | 29.5 | 87% |
| 27B dense | 6 | ~22 GB | 23 tok/s | 21.2 | 92% |
| 27B dense | 8 | ~29 GB | 18 tok/s | 17.7 | 98% |
| 35B-A3B | 4 | ~1.9 GB active | ~270 tok/s | 110–129 | 41–48% |

Dense models are already at the wall. The MoE is **not** bandwidth-bound: it is bound by dispatch,
routing and small-matrix overhead. That is the only place where engine work still has real headroom,
and it is a scheduling/fusion problem, not a "write a better GEMM" problem.

Prefill is the opposite: compute-bound. 27B prefill measured at ~800 tok/s ≈ 43 TFLOPS ≈ 75% of the
57 TFLOPS peak; the MoE does ~4,000 tok/s with only 3 B active parameters. The M5's Neural
Accelerators (Metal 4 `matmul2d`) help here a lot and almost not at all in decode.

---

## 2. The uncomfortable finding: the engine is not the bottleneck

Our own prior work is the best evidence we have:

| Engine (same machine) | Model | Decode tok/s |
|---|---|---:|
| mlx-lm / TensorFold | Qwen3.6-35B-A3B Q4 | **118–129** |
| Our C engine (streaming) | Qwen3.6-35B-A3B Q4 | 26.8 |
| Our Rust engine (own Metal) | Qwen3.6-35B-A3B Q4 | **45.4** |
| mlx-lm | Qwen3.8-27B Q4 | 29.5 |

We spent months on a 274-file Rust engine with its own Metal backend, batched command encoding,
flash attention, a Metal buffer recycler — and landed 2.6× behind MLX. The industry record agrees:

- DFlash reverted every hand-written kernel (batched GEMV, fused SiLU, custom SDPA) at **0.5–0.8×**
  stock MLX.
- OpenEvolve's best evolved Metal attention kernel was **3.2% slower** than MLX.
- MTPLX's 14-kernel port: **2 wins, 11 losses**, and both wins were prefill fusions where MLX had
  no MMA path.
- A rigorous 39-file MSL GEMM project measured **1.03× vs Apple's own bf16 GEMM** (and retracted
  earlier inflated numbers).
- The one credible counter-example, BaseRT (arXiv 2607.19438), reports **1.33× decode / 3.9× prefill
  vs MLX** on M5 Pro — but its MoE decode lead shrinks to **4–7%**, and it is a serious
  Metal-4-tensor-core engine, not a weekend project.

**Conclusion:** if the goal is maximum speed on this machine, a from-scratch kernel engine is the
most expensive way to get +20–35%, and the most likely way to get −60%. If the goal is *learning*,
it is a great project — but it should be scoped as such.

---

## 3. Where the speed actually is, ranked by measured ROI

| # | Lever | Measured / expected gain | Who does it today | Effort |
|---|---|---|---:|---|
| 1 | **MTP / speculative decode** | **2.1–2.4× decode** (65 → 154 tok/s on M5 Max) | oMLX, vllm-metal, `mlx_lm --draft-model` (classic draft only) | M |
| 2 | **Fused MoE router** | 5 tiny ops → 1: 51 µs → 5 µs per layer; **~22% of a 9 ms step** | oMLX | S |
| 3 | **Burst decode** (32–64 steps per hand-off, one `eval` per step) | **~8%** (80 → 74 tok/s when handoff is per token) | oMLX | S |
| 4 | **Prefix / radix cache** | TTFT on a repeated 30 k context: ~35 s → 1–2 s | mlx-lm server (LRU), oMLX | M |
| 5 | **KV cache int8** | 2× KV capacity, better long-context speed | mlx-lm 0.32 (`--kv-bits 8`) | S |
| 6 | **NAX prefill kernels** | prefill 2–4× (BaseRT: 3.9× vs MLX on M5 Pro); ANE prefill adds ~3–19% | oMLX, BaseRT | M–L |
| 7 | **Lower bits** | 1.5–2× decode, but quality risk | everyone | S |

Note #1 and #2 are not kernel work. They are model-graph and scheduling work — exactly the layer we
should own. Note #7 is free but dangerous: our own lab saw 27B Q4 score **0/6** where Q8 scored 5/6,
so 4-bit is not automatically "the same model, smaller".

Also worth stating: **long context, not GEMM, kills throughput.** On M5 Max the A3B falls from
110.7 tok/s at 16 k to 52.7 at 195 k; the 27B falls from 45 to 24.5 between 1 k and 64 k. An agent
that stuffs 100 k tokens into every turn will feel slow no matter which engine we write.

---

## 4. Model choice on 64 GB

Only models that fit **fully resident** at 4–8 bit are candidates. Everything ≥120 B total is out:
DeepSeek V4 Flash (284 B, ~142 GB at 4-bit), GLM-5 (744 B), GLM-4.7 (355 B), Kimi K2.5 (1 T),
MiniMax M2.1 (~230 B), Qwen3.8-Flash-Next (176 B, ~88 GB at 4-bit and needs custom kernels).
Expert offload would destroy the quality-per-second objective.

| Model | Params | 4-bit | 6-bit | 8-bit | Decode on M5 Max | Prefill | Vendor agentic scores |
|---|---:|---:|---:|---:|---|---|---|
| **Qwen3.8-27B** (dense, hybrid GDN, MTP) | 27 B | ~15 GB | ~22 GB | ~29 GB | 45.2 @1k, 40.2 @16k, 24.5 @64k **(8-bit + MTP)** | 760–818 | TB2.1 **73.0**, SWE-bench Pro **61.7**, NL2Repo 42.3, CoWorkBench 70.7 |
| **Qwen3.6-35B-A3B** (MoE, 3 B active, MTP) | 35 B | ~19 GB | ~27 GB | ~36.6 GB | 110.7 @16k, 86.2 @64k (4-bit); 98.3 @4k, 71.1 @64k (8-bit) | 3,981 | SWE-bench V **73.4**, TB2.0 51.5, SWE-bench Pro **49.5**, NL2Repo 29.4 |
| Gemma 4 31B | 31 B | ~17 GB | — | — | slow, dense | — | SWE-bench V 52.0 — not competitive |
| Gemma 4 26B-A4B | 25 B | ~13 GB | — | — | fast | — | SWE-bench V 17.4 — not usable for coding |

**Caveats.** All scores are vendor-reported on different harnesses (TB2.1 ≠ TB2.0; SWE-bench V ≠
SWE-bench Pro) and cannot be ranked against each other. The 8-bit 27B and 8-bit A3B benchmarks ran on
a 128 GB M5 Max; on 64 GB the same configs fit but with less headroom. Our own small-sample lab
tests pointed the other way from the vendor table: 27B Q8 scored 5/6 and 8/9 where A3B Q4 scored 2/4
and 2/6 — small samples, not decisive, but a warning that quantisation and harness matter more than
the model card.

**Two viable configurations on 64 GB:**

| Config | Weights | 64 k context | Decode | Prefill | Verdict |
|---|---:|---:|---:|---:|---|
| 27B, 8-bit | 29 GB | ~40 GB (tight) | 45 → 24.5 tok/s | ~800 | quality-first, 32 k safer |
| 27B, 6-bit | 22 GB | ~33 GB (comfortable) | ~50–55 tok/s (est. with MTP) | ~800 | **best balance if 6-bit quality holds** |
| A3B, 6-bit | 27 GB | ~31 GB | ~100 tok/s (est.) | ~3,900 | speed-first |
| A3B, 4-bit | 19 GB | 25 GB (measured) | 110.7 → 86.2 tok/s | ~4,000 | fastest, lowest quality risk |

**My lean:** default **Qwen3.8-27B 8-bit, MTP on, 32 k context**, with 6-bit available for 64 k+.
It is the newest generation, explicitly built for long-horizon agentic coding, has a tiny KV footprint
(hybrid GDN: only 16 full-attention layers), and fits with ~20 GB of headroom. The A3B is the "speed
mode" candidate, decided by the bake-off in §9 — not by the model card.

The one thing that could change this: if the bake-off shows 27B 6-bit is within one task of 8-bit on
24 tasks, take 6-bit and the extra context. If 6-bit degrades, stay 8-bit. If the A3B 6-bit is within
two tasks of the 27B, the speed/prefill advantage is large enough to reconsider the default.

---

## 5. What "from scratch" should mean

| Option | What we own | Speed | Effort | Verdict |
|---|---|---|---|---|
| **A. Kernel engine** | Metal kernels, graph, everything | 0.5–1.35× MLX (usually <1) | 6–12 months | No, unless the goal is learning |
| **B. MLX + own engine layer** | model graph, KV/prefix cache, MTP decoder, governor, server, harness; MLX kernels underneath | ~1.0× MLX + MTP (≈1.8–2.4× over stock) | 6–10 weeks for v1 | **Recommended** |
| **C. mlx-lm server + harness** | only the product shell | ~1.0× | 1–2 weeks | Prototype only; Python runtime, weak memory control |

Option B is genuinely "from scratch" where it matters. It also keeps the option to add a custom
`mx::Primitive` kernel later, once a profile proves where the remaining milliseconds are — which is
the oMLX and BaseRT pattern.

What we would own in B:

- **Model graph** for one architecture (Qwen3.5/3.6/3.8): gated delta-net linear attention, gated
  full attention, MoE block, MTP head, in Swift or C++ over MLX ops.
- **KV + GDN state management**: int8 KV for the 16 full-attention layers, fp32 recurrent state,
  snapshot/rewind for speculative decoding, prefix/radix cache keyed by block hashes.
- **MTP speculative decoder**: draft with the model's own MTP head, verify, roll back cache on
  rejection. This is the 2× lever and `mlx-lm` does not use it.
- **Memory governor**: wired limit, admission control, context budget, pressure reaction, model
  switch. On 64 GB this is a correctness feature, not a nicety (see §7).
- **Service + harness**: OpenAI-compatible API, tool parser, thinking preservation, subagents.

What we deliberately do not own: GEMM/attention/SDPA kernels, tokenizer, chat templates, quantisation
formats, 140 model architectures. Those are MLX's job and it ships every 3–4 weeks.

---

## 6. Language

The ceiling lives in the `.metal` source, which is the same in every host language. The host language
buys iteration speed, dispatch overhead and ecosystem — not FLOPS.

| | Performance ceiling | Iteration | Ecosystem | Safety | Maintenance | Total |
|---|---:|---:|---:|---:|---:|---:|
| **Swift** | 5 | 5 | 4 | 4 | 5 | **23/25** |
| Rust | 4 | 3 | 5 | 5 | 4 | 21/25 |
| C++ | 5 | 3 | 5 | 1 | 3 | 17/25 |
| Zig | 3 | 2 | 1 | 3 | 1 | 10/25 |

**Recommendation: Swift.** MLX Swift 0.32.3 ships Xcframeworks; Metal 4 debugging (GPU frame
capture, shader debugging, System Trace) is best in Xcode; Swift 6 actors map cleanly onto
single-owner GPU state; swift-transformers covers tokenizers; and a Mac product eventually wants a
native UI. Add a C++ target only for an `mx::Primitive` kernel if profiling demands it.

**Rust** is the credible alternative — we already have 274 files of it, the BaseRT and tessl
precedents are Rust-host + MSL, and mlx-rs/mlx-c work. But it buys safety and a single binary, not
speed, and it slows the model-graph iteration that is 90% of this project. Choose it only if the
product is a headless daemon/CLI and we want to reuse the existing Rust harness.

**C++** only if we need to modify MLX internals or graft llama.cpp. **Zig** no: no Objective-C
interop, and Metal's API is Objective-C.

Note: our old Rust engine's problem was not Rust — it was writing kernels. Moving the same team to
Swift and MLX would have produced a faster engine than the one we have.

---

## 7. Adaptive memory: what works and what doesn't

The previous project's adaptive design (resident / hybrid / SSD-expert-streaming per 16/32/64 GB tier)
was technically impressive and commercially wrong: streaming measured **~5 tok/s decode on a 16 GB
M1**, against 20–40 tok/s for a smaller resident model. Nobody wants the big model at 5 tok/s; they
want the best model that fits.

**Replace it with a quantisation ladder + context budget.** Same family, different footprint:

| RAM | Model | Bits | Weights | Max context (approx) | Decode |
|---:|---|---:|---:|---:|---:|
| 16 GB | a 4–8 B dense model of the same family | 4 | 3–5 GB | 32 k | 60–100 tok/s |
| 24 GB | A3B | 4 | 19 GB | 32 k | ~90 tok/s |
| 32 GB | A3B | 4–6 | 19–27 GB | 64 k | ~85–110 tok/s |
| 48 GB | 27B | 6 | 22 GB | 64 k | ~50 tok/s |
| 64 GB | 27B | 8 | 29 GB | 32–64 k | 45 → 24.5 tok/s |
| 128 GB | 27B | bf16 | 54 GB | 128 k | ~10 tok/s |

Two hard-won constraints from the research:

1. **Never wire 75% of RAM.** The mlx-lm server's default wired limit on 64 GB (48 GB) has produced
   kernel panics, not OOM, when KV grows. Cap at ~44 GB and enforce admission before allocating.
2. **Quantised KV is not universal.** `QuantizedKVCache` exists, but `RotatingKVCache.to_quantized`
   raises `NotImplementedError` on hybrid/sliding-window models. For Qwen3.5/3.8 the full-attention
   layers can be quantised; the GDN recurrent state stays fp32. Verify before promising 4-bit KV.

---

## 8. Proposed architecture (option B)

```
┌──────────────────────────────────────────────────────────────┐
│  App / CLI / OpenAI-compatible server / MCP                  │  Swift
├──────────────────────────────────────────────────────────────┤
│  Agent harness: tools, context manager, thinking, subagents   │  Swift
├──────────────────────────────────────────────────────────────┤
│  Engine: sessions, scheduler, MTP decoder, prefix/radix cache │  Swift
│          KV + GDN state, sampler, memory governor             │
├──────────────────────────────────────────────────────────────┤
│  Model graph: Qwen3.5 GDN + gated attention + MoE + MTP head  │  Swift (+ C++ hot path)
│  Loader: safetensors / MLX-quantised, verified digests        │
├──────────────────────────────────────────────────────────────┤
│  MLX 0.32.x core — Metal 4, NAX, SDPA, quantised matmul       │  pinned, vendored
└──────────────────────────────────────────────────────────────┘
```

Build order:

1. **Week 1–2:** measurement sprint (§9). Upgrade MLX, reproduce the numbers on this machine.
2. **Week 3–5:** model graph + loader + KV/GDN state + greedy decode, one model, exact-token parity
   against a pinned `mlx-lm` reference.
3. **Week 6–7:** MTP speculative decoder, prefix cache, int8 KV, memory governor.
4. **Week 8–9:** server + harness integration; TTFT and token/s gates on a real agent session.
5. **Week 10+:** profile; only then decide whether a custom kernel (MoE router fusion first) is worth
   it. Expected upside 1.2–1.35×; do not schedule it before the profile.

---

## 9. The 10-day measurement sprint (gates before architecture)

Run everything on this machine, one process at a time, quiet host, tokens verified.

| # | Experiment | Method | Gate |
|---|---|---|---|
| 1 | Stack refresh | MLX 0.32.4 + mlx-lm 0.32.2; `--kv-bits 8`, `--prefill-step-size` | ≥10% over 0.31.1 baseline |
| 2 | Baseline matrix | 27B {4,6,8} bit and A3B {4,6,8} bit at 4 k / 16 k / 64 k; decode + prefill + peak | numbers within 10% of published |
| 3 | **MTP A/B** | 27B 8-bit and 6-bit with/without MTP, 3 code prompts × 3 seeds; acceptance rate, net tok/s | **≥1.8× net decode** |
| 4 | **Quality bake-off** | 24 frozen coding tasks × {27B 8b, 6b, 4b, A3B 8b, 6b, 4b}; checker pass + wall time | 6-bit within 1 task of 8-bit; A3B within 2 |
| 5 | Prefix cache | 3-turn agent session on a 30 k repo context; TTFT and hit rate | TTFT ≤ 2 s on turn 2+ |
| 6 | Memory / 64 GB | 27B 8-bit at 64 k; pressure, swap, wired ceiling, admission | peak ≤ 52 GB, no swap growth, no panic |
| 7 | Host overhead | burst decode 1 vs 32 vs 64 steps per eval | ≥5% from bursting |
| 8 | Router fusion (micro) | 5-op router vs single `gather_qmm` at real geometry | ≥15% of step time |

Go/no-go after day 10:
- 27B 8-bit + MTP ≥ 40 tok/s @16 k and ≥ 30 @64 k → quality config viable.
- 6-bit within 1 task of 8-bit → 6-bit becomes default and buys context.
- A3B 6-bit within 2 tasks of 27B 6-bit → speed mode is real; otherwise drop it.
- If MTP does not reach 1.5× on coding prompts, the whole speed thesis weakens — reassess before
  writing any code.

---

## 10. Cost, risks, open questions

**Cost.** Hardware already owned. Licences: MLX MIT, Qwen Apache-2.0. No per-token cost. The only
real cost is engineering time: ~6–10 weeks for a v1 on option B, plus 8–12 weeks if we later decide
to write kernels. Option A is 6–12 months before parity is even likely.

**Risks.**
- *MLX churn*: no stable C++ ABI; pin exact versions and vendor the build.
- *64 GB wired panic*: cap wired memory, admit before allocate, test pressure paths.
- *MTP acceptance* is task-dependent; measure on our prompts, not on a forum benchmark.
- *Quantisation quality*: our own 27B Q4 0/6 result says do not assume 4-bit is free.
- *Model deprecation*: a Qwen3.9-class model will land within ~6 months; the graph layer should make
  a new architecture a 2–3 week port, not a rewrite.
- *macOS 27 + NAX*: MLX has had build breakage on new OS versions; pin and test.

**Open questions I need answered before planning further:**

1. **Goal:** is this a product we will use/sell daily, or a learning/ownership project? Option A is
   defensible only for the second.
2. **Workload:** coding agent (long context, tool loops, quality-critical) or chat/general?
3. **Runtime constraints:** is "no Python in the shipped product" hard? Is a native Swift app
   acceptable, or must it be CLI/daemon/headless?
4. **Memory tiers:** do we actually need 16/32 GB Macs, or is 64 GB the only target for v1?
   That changes the model ladder and the harness.
5. **Timeline/budget:** is 6–10 weeks acceptable, or does v1 need to exist in two weeks?
6. **Old code:** keep the Rust engine as a reference/oracle, or start clean and ignore it?

---

## Appendix — sources

- Prior lab state and measurements: an earlier private lab checkout, not part of this repository.
- M5 Max specs and Metal 4: [Apple Mac Studio specs](https://www.apple.com/mac-studio/specs/),
  [WWDC25-205](https://developer.apple.com/videos/play/wwdc2025/205/),
  [Apple ML research on M5](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)
- MLX releases: [mlx v0.32.4](https://github.com/ml-explore/mlx/releases/tag/v0.32.4),
  [mlx-lm v0.32.0](https://github.com/ml-explore/mlx-lm/releases/tag/v0.32.0),
  [mlx-swift 0.32.3](https://github.com/ml-explore/mlx-swift/releases/tag/0.32.3)
- Engine benchmarks: [oMLX A3B 4-bit on 64 GB](https://omlx.ai/benchmarks/performance/r2xu5xwc),
  [oMLX 27B 8-bit](https://omlx.ai/benchmarks/performance/ow9yn3bm),
  [BaseRT paper](https://arxiv.org/abs/2607.19438)
- Kernel failure record: [metalworking "The Failures"](https://metalworking.vercel.app/glossary/war-stories/the-failures/)
- Models: [Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B),
  [Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)
