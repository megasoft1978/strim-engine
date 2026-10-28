# Qwen3.8-27B quantization ladder: update of the 2026-10-27 survey (2026-10-28)

Scope (owner): only quantizations of the SAME Qwen3.8-27B (+ its MTP head). Tiers that cannot fit are "not supported".
This file UPDATES `docs/RESEARCH-QUANT-TIERS-2026-10-27.md` (memory math, tier table, candidate repos, test plan); that text is not repeated. Section numbers below are the owner's question list, not the old doc's.
Tags: **[card]** vendor/author model card, **[repro]** third-party measurement with published method, **[community]** forum/blog/discussion, **[computed]** derived here from cited inputs, **[internal]** our own measurement. GAP = nothing found. HYPOTHESIS = untested inference.
All HF sizes below come from the HF API file listing (`siblings[].size`, GiB = 2^30) fetched 2026-10-28; "backbone" = file size minus the 0.86 GiB bf16 vision tower (Strim never loads it).

## 0. What changed since yesterday (read this first)

1. **A real 2-bit candidate exists: `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`** (Qwen3.8-27B base, 8.01 GiB file, 7.14 GiB without vision, MLX affine 2-bit **g128** with a blockwise Hadamard rotation of the activations; vendor average over 14 benchmarks 84.78 vs 86.32 FP16 = 98.2 %, BFCL v3 74.92 vs 76.74) [card]. It is the first thing that makes a 16 GB tier look possible. Caveats: vendor-only numbers (vLLM/H100, n=1), no MTP and no vision in the pack, needs a custom per-linear Hadamard transform in the loader (section 5).
2. **A full oQ ladder for the same model is on HF** (`Jundot/Qwen3.8-27B-oQ{2,2.5,3,3.5,4,5,6,8}e-mtp`, all with the MTP head bundled, all mixed per-tensor 2-8 bit, g64 and some g128). Yesterday's doc only knew oQ4e/6e/8e. Sizes and bit mixes in section 2. Our engine already loads oQ4e (mixed 4/5-bit, bundled head); 2/3-bit and g128 need work.
3. **New quality numbers** (still none on long agentic runs): KL for uniform MLX 8/6/4-bit (orcarouter), 3/3.7/3.8/4.5/5.0 (AtomicChat), dense Qwen3.6-27B 2-8-bit on a diverse corpus (omlx#945), MTPLX 4-bit g32 + 8-bit-sensitive pack. Section 1.
4. **Our engine is closer to a ladder than yesterday's table said, with one dangerous exception**: bits are inferred per tensor from shapes, but the group size is hard-coded 64 at every call site. A g128 tensor is silently mis-read (computed: a 4-bit g128 tensor infers 8 bits and produces garbage, no error). Details in section 5.
5. Local evidence (section 6): only a synthetic per-bit kernel bench could be run (machine swap-saturated by other lanes). Result: decode scales with bytes at every width, prefill is bit-independent (2-bit not slower), but the MTP verify step (M=4) gains nothing below 4-bit.

## 1. State of the art (what has real numbers for 27B-class Qwen3.5/3.6/3.8)

### 1.1 Techniques, and what is usable on Apple Silicon

| technique | status for Qwen3.8-27B | usable by Strim |
|---|---|---|
| MLX affine RTN, 2-8 bit, g32/64/128 | stock repos 2/3/4/5/6/8 bit (yesterday's list; AtomicChat also published bf16/8/6/5-bit on 2026-10-28) | yes, kernels exist for bits 2,3,4,5,6,8 and g32/64/128 (section 3) |
| oQ / oQe (oMLX): per-tensor sensitivity -> bit allocation, importance matrix (128 x 512 tokens), weighted-least-squares scale/bias refit | full ladder oQ2e..oQ8e on HF, MTP bundled; described only through release notes [community] `https://newreleases.io/project/github/jundot/omlx/release/v0.2.20` (no paper, code not read) | yes as a checkpoint format (it is plain affine with per-tensor overrides in `config.json`) |
| DWQ (distill scales/biases from a teacher) | AtomicChat 3.5 bpw: uniform 3-bit g64 + clipping search + DWQ from an 8-bit teacher (1-2 h on one GPU) KL 0.215 vs 0.223 without DWQ: tiny gain at 3-bit [card]. deuce11's earlier 3-bit DWQ stopped mid-sentence until re-done from a bf16 teacher (yesterday's doc) | same format as RTN, so loadable; building it needs Python/mlx-lm |
| GPTQ / AWQ on MLX | JoshuaCalhoon 4-bit g128 GPTQ (KL 0.0747 vs 0.1175 stock, [card]); `sady4850/...-4bit-GPTQ` (14.95 GiB, 48 dl, no card data); AWQ 4-bit PPL +7.7 % on code (avlp12 via yesterday's doc) | loadable only after g128 support |
| Unsloth Dynamic 2.0/3.0 (UD-* GGUF, imatrix) | strongest agent-level evidence, but GGUF only (yesterday's section 2.3, Quesma, ByteShape, ISTA) | no (use as external oracle). Unsloth also publishes `UD-MLX-3bit/6bit` for Qwen3.6-27B [card]; for Qwen3.8 only found as a 23.5 GB "UD-MLX-4bit" in omlx#945 (not a 4-bit-sized file) |
| MXFP4 / NVFP4 / MXFP8 in MLX | MLX has the modes; quality worse than affine at equal bits [internal] docs/QUANTIZATION-2026-10-25.md; `airagrp` NVFP4 variants KL 0.038-0.057, QAT-NVFP4 0.0753 (PPL 7.298 vs bf16 6.935), MXFP8 0.0037-0.0068, 19-22 GiB [card, WikiText-2] | optional, low priority |
| Vector/trellis (QuIP#, AQLM, QTIP), TurboQuant/PolarQuant | no Qwen3.8-27B MLX checkpoint found. Academic code-gen study (arXiv 2607.14181, Qwen2.5-Coder, not Qwen3.8): AQLM matches or exceeds full precision, QuIP# has the largest correctness drop on complex prompts [card/abstract only]. TurboQuant-MLX is KV-cache oriented; PolarQuant weights paper reports 4-bit on a 9B model only | GAP for 27B; needs custom kernels: not a near-term option |
| Hadamard-rotated low-bit (Prism "Bonsai") | Ternary-Bonsai-2-27B, 2-bit affine g128 container, see section 0/4 | yes with moderate loader work (section 5) |
| KV-cache quantization | Qwen3.6-27B dense q8_0 KV: KL 0.024; q4_0 KV: KL 0.087-0.117 (0.581 on long documents, 0.086 on tool calls); only combined K+V tested [repro] `https://localbench.substack.com/p/kv-cache-quantization-benchmark` (llama.cpp, top-40 KL, 250K tokens). Only the 16 full-attention layers have a KV; the GDN state stays fp32. No MLX measurement (GAP) | q8 only, 3-5 d (yesterday's table) |
| Quantized prefill, bf16 decode (Mix-Quant, arXiv 2605.20315) | NVFP4 prefill + BF16 decode, up to 3x prefill speedup, "minimal" loss, models not named in abstract [card/abstract] | not applicable on MLX today (needs fp4 activation kernels) |
| 1.58-bit / ternary QAT from Qwen | no Alibaba release. PrismML Bonsai (ternary, 1.72 true bpw) exists for Qwen3.6 (`Ternary-Bonsai-27B-mlx-2bit`, 7.91 GiB) and Qwen3.8 (`Ternary-Bonsai-2-27B-mlx-2bit`); 1-bit `Bonsai-27B-mlx-1bit` (Qwen3.6). Method (QAT vs PTQ) not stated on the card | the Qwen3.8 one is in scope |

### 1.2 KL / agreement tables (vs bf16 unless noted); corpora differ, so only the ordering inside one row group is comparable

| group | recipe | size (GiB file) | mean KL | top-1 | corpus, tag |
|---|---|---:|---:|---:|---|
| orcarouter (MLX CUDA, 1024 tok) | uniform 8-bit | n/a | 0.00068 | 98.34 % | wikitext-2 [card] `https://huggingface.co/orcarouter/Qwen3.8-27B-MLX` |
| | uniform 6-bit | | 0.00216 | 96.97 % | |
| | uniform 4-bit | | 0.02824 (p95 0.109) | 92.68 % | |
| AtomicChat (H200, mlx-lm 0.31.3) | per-tensor 5.00 bpw | ~16.4 | 0.031 | 91.5 % | held-out neutral text [card] `https://huggingface.co/AtomicChat/Qwen3.8-27B-MLX-AD-3.50bpw-DWQ-12.7GB` |
| | uniform 4-bit (4.50) | 14.95 | 0.053 | 89.5 % | |
| | per-tensor 3.80 | 12.75 | 0.148 | 82.3 % | |
| | mlx-lm `mixed_3_4` 3.70 | ~12.4 | 0.166 | 82.4 % | |
| | uniform 3-bit + clip + DWQ (3.50) | 11.82 | 0.215 | 79.6 % | |
| Jundot (oMLX corpora) | oQ4e (4.887 bpw, 80.8 % 4-bit / 17.4 % 5-bit) | 15.81 | 0.0117 code, 0.0600 novel prose | n/a | 32,768 tok each [card] |
| MTPLX pack `Youssofal/...-MTPLX-Optimized-Speed` | 4-bit g32 + 8-bit embeddings/head/GDN out_proj/last 8 MLP, bf16 GDN conv + MTP head | 19.26 | 0.012 (coding battery 0.0220) | 96.0 % | 2,389 positions [card]; the same card says flat 4-bit is 1.7x farther |
| MTPLX 8-bit dynamic | | n/a | 0.0005 | 99.3 % | same |
| JoshuaCalhoon (agentic code, 96 seqs) | stock MLX 4-bit g64 | 14.95 | 0.1175 | 88.1 % | yesterday's doc [card] |
| | 4-bit g128 GPTQ + 8-bit k/v/a/b, lm_head 6-bit | 14.60 | 0.0747 | 92.5 % | |
| omlx#945, dense **Qwen3.6**-27B, mixed-domain micro prompts | plain MLX 8 / 6 / 5 / 4 / 3 / 2-bit | 26.6 / 20.4 / 17.2 / 14.1 / 11.0 / 7.8 GB | 0.079 / 0.168 / 0.334 / 0.465 / 0.917 / 2.695 | n/a | [community] `https://github.com/jundot/omlx/discussions/945` |
| | oQ8/6/5/4/3.5/3/2 | 26.6 / 20.8 / 17.7 / 14.7 / 12.7 / 11.8 / 9.7 GB | 0.079 / 0.167 / 0.344 / 0.439 / 0.815 / 0.819 / 2.026 | n/a | same (oQ4 beats plain 4-bit by only 5 %; oQ3 beats plain 3-bit by 11 %) |
| | same author, WikiText-2 | | plain Q4 0.036 | n/a | the same quant is 13x "worse" on the diverse set |
| airagrp | QAT-NVFP4 (MLX nvfp4) | 19.15 (+0.79 MTP) | 0.0753 | n/a | WikiText-2 [card] |

Reading (HYPOTHESIS where marked):
- KL moves ~10x with the corpus (WikiText 0.03 vs diverse/agentic 0.12-0.46 for the same plain 4-bit). Nothing above is a code-agent measurement except JoshuaCalhoon and MTPLX. Use our own `quanteval` corpus (section 6) before trusting any absolute number.
- Across all groups the ladder is monotone and roughly geometric: each step down 8 -> 6 -> 5 -> 4 -> 3 multiplies KL by ~2-3x; 6-bit is ~2-3x the KL of 8-bit and still "near-lossless" (top-1 97 %); plain 4-bit is 13x 6-bit on WikiText; 3-bit is 2-3x worse than 4-bit and 2-bit is another 3x.
- Mixed recipes help most at 4-bit and below when they spend the saved bits on a few tensors (oQ4e 0.0117, MTPLX 0.012-0.022, GPTQ+8-bit set 0.0747 vs 0.1175), not by themselves at a given average bpw: oQ vs plain at equal size is only 5-11 % better KL in omlx#945. The recipe that matters is "which tensors get 8-bit" (embeddings/lm_head, GDN out_proj/in_proj_a/b, full-attn k/v, last blocks), matching yesterday's avlp12 finding (-18.9 % excess NLL for +1.6 % bytes).
- KL is not task quality. Where task data exist (ByteShape, ISTA, Quesma, Bonsai card), a GGUF Q4_K_M/UD-Q4_K_XL (KL ~0.01-0.02) matches BF16 on short-horizon benchmarks. Plain MLX 4-bit g64 has KL 0.03-0.46 depending on corpus, i.e. 2-20x worse than that class: **that is the case for moving off stock 4-bit**, but it is a distribution argument, not a task result (GAP).

### 1.3 Task-level evidence for 27B-class (additions to yesterday's table)

| evidence | result | tag |
|---|---|---|
| Prism card, 14 benchmarks, thinking mode, EvalScope + vLLM on H100 | FP16 86.32; UD-Q4_K_XL (5.2 bpw) 85.18 (98.7 %); UD-IQ2_XXS 2.8 bpw 72.59 (84.1 %); **Bonsai-2 1.72 bpw 84.78 (98.2 %)**. Per benchmark FP16 -> Bonsai: LiveCodeBench 90.05 -> 90.07, HumanEval+ 93.29 -> 95.12, MBPP+ 83.86 -> 83.07, IFEval 91.50 -> 91.31, **BFCL v3 76.74 -> 74.92**, MuSR 79.63 -> 70.63, MMLU-Redux 91.46 -> 89.09, MMMU-Pro 81.73 -> 75.49 | [card, vendor, n=1] `https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-mlx-2bit` |
| baa-ai `Qwen3.8-27B-RAM-13GB-MLX` (3.81 bpw, 13.0 GB incl. vision, "proprietary sensitivity allocation") | WikiText-2 PPL 6.46 vs bf16 5.99 (+7.8 %) and 13 GB GGUF 6.02; "agent-safety coherence gate PASS" (undefined); no MTP | [card] |
| OptiQ-4bit (261 of 498 tensors 8-bit, 18.9 GiB) | MMLU 84.1, GSM8K 96.1, IFEval 77.1, BFCL-V3 simple 93.5, HumanEval 92.1; no bf16 comparison on the card | [card] |
| Practitioner reports on Qwen3.6-27B (insiderllm roundup, 4 Reddit reports, "we didn't run this ourselves") | Q4 breaks tool-call JSON/diff formatting; errors and failure to call tools after ~30K context; Q5/Q6 recovered most; reasoning/math held | [community], anecdotal. Confounded (calibration + runtime changed too) `https://insiderllm.com/guides/qwen-3-6-q4-quant-coding-agents/` |
| Quesma, ByteShape, ISTA, Unsloth (yesterday's section 2.5) | unchanged: Q4_K_M ~ BF16 on TB2.1/GPQA; 3.0-3.5 bpw learned formats within ~1-3 points; <= 2.9 bpw loses 5-14 points aggregate | [repro]/[card] |

Known failure modes (all [community] unless noted): tool-call JSON/diff formatting at 4-bit, long-context drift after ~30K tokens, instruction-following on long rule lists, early truncation/stops at 3-bit when the DWQ teacher was not bf16 (deuce11, yesterday). A Prism-style 2-bit has MuSR -9 points and MMMU-Pro -6: knowledge/multi-hop reasoning degrades before code/tool scores do (HYPOTHESIS: matters for long agent runs that need retrieval from earlier context).

### 1.4 MTP head with a quantized target or head
- Our own: bundled/overlay head in 4-bit and 8-bit already run (memory doc: head 4-bit with 4-bit target). Acceptance per quant was NOT measured (section 6.2).
- External: ToPo-ToPo drafter card says bf16 and 4-bit drafters accept identically under greedy, bf16 slightly better on code [community]; Tess-27B full 4-bit build acceptance length ~2.9 -> ~2.8 [community]; MTPLX acceptance 0.95 / 0.88 / 0.80 at depths 1/2/3 on a coding task with a bf16 head on a 4-bit-g32 target [card]. Several NVFP4 builds keep the head bf16 by policy without measurement. One MLX pairing of 4-bit target + drafter showed no speedup [community]. GAP: no controlled sweep of head bits x target bits. The Bonsai pack has no MTP at all.

## 2. What is on Hugging Face right now (Qwen3.8-27B MLX, HF API 2026-10-28)

Sizes are file totals (weights incl. 0.86 GiB vision tower and bundled head where marked). Downloads are all-time counters as returned by the API.

| repo | recipe | GiB | dl / likes | MTP | note |
|---|---|---:|---|---|---|
| `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit` (2026-09-22) | ternary in 2-bit g128 + Hadamard (block 1024), "1.72 true / 2.25 stored bpw" | 8.01 (7.14 backbone) | 30.9K / 478 | **no** | needs custom loader; Apache-2.0 |
| `Jundot/Qwen3.8-27B-oQ2e-fp16-mtp`, `oQ2.5e-mtp` (2026-10-25) | oQ2e, oQ2.5e: 2-bit g64 13 %, 3-bit g128 69 %, 3-bit g64 5 %, 4-bit 1 %, 5-bit 10 %, bf16 2 % (oQ2.5e) | 11.73 / 11.77 (oQ2.5e backbone 10.62) | 159 / 163 dl | bundled (0.29 GiB) | the "2-bit" label is misleading: 3.64 bpw average; **g128 mix** |
| `Jundot/...-oQ3e-mtp` | 3-bit g64 83 %, 4-bit 5.9 %, 5-bit 9.2 %, bf16 1.9 %; 3.976 bpw avg | 12.86 (backbone 11.71) | 367 dl | bundled | no KL on card |
| `Jundot/...-oQ3.5e-mtp` | 3-bit g64 71.6 %, 4-bit 5.9 %, 5-bit 16.0 %, 6-bit 4.6 %; 4.249 bpw | 13.74 (backbone 12.59) | 502 dl / 3 | bundled | no KL on card |
| `Jundot/...-oQ4e-mtp` (the one we run) | 4-bit 80.8 %, 5-bit 17.4 %, bf16 1.9 %; 4.887 bpw; KL 0.0117 code / 0.0600 prose | 15.81 | 20.8K / 75 | bundled | |
| `scottlowry/...-oQ5e-mtp` (mirror; `Jundot/...-oQ5e` returns 401) | oQ5e | 18.90 | 274 dl | bundled | |
| `Jundot/...-oQ6e-mtp` / `-oQ8e-mtp` | 6-bit g64 90.5 % + 8-bit + bf16, 6.829 bpw / 8-bit | 22.09 / 27.94 | 2.2K / 2.6K | bundled | no KL on card |
| `mlx-community/Qwen3.8-27B-4bit` / `lmstudio-community/...-MLX-{4,5,6,8}bit` | stock affine g64 | 14.95 / 14.95-27.48 | millions (lmstudio ~3.4-3.6 M each) | no (overlay `mlx-community/...-MTP-{4,8}bit` 0.22 / 0.42 GiB) | what we use today |
| `AtomicChat/Qwen3.8-27B-MLX-AD-{3.50,3.70,3.80,4.50,5.00}bpw-DWQ-*GB` (2026-10-28) | the 3.50 card: uniform 3-bit g64 + clip + DWQ; others per-tensor | 11.82 / ~12.2 / 12.75 / 14.95 / ~16.4 | 140-290 dl | no | KL on card (section 1.2); also `AtomicChat/...-MLX-{5,6,8}bit/bf16` stock |
| `baa-ai/Qwen3.8-27B-RAM-13GB-MLX` | 3.81 bpw, aimed at 16 GB | 12.12 | 112 dl | no | PPL +7.8 % |
| `Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed` | 4-bit g32 + 8-bit sensitive set + bf16 GDN conv/head | 19.26 | **27.9K / 170** | bf16 head, depth 3 | MTPLX runtime, 58.7 tok/s on M5 Max [card] |
| `mlx-community/Qwen3.8-27B-OptiQ-4bit` | 261/498 tensors 8-bit | 18.95 | ~9.5K | no | |
| `JoshuaCalhoon/...-4bit-GPTQ` (g128) | KL 0.0747 | 14.60 | 197 dl | no | g128 |
| `leonsarmiento/...-3bit-mtp-mlx` | 3-bit g64 + 4-bit embed/head | 12.13 | 1.4K dl | bundled | speed-only card |
| `orcarouter/Qwen3.8-27B-MLX` | bf16 + KL table for 8/6/4 | 82.5 (multi-quant repo) | 1.5K | | the KL source |
| `airagrp/Qwen3.8-27B-QAT-NVFP4` | QAT NVFP4 (from QUASAR-QAT) | 19.15 | 303 dl | separate `mtp.safetensors` 0.79 | |
| `deuce11/...-6bit-RTN-MLX-TextOnly` | text-only 6-bit | 20.36 | 79 dl | no | |

Pattern: abundant fine-tunes/"uncensored"/"distilled" re-quants of the same base are noise for us; the usable same-base lines are stock affine, oQ*e (bundled head), Bonsai, MTPLX, AtomicChat/DWQ. Vision is dead weight everywhere; text-only repos exist (deuce11) but rarely.

## 3. Speed implications on Apple GPU

### 3.1 From MLX source (`.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp`, mlx-swift 0.32.3) [computed from source]
- Kernels are templated on bits {2,3,4,5,6,8} and group_size {32,64,128}; the affine path has qmv_fast (needs N%8==0 and K % (pack*2*32) == 0: 512 for 2/3/4/5-bit, 256 for 6/8-bit; every Qwen3.8 K (5120, 6144, 17408) satisfies it), qmv_wide (affine only on GPU gen >= 15), qmm/qmm_splitk, and **NAX (M5 neural accelerator) qmm** for affine when macOS >= 26.2, transposed, K % 64 == 0 and the activation is not fp32. NAX applies to every bit width in the same dispatch, so prefill on M5 is not bit-specific in routing. The fp modes (mxfp4/nvfp4/mxfp8) have their own qmv/qmm; an nvfp4-specific narrow qmv exists for M5 Max.
- Packing: 3-bit and 5-bit pack 8 values in 3/5 bytes (the unpack is more ALU than 4/8-bit); 2-bit is 16 per uint32. Decode (M=1) is bandwidth-bound, so the per-token cost scales with bytes unless unpack ALU becomes the bound; prefill (M >= 13) runs qmm/NAX, compute-bound, where the dequant ALU per weight tile is amortized over M rows.
- Hadamard: `hadamardTransform` exists in mlx-swift (`Ops.swift:1652`), enough for Bonsai's block-1024 transform.

### 3.2 Our numbers
- [internal] bench/results/speed-w2-L8: 4-bit qmv_wide ~275 GB/s (about half of the M5 Max 614 GB/s peak when several vectors share a weight pass), qmm ~170 GB/s; 26.7-26.9 ms/pass for all projections at M=1 over 14 GB streamed (= ~520 GB/s, i.e. ~85-90 % of the 614 GB/s roofline) [internal]. 8-bit measured at 98 % of a 515 GB/s bound (yesterday's doc).
- Synthetic per-bit kernel table (decode M=1, verify M=4, prefill M=1024) from `quanteval bits`: see section 6.
- Roofline ceilings for the candidate recipes (90 % of peak, no MTP, bytes per token = (26.896 - 1.27 embedding) B params x bpw / 8) [computed]:

| recipe (bpw) | GB/token | M4 base 120 | M5 base 153.6 | M4 Pro 273 | M5 Max 614 |
|---|---:|---:|---:|---:|---:|
| ternary Bonsai-2 (2.25 stored) | 7.2 | 15.0 | 19.2 | 34.1 | 76.7 |
| oQ2.5e (~3.2) | 10.3 | 10.5 | 13.5 | 24.0 | 53.9 |
| 3-bit g64 (3.5) | 11.2 | 9.6 | 12.3 | 21.9 | 49.3 |
| oQ3.5e (~3.7) | 11.9 | 9.1 | 11.7 | 20.7 | 46.6 |
| stock 4-bit (4.5) | 14.4 | 7.5 | 9.6 | 17.0 | 38.3 |
| oQ4e (~4.9) | 15.7 | 6.9 | 8.8 | 15.7 | 35.2 |
| 6-bit (6.5) | 20.8 | 5.2 | 6.6 | 11.8 | 26.5 |
| 8-bit (8.5) | 27.2 | 4.0 | 5.1 | 9.0 | 20.3 |

  Vendor-measured Bonsai-2 on M5 Max: 47.0 tok/s TG128 and 765 tok/s PP512 (M5 Pro 28.7 / 393, M4 Pro 18.0 / 125) on its own GGUF/PQ2_0 stack, pre-rotation build, "pending re-measurement" [card]: that is 61 % of our computed ceiling on M5 Max and 53 % on M4 Pro. The Prism ceilings are therefore a bound, not a forecast.
- So: going from stock 4-bit to oQ4e costs ~9 % decode (more bytes); 4 -> 6-bit costs 31 %; 4 -> 8-bit 47 %; 4 -> 3.5-bit gains ~29 %; 4 -> ternary gains ~100 %. MTP (x1.7-1.9 on our 4/8-bit; acceptance per quant in section 6) multiplies all of these.
- Prefill: Strim's 4-bit cold prefill and the dequant-in-tile proxy are in docs from lanes L11/L12 [internal, not re-read]. Whether 2/3-bit prefill is slower than 4-bit on NAX is measured below (M=1024 rows of the synthetic table). Mix-Quant (above) is the only literature on lowering prefill ALU and it needs fp4 activations: not available.

## 4. 16 GB and 8 GB feasibility

Budget (yesterday's assumptions, not re-measured; web search again found only conflicting community numbers for 16 GB: ~11-12 GB GPU limit "roughly 70-75 %", raise to ~13,000 MB suggested [community] `https://developer.apple.com/forums/thread/732035`, `https://llmconfigurator.com/en/guides/troubleshooting/increase-metal-vram-limit-apple-silicon`; GAP: no 16 GB measurement on macOS 27): U = min(wired limit, RAM - 5.5 GiB) = 10.5 GiB at 16 GB, 2.5 at 8 GB. F = backbone + MTP head + 0.15 GDN state + 2.0-2.5 (MLX cache, one prefill chunk 0.8, runtime).

| candidate (backbone GiB) | F with 2.0 / 2.5 overhead | room in U = 10.5 | context bf16 KV (64 KiB/tok) / q8 KV (34 KiB/tok) | verdict |
|---|---|---|---|---|
| ternary Bonsai-2 (7.14), MTP head grafted 0.29 | 9.6 / 10.1 | 0.9 / 0.4 GiB | 15K / 28K (2.0) ; 7K / 13K (2.5) [computed] | **only candidate that can fit 16 GB**, barely: 16-32K needs the lean overhead (MLX cache limit ~256 MB, 512-token prefill chunks), q8 KV, the trie off and nothing else running. If a lean macOS leaves U ~12 GiB (RAM - 4 GiB) the room doubles to ~2-2.4 GiB (45-70K q8). Quality: vendor 98.2 %, unverified |
| oQ2.5e (10.62) | 13.1 / 13.6 | -2.6 / -3.1 | none | does not fit (needs U >= 13.5: only with wired limit raised to ~14 GiB and macOS squeezed to 2 GiB: swap territory) |
| baa-ai / AtomicChat 3.5 bpw (~11-11.2) | ~13.5-14 | negative | none | does not fit |
| anything >= 3-bit | | | | does not fit |

- **16 GB: feasible only with a ~2-bit recipe, i.e. Bonsai-2; "experimental tier"** gated on (a) our own gate A/B on Bonsai (section 7 experiment 3), (b) a Hadamard-aware loader, (c) KV q8 and a small-RAM memory plan (section 5). Expected decode on a 16 GB base chip: M4 base ceiling 15 tok/s, M5 base 19 tok/s (vendor-realized fraction ~55-60 % => ~8-11 tok/s without MTP; M4 Pro 16 GB-class not sold, 24 GB minimum) [computed + card]. Do not promise agent-grade 16 GB.
- **8 GB: no.** The smallest same-model artifact is 7.14 GiB (Bonsai backbone) against a GPU budget of ~6-7 GiB total before KV, state, OS. Vendor claims a 3.9 GB 1-bit Bonsai-27B (Qwen3.6 base, `Bonsai-27B-mlx-1bit`, 89.5 % on the vendor average); that is a different base model and 1-bit is out of scope and below the quality bar (yesterday: IQ1 is near random on GPQA, no tool calling).

## 5. Engineering effort in Strim (code read 2026-10-28, working tree = HEAD + other lanes' hunks)

Findings from the code:
- `WeightStore.quantBits(w, s, groupSize: 64)` (`Sources/StrimCore/Weights.swift:97`): bits = 32 x packedCols / (groups x groupSize); returns 4 when the result is not in 2...8. Every caller passes the default 64: `embedding`, `qmm`, `linear` (Weights.swift), `OpTimer.linearCost` (`kk = scales.last * 64`), draft-vocab slicing, benches. **There is no read of `config.json`'s `quantization` block anywhere** (grep over Model.swift/QwenModel.swift/MTP.swift: zero hits), so mixed bits work purely through shape inference and mixed group sizes do not work at all. Computed consequences: 4-bit g128 -> infers 8 bits (garbage, no error); 3-bit g128 (oQ2.5e's main block, 69 % of weights) -> infers 6; 2-bit g128 (Bonsai) -> infers 4. Needs a guard before any new quant is loaded.
- Production matmul path is MLX `quantizedMatmul` only (`Layer.swift` MLP via `OpTimer.qmm`/`linear`, GDN/Attention via `store.linear`, `ChunkInvariantLinear` wraps `store.linear`). The hand-written `QGEMV` (hard-coded 4-bit, g64) is referenced only from benchmark commands in `main.swift`, not from model code. The GDN scan/blocked kernels, attention and norms operate on activations: weight-agnostic.
- `mlpFused` concatenates gate and up weights/scales/biases along rows and calls one qmm with bits inferred from the fused tensor: valid only if both have the same bits and group size. oQ configs observed (oq4e-mtp: 166 per-tensor overrides, none on gate/up/q/qkv; overrides on in_proj_a/b/z, out_proj, down_proj, k_proj, o_proj) never split gate/up, but a custom recipe could.
- MTP head: separate `WeightStore` with `keyPrefix`, bits inferred independently, bf16 `fc` handled by the absent-scales fallback in `linear`. Works with 4-bit and 8-bit overlays and bundled oQ heads today.
- Memory plan (`Sources/StrimEngine/Admission.swift`): RAM-scaled already (50 % of RAM default, `max(..., min(weights + 8 GiB, 80 % RAM))`, MLX cache budget/32, trie <= budget/5 and >= 1 GiB, `requestReserveBytes` fixed 6 GiB, workspace 0.8 GiB). It takes `weightFileBytes`, so a smaller quant is automatically smaller. But the constants are 64 GB-shaped: at 16 GB the reserve (6 GiB) + 1 GiB minimum trie + 0.8 chunk leave nothing; `Memory.memoryLimit` is `max(budget, 70 % RAM, weights + 2 GiB)` (`EngineCore.swift:263`), above any small-tier safe value. Not based on `recommendedMaxWorkingSetSize`.
- Model picker: `GET /v1/strim/models` (`ControlProduct.listModels`) returns `name, path, size_gb, kind` (`kind` "mtp" is guessed from the directory name). No quant tag, bpw, RAM requirement or "fits this Mac" flag. `EngineSlot` (actor) loads/unloads by path, so switching tiers at runtime is structurally there.
- Prefix disk cache fingerprint (`PrefixDisk.fingerprint`) hashes `config.json` + all safetensors names/sizes/mtimes of model and head + cut policy + `engineRev` ("strim-prefix-disk-r1"): a different quant gets its own directory automatically. `engineRev` must be bumped only when cached tensor semantics change (a Hadamard path changes numerics, so bump with it). The in-memory trie is per loaded model.
- Tests/gates: exactness goldens and gen16 reference ids were recorded on 4-bit; each shipped quant needs its own goldens (they cannot be shared; chunk-invariance/batch-parity tests are quant-independent in principle but their expected arrays are per model).
- Conversion: no Swift converter exists; the repo has no Python tools. MLX Swift has `quantized(_:groupSize:bits:)` (used in micro benches), so plain RTN with a mixed-bit predicate is writable in Swift.

| item | change | S/M/L | note |
|---|---|---|---|
| Per-tensor bits 2-8 at g64 | already works via shape inference; add tests with synthetic 2/3/5/6-bit tensors | S (0.5 d) | kernels exist |
| Per-tensor group size (g32/g64/g128) + bits from `config.json` `quantization` (global + per-path overrides), shape inference only as cross-check; reject on mismatch instead of guessing | Weights.swift + OpTimer + draft-vocab + call sites with literal 64 | M (1.5-2 d) | **prerequisite for oQ2.5e, g128 GPTQ, MTPLX g32, Bonsai** and a safety fix |
| mlpFused with unequal gate/up bits | fall back to unfused | S (0.5 d) | |
| Hadamard-rotated linears (Bonsai): `hadamard.json` (block 1024, shared sign vectors of widths 5120/6144/17408, 401 rotated weights, 1 inverse for the embedding, `gdn_v_grouped` layout flag), fp32 sign-multiply + `hadamardTransform` before each rotated matmul, inverse transform on embedding rows; new `model_type` | M (4-6 d incl. layout flag and numerical check vs the Python runtime on a fixed prompt) | extra elementwise passes per matmul at M=1: small vs bandwidth, unmeasured. Pack has no MTP (see next row) |
| MTP head for Bonsai | graft overlay head; the rotation touches only linear inputs so the hidden stream is in the natural basis (read from `runtime.py`: embedding is inverse-rotated back); acceptance with a 2-bit target is unmeasured | S to attempt (1 d), M if acceptance collapses | HYPOTHESIS |
| Tier selection by RAM + `recommendedMaxWorkingSetSize`; scaling of `requestReserveBytes`, trie minimum, MLX cache and `memoryLimit` for 16/24/32 GB | Admission.swift, EngineCore.swift | M (2-3 d) | already RAM-scaled in shape |
| KV q8 (16 full-attention layers) incl. trie serialization | needed for 16/24 GB | L (3-5 d + gates) | per yesterday; skip below 24 GB if the 16 GB tier is dropped |
| Picker/API: `quant`, `bpw`, `min_ram_gb`, `fits`, recommended flag; app UI list | StrimAPI/ControlProduct/app | S-M (2 d) | |
| Download of prebuilt MLX repos (resumable, size + sha256 from HF API, disk-space check), model catalog JSON shipped with the app | Swift-only, URLSession | M (3 d) | prebuilt repos are acceptable: no Python in the product; Apache-2.0 allows redistribution of mirrors on our own org if we want stability |
| Own converter in Swift (RTN with mixed-bit predicate, MTP graft) | mlx-swift `quantized` | M (3-4 d) | uncalibrated: no oQ/DWQ/GPTQ quality |
| Calibrated recipes (oQ imatrix, DWQ, GPTQ) | external Python job producing HF artifacts, never shipped in the app | L (weeks) and not needed while oQ*e repos exist | |
| Per-quant goldens + gates (gen16, batch parity, prefix exactness, mini agentbench) | | M per shipped tier (1-2 d each) | limit the number of tiers |
| `quanteval` command (this doc's section 6) | new `Cmd_QuantEval.swift` + one dispatch line | S (done as a spike, uncommitted) | |

**Overall (my estimate, HYPOTHESIS about calendar time for one engineer):**
- Ladder from existing prebuilt MLX repos for >= 24 GB (stock 6/8-bit, oQ3.5e/oQ4e/oQ5e/oQ6e, group-size handling, mlpFused guard, plan constants, picker fields, downloader, goldens for 3-4 tiers): **M, ~2-3 weeks**.
- Add the experimental 16 GB tier (Bonsai loader + MTP graft + KV q8 + small-RAM plan + gates): **+1.5-2 weeks (M-L)**, risk concentrated in quality on long agent runs and in MTP acceptance.
- Own calibrated quantization pipeline: **L, not recommended**; use community repos and re-evaluate with `quanteval`.

## 6. Local evidence

**STATUS: partial. Model-level runs (footprint, decode/prefill tok/s, MTP acceptance, KL/agreement vs the 8-bit) were NOT run; only a synthetic per-bit kernel bench was.** Reason: at 13:38-13:45 CET the machine was memory-saturated by other lanes (`vm.swapusage` used 13.6 of 14.3 GB, 0.8 GB unused, 23 GB wired by other processes). A first queued run (bench lock obtained) was killed by my own watchdog within seconds because swap had grown by 4.3 GB without any process of mine running; loading the 28 GB 8-bit reference on that machine would have pushed it into swap exhaustion. Nothing else was left running. All numbers below are **indicative** (other lanes were active, synthetic random weights, one shape, min of 5 x 16 chained matmuls).

Built in a snapshot (`git archive HEAD` of 901a732's parent, `--scratch-path /tmp/strim-build-qs`, `nice -n 19`, release): `strim quanteval ref|cmp|bits` (new `Sources/StrimCLI/Cmd_QuantEval.swift` + one `case "quanteval"` line in `Commands.swift`, both left uncommitted because `Commands.swift` carries other lanes' hunks). The `ref`/`cmp` pair is untested end-to-end (it compiles; the first end-to-end run is experiment 1 of section 7.3). Design: windows of 2048 tokens (fresh cache each), reference top-256 log-probs stored, KL(ref||cand) over the reference top-256, top-1 agreement, perplexity of both, plus 4 greedy 64-token continuations per corpus (teacher-forced agreement and max |delta log-prob|). Tail mass outside the top-256 is reported. Windows are independent, so long-context drift is not probed (limit).

### 6.1 Synthetic quantized-matmul speed per bit width (M5 Max 64 GB, one matrix N=17408, K=5120 = the MLP down/gate-sized shape; 8 rotating weight copies; macOS 27, NAX path active) [internal, indicative]
`strim quanteval bits`, raw: `bench/results/quant-update-20261028/bits.txt` (untracked).

| bits, group | decode M=1: ms / GB/s | verify M=4: ms / GB/s | prefill M=1024: ms / TFLOPS | M=1 relative to 4-bit g64 | roofline ratio (bits+0.5)/(4.5) |
|---|---|---|---|---:|---:|
| 2 g64 | 0.051 / 544 | 0.102 / 272 | 3.11 / 58.7 | 0.51 | 0.56 |
| 2 g128 | 0.055 / 458 | 0.106 / 237 | 3.12 / 58.5 | 0.55 | 0.53 |
| 3 g64 | 0.080 / 484 | 0.110 / 355 | 3.25 / 56.2 | 0.80 | 0.78 |
| 3 g128 | 0.070 / 514 | 0.110 / 330 | 3.22 / 56.8 | 0.70 | 0.72 |
| 4 g64 | 0.100 / 502 | 0.108 / 465 | 3.17 / 57.6 | 1.00 | 1.00 |
| 4 g128 | 0.091 / 519 | 0.115 / 411 | 3.16 / 57.8 | 0.91 | 0.94 |
| 5 g64 | 0.121 / 508 | 0.124 / 496 | 3.39 / 53.8 | 1.21 | 1.22 |
| 6 g64 | 0.136 / 531 | 0.147 / 494 | 3.43 / 53.3 | 1.36 | 1.44 |
| 8 g64 | 0.174 / 544 | 0.177 / 534 | 3.38 / 53.9 | 1.74 | 1.89 |

Findings (indicative, one shape):
1. **Decode (M=1) scales with bytes at every bit width**: 450-545 GB/s everywhere, no sign that the 3-bit/5-bit unpack or the 2-bit path is ALU-bound. The roofline table of section 3.2 is therefore valid for the matmul part of decode.
2. **Prefill is bit-width independent, and not slower at low bits**: 53-59 TFLOPS at M=1024 for all widths; 2-bit is ~10 % faster than 6/8-bit. The hypothesis in the brief (3/2-bit prefill slower because of dequant ALU) is refuted on this chip/OS with the NAX path.
3. **Verify (M=4, the MTP step) does NOT scale with bytes at low bits**: 2-bit 0.102 ms and 3-bit 0.110 ms cost the same as 4-bit (0.108 ms); only above 4-bit does the cost grow (6-bit +36 %, 8-bit +64 %). At M=4 the kernel is not bandwidth-bound below 4-bit (effective 237-355 GB/s). HYPOTHESIS: the speed advantage of 3-bit/2-bit under MTP is smaller than the roofline suggests (a 4 -> 2-bit model could gain ~1.9x on M=1 passes but only ~1.06x on M=4 verify passes, so its MTP speedup is lower and the net gain over 4-bit shrinks). To be measured end-to-end with `benchmtp` on a real low-bit checkpoint before any speed claim for the 16/24 GB tiers.
4. g128 vs g64: g128 is 5-10 % faster at 3/4-bit decode, and slightly slower at 2-bit (noise level).

### 6.2 Not measured (and why)
Load footprint, decode/prefill at 4K on 4/6/8-bit and oQ4e, MTP acceptance per quant, KL/top-1/max-logit-diff vs 8-bit: needs ~15-28 GB of free memory per model and a quiet machine. Reference numbers that already exist: 4-bit active 14.6-15.0 GiB with head, decode ~76-81 tok/s MTP on 4-bit and 17.2 / 33.3 tok/s (no MTP / MTP) on 8-bit [internal docs/MEMORY-2026-10-26.md, docs/QUANTIZATION-2026-10-25.md]. The run is ready: one command list in section 7.3 experiment 1.

## 7. Recommended ladder, verdict, first experiments

### 7.1 Recommended ladder (HYPOTHESES to be confirmed by gate A/B; sizes from the HF API, contexts [computed] with yesterday's U range and F = backbone + head + 0.15 + 2.5 GiB, single sequence, trie off)

Speed delta is the roofline ratio of bytes per token versus stock 4-bit (14.4 GB), so it is chip-independent, M=1 passes only. With MTP the verify pass (M=4) does not speed up below 4-bit (section 6.1), so sub-4-bit tiers gain less than shown once MTP is on (HYPOTHESIS, to be measured).

| RAM | recipe (repo) | weights+head GiB | context bf16 KV / q8 KV | decode vs stock 4-bit | quality evidence / expected loss |
|---|---|---:|---|---|---|
| 8 GB | not supported | - | - | - | smallest same-model file (7.14 GiB) exceeds the GPU budget |
| 16 GB | **experimental**: Ternary-Bonsai-2 (+ grafted 4-bit MTP head, q8 KV, trie off, lean plan) | 7.1 + 0.2 | 15K / 28K at best, 7K / 13K typical | roofline +100 %; vendor measured 47 tok/s on M5 Max without MTP vs our computed 4-bit ceiling of 38 [card, computed] | vendor 98.2 % of FP16 on 14 benchmarks, BFCL -1.8, MuSR -9 [card]; unverified; no long-agent data |
| 24 GB | oQ3.5e-mtp (fallback oQ3e if context is tight) | 12.6 + 0.3 (oQ3e: 11.7 + 0.3) | 40K / 75K (oQ3e: 55K / 100K) | +21 % (oQ3e +29 %) | no KL on the Jundot cards; comparable 3.8 bpw recipes have 3x the KL of 4.5-bit uniform on neutral text (0.148 vs 0.053) [card]; learned 3.0-3.5 bpw GGUF is near-lossless on short tasks (ByteShape/ISTA) [card]. Expect "small visible loss, long-run tool reliability unproven" |
| 32 GB | oQ4e-mtp (what we run) or an 8-bit-sensitive-set 4-bit (GPTQ-g128 style once g128 loads) | 14.95 | 100-140K / 190-260K | -8 % | oQ4e KL 0.0117 code / 0.060 prose [card]; Q4_K_M-class GGUF is task-equal to BF16 on TB2.1 [repro] |
| 36 GB | oQ5e-mtp (`scottlowry` mirror; Jundot's returns 401) | 18.0 + 0.3 | 100-160K / 190-300K | ~-26 % | no KL card; 5-bit plain KL is 2x 6-bit and ~0.6x 4-bit on omlx#945 [community] |
| 48 GB | oQ6e-mtp | 21.2 + 0.3 | 190-290K / full | ~-30 % | 6-bit plain: KL 0.0022, top-1 97 % [card], PPL +0.24 % code (avlp12) |
| 64 GB+ | oQ6e default, oQ8e as the reference/"max quality" option | 21.5 / 27.1 + 0.3 | full | -30 % / -47 % | 8-bit KL 0.0007, top-1 98.3 % [card] |

### 7.2 Does it make sense to switch the default 4-bit?
- **Yes, away from the stock uniform 4-bit g64, on every tier where +1 GiB is affordable (>= 32 GB); provisional until gate A on our own corpus.** Reasons: (1) every public KL measurement ranks plain MLX 4-bit g64 several times worse than 4-bit recipes that keep a small sensitive set at 5-8 bit (oQ4e 0.0117 vs plain 0.028 on different corpora; GPTQ + 8-bit set 0.0747 vs 0.1175 on the same corpus; MTPLX 1.7x), at +0.5-1.5 GiB and ~8 % decode; (2) the failure reports on long agent runs (tool-call JSON, drift past ~30K) are Q4-class; (3) the engine already loads oQ4e, so the switch is a default-model change, not new engineering.
- **Not shown:** that oQ4e or any MLX 4-bit variant matches BF16 on long multi-step agent tasks. The old doc's gate B (agentbench paired vs 8-bit) is still the arbiter. Do not switch the 64 GB default (already 6-bit class per the product plan).
- 3-bit and below only as tier-forced options, with the quality caveat stated in the picker.

### 7.3 The first 3 experiments (exact)
1. **Gate A on the local files, when >= 35 GB of RAM is free** (the machine was swap-saturated at the time of this run, section 6): `strim quanteval ref models/qwen38-8bit <out>/ref8.bin 2048 code=<ids> prose=<ids>`, then `strim quanteval cmp models/qwen38-4bit|qwen38-oq4e-mtp|qwen38-6bit <out>/ref8.bin`; token files from `strim tokenize --text`; same command later on oQ3.5e/oQ3e/oQ5e/oQ6e (download with `aria2c -x 4 -s 4 -k 1M -c`, 13.7 / 12.9 / 18.9 / 22.1 GiB; all g64 so they load on today's engine, 3-bit and 6-bit by shape inference) plus `benchctx` 4K and `benchmtp` (acceptance). Output: the table of section 6 with real numbers for the six ladder rungs. 1 day.
2. **Add the config-driven per-tensor bits/group-size read and the "reject, never guess" guard** (section 5, M), then rerun experiment 1 on `Jundot/...-oQ2.5e-mtp`, `JoshuaCalhoon/...-4bit-GPTQ` and `Youssofal/...-MTPLX-Optimized-Speed` (g128/g32). This also fixes today's silent mis-load. 2 days.
3. **Bonsai-2 feasibility spike for the 16 GB tier**: (a) in a scratch dir outside the repo run the vendor Python runtime on a fixed 512-token prompt and dump top-256 logprobs as the oracle; (b) a Swift `HadamardLinear` spike (sign multiply + `hadamardTransform` block 1024 + qmm g128/2-bit, embedding inverse, `gdn_v_grouped`) that must reproduce the oracle top-1 and KL < 0.01 on that prompt; (c) graft the 4-bit MTP head and measure acceptance; (d) run with `STRIM_MEM_BUDGET_GB=10.5`, trie off and the 4K/16K/32K prefill + decode peak footprint to confirm the 16 GB budget. Go/no-go for the 16 GB tier on (b)+(c)+(d) and then gate B on agentbench. 4-6 days.

### 7.4 Big versus small changes (summary)
- **Small**: choose a different prebuilt affine checkpoint at g64 (2-8 bit) - it loads today; picker fields; plan constants; mlpFused guard; per-quant goldens; `quanteval` harness.
- **Medium**: config-driven per-tensor bits and group size (also a correctness fix); RAM-tier auto-selection and download manager; Hadamard-rotated linears for Bonsai; MTP head acceptance work per quant.
- **Large**: KV quantization with trie serialization; calibrated quant pipeline (oQ/DWQ/GPTQ) in our own tooling (do not build); GGUF K/IQ import, vector/trellis formats, fp4 activation prefill (do not build).
