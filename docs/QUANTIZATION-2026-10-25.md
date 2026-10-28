# Quantization and efficiency — findings and revised default

**Date:** 2026-10-25 · **Machine:** M5 Max 64 GB · **Model:** Qwen3.8-27B (dense, hybrid GDN, MTP)
**Status:** measurement + research. Supersedes the "8-bit default" line in [PLAN-v1.md](PLAN-v1.md).

---

## 1. What we just measured on this machine

Same prompts (4,108 tokens, code-ish), greedy, 256 generated tokens, 2–3 runs, MLX 0.32.4,
mlx-vlm 0.7.10, quiet machine.

| Config | Weights on disk | Decode | Prefill | Peak | Notes |
|---|---:|---:|---:|---:|---|
| 8-bit, no speculation | 29.5 GB | **17.2 tok/s** | 532 tok/s | 32.7 GB | at 98% of the 515 GB/s bandwidth bound |
| 8-bit + MTP drafter (0.45 GB) | 30.0 GB | **33.3 tok/s** | 597 tok/s | 33.1 GB | **1.94× decode**, lossless (verification) |

The MTP result is the first hard confirmation of the project thesis on this machine: **+94% decode
for +1.6% bytes**, no quality change. It also means the 8-bit config is now clearly wrong from a
product standpoint — it pays 30% more memory than 6-bit for 0.3% perplexity and 25% less speed.

The MTP drafter is `mlx-community/Qwen3.8-27B-MTP-8bit`, a 0.45 GB split of the model's own MTP head,
loaded by `mlx-vlm --draft-model ... --draft-kind mtp`. The base checkpoints do **not** contain the
`mtp.*` tensors.

---

## 2. The quality evidence for lower bits

The only controlled, paired, same-machine study of Qwen3.8-27B quantization found
([avlp12/Qwen3.8-27B-Alis-MLX-6bit](https://huggingface.co/avlp12/Qwen3.8-27B-Alis-MLX-6bit), 2026-08-22,
~103 k tokens, per-token paired PPL, 95% CI):

| Format | True bpw | Size | Δ en | Δ ko | Δ code (CPython) |
|---|---:|---:|---:|---:|---:|
| affine 8-bit gs64 | 8.5 | 29.5 GB | +0.05% | +0.05% | +0.01% |
| **affine 6-bit gs64** | 6.5 | **22.6 GB** | **+0.33%** | **+0.11%** | **+0.24%** |
| 6-bit + graded 8-bit tensors | 6.44 | 22.3 GB | — | — | **−18.9% excess NLL** vs uniform 6-bit (t = −7.3) |
| 4-bit AWQ gs64 | 4.5 | 15.6 GB | +1.2% | +2.7% | **+7.7%** |
| 3-bit affine | 3.5 | 12.2 GB | — | — | visibly worse (TQ 8.01 vs 7.27 PPL) |

Key conclusions:

1. **6-bit is effectively free.** +0.24% on code, Korean CI includes zero. This is noise for any
   product decision.
2. **4-bit is a different quality class on code.** +7.7% PPL is not "the same model, smaller"; it is
   the difference the earlier lab runs saw (27B Q4 scoring 0/6 where Q8 scored 5/6).
3. **Graded allocation beats uniform bits.** Moving five *small* groups to 8-bit — `k_proj`, `v_proj`,
   GDN `in_proj_a`/`in_proj_b`, `lm_head` — bought −18.9% excess NLL for +1.6% bytes. Spending the
   same bytes on arbitrary mid-depth FFN tensors bought only −1.2%. The sensitive tensors are the
   boundary ones: layer-0 KV (56× average), `lm_head` (8×), early layers (10×), last blocks (6.8×).
4. **5-bit is the open question.** No published 27B-quality number. Size ~19.1 GB (affine) or
   17.4 GB (AWQ 5.0 bpw). One 5.0 bpw AWQ card reports 503/564 vs bf16 507/564 on a code eval — close,
   but n=564 and single-party. It must go through our 24-task bake-off before it becomes a default.

Cross-checks: an independent multi-format sweep (Quesma, 2026-08-26; quanteval, 2026-09-30) finds
4-bit GGUF matching BF16 on Terminal-Bench 2.1 / GPQA-D for agentic tasks, with degradation appearing
at ~7 GB (2-bit) and collapse at ~6 GB (1-bit). Aider Polyglot degrades first; short/shell tasks hold.
So "4-bit is fine" is true for some task mixes and false for code-heavy ones — exactly why we measure
our own tasks rather than trust a leaderboard.

---

## 3. What does *not* help

| Idea | Verdict |
|---|---|
| **TurboQuant weights** (Hadamard + Lloyd-Max) | **Reject.** PPL 7.2496 vs 7.2685 (−0.3%) but **11.3 vs 29.7 tok/s** on exactly this model. |
| **MXFP4 / NVFP4 as mlx-lm ships them** | Worse than affine at equal bpw (+4.3% / +5.0% PPL vs +2.7%). Native, but not a quality win. |
| **4-bit KV everywhere** | Catastrophic without layer-0 protection (PPL 21.2 → 507 on a small model). On this hybrid only 16/64 layers cache; at 16 k it saves 0.77 GB for ~3% decode. Only worth it >32 k, and only 8-bit. |
| **SLQ-EAR98** (23.7 GB) | vLLM/Humming only; cannot run on MLX. |
| **Ternary 2-bit** (5.9 GB, 98.2% avg) | The only genuine step change, but vendor evidence and a vendor runtime; ~47 tok/s via llama.cpp. Watch it, don't build on it yet. |
| **AWQ as a general win** | An independent audit of 1.5–8 B code models found AWQ statistically indistinguishable from RTN; the win is at 5 bpw, not 4.5. |

---

## 4. Revised recommendation

**Default: affine 6-bit gs64, graded with 8-bit `k_proj`, `v_proj`, `in_proj_a`, `in_proj_b`, `lm_head`;
norms, `A_log`, `dt_bias`, conv1d, vision tower at bf16. ~22.3 GB. Plus the MTP drafter.**

Expected on this machine: **~40–45 tok/s decode @4k** (21 tok/s no-MTP × 1.94), prefill ~600 tok/s,
peak ~26 GB — i.e. faster than the current 8-bit config while using 7 GB less and losing 0.3% PPL.

Then, in order:

1. **Measure stock 6-bit + MTP** (`lmstudio-community/Qwen3.8-27B-MLX-6bit`, downloading) — confirms
   the projection before we build a graded conversion.
2. **Produce the graded 6-bit locally** with `mlx_lm.convert --q-bits 6` + `quant_predicate`
   (or `mlx_lm.dynamic_quant`, which measures per-layer sensitivity and defaults to 4/5-bit — set
   target 6.0). Needs the bf16 source (55 GB download) once.
3. **Test 5-bit graded (19.6 GB) + MTP** against 6-bit on the 24-task bake-off. If within one task,
   it is the new default: ~50 tok/s at 20 GB.
4. **4-bit only with task evidence**, and prefer AWQ **5.0 bpw** (17.4 GB) over 4.5 bpw if pursued.
5. **KV int8 only above 32 k context**, with `--quantized-kv-start 8192`; never uniform 4-bit.

Everything else stays as in [PLAN-v1.md](PLAN-v1.md): MLX substrate, Swift engine layer, prefix cache,
memory governor, 64 GB only. The only plan edit is the default checkpoint and the addition of a
graded-quant step in Phase 1/2.

---

## 5. Efficiency hacks worth testing (community-measured)

| Hack | Reported effect | Status |
|---|---|---|
| MTP draft depth k=3 (vs 2/4) | 24.6 → 53–72 tok/s on M4 Max; acceptance 99.6% code, 78% prose | test k=2/3/4 on our prompts |
| ANE prefill (64 MLP layers) | 4 k prefill 83 → 274 tok/s, decode +11%; fraction 0.5 optimal | risky: 48 GB M5 Pro hit 56 GB footprint + swap; test on 64 GB only with a governor |
| DFlash2 drafter | 16 → 46–63 tok/s on M5 Pro; 140 k ctx at 43.7 GB | alternative to MTP if acceptance is poor |
| Prefix/radix cache | TTFT 35 s → 1–2 s on repeated 30 k context | already in the plan |
| Wired limit | `iogpu.wired_limit_mb=56320` used by DFlash2 | needs a hard cap; kernel panics otherwise |
| `--prefill-step-size` | small prefill gains | free to tune |

No smaller model beats Qwen3.8-27B per GB: llmrun composite (2026-10-24) scores it 119/122 at
17.9 GB, ahead of Gemma 4 31B (107 @21.7), Qwen3.6-35B-A3B (105 @22.0) and Gemma 4 26B-A4B
(104 @16.5). It is also the only one of these with an agentic score. Qwen3.8-14B/8B does not exist.

---

## 6. Open measurements (next 48 h)

1. Stock 6-bit + MTP @4k and @16k — gate: ≥38 tok/s @4k, ≥30 @16k.
2. MTP depth sweep k=2/3/4 — gate: best net tok/s, acceptance per prompt type.
3. 5-bit stock + MTP (download `lmstudio-community/Qwen3.8-27B-MLX-5bit`, 19.1 GB) — gate: ≥45 tok/s.
4. 24-task bake-off on {8-bit, 6-bit, 5-bit, 4-bit} — gate: 6-bit within 1 task of 8-bit; 5-bit within 1 of 6-bit.
5. 64 k memory with 6-bit + int8 KV — gate: peak ≤ 45 GB, no swap growth.

---

## 7. Update (same day): MTP changes the quantization decision

Speculative decoding is not quant-neutral. Measured on this machine, 4,108-token prompt, 256 tokens,
2–3 runs after warm-up:

| Config | Decode @4k | Prefill | Peak | vs no-MTP |
|---|---:|---:|---:|---:|
| 8-bit | 17.2 tok/s | 532 | 32.7 GB | — |
| **8-bit + MTP-8** | **33.3 tok/s** | 597 | 33.1 GB | **1.94×** |
| 6-bit | 23.4 tok/s | 672 | 26.0 GB | — |
| **6-bit + MTP-8** | **21.2 tok/s** | 695 | 26.4 GB | **0.91×** |
| 4-bit | 31.6 tok/s | 722 | 19.2 GB | — |
| **4-bit + MTP-4** | **51.1 tok/s** | 741 | 19.5 GB | **1.62×** |

The 6-bit case is not noise: acceptance is identical to 8-bit (2.58 accepted tokens/round, 79.2% of
drafted, 12 rounds) yet verification is slower than plain decode. A microbenchmark of
`quantized_matmul` at M=3 shows 6-bit at 326 µs vs 8-bit at 278 µs and 4-bit at 277 µs per 4096²
projection — the small-batch 6-bit path is the slow one, and it is paid on every layer of every
verification step. MLX 0.32's `qmv_wide`/JIT GEMV work covers 4-bit and 8-bit paths, not 6-bit.

Consequences:

1. **6-bit is no longer the default.** It is the best *non-speculative* config (23.4 tok/s, +0.24%
   code PPL) but MTP makes it slower than doing nothing.
2. **4-bit + MTP is the speed leader**: 51.1 tok/s at 19.5 GB, 1.6× over 4-bit alone and 1.55× over
   8-bit + MTP, at half the memory. Its quality is the open question.
3. **8-bit + MTP remains the quality-safe config**: 33.3 tok/s, 30 GB, +0.01% PPL.
4. **5-bit is now lower priority** — it likely shares the 6-bit small-batch path and would lose MTP
   the same way. Test only if 4-bit fails the task bake-off.

Quality evidence so far (three-task suite, 12 steps): `spec-from-tests` passes on both 6-bit and
4-bit (31 and 30 hidden tests); `debug-flaky-concurrency` fails on both 8-bit and 6-bit (out-of-order
stress failure). The 4-bit run of the concurrency task is the next discriminator.

**Interim default: 4-bit + MTP**, gated on the 24-task bake-off; 8-bit + MTP as the quality mode.

---

## 8. Prefill fix and final 4-bit config (same day)

The default mlx-vlm prefill step was leaving ~2× on the table. `--prefill-step-size 2048`:

| Context | Prefill default | Prefill step 2048 | Decode |
|---|---:|---:|---:|
| 1k | 387 tok/s | **909 tok/s** | 33.1 (no MTP) |
| 4k | 722 tok/s | **994 tok/s** | 32.6 (no MTP) |
| 4k + MTP | — | **1,000 tok/s** | **57.7 tok/s** |

Final measured config: **4-bit + MTP-4 + prefill-step 2048 → 57.7 tok/s decode, ~1,000 tok/s prefill,
19.5 GB peak, 4k TTFT ≈ 4.1 s.** That is 1.8× the 8-bit + MTP decode, 2.4× the prefill, and 10 GB
smaller.

Quality repeat on the hardest TypeScript task (`linked-recipe-macros`, 20 steps):
4-bit **3/3 PASS** (254 s, 393 s, 416 s), 8-bit **1/1 PASS** (280 s). No test files touched in any run.

---

## 9. Long context (same day)

Locked config, `--prefill-step-size 2048`, MTP-4 drafter, 4-bit:

| Context | Prefill | Decode | Peak | Needle (ZX-4417) |
|---|---:|---:|---:|---|
| 16 k | 970 tok/s | 48.7 tok/s | 20.4 GB | **PASS** |
| 64 k | 788 tok/s | 35.5 tok/s | 24.3 GB | **PASS** |

4k TTFT ≈ 4.1 s, 64k TTFT ≈ 83 s (cold prefill; prefix cache removes it on later turns).
Memory at 64k is 24.3 GB — 28 GB below the 52 GB budget, so the context can grow further if needed.

**int8 KV was rejected**: at 64k it made things worse — prefill 685 vs 788 tok/s, decode 26.3 vs
35.5 tok/s, peak **28.5 vs 24.3 GB**. The quantized-cache path allocates both caches during
conversion and is slower on this hybrid model. Keep fp16 KV.
