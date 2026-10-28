# Qwen3.8-27B on M5 Max 64 GB / MLX — quant & speed research (as of 2026-10-25)

## 1. Quant options

| Repo | Format / bpw | Size | Reported quality / speed | Conf. |
|---|---|---|---|---|
| [mlx-community/Qwen3.8-27B-4bit](https://huggingface.co/mlx-community/Qwen3.8-27B-4bit) (+8bit) | MLX affine 4.5 / 8.5 bpw | ~15.6 / ~29.5 GB (est.) | Bare mlx-vlm conversion, no evals, no MTP head in card | Low |
| [lmstudio-community/…-MLX-4bit/5bit/6bit/8bit](https://huggingface.co/lmstudio-community/Qwen3.8-27B-MLX-8bit) | 4.5/5.5/6.5/8.5 | ~15.6–29.5 GB (est.) | Only 8-bit has a number: MMLU 85.0% (100q, M2 Max, 2026-10-14) | Low–Med |
| [TensorFold/Qwen3.8-27B-MLX-4bit](https://huggingface.co/TensorFold/Qwen3.8-27B-MLX-4bit) | 4.695 bpw, g64 | 16.06 GB | 39.9 tok/s decode, 20.1 GB peak (M3 Ultra); **no MTP head** | High |
| [Jundot/Qwen3.8-27B-oQ4e-mtp](https://huggingface.co/Jundot/Qwen3.8-27B-oQ4e-mtp) | 4.887 bpw mixed+MTP | 16.97 GB | KL 0.0117 on Python code; engine behind 53–72 tok/s recipe | High |
| [Jundot/…-oQ3.5e-mtp](https://huggingface.co/Jundot/Qwen3.8-27B-oQ3.5e-mtp) | 4.249 bpw mixed+MTP | 14.76 GB | Re-quantized 2026-10-24; no published eval | Med |
| [Youssofal/…-MTPLX-Optimized-Speed](https://huggingface.co/Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed) | "4-bit dynamic" | 20.4 GB dl / 23.6 GB peak | 96.0% top-1, KL 0.012; 87.6 tok/s best (M5 Max, 2026-09-16) | High |
| [Youssofal/…-MTPLX-Optimized-Quality](https://huggingface.co/Youssofal/Qwen3.8-27B-MTPLX-Optimized-Quality) | 8-bit dynamic | 36 GB RAM min | 99.3% top-1, KL 0.0005 | High |
| [unsloth Q4_K_M](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) | GGUF 5.0 | 17.1 GB | 96.9% of Q6_K; matches BF16 on Terminal-Bench 2.1 | High |
| [unsloth Q5_K_M](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) | 5.8 | 19.8 GB | 99.1% of Q6_K; only quant within 3 pts on *every* dataset | High |
| [unsloth Q6_K](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) | 6.7 | 22.9 GB | Reference: 81.4% overall | High |
| [unsloth UD-IQ3_XXS](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) | 3.2 | 10.9 GB | 96.5% of Q6_K ≡ Q4_K_M, 64% the size; Aider −10–17% | High |
| [ISTA-DASLab GSQ-RCO](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF) IQ3_S / IQ2_S | 3.5 / 2.75 | 11.8 / 9.3 GB (+0.35 MTP) | LCB v6 85.71 (=BF16) / 82.29; GPQA 89.39 / 86.36 | High (vendor) |
| [kaitchup SLQ-EAR98](https://huggingface.co/kaitchup/Qwen3.8-27B-SLQ-EAR98) | mixed int, ~98% EAR | 23.7 GB | EAR 98.0%; **vLLM+Huming only — will not run on MLX** | High |
| nvidia / unsloth NVFP4, cyankiwi AWQ-INT4, EXL3 | fp4/int4/exl3 | 10–16 GB | CUDA-only paths | High |
| Ternary "Bonsai 2 27B" | ternary | ~11.4 GB peak | 64.4 tok/s after 4k prompt, quality unverified | Low |

## 2. Findings

- **4-bit ≈ lossless on agentic coding (measured).** Quesma's ~$3k sweep: Q4_K_M (17 GB) matched BF16 (55 GB) on Terminal-Bench 2.1 (89 tasks) and on GPQA-D; 2-bit (10.7 GB) cost ~5 pts; 1-bit collapsed to chance. Blog 2026-08-26, HN 2026-09-08. https://quesma.com/blog/qwen38-27b-quantizations-benchmarked/
- **295-run confirmation, and the cliff is sharp (measured).** 11 unsloth GGUFs, 7 agentic/coding sets: plateau 22.9→8.4 GB at 92.6–99.1% of Q6_K, knee at 8.4 GB, cliff at 7.3 GB (79.6%), collapse at 6.2 GB (8.5%). Report 2026-09-30. https://quanteval.ai/reports/qwen3.8-27b-quantization-cliff.html
- **Aider Polyglot breaks first (measured).** Same report: Aider holds 88–92% down to UD-Q2_K_XL then falls to 70% (IQ2_S) / 36% (IQ2_XXS), while AgentBench-OS and short shell tasks stay >96%. Judge quants on multi-file editing, not averages.
- **Q4 has a small, real code penalty; Q5 is the plateau (measured).** EvalPlus on RTX 5090: Q5_K_M 57.7/45.7, Q6_K 59.3/48.8, Q8_0 56.9/45.7, Q4_K_M 55.0/46.3, Q4_K_XL 57.9/41.5 (MBPP+/HumanEval+). Q8 bought nothing over Q6. 2026-08-27. https://umarsalim.com/blog/quantising-qwen3-8-27b-where-quality-plateaus/
- **GGUF-only recipes are not MLX options.** GSQ/RCO (arXiv 2604.18556 / 2605.00649) is a llama.cpp/Ollama/LM Studio GGUF; SLQ-EAR needs vLLM+Humming on Blackwell. Both are excellent value but irrelevant to an M5 Max MLX stack.
- **MTP is the single biggest decode lever (measured).** M4 Max, oQL4e: raw 24.6 tok/s → 53.3 prose / 72.1 code at k=3; acceptance 99.6% on code (3.76 tok/cycle) vs 78% prose. k=4 gains +1.2 on code but loses 5.4 on prose. 2026-08-21. https://github.com/Weschera/Qwen3.8-27B-oMLX-MTP-Mac
- **ANE prefill helps decode indirectly (measured).** 64 MLP layers on the Neural Engine: 4K prefill 83 → 274 tok/s (3.3×) and decode +11%, because prefill no longer blocks decode in shared engine steps. Fraction 0.5 is the sweet spot; 0.75 was worse. Same source.
- **On 48 GB, ANE prefill can backfire (anecdotal).** Korean M5 Pro/48 GB comparison of oQ4e vs AWQ-5.0bpw vs oQ6e (TurboQuant KV 8-bit) had to switch ANE off: model hit ~56 GB with >24 GB swap. 2026-08-20. https://blog.naver.com/hoistudio/224384459306
- **DFlash2 ≈ 3.8× over plain decode (measured, vendor).** M5 Pro 64 GB: 16.2–16.6 tok/s un-drafted → 45.9–62.8 with `z-lab/Qwen3.8-27B-DFlash2`; 140k context at 43.69 GiB peak; prefix resume 0.25–0.69 s. Uses `iogpu.wired_limit_mb=56320` (88%). https://github.com/ashhart/TensorFold/blob/main/docs/recipes/qwen3.8-27b.md
- **TurboQuant KV is real but unquantified.** oMLX exposes `turboquant_kv_enabled`, `kv_bits` (4), `skip_last`; one sibling repo claims 5× smaller KV at 32k with no decode cost. No controlled Qwen3.8 quality study found — treat the 5× as vendor claim.
- **No smaller 2026 model beats it on quality-per-GB for coding (composite, 2026-10-24).** Coding/Agents: Qwen3.8-27B 119/122 @17.9 GB; Gemma 4 31B IT 107 @21.7; Qwen3.6 35B-A3B 105 @22.0; Gemma 4 26B-A4B 104 @16.5; GPT-OSS-20B 102 @13.1. Qwen3.8-27B is also the only one with an agentic score at all. https://llmrun.dev/benchmark/llmrun-score/coding?vram=64
- **No evidence of Qwen3.8-14B/8B.** Multiple searches returned nothing; GLM-4.7-Flash exists (AWQ-4bit) but has no coding-agent numbers in the rankings I checked. Don't budget for a smaller sibling that isn't there.

## 3. Warnings

- `0bserverx/…Heretic-Abliterated-Uncensored-GGUF`: **all RVN GGUFs missing `tokenizer.chat_template`** → tool calling and thinking control broken (discussion #8, Aug 2026).
- `TensorFold/Qwen3.8-27B-MLX-4bit`: **no MTP head** — you get zero MTP speculation unless you add a drafter.
- Jundot oQ4e/oQ3.5e were **re-quantized** (2026-10-11, 2026-10-24); oQ3.5e also notes "Better Low-Bit oQ". Stale local copies are silently worse — re-download.
- Unsloth **replaced its v2 GGUFs on 2026-08-19**; Quesma's tested files no longer exist (reproducibility caveat).
- oMLX **v0.6.3rc2 had a severe MTP accept-rate regression** on M3 Max (−50–70% TG vs 0.6.2): https://github.com/jundot/omlx/issues/2978. Pin a version and bench before/after.
- oMLX ≤0.6.1 **overestimated hybrid KV size 4×**, causing false OOM on Qwen3.5/3.6/3.8; fixed in 0.6.3rc2. Chat-template "fix" repos (e.g. `froggeric/Qwen-Fixed-Chat-Templates`) exist because some conversions ship the wrong one — verify tool-call rendering before trusting an agent loop.
- `moe_expert_offload_*` flags in oMLX are **inert on this dense model**; "expert cache" tuning does not apply.

## 4. Shortlist for M5 Max 64 GB

1. **Jundot/Qwen3.8-27B-oQ4e-mtp (16.97 GB)** — best-documented MLX 4-bit for this exact engine; keeps MTP, KL 0.0117 on code. Pair with MTP k=3 + ANE prefill.
2. **TensorFold/Qwen3.8-27B-MLX-4bit (16.06 GB) + z-lab DFlash2 drafter** — highest measured decode on 64 GB Apple silicon (46–63 tok/s), but no MTP head, so it lives or dies by the drafter.
3. **unsloth Q5_K_M (19.8 GB) if you ever use GGUF** — the only quant within 3 pts of Q6_K on every dataset; Q6_K/Q8 are not worth 3–7 GB here.
