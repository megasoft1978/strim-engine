# Qwen3.8-27B quantizations per Mac memory tier: research and test plan (2026-10-27)

Scope (owner, 2026-10-27): only quantizations of the SAME Qwen3.8-27B (+ its MTP head). No other models.
Read-only research; nothing downloaded. All HF numbers pulled via the public HF API on 2026-10-27 (sizes = sum of weight files, GiB = 2^30).
Reliability tags: **[card]** vendor/author model card, **[repro]** third-party benchmark with method published, **[community]** unverified blog/forum/repo, **[computed]** derived by us from cited inputs, **[internal]** our own earlier docs/measurements (re-used, not re-run today).
Hypotheses are labelled HYPOTHESIS. Where no data exists the text says GAP.

## 0. Base facts (computed from the official config)

Source: `https://huggingface.co/Qwen/Qwen3.8-27B/raw/main/config.json` and card, 2026-10-27 [card]. model_type `qwen3_5_text`, 64 layers = 48 Gated-DeltaNet + 16 gated full-attention (every 4th), hidden 5120, 24 Q / 4 KV heads, head_dim 256, vocab 248,320, untied lm_head, 1 MTP layer, 262,144 ctx native, Apache-2.0. 27.78 B params in the checkpoint = 26.896 B language backbone + 0.461 B vision encoder + 0.425 B MTP head (split from the oQ4e card [card], `https://huggingface.co/Jundot/Qwen3.8-27B-oQ4e-mtp`).

| quantity | value | tag |
|---|---|---|
| Full-attn KV per token (bf16) | 16 layers x 2 x 4 heads x 256 x 2 B = **64 KiB** (32K=2 GiB, 128K=8 GiB, 256K=16 GiB) | [computed] |
| KV with q8 / q4 (affine g64, scale+bias fp16 -> 8.5/4.5 bits) | **34 / 18 KiB** per token | [computed] |
| GDN recurrent state per sequence | 48 layers x 48 heads x 128 x 128 x 4 B = 144 MiB + conv ~ **147 MiB** (fp32, not quantizable) | [computed], matches [internal] docs/MEMORY-2026-10-26.md |
| Affine g64 true bits/weight | bits + 0.5 (fp16 scale + bias per 64). g32 = bits+1.0, g128 = bits+0.25 | [computed] |
| Text-only weight bytes = 26.896 B x bpw / 8 | 2-bit 7.83, 3-bit(3.5) 10.96, 4-bit 14.09, 5-bit 17.22, 6-bit 20.35, 8-bit 26.61 GiB | [computed]; checks: mlx-community 4-bit repo 14.95 GiB = 14.09 + 0.86 GiB bf16 vision tower; lmstudio 6-bit 21.21 = 20.35 + 0.86 |
| MTP head | 0.22 GiB (4-bit) / 0.42 GiB (8-bit) as separate overlay repos; 0.29 GiB inside oQ4e | [card] |

The vision tower (0.86 GiB bf16) is dead weight for Strim; all "repo size" figures below include it unless stated.

## 1. Memory tiers: what is really usable

### 1.1 GPU wired limit (the hard cap for MLX weights + KV)

- **Measured on this Mac** (M5 Max, 64 GB, macOS 27.0.1): `sysctl iogpu.wired_limit_mb` = 57344, and a Metal probe prints `recommendedMaxWorkingSetSize` = **56.0 GiB = 87.5 % of RAM**. No `/etc/sysctl.conf` exists, so this is either the OS default for macOS 27 or a value set earlier; I could not tell which [computed, 2026-10-27]. Probe source (compile with `swiftc`): `import Metal; print(Double(MTLCreateSystemDefaultDevice()!.recommendedMaxWorkingSetSize)/1073741824)`.
- Other published data points are inconsistent and on older macOS: 32 GB M2 Max, macOS 26.5.2: default `iogpu.wired_limit_mb`=0, recommendedMax 24.96 GiB (78 %) [community] `https://modelpiper.com/blog/iogpu-wired-limit-mb-mac` (2026); 128 GB M5 Max, macOS 26.6.2: 107.52 GiB (84 %) [community] `https://github.com/evanwtf/local-llm/issues/30`; 64 GB M1 Max: 49152 MB (75 %) [community] `https://github.com/ggml-org/llama.cpp/discussions/2182` (older). The commonly quoted "75 %" is therefore a lower bound, not a rule.
- **GAP:** no sourced default for 8, 16, 24, 36, 48 GB on macOS 27. **First test-plan step: run the Metal probe on a real machine of each tier.** Until then the tables use B_low = 75 % and B_high = 87.5 % of RAM.
- Raise: `sudo sysctl iogpu.wired_limit_mb=<MiB>` (resets at reboot; `=0` restores default; key name is `debug.iogpu.wired_limit` in bytes on pre-Sonoma). Wired memory cannot be paged or compressed; over-raising stalls or hangs the machine; sources advise staying below ~90 % of RAM [community, same two URLs]. Needs sudo: owner step, never automatic.

### 1.2 Usable budget for Strim

Usable U = min(B, RAM - 5.5 GiB). The 5.5 GiB (macOS ~3.5 + one browser/editor ~2) is an **assumption, to be measured** (`vm_stat`/footprint of a clean login on each tier). Fixed engine overhead F = weights(text) + MTP 0.3 + GDN 0.15 (1 seq) + 2.5 (MLX cache limit ~1, one 1K prefill chunk transient ~0.8 [internal], runtime ~0.7) [computed/assumed]. Prefix-trie memory is NOT included: every cached node costs real GiB (~1.2 GiB/node today, [internal] docs/MEMORY-2026-10-26.md), so small tiers must run with the trie off or tiny.

| RAM | B_low (75 %) | B_high (87.5 %) | U (low / high) |
|---|---:|---:|---:|
| 8 GB | 6.0 | 7.0 | **2.5** / 2.5 |
| 16 GB | 12.0 | 14.0 | **10.5** / 10.5 |
| 24 GB | 18.0 | 21.0 | **18.0** / 18.5 |
| 32 GB | 24.0 | 28.0 | **24.0** / 26.5 |
| 36 GB | 27.0 | 31.5 | **27.0** / 30.5 |
| 48 GB | 36.0 | 42.0 | **36.0** / 42.0 |
| 64 GB | 48.0 | 56.0 (measured) | **48.0** / 56.0 |

### 1.3 Does the 27B fit, and with how much context (computed)

Context = (U - F) / KV-bytes-per-token, in thousand tokens, bf16-KV / q8-KV; "no" = F >= U. Model ctx cap 262K, so numbers above 256K are just "full". Single sequence, no trie. All computed with the formulas of section 0.

| tier | 2-bit g64 (F 10.8) | 3-bit mixed ~3.7 bpw (F 14.6) | 4-bit g64 (F 17.0) | oQ4e ~4.9 (F 18.0) | 5-bit (F 20.2) | 6-bit (F 23.3) | 8-bit (F 29.6) |
|---|---|---|---|---|---|---|---|
| 8 GB | no | no | no | no | no | no | no |
| 16 GB | no (10.8 > 10.5) | no | no | no | no | no | no |
| 24 GB low / high | 118K/222K / 126K/238K | **55K/105K / 64K/120K** | 15K/29K / 23K/45K | no / 8K/16K | no | no | no |
| 32 GB | 216K/407K+ | 154K/290K | 114K/214K (low) 154K/291K (high) | 98K/185K - 139K/262K | 62K/118K - 103K/195K | 11K/21K - 52K/98K | no |
| 36 GB | full | 203K+ | 163K/307K - 220K+ | 147K - 205K | 111K/210K - 169K | 60K/114K - 117K/221K | no - 15K/28K |
| 48 GB | full | full | 310K+ | 295K+ | 259K/488K+ | 208K/391K - 306K | 105K/198K - 203K/383K |
| 64 GB | full | full | full | full | full | 404K+ | 302K/568K - 433K/815K |

Verdicts per tier:
- **8 GB: does not fit.** Even the smallest sane 27B (2-bit, 7.83 GiB weights) exceeds the whole GPU budget (6-7 GiB) before KV, MTP, state or the OS. IQ1_S GGUF is 5.77 GiB [card, unsloth] and 1-bit is near-random on GPQA (Quesma below). No.
- **16 GB: does not fit in practice.** 2-bit needs 7.83 + 0.3 + 0.15 + ~2.5 = 10.8 GiB vs U = 10.5 GiB (RAM - 5.5), i.e. negative headroom for any KV. Even raising the wired limit to the 90 % edge (14.4 GiB) leaves the macOS + apps with 1.6 GiB, which is swap-thrash territory. Only technically possible with a ~2.5 bpw learned format, ~1-2 GiB KV (~30-60K q8), nothing else running, and a 2-bit model of unknown agent quality (section 2.5). Not a product tier.
- **24 GB: fits only at <= ~3.7 bpw (or 4-bit with <= 45K context).** See section 2.5 on whether 3-bit is usable.
- **32 GB: 4-bit class + MTP, 100-290K context.** 5-bit possible at high B.
- **36 GB: 5-bit comfortable; 6-bit with 60-220K.**
- **48 GB: 6-bit comfortable; 8-bit with 105-380K.**
- **64 GB: 8-bit reference fits with 300K+; 6-bit is the product default (internal).**

### 1.4 Decode speed ceilings (bandwidth-bound, computed)

tok/s ceiling = bandwidth / bytes read per token. Bytes per token = (backbone params - embedding table 1.27 B) x bpw/8 (embedding row lookups are negligible; lm_head is fully read). KV read at <= 64K is small vs weights and ignored. These are **ceilings**: [internal] measured 8-bit at 98 % of the 515 GB/s bound on the M5 Max (17.2 tok/s, no MTP) and MTP gave 1.94x (33.3 tok/s) on the same box, lossless by verification; do not assume the same acceptance on other quants.

Bandwidth (Wikipedia Apple-silicon table, 2026-10-27 [community-reference] `https://en.wikipedia.org/wiki/Apple_silicon`; M5 family also from Apple support pages via search): M1 68.25; M1 Pro 204.8; M1 Max 409.6; M2 102.4; M2 Pro 204.8; M2 Max 409.6; M3 102.4; M3 Pro 153.6; M3 Max 307.2 or 409.6; M4 120; M4 Pro 273; M4 Max 410 or 546; M5 153.6; M5 Pro 307.2; M5 Max 460.8 (32-core GPU) or 614.4 (40-core). Max RAM: M1 16, M2 24, M3 24, M4 24, M5 32, M5 Pro 64; M3 Pro 36, M4 Pro 64, M5 Max up to 128.

Bytes read per token: 2-bit 8.0 GB, 3.7-bit 11.9, 4-bit 14.4, ~4.9-bit 15.4, 5-bit 17.6, 6-bit 20.8, 8-bit 27.2.

| chip (GB/s) | 3.7-bit | 4-bit | 5-bit | 6-bit | 8-bit |
|---|---:|---:|---:|---:|---:|
| M1 (68) | 5.7 | 4.7 | 3.9 | 3.3 | 2.5 |
| M2 / M3 (102) | 8.6 | 7.1 | 5.8 | 4.9 | 3.8 |
| M4 (120) | 10.1 | 8.3 | 6.8 | 5.8 | 4.4 |
| M5 / M3 Pro (153.6) | 12.9 | 10.7 | 8.7 | 7.4 | 5.6 |
| M1/M2 Pro (204.8) | 17.2 | 14.2 | 11.6 | 9.8 | 7.5 |
| M4 Pro (273) | 22.9 | 18.9 | 15.5 | 13.1 | 10.0 |
| M5 Pro (307) | 25.8 | 21.3 | 17.4 | 14.8 | 11.3 |
| M5 Max 32c (461) | 38.7 | 32.0 | 26.2 | 22.1 | 16.9 |
| M5 Max 40c (614) | 51.6 | 42.6 | 34.9 | 29.5 | 22.6 |

Reading: a 24 GB base-chip Mac (100-120 GB/s) caps at ~9-10 tok/s at 3.7 bpw before MTP (HYPOTHESIS: ~16-19 with MTP at 1.7-1.9x). That is slow for agent loops regardless of fit.

## 2. Available quantizations of Qwen3.8-27B

### 2.1 MLX affine, uniform (official-ish converters)

| repo | format | GiB | date | dl / likes | MTP head |
|---|---|---:|---|---|---|
| `lmstudio-community/Qwen3.8-27B-MLX-4bit` | affine 4 g64 | 14.95 | 2026-08-14 | 3.59 M / 115 | no |
| `lmstudio-community/Qwen3.8-27B-MLX-5bit` | affine 5 g64 | 18.08 | 2026-08-14 | 3.40 M / 17 | no |
| `lmstudio-community/Qwen3.8-27B-MLX-6bit` | affine 6 g64 | 21.21 | 2026-08-14 | 3.42 M / 39 | no |
| `lmstudio-community/Qwen3.8-27B-MLX-8bit` | affine 8 g64 | 27.48 | 2026-08-14 | 3.43 M / 51 | no |
| `mlx-community/Qwen3.8-27B-4bit` / `-8bit` / `-bf16` | affine 4 / 8 g64 / bf16 | 14.95 / 27.48 / 50.96 | 2026-08-14 | 881K / 27.6K / 4.3K dl | no |
| `mlx-community/Qwen3.8-27B-MTP-4bit` / `-8bit` / `-bf16` | **overlay only**: MTP head | 0.22 / 0.42 | 2026-08-14 | 11.6K / 2.8K dl | this IS the head (separate repo; matches our "separate MTP head" design) |
| `keXjos/Qwen3.8-27B-mlx-2Bit`, `0xSojalSec/...-2bit` etc. | affine 2 g64 | 7.83 | 2026-08 | ~1K dl | no |
| `Chungulus/Qwen3.8-27B-MLX-3bit-Group32` | affine 3 g32 | 13.39 | 2026-08-16 | 78 dl | no |

All [card]. Card claims are only "converted with mlx-vlm". No eval on any of these. Sizes verified against section 0 arithmetic. g32 / g128 uniform repos are rare (the only g128 found is the GPTQ one below).

mxfp4 / nvfp4 / mxfp8 (MLX modes, `mlx-community/Qwen3.8-27B-mxfp4` 14.17 GiB g32, `-nvfp4` 14.95 GiB g16, `-mxfp8` 26.69 GiB; 2026-08-14, 1-4K dl): [internal] docs/QUANTIZATION-2026-10-25.md measured them worse than affine at equal bpw (PPL +4.3 % / +5.0 % vs +2.7 %). No agent data. The engine would also need a new quant mode (section 5).

### 2.2 MLX mixed-precision / learned (sensitive layers kept higher)

| repo | recipe | GiB | MTP | quality evidence |
|---|---|---:|---|---|
| `Jundot/Qwen3.8-27B-oQ4e-mtp` (2026-10-25 rev; 19.6K dl, 75 likes) | oMLX oQe: 4-bit g64 (80.8 % of weights) + 5-bit (17.4 %) + bf16 (1.9 %), 4.887 bpw total, importance-matrix + WLS refit | 15.81 | **bundled** (`mtp.*`, fc bf16) | KL vs bf16: **0.0117 code, 0.0600 novel prose** (32,768 tok each; re-quant of 2026-10-11 improved -18 % / -14 %) [card]. [internal] earlier rev: code PPL 4.697 vs 4.660 for stock 4-bit, i.e. no PPL win; re-test the new rev |
| `Jundot/...-oQ6e-mtp` / `-oQ8e-mtp` | 6-bit g64 90.5 % + 8-bit 7.6 % + bf16, 6.829 bpw | 22.09 / 27.94 | bundled | no KL on card |
| `mlx-community/Qwen3.8-27B-oQ4` / `-oQ6` | oQ without the `e` improvement | 15.50 / 21.70 | no | none |
| `mlx-community/Qwen3.8-27B-OptiQ-4bit` (2026-10-18, 9.5K dl) | KL-sensitivity: 261 of 498 tensors 8-bit, 237 4-bit, g64 | **18.95** (label "4-bit", really ~6) | no | method card only |
| `JoshuaCalhoon/Qwen3.8-27B-MLX-4bit-GPTQ` (2026-10-22, 186 dl) | GPTQ on 4-bit **g128**; lm_head 6-bit; full-attn k/v_proj and GDN `in_proj_a/b` 8-bit; calibrated on multi-turn agentic-coding sessions | 14.60 | not mentioned | KL vs bf16 **0.0747** vs **0.1175** for `mlx-community/Qwen3.8-27B-4bit`; top-1 agreement 0.925 vs 0.881; 96 held-out agentic sequences (~37.8K tok); "tied or edged" on an agentic suite, 1 sample per item [card, single party] |
| `leonsarmiento/Qwen3.8-27B-3bit-mtp-mlx` (1.4K dl) / `-3bit-mlx` (702 dl) | 3-bit g64, embeddings + lm_head 4-bit, vision 8-bit, 582 per-tensor overrides, 3.716 bpw | 12.13 / 11.83 | bundled 4-bit MTP (+0.33 GB; only oMLX runs it) | speed only on card |
| `abuarchive/Qwen3.8-27B-2bit-oQ2` | oQ 2-bit mixed | 10.51 | no | none |
| `AtomicChat/Qwen3.8-27B-MLX-AD-{3.50,3.70,3.80,4.50,5.00}bpw-DWQ-*GB` | DWQ at fixed bpw: 11.82 / ~12.4 / ~12.7 / 14.95 / ~16.4 GiB | none | none | **no card text** (84-byte README): unvetted [community] |
| `Litwein/...-oQ4e-DWQ-MTP-MLX` | oQe + DWQ | 19.27 | bundled | none |

Cautionary data point: `deuce11/Qwen3.8-27B-3bit-DWQ-MLX-TextOnly` was **removed** by its author after a 3-bit DWQ distilled from an 8-bit teacher stopped prose mid-sentence; the rebuilt `...-3bit-DWQ-BF16-MLX-TextOnly` (bf16 teacher) fixed it [card, 2026-10-24]. Lesson: DWQ teacher must be bf16, and 3-bit needs end-of-sequence/length checks in any eval.

### 2.3 GGUF (llama.cpp world; not loadable by Strim, but the only place with agent-level quality data)

Sizes in GiB, from the HF API 2026-10-27 [card]. Unsloth `unsloth/Qwen3.8-27B-GGUF` (6.0 M dl, 5.4K likes, "Dynamic 3.0", 2026-08-13): UD-IQ1_S 5.77, IQ1_M 6.27, IQ2_XXS 6.77, IQ2_S 7.80, Q2_K_XL 9.15, IQ3_XXS 10.18, IQ3_S 11.21, Q3_K_XL 12.24, IQ4_XS 13.27, Q4_K_S 14.30, Q4_K_M 15.33, Q4_K_XL 16.35, Q5_K_S 17.38, Q5_K_M 18.41, Q5_K_XL 19.44, Q6_K 20.47, Q6_K_XL 23.56, Q8_0 27.05, Q8_K_XL 29.30, BF16 50.9; plain Q4_0 14.95, Q4_1 16.34. MTP is a separate file (`MTP/mtp-...-Q4_0.gguf`, 1.28 GiB) and is **stripped from Q2_K_XL and smaller** ("saving ~500 MB") [card]. `bartowski/Qwen3.8-27B-GGUF` (276K dl): IQ2_XXS 8.27, IQ2_M 9.80, Q2_K 10.08, IQ3_XXS 11.47, IQ3_M 13.84, IQ4_XS 14.41, Q4_K_M 16.24, Q5_K_M 19.49, Q6_K 22.22, Q8_0 27.12. `lmstudio-community` (1.1 M dl): Q4_K_M 15.66, Q6_K 20.89, Q8_0 27.05. `ggml-org` (2.3 M dl): Q4_K_M 17.67, Q8_0 26.63, separate `mtp-*` (Q4_0 1.56, Q8_0 2.95 GiB). `byteshape/Qwen3.8-27B-GGUF` (2.0 M dl, ShapeLearn, MTP bundled < 250 MB): 2.56 / 2.88 / 3.01 / 3.23 / 3.84 bpw = 8.8 / 9.9 / 10.4 / 11.0 / 13.1 GB. `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF` (1.25 M dl, 2.4K likes): IQ2_XS 2.50 bpw 8.4 GB, IQ2_S 2.75 / 9.3, IQ3_XXS 3.00 / 10.1, IQ3_S 3.50 / 11.8, optional `-mtp` builds (+0.35 GB).

K-quant/IQ formats are block formats with non-uniform codebooks; MLX has no kernels for them. Conversion GGUF -> MLX affine re-quantizes (loses the benefit). Use them as external quality oracle only.

### 2.4 Other formats (not usable on Apple silicon via MLX)

Official FP8 `Qwen/Qwen3.8-27B-FP8` 28.75 GiB (4.47 M dl); NVFP4 `unsloth/...-NVFP4` 21.81 GiB (1.5 M dl), `nvidia/...-NVFP4`; AWQ-INT4 `cyankiwi/...-AWQ-INT4` 19.57 GiB (975K dl); GSQ 3-bit compressed-tensors `ISTA-DASLab/Qwen3.8-27B-3Bit-GSQ` 11.02 GiB (vLLM only, **MTP removed**, per card). All need CUDA/vLLM kernels [card]. FP8 is useful only as a source for dequantization. The FP8 and AWQ/GSQ repos could in principle be dequantized and re-quantized to MLX, but that stacks two quantization errors; bf16 (mlx-community/Qwen3.8-27B-bf16, 50.96 GiB) is the right source.

### 2.5 Quality evidence (what exists)

Task-level, nothing on MLX; all on GGUF/vLLM, mostly short-horizon. Nothing found measures multi-file multi-step agent tasks per quant (GAP).

| evidence | result | tag |
|---|---|---|
| Quesma, 2026-08-26, llama.cpp on Modal GPUs, Terminal-Bench 2.1 (89 tasks, 3 h limit, xhigh thinking), GPQA-D, IFBench, Wilson 95 % CIs. `https://quesma.com/blog/qwen38-27b-quantizations-benchmarked/` | **BF16 and Q4_K_M match Qwen's reported TB2.1**; Q8_0 not run; **UD-Q2_K_XL drops noticeably** (exact % only in charts, axis ~55-80 %); UD-IQ1_S/M near random on GPQA-D (below random for IQ1_S); IFBench unchanged down to Q2_K_XL; author: KL/top-1 "does not tell us whether the model gets worse at solving tasks". Run counts not stated | [repro], strongest agent-ish datum |
| ByteShape, 2026-09-14 (upd. 09-18). `https://byteshape.com/blogs/Qwen3.8-27B/` | Aggregate of 8 benchmarks incl. BFCL V4, ACEBench, LiveCodeBench v6, Multiple-HumanEval, normalized to BF16: ShapeLearn 2.56 bpw **93.0**, 2.88 **96.6**, 3.01 **97.3**, 3.23 **98.7**, 3.84 **99.6**; Unsloth UD-IQ2_S 86.3, Q2_K_XL 95.7, IQ3_S 95.6, Q3_K_XL 97.6, IQ4_XS 99.2, Q4_K_M 97.0, Q4_K_XL 98.7, Q5_K_M 99.0; ISTA IQ2_XS 86.5, IQ3_S 99.4; bartowski IQ2_XXS 79.9, Q2_K 96.2, IQ3_M 96.7. Per-benchmark BFCL/ACEBench numbers are not published; non-monotonic (Q4_K_M 97.0 < Q4_K_S 98.8) so noise is ~+-1.5 points | [card/vendor, single party] |
| ISTA-DASLab GSQ-RCO card (2026-08/09), single runs, xhigh thinking. `https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF` | BF16: AIME25 100 / GPQA-D 89.90 / LCB v6 85.71. IQ3_S 3.5 bpw: 100 / 89.39 / 85.71 ("task-lossless"). IQ3_XXS 3.0: 100 / 88.89 / 84.57. IQ2_S 2.75: 100 / 86.36 / 82.29. IQ2_XS 2.5: 96.67 / 84.85 / 76.57. Unsloth UD-IQ2_S 2.49: 86.67 / 76.26 / 72.00; UD-Q2_K_XL 2.88: 100 / 86.87 / 82.28; UD-IQ3_S 3.52: 96.67 / 89.90 / 84.00. Wikitext PPL BF16 7.05 -> IQ3_S 7.07, IQ2_XS 7.69 | [card/vendor, n=1] |
| ISTA 3-bit GSQ (vLLM), same card family | AIME25 100 / GPQA-D 91.41 vs base 100 / 89.90 | [card, n=1] |
| avlp12 paired PPL study 2026-08-22 (via [internal] docs/QUANTIZATION-2026-10-25.md). `https://huggingface.co/avlp12/Qwen3.8-27B-Alis-MLX-6bit` | PPL delta vs bf16 on code: 8-bit +0.01 %, **6-bit +0.24 %**, 4-bit AWQ g64 **+7.7 %** (en +1.2 %), 3-bit affine "visibly worse" (8.01 vs 7.27 on one text). 6-bit with 5 small groups at 8-bit (k_proj, v_proj, GDN in_proj_a/b, lm_head): -18.9 % excess NLL vs uniform 6-bit for +1.6 % bytes | [internal] summarizing [community] |
| Our PPL, 512-token slices (docs/MODEL-VARIANTS-2026-10-26.md) | code PPL 4-bit 4.660, 6-bit 4.624, 8-bit 4.588; oQ4e (old rev) 4.697 | [internal] |
| KL vs bf16 on MLX 4-bit g64 uniform | **0.1175** (agentic coding corpus, top-1 0.881) vs 4-bit g128 GPTQ+8-bit sensitive tensors 0.0747 / 0.925 | [card] JoshuaCalhoon |
| KL on GGUF Q4_K_M (community table, search summary, unverified corpus) | 0.011-0.021 (AD-Q4_K_M 0.01126, ggml-org 0.0147, lmstudio 0.02094); top-1 95.6 % for AD | [community] via `https://huggingface.co/AtomicChat/Qwen3.8-27B-GGUF` (not re-fetched) |
| Unsloth Dynamic 3.0 page (undated v3.0 section) `https://unsloth.ai/docs/basics/dynamic-3.0-ggufs` | claims >10 % better top-1 at same size; UD-IQ1_S "72 % (77 % elsewhere on same page)" top-1; "Divergence-300@32" (greedy 32-token agreement with BF16): UD-Q2_K_XL ~25 %, IQ2_S < 8-10 %; says 1-bit should not be used for tool calling or agentic work; KL only in charts | [card/vendor] |

Interpretation (HYPOTHESIS unless noted):
1. Down to ~4 bpw with learned/mixed GGUF formats, task scores are within noise of BF16 on short-horizon benchmarks (Quesma, ByteShape, ISTA). **It is not shown for long multi-step agent tasks.** Greedy 32-token agreement of 25 % at Q2_K_XL (Unsloth) says trajectories diverge early; whether they diverge into worse solutions is exactly what the unknown is. Errors compound over 30-100 tool calls; single-shot benchmarks understate this.
2. The MLX-uniform 4-bit g64 recipe has a KL of 0.1175 on agentic code, roughly 5-10x the KL of GGUF Q4_K_M/oQ4e on other corpora (corpora differ: not comparable, but the gap is large enough to test first). Our PPL data says +1.6 % on 512 tokens, which hides tail damage.
3. 2-bit and below: unusable for tool calling (vendor says so; 1-bit collapses [repro]). 2.5-2.9 bpw learned formats lose 5-14 aggregate points (ByteShape), and Quesma sees a noticeable TB2.1 drop at Q2_K_XL. For long agent runs treat 2-bit as too lossy.
4. 3-bit: **learned/mixed 3.0-3.5 bpw** (IQ3_S-class, GSQ) looks near-lossless on short tasks (ByteShape 98.7 at 3.23; ISTA IQ3_S equal on LCB) [card]. **Plain MLX affine 3-bit RTN** looks much worse (avlp12 PPL; 3-bit DWQ author saw truncation) [community]. So "3-bit at 24 GB" is plausible only with a learned recipe (DWQ/GPTQ/oQ) we would have to build or vet; no vetted MLX 3-bit repo with eval exists today. The two 3-bit MLX repos with MTP are speed-only cards.

### 2.6 KV-cache quantization

- Mechanics (local `mlx_lm` 0.31.2 `generate.py`): `kv_bits`, `kv_group_size=64`, `quantized_kv_start`; `KVCache.to_quantized` once `offset >= quantized_kv_start`. Server flags `--kv-bits --kv-group-size --quantized-kv-start` (default start 5000) [community] `https://github.com/ml-explore/mlx-lm/issues/1043`. Only the 16 full-attention layers have a KV; the GDN state stays fp32 (cannot be quantized), so KV q8/q4 saves at most 64 -> 34 / 18 KiB per token: 32K = 2 -> 1.06 / 0.56 GiB; 128K = 8 -> 4.2 / 2.2 GiB. [computed]
- Quality: 8-bit KV is "cheap", uniform 4-bit can flip nearly all tokens on a small dense model; recommended K at 8-bit, V lower [community] `https://github.com/IonDen/mlx-quant-fidelity`, `https://github.com/arozanov/turboquant-mlx`. [internal] 4-bit KV without layer-0 protection took a small model PPL 21 -> 507. **GAP:** no published KV-quant measurement for Qwen3.5/3.8 hybrids. Prior position: q8 only, start at >= 8K; q4 for V only as an experiment.
- Value by tier: KV q8 saves 0.5 GiB at 16K and 4 GiB at 128K. It matters on 24 GB (turns 55-64K into 105-120K at 3.7 bpw), little at >= 48 GB.
- Weight x KV combos worth testing: 3.7-bit + q8 KV (24 GB), 4-bit + q8 KV (32 GB), 5-bit + bf16/q8 KV (36 GB).

### 2.7 Which recipes we can produce ourselves

Installed here: `mlx_lm` 0.31.2 with `mlx_lm.convert`, `.dwq`, `.awq`, `.gptq`, `.dynamic_quant`, `.perplexity`, `.evaluate` (checked on disk 2026-10-27). `convert.py` exposes `--q-bits`, `--q-group-size`, `--q-mode {affine,mxfp4,nvfp4,mxfp8}` and four named recipes (`mixed_2_6, mixed_3_4, mixed_3_6, mixed_4_6`: high bits only for `v_proj`/`v_a_proj`/`v_b_proj`/`down_proj` in the first eighth, last eighth and every third layer, plus `lm_head` always; embeddings fall to the low bits; mixed recipes only with affine) [computed from `https://raw.githubusercontent.com/ml-explore/mlx-lm/main/mlx_lm/convert.py` and the local file]. The Python API takes any callable `quant_predicate(path, module, config) -> bool|dict`, so a custom "4-bit with 6/8-bit for the sensitive tensors" recipe is a ~30-line predicate:

- sensitive set (from [internal] avlp12 numbers + JoshuaCalhoon + OptiQ cards): `embed_tokens`, `lm_head`, full-attn `k_proj`/`v_proj`, GDN `in_proj_a`/`in_proj_b` (tiny), `down_proj` of first and last 4-8 layers, optionally GDN `in_proj_qkv`/`out_proj`; MTP head `fc` bf16 (as in oQ/leonsarmiento).
- Cost of the 8-bit set: embed + lm_head (2 x 1.27 B params) at 8-bit instead of 4-bit adds 2.54 B x 4/8 = 1.27 GB = ~1.2 GiB; k/v/a/b projections add well under 0.2 GiB [computed from config dims; the predicate dry-run should print the exact figure].
- **Source weights**: `mlx-community/Qwen3.8-27B-bf16` 50.96 GiB (or the official 51 GiB bf16). Download once with `aria2c -x 4 -s 4 -k 1M -c`. **mlx-lm drops `mtp.*` on load** (`qwen3_5.py` sanitize, line ~313), so a self-converted checkpoint has no MTP head: graft the existing overlay (`mlx-community/Qwen3.8-27B-MTP-8bit` 0.42 GiB) as we already do for the stock checkpoints.
- **Cost estimates** (GAP: no timing data found for 27B; to be measured by a pilot):
  - plain RTN / predicate convert: I/O-bound, expected minutes; **peak memory risk**: the bf16 model is 51 GiB on a 64 GB Mac whose budget is 56 GiB. Convert with everything else closed and the memory watchdog (section 4.3); never let swap grow; if free memory < 6 GiB abort.
  - `mlx_lm.dynamic_quant` (sensitivity sweep, then bit allocation), `mlx_lm.gptq`, `mlx_lm.awq`, `mlx_lm.dwq` (distill scales/biases from a teacher; teacher + student + activations simultaneously: bf16 teacher 51 GiB alone saturates the Mac; an 8-bit teacher (26.6 GiB) fits but the deuce11 incident shows 8-bit teachers produced truncation at 3-bit): feasible for <= 4-bit students only with a streamed/precomputed-targets path (`dwq.py` has `compute_dwq_targets`), otherwise run on a bigger machine or accept layer-wise GPTQ.
  - Calibration data: 128-1,024 sequences of 512-2,048 tokens (oQe used 128 x 512; JoshuaCalhoon used agentic sessions; ISTA used 17.5 % code + 10 % agentic trajectories + 14 % long context). Use Strim agent transcripts from tasks **not** in the eval split (leakage control), plus code and prose.
  - Evidence that calibration on agent traces matters: JoshuaCalhoon KL 0.0747 vs 0.1175 (above). Single-party claim.
- Not feasible for us: GSQ/RCO and ShapeLearn (research code, GGUF target), GGUF K/IQ kernels in MLX.

## 3. Candidate list for testing (one model, ten recipes)

R = reference. "src" = existing repo or self-made.

| id | recipe | GiB (text, ~) | src | fits tier |
|---|---|---:|---|---|
| Q8 | affine 8-bit g64 (R) | 26.6 | `lmstudio-community/...-MLX-8bit` (local `models/qwen38-8bit`) | 48, 64 |
| Q6g | 6-bit g64 + 8-bit sensitive set (HYPOTHESIS: new default) | ~20.6 | self | 36, 48, 64 |
| Q6 | stock 6-bit g64 | 20.35 | `lmstudio-community/...-MLX-6bit` (local) | same |
| Q5g | 5-bit g64 + 8-bit sensitive | ~17.6 | self | 32 (high), 36 |
| Q4 | stock 4-bit g64 (baseline, local) | 14.09 | `lmstudio-community`/`mlx-community` | 32, 24 (short ctx) |
| Q4o | oQ4e-mtp | ~15.0 | `Jundot/...-oQ4e-mtp` (local `models/qwen38-oq4e-mtp`) | 32, 36 |
| Q4G | 4-bit g128 GPTQ + sensitive 8-bit | ~13.7 | `JoshuaCalhoon/...-4bit-GPTQ` | 24, 32 |
| Q4s | 4-bit g64 + 6/8-bit sensitive set (embeddings, lm_head, first/last layers, GDN in/out, MTP) | ~14.8 | self | 24 (short), 32 |
| Q3d | 3-bit g64 learned (DWQ/GPTQ, agent-trace calibration, embed/lm_head 4-bit) | ~11.7 | self (+ `leonsarmiento/...-3bit-mlx` 11.83 GiB as the unvetted external) | 24 |
| Q2 | affine 2-bit g64 (`keXjos/...-mlx-2Bit` 7.83 GiB) | 7.83 | repo | negative control; 16 GB feasibility |

External oracle (not a product format): `unsloth/Qwen3.8-27B-GGUF` UD-Q4_K_M 15.33 GiB and UD-IQ3_S 11.21 GiB via llama.cpp, to anchor "what a good 4-bit / 3-bit can do" for KL and tasks.

## 4. Test plan (NOT run now)

### 4.0 Step 0: tier budgets (1 hour)
Run the Metal probe and `sysctl iogpu.wired_limit_mb` on one machine of each tier (8/16/24/32/36/48; owner or a friend's machines), plus a clean-login `footprint`/`vm_stat` of macOS + a browser. Replace the B_low/B_high and the 5.5 GiB assumptions in section 1.2.

### 4.1 Reference
Reference = **Q8** (8-bit g64, 26.6 GiB, fits this 64 GB Mac at 56 GiB budget; ΔPPL vs bf16 +0.01 % code per avlp12 [community]). bf16 (51 GiB) leaves only ~5 GiB headroom on this Mac: use it only for a short anchor run (<= 16 x 4K-token teacher-forced sequences, KL of Q8 vs bf16, with the abort rules below) to confirm Q8 ~ bf16. Do not use bf16 as the main reference.

### 4.2 Metrics
A. **Distribution**: teacher-forced on a fixed set of 64 held-out agent prompts (8-24K tokens each: Strim transcripts of agentbench runs not used for calibration, plus 8 long multi-file sessions), reference = Q8 logits. Report mean KL(ref||q) overall, on tool-call JSON tokens, on code-edit tokens, p95/p99 per-token KL, top-1 agreement, and all four by position bucket (0-2K, 2-8K, 8-24K) to see long-context drift. Instruments: `strim benchppl` extended with logits dump, or `mlx_lm.perplexity`/`mlx-quant-fidelity` as cross-check.
B. **Task level**: `strim agentbench run --arms H,C --model <dir> --seed S` on the 17 tasks in `bench/agenttasks` (12 test-fix Swift/Go, 3 mechanical-edit, 2 repo-qa), plus 6 new long tasks (multi-file, 30-80 expected steps, e.g. add a feature across 3-5 files with test updates; both languages). Metrics: pass rate (verifier), **steps-to-failure** (index of the first tool call after which the verifier can no longer pass, or the step where it aborts; logged by the runner's ledger), invalid/malformed tool calls per 100 calls, loops/repeated-tool-call rate, tokens per task, wall time. Same seeds across quants (paired). Sampling per Qwen card (T=1.0, top_p 0.95, top_k 20 thinking) for realism; 5 seeds. 17 tasks x 5 seeds = 85 paired runs per arm; with run-to-run noise from the reference (Q8 vs Q8 on 5 seeds, measured first) as the noise floor.
C. **Systems**: decode and prefill tok/s at 4K/16K/64K (`strim benchctx`), MTP acceptance and tok/s, peak `phys_footprint`, swap delta, time-to-first-token.
D. **KV variants** on the 2-3 best weights: bf16 vs q8 (start 8192) vs K8/V4, same A/B/C.

### 4.3 Running safely on this 64 GB Mac (abort rules)
- Emulate a smaller tier by setting the engine budget (`STRIM_MEM_BUDGET_GB`, see docs/MEMORY-2026-10-26.md) to the tier's U (18, 24, 27, 36 GiB), prefix trie off or <= 1 GiB (`STRIM_PREFIX_CACHE_MB`), and MLX cache limit 1 GiB; optionally lower `iogpu.wired_limit_mb` with sudo (owner step) to B_low of the tier. This does not reproduce OS/app pressure; the real-machine run (4.0 hardware) is the final gate for 24 GB and 32 GB.
- Run quants sequentially, one process, nothing else heavy; page out nothing: **abort the run** if swap-used grows > 256 MB from its pre-run value, free+inactive < 6 GiB, `phys_footprint` > the tier budget + 10 %, or the memory pressure state turns yellow/red. The existing bench watchdog (per-step footprint log; 40 GB footprint / swap-growth abort, commit 181cba3) is the base; lower its limit to the tier budget when emulating.
- Self-conversion from bf16 (51 GiB) and any DWQ/GPTQ job only with the same abort rules, or on another machine.

### 4.4 Acceptance thresholds for "minimal quality loss" (proposals, to calibrate with the noise floor)
Calibration basis: Q4_K_M matches BF16 on TB2.1 within noise (Quesma, [repro]) while its KL is ~0.011-0.021 and top-1 ~95 % [community]; oQ4e 0.0117 on code [card]; uniform MLX 4-bit 0.1175 on agentic code [card] is the "probably too lossy" end. Proposed:
- **Distribution gate (cheap, run on every candidate first):** mean KL on code/agentic tokens <= 0.02 and top-1 agreement >= 93 %; p99 per-token KL not worse than 2x that of Q4_K_M-GGUF oracle; tool-call-token KL <= the overall KL. Fail = drop (except as negative control).
- **Task gate (the real one):** paired pass-rate difference vs Q8 with 95 % paired-bootstrap CI whose lower bound is >= -10 percentage points AND point estimate >= -5 pp; steps-to-failure median >= 90 % of Q8's; invalid tool calls <= Q8 + 1 per 100 calls; no run killed by length/loop more often than Q8. "Within noise" is defined by the Q8-vs-Q8 rerun spread (if that is already > 5 pp, the threshold becomes that spread).
- Justification for -5 pp: with 17 tasks x 5 seeds the paired SE is ~4-6 pp, so smaller effects are not detectable; claiming "lossless" below that is unsupported. Detecting a true 3 pp loss needs ~300+ paired runs: **the 17-task corpus is too small for fine tiers; add tasks (target 40+) before trusting 5-bit vs 6-bit decisions**, and lean on gate A for those.
- Tier-specific: 24 GB (3-bit class) gets a stricter long-horizon gate: steps-to-failure on the 6 long tasks within 85 % of Q8 and zero truncation/looping regressions.

### 4.5 Per-tier arms (each includes Q8 as reference on the 64 GB box)
| tier | arms | KV |
|---|---|---|
| 24 GB | Q4 (short-ctx only), Q4G, Q4s, Q3d, leonsarmiento 3-bit, Q2 (neg. control) | bf16 vs q8 |
| 32 GB | Q5g, Q4o, Q4G, Q4s, Q4 | bf16 vs q8 |
| 36 GB | Q6g, Q5g, Q4o, Q4s | bf16 |
| 48 GB | Q8, Q6g, Q6, Q5g | bf16 |
| 64 GB | Q8 (R), Q6g, Q6 | bf16 |
| 8/16 GB | no run (does not fit); optionally Q2 + KV q8 at 16 GB with raised limit as a 1-hour feasibility check only | q8 |

Order: gate A on all (1 day, cheap), then gate B on survivors.

## 5. What Strim needs per quantization (engineering list)

State today (from repo, 2026-10-27): `WeightStore.quantBits` infers per-tensor bits from packed shapes (4/5/6/8 work; oQ4e loads); `groupSize` defaults to 64 everywhere (`Sources/StrimCore/Weights.swift`); MTP head loads from bundled `language_model.mtp.*` (oQ) with bf16 `fc`, or from a separate overlay.

| item | needed for | rough effort |
|---|---|---|
| Per-tensor mixed bits (affine 2-8) from shapes/`config.json` overrides | Q6g, Q5g, Q4s, Q3d, oQ, OptiQ | done for 4/5/6/8; add 2/3-bit (fits `mx.quantized_matmul` bits 2,3): 0.5 d + tests |
| Per-tensor group size (g32 / g128) read from `config.json` (shape-ratio alone cannot disambiguate bits vs group) | Q4G, Chungulus g32 | 1 d |
| MTP head in 4/8-bit overlay or bundled, bf16 `fc`, bits independent of the base | all | mostly done; verify acceptance rate vs head bit-width: 1 d |
| Engine budget derived from Metal `recommendedMaxWorkingSetSize` (not 80 % of RAM), prefix trie off/small by tier, auto-pick quant + KV mode + max ctx from budget | all small tiers | 2 d |
| KV quantization (q8, K8/V4) on the 16 full-attention layers: quantized cache + attention via `quantized_matmul`, prefix-cache (trie) serialization of quantized KV, `quantized_kv_start` | 24 GB, long ctx | 3-5 d (+ risk: GDN boundary snapshots stay fp32 and dominate the trie) |
| Lazy / smaller prefill chunks (e.g. 512) to cut the 0.8 GiB transient | 24-32 GB | 0.5 d |
| mxfp4/nvfp4/mxfp8 modes (mlx-swift `mode:` parameter, scales layout) | optional; measured worse than affine | 1-2 d; skip unless a tier needs it |
| GGUF K/IQ quant import | none: no MLX kernels; only dequant->requant | do not build (weeks); keep llama.cpp as oracle |
| FP8/NVFP4/AWQ/GSQ compressed-tensors | none | do not build |
| Self-quantization pipeline script (bf16 download via aria2c, predicate convert, MTP graft, memory-guarded) | Q6g, Q5g, Q4s, Q3d | 1-2 d (+ DWQ/GPTQ pilot 1-2 d) |
| `quantinfo`-style eval harness: KL dump + top-1 + tool-token KL on a fixed prompt set | gate A | 1-2 d |
| Eval corpus growth to 40+ tasks incl. 6 long multi-file tasks | gate B power | 3-5 d |

Non-affine architectures and other models are out of scope per the owner.

## 6. Recommendation (hypotheses to test, not conclusions)

| usable GB (low/high) | tier | recommended quant (HYPOTHESIS) | expected ctx (bf16 KV / q8 KV) | decode ceiling, chip example (computed), x~1.7-1.9 with MTP unverified |
|---|---|---|---|---|
| 2.5 | 8 GB | does not fit | - | - |
| 10.5 | 16 GB | does not fit (2-bit needs 10.8) | - | - |
| 18-18.5 | 24 GB | Q3d (learned 3-bit, 11.7 GiB) + q8 KV; Q4G/Q4s only for <= 25-45K ctx | 55-64K / 105-120K | M4 Pro 24 GB: 22.9; M2/M3/M4 base: 8.6-10.1 |
| 24-26.5 | 32 GB | Q4s or Q4G (+MTP), Q5g if B is high | 98-154K / 185-291K | M5 base 32 GB: 10.7; M1/M2 Pro: 14.2 |
| 27-30.5 | 36 GB | Q5g (or Q4o if Q5g fails the gate) | 111-169K / 210-318K | M3 Pro 36: 8.7 (5-bit); M3 Max 307-409: ~17-23 |
| 36-42 | 48 GB | Q6g | 208-306K / full | M4 Pro 48: 13.1; M4 Max 546: ~26 |
| 48-56 | 64 GB | Q6g default, Q8 reference/optional | 400K+ (trie-limited) | M5 Pro 64: 14.8 (6-bit); M5 Max 40c: 29.5 (6-bit, 22.6 for 8-bit) |

First 3 experiments:
1. **Distribution gate on what already exists locally:** KL/top-1 vs Q8 on 64 agent prompts for Q4 (stock), Q4o (new oQ4e rev), Q4G (JoshuaCalhoon GPTQ g128), Q6 and Q2; confirms or refutes "stock MLX 4-bit g64 is 5-10x the KL of a good 4-bit" (KL 0.1175 vs ~0.01-0.07). Download only Q4G (~14.6 GiB) and Q2 (7.8 GiB) with aria2c. Expected 1 day.
2. **Q8-vs-Q8 noise floor + Q6 vs Q8 on `strim agentbench` (H,C arms, 5 seeds)** to size the noise and decide whether 17 tasks suffice; in parallel add the long multi-file tasks. This fixes the thresholds of section 4.4.
3. **Build Q6g/Q5g/Q4s with a custom predicate (+ MTP graft) and test 24/32 GB candidates**: Q4s vs Q4G vs Q4o on gate A then B; in the same sprint test q8-KV on Q4s at 32K/64K (steps-to-failure). Then decide whether 3-bit (Q3d) is worth the DWQ/GPTQ effort for 24 GB, or whether 24 GB is declared "4-bit, <= 45K context, or unsupported".

## Sources (fetched 2026-10-27 unless noted)
- HF API listings/cards: `https://huggingface.co/Qwen/Qwen3.8-27B`, `mlx-community/*`, `lmstudio-community/*`, `unsloth/Qwen3.8-27B-GGUF`, `bartowski/Qwen3.8-27B-GGUF`, `ggml-org/Qwen3.8-27B-GGUF`, `byteshape/Qwen3.8-27B-GGUF`, `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF` and `...-3Bit-GSQ`, `Jundot/Qwen3.8-27B-oQ4e-mtp`, `JoshuaCalhoon/Qwen3.8-27B-MLX-4bit-GPTQ`, `leonsarmiento/Qwen3.8-27B-3bit-mtp-mlx`, `mlx-community/Qwen3.8-27B-OptiQ-4bit`, `deuce11/Qwen3.8-27B-3bit-DWQ-MLX-TextOnly`, `AtomicChat/*` (download/like counts and sizes as of today).
- `https://quesma.com/blog/qwen38-27b-quantizations-benchmarked/` (2026-08-26); `https://byteshape.com/blogs/Qwen3.8-27B/` (2026-09-14/18); `https://unsloth.ai/docs/basics/dynamic-3.0-ggufs`.
- Wired limit: `https://modelpiper.com/blog/iogpu-wired-limit-mb-mac`, `https://github.com/evanwtf/local-llm/issues/30`, `https://github.com/ggml-org/llama.cpp/discussions/2182`.
- Bandwidth: `https://en.wikipedia.org/wiki/Apple_silicon`.
- KV quant: `https://github.com/ml-explore/mlx-lm/issues/1043`, `https://github.com/IonDen/mlx-quant-fidelity`, `https://github.com/arozanov/turboquant-mlx`.
- mlx-lm: `https://raw.githubusercontent.com/ml-explore/mlx-lm/main/mlx_lm/convert.py` and local install 0.31.2.
- Internal: docs/QUANTIZATION-2026-10-25.md, docs/MODEL-VARIANTS-2026-10-26.md, docs/MEMORY-2026-10-26.md, bench/agenttasks/README.md.
