# Qwen4 leak refresh and Strim fit (as of 2026-10-27)

Builds on /tmp/strim-research/qwen4-smaller-mac.md (not redone). Reliability tags: [OFFICIAL] Alibaba/HF card/config; [REPO] public code/PR read via gh/WebFetch; [LEAK-CREDIBLE] third-party analysis of real artifacts; [RUMOR] social/SEO/aggregator/prediction market; [COMPUTED] derived from a config value stated here; [ASSUMED] mine.
No Qwen4 weights, config.json, model card, API id or date exist anywhere verified. Every Qwen4-27B dimension below is inferred, not leaked verbatim.

## 1. Release date signals
| Signal | Date | Tag | Source |
|---|---|---|---|
| Alibaba: "Qwen4 is currently in training"; Apsara slide "Qwen4 Series Coming Soon" over Max / Flash / Plus / 27B | 2026-09-22 | OFFICIAL (written) + stage slide second-hand | https://stealthmodels.com/qwen-4 ; https://www.orcarouter.ai/blog/qwen-4-27b |
| Qwen3.8-Flash-Next card: "preview of the Qwen4 architecture" | 2026-08-26/27 | OFFICIAL | https://huggingface.co/Qwen/Qwen3.8-Flash-Next |
| Qwen Developers X posts "big or small?" then "let's do both!" | 2026-10-10 | RUMOR (no names) | stealthmodels |
| Arena anon 'Kalmia' first seen 2026-10-21; tokenizer test: garbles 6/8 Qwen-trip tokens, 0/40 others (Qwen3.7/3.8 same). Several checkpoints swapped 23-24 Oct | 2026-10-21..24 | LEAK-CREDIBLE for "Qwen tokenizer family", RUMOR for "is Qwen4" | https://x.com/aitrackerbot/status/2113096168863375668 ; https://live.aitracker.bot/kalmia-arena |
| Arena anon 'Kerria' listed under Alibaba (Qwen tokenizer); no evidence page, no tokenizer test | 2026-10-27 | RUMOR (tracker listing only) | https://live.aitracker.bot/kalmia-arena |
| Prediction market: launch before 2026-11-01 74-83% | 2026-10-26 | RUMOR | yottalabs, glukhov, search summaries |
| Apsara Amsterdam programme (10-29) features Qwen3.8-Max, no Qwen4 launch announced | 2026-10-26 | RUMOR/aggregator | stealthmodels |
| Earlier "September" leak (single YouTube-sourced) | July | RUMOR, already failed | https://www.geeky-gadgets.com/qwen-4-leaked-release/ |
| Cadence: Qwen3.8 Max 08-03, 27B weights 08-13/14 (~10 d lag) | Aug | inference | yottalabs |
| HF org Qwen page (fetched today): newest items Qwen-Image-2.1-Turbo, Qwen3Guard-Stream, Qwen-Drive-1.0-4B, Qwen3.8-Flash-Next(-FP8); no Qwen4 | 2026-10-27 | OFFICIAL (absence) | https://huggingface.co/Qwen |

## 2. Sizes and context
- Tiers named: Max, Plus, Flash, 27B open-weights [OFFICIAL slide, second-hand]. 27B dense vs MoE: not stated by Alibaba. "Qwen4-27B dense" appears in the title/scope of an Intel-side downstream kernel PR ("Enable Qwen3.8-flash-next 8 cards fp8 & int4 and optimize qwen4-27b", merged into analytics-zoo:downstream/v0.31.0, branch 2026-10-19; scope "Qwen4-27B dense at TP2 FP8, TP1/TP2 INT4, MTP draft=4"). PR itself not publicly readable; known via screenshot in https://x.com/0x0SojalSec and teardown https://github.com/satyajitghana/ai (content/articles/qwen4-27b-vllm-xpu.mdx, 2026-10-26) [LEAK-CREDIBLE]. Upstream vllm-xpu-kernels has no Qwen4-27B reference.
- Qwen4-35B-A3B working name: secondhand [RUMOR] (stealthmodels). "Qwen 4 Coder 32B-A3B": fake.
- 5-10T params = Qwen4.5/Qwen5 roadmap, not Qwen4 [OFFICIAL keynote, second-hand].
- Context: unknown for Qwen4-27B. Flash-Next is 262,144 native, 1M YaRN [OFFICIAL card]. Qwen3.8-27B is 262,144.
- License: unknown. Flash-Next is qwen-community-1.0 (not Apache); Qwen3.8-27B is Apache-2.0. Risk: 27B could move to community license [ASSUMED].

## 3. Architecture facts that matter to Strim
Confirmed only for Qwen3.8-Flash-Next (config.json fetched today, https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/config.json): model_type `qwen4_exp`, text model_type `qwen4_exp_text`, hidden 2560, 48 layers (3 linear_attention : 1 full_attention), 24 Q heads / 2 KV heads, head_dim 256, vocab 248,320, MTP 1 hybrid full_attention layer, no quantization field. Plus (card, prior report): HyperConnection/Gated Residual with 4 lanes rank 320, QSA (indexer ratio 4, 512 blocks = 2048 tokens, indexer 4 Q heads / 1 shared K head, index dim 128 per TensorFold notes), PLE/n-gram table 51B params hash-addressed from current + 2-3 previous tokens, 512 experts top-10 + 1 shared, 125B/6B active.

Inferred for a dense Qwen4-27B (all [ASSUMED] or [LEAK-CREDIBLE-by-reasoning], none verbatim):
- Hidden 5120, 24 Q / 4 KV heads: PR text "H5120" and per-rank "Q12/KV2" at TP2 imply 24/4 (Flash-Next would be Q12/KV1 at TP2). GDN "BA48/96" implies 48 V heads. Source: satyajitghana teardown.
- Carries Flash-Next "organs": 4-lane hyper-connection ("HC" in PR rows) and QSA. PLE: PR text silent; TensorFold and tqllm dense adapters (below) both include PLE in the dense admission. Whether a 27B has a PLE table and its size: UNKNOWN.
- Layer count, GDN:attn ratio: unknown. Predecessor is 64 layers, 3:1. Flash-Next is also 3:1. Likely 3:1 [ASSUMED].
- Vocab: 248,320 on both existing models; likely unchanged [ASSUMED]. Tokenizer.json sha not available.
- MTP: 1 layer; vLLM config n_predict=1 and `index_share_for_mtp_iteration` flag (QSA selection shared across MTP iterations) [REPO via teardown]. Intel PR says draft=4 meaning one layer replayed 4 times.
- Chat template / tool-call format: no leak. Flash-Next/3.8 already have enable_thinking / preserve_thinking / reasoning_effort.
- Quantization recommendation: none from Alibaba. Third parties: FP8 (Qwen/Qwen3.8-Flash-Next-FP8), NVFP4 (NVIDIA), NF4 for PLE table (vllm #60670). Placeholder HF repo https://huggingface.co/IteraCompute/Qwen4-27B-NVFP4 (created 2026-10-14, "work-in-progress", 0 bytes, no base_model): third-party, not real weights.
- Norm convention hazard: HF centered norms use `1 + gamma`; MLX checkpoints may carry pre-shifted gains (mlx-vlm #2111/#2114 closed, #2417 merged "Fix prequantized Qwen4 PLE loading").

## 4. Repos, PRs (queried 2026-10-27 via gh)
Naming: everything is `qwen4_exp` / `Qwen4Exp` (Flash-Next). No `qwen4` model_type for a 27B anywhere upstream yet.
- ml-explore/mlx-lm: #1788 "Add Qwen3.8-Flash-Next (qwen4_exp)" OPEN, label "await verification", 2026-08-26; #1821 "Trimmable ArraysCache alternative" open (relevant to MTP/prefix-cache-like rollback).
- Blaizzy/mlx-vlm: MERGED #2034 (n-gram shard gathers), #2126 (QSA cache reuse + batched parity), #2417 (prequantized Qwen4 PLE loading), #2046 (Qwen3.8 MTP draft depth); closed #2111, #2114, #2038. So mlx-vlm has a working Python reference for qwen4_exp: usable as Strim's day-0 oracle.
- huggingface/transformers: `models/qwen4_exp` merged (2026-08-26 per stealthmodels); open #49923 (eager NaNs with left padding), #49694; merged #49840 (indexer position cache lifecycle, 2026-10-22).
- ggml-org/llama.cpp: #27739 "model : add Qwen4-Exp" closed (superseded; qwen4exp support merged by #27941, #27880, #29824, #30602 fused hc_post, #28770 CUDA sparse FA); open #29286 "sanity check for dflash n_embd_inp_enc and qwen4 ple_n_heads", #31185 external PLE file loading (2026-10-26).
- vllm-project/vllm: registry Qwen4ExpForCausalLM, Qwen4ExpForConditionalGeneration, Qwen4ExpMTP on main; merged #57387 (upstream configs), #54371 (PLE offload), #57497; open #53909 (fuse op), #59528 (QSA ring-buffer bug), #64022 (2026-10-27 AMD MTP draft), #63908, #63849. Zero PRs naming Qwen4-27B (only the Intel downstream fork).
- sgl-project/sglang: #36585 (native Qwen4-Exp, open, agent-authored), #38492 draft (RecoverSSM for MTP verify), #46248, #46191 (host KV tier for QSA), many open Ascend/AMD/Intel PRs through 2026-10-26.
- Competitor engines with a "dense Qwen4" adapter built from the Flash-Next block, no checkpoint: ashhart/TensorFold docs/recipes/qwen4-dense.md ("dense version of the related Flash Next architecture... No released Qwen4-27B checkpoint was available... supplied kernel notes establish supported shapes, not the complete model configuration"; requires hidden divisible by 256, GDN head dim 128, conv len 4, attn head dim 256, index dim 128; refuses MoE and undeclared MTP); turbo-tan/tqllm PR #15 "Qwen4.0 preparation: dense Qwen4 graph on the Flash-Next block" (HC mixer + gated attention with QSA + GDN + dense SwiGLU + PLE via ple_block; 2026-10-25); warpfront/hipfire PR #929 (merged 2026-10-20, "Qwen4 dense FFN"). These are inferences by third parties from the same kernel notes: they corroborate each other but not an independent source.

### 4b. Coordinator lead: fork feal87/myllama.cpp (checked 2026-10-27; single-fork evidence, not official)
- Repo is a plain fork of ggml-org/llama.cpp (357 ahead / 201 behind; last push 2026-10-19; branches master, experiment/moe-expert-ngram, experimental/permanent-l2-pool). Most commits are upstream merges. Fork-only work is storage/offload plumbing (disk-stage expert read-ahead, L2 expert pool, direct-read lazy PLE, Windows direct I/O), which is why its src/models/qwen4exp.cpp is 2238 lines vs 1262 non-blank lines upstream (101,892 B vs 74,872 B).
- NOT a different architecture and NOT a placeholder: upstream ggml-org/llama.cpp already ships the same file `src/models/qwen4exp.cpp` + `conversion/qwen4exp.py` (arch `QWEN4EXP`, converter registered for `Qwen4ExpForConditionalGeneration` / `Qwen4ExpForCausalLM`), actively edited today (#31243 2026-10-27, #31142 10-26, #31028 "qwen: merge tensors on convert" 10-25; earlier #29825, #29958, #29994, #30613 k-pool). It is Qwen3.8-Flash-Next's architecture, i.e. what the HF config.json above already shows (GDN + QSA, 3:1, HC, PLE, MoE, MTP).
- Why the hparams look DeepSeek-V4-like: field names `dsv4_hc_mult`, `dsv4_compress_ratios`, `hc_low_rank`, hyper-connection sinkhorn iterations and KV keys are shared with llama.cpp's DEEPSEEK4 / GLM5_NEXT ("glm5-next") code (same mHC and k-pool machinery, upstream tests treat QWEN4EXP and GLM5_NEXT together). Names are llama.cpp implementation borrowing, not evidence that Qwen4 is a DeepSeek derivative.
- It is MoE-only in llama.cpp: upstream qwen4exp.cpp builds `ffn_gate_inp`, `ffn_*_exps`, shared-expert gate and GGML_ASSERTs `ffn_gate_inp != nullptr` for every layer (line ~1246); `case 48: LLM_TYPE_A3B` is only a size label. tests/test-llama-archs.cpp lists QWEN4EXP among MoE archs. There is NO dense Qwen4 path in llama.cpp, no `qwen4` (non-exp) arch, no Qwen4-27B: consistent with section 4, no upstream engine knows a dense Qwen4.
- Test fixture values (tests/test-llama-archs.cpp, upstream) are synthetic, not model dimensions: hc count 4, hc low rank 8, sinkhorn iterations 2, compress ratio 4, PLE ngram size 3 with 2 heads per ngram (n_heads 4), indexer key length = head dim, top_k 131072, block/kpool 4, local blocks 1, SSM conv 4, state 128, inner 256. Real-config values (also in section 3): ratio 4, 4 HC lanes, GDN head dim 128, conv 4, attn head dim 256 agree with these.
- Extra converter facts (upstream conversion/qwen4exp.py): the MTP head is "one full-attention QSA block after the trunk, fed by the trunk's hc-wide residual" (so MTP input is the 4-lane residual, not a single hidden); MTP never reads PLE; QSA layers must share one compress ratio; QSA needs ratio > 1 dividing the indexer budget. `full_attention_interval` is also read from config (layer = `(i+1) % interval != 0` is recurrent), same rule as Strim's `%4` but configurable.
- Implication for ~27B dense Qwen4 drop-in: the fork adds nothing about it; it reinforces that the only shipped new-gen architecture is the 125B MoE one and that a dense Qwen4 would need (at minimum) a new converter/arch in every engine; none exists. A Strim port of Flash-Next-style features should follow upstream llama.cpp (QSA k-pool selection, HC combine/post fused ops, MTP fed by hc-wide residual) rather than the fork.

## 5. Benchmark / quality claims
No measured Qwen4-27B result exists. Kalmia "beat GPT-6.1 Sol Ultra on one prompt set" is anecdotal [RUMOR]. "Qwen 4 Max Preview 53" not on Artificial Analysis; "Qwen4-Coder 82% SWE-bench" from an illustrative page. Forecast tables on stealthmodels (27B HLE 34-42, Terminal-Bench 6-29) are editorial guesses dated 2026-09-28. Only measured numbers are for Flash-Next preview (vendor: DeepSWE 58.7, SWE-bench Pro 62.5, LiveCodeBench v6 91.9; one tester: Flash-Next failed a game task 5x where Qwen3.8-27B passed). Do not use any as Strim claims.

## 6. Memory fit for Strim
Baseline (Qwen3.8-27B, measured/computed in prior report): weights 15.17 GiB on disk (4-bit g64 + MTP head), 64 KiB/token KV + 4 KiB MTP KV, ~147 MiB GDN+conv per sequence, chunk transient ~0.8 GiB.

Scenario A: dense Qwen4-27B, same 5120/64/24Q-4KV/256 skeleton, plus HC + QSA, NO large PLE.
- Weights: ~15.2 GiB + HC projections (rank 320 gate/mix per layer; size not published) [ASSUMED < 1 GiB]. Weights unchanged otherwise [assumed layer count 64].
- KV: 64 KiB/token [computed from leaked heads 24/4 + assumed 16 attn layers]. QSA does NOT shrink storage (it selects from the full cache); it cuts decode attention reads to ~2051 positions.
- QSA indexer cache: compressed keys ratio 4, index dim 128, bf16 -> 128 x 2 / 4 = 64 B/token/layer, x16 = 1 KiB/token [ASSUMED dims; vLLM #59528/sglang #46191 confirm an extra cache exists]. Plus a few tail tokens.
- HC residual: 4 lanes x 5120 x 2 B = 40 KiB per in-flight token (activation, not cached): ~40 MiB per 1024-token prefill chunk [COMPUTED from assumed 4 lanes].
- Full 262,144 ctx: KV 16 GiB + MTP 1 GiB + indexer 0.25 GiB + GDN 0.15 = ~17.4 GiB per sequence. Total with weights 15.2 + 0.8 = ~33.4 GiB for ONE full-context sequence. Fits 64 GB (wired 56 GiB) with ~22 GiB left for prefix trie + MLX cache (default 12 + 4 GiB ok). Answer: YES, a ~27B dense with this skeleton fits 64 GB with full context + prefix cache, 1 sequence; 2 full-context sequences (51 GiB) leave almost no trie.
- Smaller Macs: same table as prior report within +0.3 GiB (indexer) + HC activation 40 MiB: 32 GiB ~145K ctx raised-limit; 36 GiB ~205K; 48 GiB full 262K; 24 GiB marginal. Plus the PLE caveat below.

Scenario B: dense 27B WITH a PLE n-gram table (TensorFold/tqllm adapters include PLE geometry; size UNKNOWN).
- Each 10B PLE params at 4.5 bpw = 5.2 GiB [COMPUTED]. Flash-Next ratio would be 51B params = 26.7 GiB at 4-bit [COMPUTED from card]; applied to a 27B that would make resident weights ~42 GiB: 64 GB ok with ~14 GiB for KV (~200K tokens, no trie), 48 GB no. The table is hash-gather (16 rows/token, positions precomputable), so offloading / mmap streaming is possible (vLLM/SGLang do it) but Strim has no PLE path [REPO facts, Strim status from prior report]. Pure assumption which scenario applies.

Scenario C (llama.cpp only implements this MoE form): Flash-Next-style 125B-A6B MoE (the 'Qwen4-35B-A3B' naming is rumor; 125B is the only sized artifact).
- 125B x 4.5 bpw = 70.3 GB = 65.5 GiB [COMPUTED]. Of that 51B PLE = 26.7 GiB, 4B MTP, 74B body/experts = 38.8 GiB.
- Does NOT fit 64 GB resident (wired 56 GiB, 65.5 needed). With PLE streamed from SSD: 38.8 + 4B MTP (2.1) + KV: Flash-Next KV = 12 attn layers x 2 x 2 KV heads x 256 x 2 B = 24 KiB/token [COMPUTED] -> 262K = 6 GiB. ~47 GiB resident, fits 64 GB, needs NO MoE-less engine: Strim has zero MoE/QSA/HC/PLE code, est 2-4 weeks (prior report [ASSUMED]). Needs 96 GB+ for PLE resident. Decode speed upside: 6B active -> bandwidth-bound decode could be several times the 27B's, but PLE gather and router add cost [ASSUMED].
- A 35B-A3B (rumor) at 4.5 bpw would be 19.7 GB = 18.4 GiB [COMPUTED], fits 32 GB+ if no PLE.

## 7. Verdict
- P(Qwen4-27B weights public by 2026-11-01): ~45% (market says 74-83% but is a rumor; HF org empty today, Amsterdam Apsara programme lists no Qwen4). By 2026-11-15: ~70%. By 2026-12-31: ~90%. [my judgment]
- P(27B is dense): ~75%. P(it uses HC + QSA, i.e. Flash-Next block): ~70% (three independent third parties built the same assumption from the same kernel notes, so the evidence is correlated, not independent). P(plain Qwen3.8-style skeleton, no HC/QSA): ~15%. P(MoE or other): ~10-15%.
- P(drop-in switch = new weights + config-only change in Strim): <5%. P(plain-skeleton scenario, 1-2 days work): ~15%. Likely path (HC + QSA + maybe PLE): days to 2-3 weeks of kernel work, with mlx-vlm already giving an oracle. Realistic Strim-on-Qwen4 timing: weights on day D, working port D+2 days (plain skeleton) to D+2-3 weeks (HC + QSA + PLE offload).
- Strim hardcodes that will break (from prior report A3; verified by third-party leaks here):
  - hidden `5120` literals (QwenModel/MTP/SpecStream): same size likely, but must be config-driven anyway.
  - `(layer+1) % 4` attention pattern (Layer.swift:83, Batch.swift:28,79,198) and `layers: 64`: read `layer_types`.
  - Attention: QSA indexer + top-k block selection + compressed-key cache; new cache kind in PrefixCache nodes, admission and exactness check; MTP can share selection (`index_share_for_mtp_iteration`).
  - MTP head input becomes the hc-wide (4-lane) residual and uses a QSA layer (llama.cpp converter); today's MTP.swift assumes a single hidden vector.
  - HC 4-lane residual: new ops, 4x residual width, norm gamma convention (1+gamma vs pre-shifted).
  - PLE n-gram table: new weight type, hashing from current + previous tokens (prior-token state must be in the prefix cache node), offload/mmap decision.
  - Draft vocab json bound to tokenizer sha256, chat template renderer, ToolCallParser, StrimPrompt ledger: unknown until tokenizer.json/template published; regen/diff on day 0.
  - MemoryModel constants (64 KiB/token, 4 KiB MTP, 147 MiB GDN, 0.95 weights factor, 800 MiB transient): recompute; add indexer bytes/token and PLE resident bytes.
  - GDN Metal kernels (48V/16QK x128, conv 4): expected to match (GDN head dims 128 in both released models and in third-party notes) [ASSUMED].
  - Gates X1-X4 and perf baselines: regenerate from mlx-vlm oracle (qwen4_exp support merged there).

## 8. Monitoring list (poll daily)
- HF org listing sorted by recent: https://huggingface.co/Qwen/models?sort=modified ; collections https://huggingface.co/Qwen/collections ; API: `curl -s "https://huggingface.co/api/models?author=Qwen&sort=lastModified&direction=-1&limit=20"` and grep qwen4|Qwen4. Also ModelScope https://modelscope.cn/organization/Qwen.
- Official: https://qwen.ai/blog, https://github.com/QwenLM (new repo `Qwen4`, like QwenLM/Qwen3.8), X @Alibaba_Qwen, @JustinLin610-style Qwen dev accounts (@Qwen developers), https://x.com/aitrackerbot, https://live.aitracker.bot (kalmia, kerria).
- Code (run `gh search prs --repo R "qwen4" --limit 20 --json number,title,state,createdAt`): ml-explore/mlx-lm, Blaizzy/mlx-vlm, huggingface/transformers, ggml-org/llama.cpp, vllm-project/vllm, sgl-project/sglang, plus `gh search code "Qwen4ForCausalLM"`, `"qwen4_text"`, `"Qwen4-27B"`, `"qwen4_dense"`. Trigger conditions: a model_type other than `qwen4_exp`, a `Qwen4DenseForCausalLM`/`qwen4` registry entry, or a transformers `models/qwen4` dir.
- Third-party engines that pre-build the dense graph: ashhart/TensorFold (docs/recipes/qwen4-dense.md), turbo-tan/tqllm PR #15, warpfront/hipfire, gdevenyi/FreeToken, tpurtell/cuteafd. Their commits will reveal geometry the day a config is visible.
- Quantizers who get early access: IteraCompute/Qwen4-27B-NVFP4 (placeholder today), mlx-community, unsloth, nvidia, bartowski; search HF `qwen4` daily: `curl -s "https://huggingface.co/api/models?search=qwen4&sort=createdAt&direction=-1&limit=30"`.
- Keywords: "Qwen4-27B", "Qwen4 27B dense", "qwen4_exp_text", "Kalmia", "Kerria", "Qwen 4 weights", "Qwen4 Apsara Amsterdam 2026-10-29".
- Trigger actions on hit: fetch config.json + tokenizer.json + chat_template.jinja, run the config diff, decide scenario A/B/C within 30 min (prior report A4).

## Unresolved
- Qwen4-27B layer count, GDN ratio, HC lane count, PLE presence/size, context length, license, template/tool format: not leaked.
- Kalmia/Kerria identity unproven; both only tokenizer-based.
- Intel downstream PR not directly read; relied on screenshot + teardown by a third party.
- Strim GDN kernel dimension hardcoding not inspected (inherited).
