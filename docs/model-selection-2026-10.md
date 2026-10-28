# Open-weight model selection for 64 GB Mac Studio (M5 Max, 40c GPU) — 25 Oct 2026

Target: M5 Max 18c CPU / 40c GPU, **614 GB/s** bandwidth, 64 GB unified ([Apple specs](https://images.apple.com/jo/mac-studio/specs/)). 64 GB is an M5 Max–only config. Practical model budget ≈ 44–48 GB after OS + KV.

## Candidates

| Model | Total / Active | Ctx | License | 4-bit | 6-bit | Published scores (vendor unless noted) |
|---|---|---|---|---|---|---|
| **Qwen3.6-35B-A3B** (Apr 2026) | 35B / 3B | 262K (1.01M YaRN) | Apache-2.0 | ~19–20 GB | ~27–28 GB | SWE-bench V **73.4**, TB2.0 51.5, LCB v6 80.4, MMLU-Pro 85.2, AIME26 92.7 |
| **Qwen3.8-27B** (Aug 2026) | 27B dense | 262K (1M YaRN) | Apache-2.0 | ~15 GB | ~22 GB | SWE-bench Pro **61.7**, TB2.1 **73.0**, LCB v6 **90.3**, GPQA 89.2, HLE 30.8 |
| Qwen3.8-Flash-Next (Oct 2026) | 176B (125B+51B emb) / 6B | 262K (1M YaRN) | n/v | ~88 GB ✗ | ✗ | arch preview; no SWE numbers |
| DeepSeek V4 Flash-0731 (31 Jul 2026) | 284B / 13B | 1M | MIT | ~142 GB ✗ | ✗ | TB2.1 **82.7**, DeepSWE 54.4, NL2Repo 54.2 |
| GLM-5 (Feb 2026) | 744B / 40B | 200K | MIT | ~372 GB ✗ | ✗ | AA Intelligence 50 (indep.) |
| GLM-4.7 | 355B / 32B | 200K | MIT | ~178 GB ✗ | ✗ | AA Intelligence 42 (indep.) |
| MiniMax M2.1 | ~230B / ~10B* | ~200K* | Modified MIT | ~115 GB ✗ | ✗ | SWE-bench V 74.0, TB2.0 47.9 |
| Kimi K2.5 (Jan 2026) | 1T / 32B | 256K | Modified MIT | ~500 GB ✗ | ✗ | SWE-bench V 76.8, TB2.0 50.8 |
| Nemotron 3 Super (Mar 2026) | 120B / 12B | 1M | n/v | ~60 GB (too tight) | ✗ | — |
| gpt-oss-120b | 117B / 5.1B | 128K | Apache-2.0 | ~63 GB (MXFP4) | ✗ | superseded |
| gpt-oss-20b | 21B / 3.6B | 128K | Apache-2.0 | ~12 GB | — | superseded (Aug 2025) |
| Gemma 4 26B-A4B | 25.2B / 3.8B | 256K | Apache-2.0 | ~13 GB | ~19 GB | SWE-bench V **17.4**, MMLU-Pro 82.6, LCB 77.1 |
| Gemma 4 31B | 30.7B dense | 256K | Apache-2.0 | ~16 GB | ~23 GB | SWE-bench V 52.0, MMLU-Pro 85.2, AIME 89.2 |

Footprints are calculated (params × bits/8 + ~5% overhead). *MiniMax M2.1 total/active not restated on the card I read — flagged.

## Findings

- **The 64 GB ceiling is brutally selective.** At 4-bit, only models under ~48B total fit. Everything ≥120B total (DeepSeek V4 Flash 284B, GLM-5 744B, Kimi K2.5 1T, MiniMax M2.1 230B, Nemotron 3 Super 120B) needs 60–500 GB — all fail residency ([DeepSeek V4 Flash, MIT, 284B/13B](https://www.opensourceforu.com/2026/08/deepseek-open-sources-v4-flash/), 3 Aug 2026; [GLM-5 744B/40B, ~1.5 TB BF16](https://artificialanalysis.ai/articles/glm-5-everything-you-need-to-know), 11 Feb 2026).
- **Measured on the exact target box** (M5 Max 40c, **64 GB**, Qwen3.6-35B-A3B MLX 4-bit, 23 Aug 2026): **110.7 tok/s decode @16K, 86.2 @64K, 69.2 @128K**; prefill **3,981 / 2,428 / 1,420 tok/s**; peak 21.2 / 25.1 / 30.5 GB. At 195K ctx peak was 40.8 GB of the 64 GB — fits with real headroom ([oMLX](https://omlx.ai/benchmarks/performance/r2xu5xwc)).
- **The dense-vs-MoE gap is the whole story.** Dense Qwen3.8-27B at 8-bit measured **45.2 tok/s @1K, 40.2 @16K, 24.5 @64K** with prefill 760–818 tok/s ([oMLX](https://omlx.ai/benchmarks/performance/ow9yn3bm), 18 Aug 2026). At 6-bit expect ~50–55 tok/s. The 3B-active MoE is **~2.5–3× faster in decode and ~5× faster in prefill** at 8-bit, and ~2× faster at 4-bit, on identical hardware. Dense 27B at bf16 collapses to **9.3 tok/s** (54 GB working set) — pure bandwidth starvation.
- **A3B MoE scales gracefully with context** because KV, not weights, dominates: 4-bit 35B-A3B holds 52.7 tok/s even at 195K context, where a dense model would be far slower.
- **The 8-bit A3B datapoint confirms bit-width is nearly free:** 98.3 tok/s @4K and 71.1 @64K at 8-bit / 36.6 GB vs 110.7 @16K at 4-bit / 21.2 GB. Going 4→6 bit costs ~10–15% speed for a real quality gain ([oMLX 8-bit](https://omlx.ai/benchmarks/performance/f9kg3d0e); [MTP variant](https://omlx.ai/benchmarks/performance/3cjzwp08) hits 107.4 @1K).
- **First-class support exists for exactly three of these.** Qwen3.6-35B-A3B and Qwen3.8-27B both ship as MLX quants and run in LM Studio/llama.cpp/mlx-lm; oMLX shows Gated-DeltaNet kernels, MTP, ANE-offloaded prefill working. Qwen3.8-Flash-Next needs **custom code** — GDN + Qwen Sparse Attention, a 51B N-gram embedding table with NVIDIA-only host offload, and MTP ([vLLM recipe, 13 Oct 2026](https://recipes.vllm.ai/Qwen/Qwen3.8-Flash-Next)). DeepSeek V4 Flash needs FP4 expert kernels + interleaved compressed sparse attention (CSA/HCA) — no MLX path. Kimi K2.5 is vLLM/SGLang/KTransformers only.
- **Agentic coding quality is not where the small models are weakest — it's latency.** Gemma 4 26B-A4B (3.8B active, 13 GB) is fast but scores **SWE-bench Verified 17.4** vs Qwen3.6-35B-A3B's 73.4 — an unusable gap for agentic work ([Gemma 4 card](https://ai.google.dev/gemma/docs/core/model_card_4.md)). Gemma 4 31B at 52.0 is also clearly behind.
- **Llama 5 does not exist** as of Oct 2026; Meta's current open release is Llama 4 and the 30B-class "Muse Glimmer" ([status, Oct 2026](https://ai-garage.jp/news/llama-5-release-status/)). Not a candidate.
- **Vendor-vs-independent caveat:** all SWE-bench/TB numbers above are vendor-reported on differing harnesses (Qwen uses its own Bash+edit scaffold; Qwen3.8-27B uses Claude Code; DeepSeek uses DeepSeek Harness). **TB2.1 and TB2.0 are not comparable** — Qwen3.8-27B's 73.0 (TB2.1) and Qwen3.6-35B-A3B's 51.5 (TB2.0) cannot be ranked against each other. I found **no independent leaderboard score** for either Qwen model; only oMLX community throughput (single-user, n=1 runs).

## Ranked shortlist

1. **Qwen3.6-35B-A3B, 5–6 bit (~24–28 GB) — highest confidence.** SWE-bench Verified 73.4 with 90–110 tok/s decode and ~4,000 tok/s prefill on this exact machine. The only model here that is simultaneously strong at agentic coding *and* fast enough to feel interactive. 6-bit leaves ~35 GB for KV.
2. **Qwen3.8-27B, 4–6 bit (~15–22 GB) — medium-high confidence, quality ceiling pick.** Newer, better on hard agentic suites (SWE-bench Pro 61.7, TB2.1 73.0, LCB 90.3) and 2× smaller on disk, but ~50 tok/s and ~760 tok/s prefill. Choose it if per-token quality matters more than loop latency; expect roughly half the agent iteration speed.
3. **Gemma 4 26B-A4B / 31B — low confidence, fallback only.** Cheap and fast, but agentic coding is well behind; keep as a lightweight utility model, not the primary.
4. **Larger MoE with expert offload — not recommended.** DeepSeek V4 Flash and GLM-5 are the quality leaders on paper (TB2.1 82.7 and ~81), but at 142–372 GB they'd run mostly from SSD. Expert offload over Thunderbolt/USB destroys decode rate and prefill; this contradicts the "quality per token of speed" objective.
5. gpt-oss-20b/120b, Llama 4, MiniMax M2.1, Kimi K2.5 — superseded or non-resident.

**Recommendation:** support **Qwen3.6-35B-A3B** first, default 6-bit (MLX), with 4-bit as the long-context profile; add Qwen3.8-27B as the second model for hard, quality-critical tasks.
