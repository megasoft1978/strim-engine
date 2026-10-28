# Rival study: rapid-mlx 0.15.7 (2026-10-28)

Purpose: find techniques Strim could reproduce independently (idea level). Read-only source study of the installed keg (`/opt/homebrew/Cellar/rapid-mlx/0.15.7_1/libexec/lib/python3.15/site-packages/rapid_mlx`, plus its `mlx_lm` 0.31.3). Nothing was executed or benchmarked; every gain below is an estimate. The vendored copy under `vendor/rapid-mlx-src` and `~/tools/rapid` (0.16.8) were not studied. Paths below are relative to `rapid_mlx/` unless they start with `Sources/`, `docs/` or `bench/`.

## 0. License and use restrictions

- rapid-mlx: Apache-2.0 (METADATA, `licenses/LICENSE`). NOTICE: began as vLLM-MLX (waybarrios, Apache-2.0), "extensively modified". No non-commercial or field-of-use clause found (grep for patent/non-commercial in dist-info: only the standard Apache text).
- Third-party parts inside it, each under its own license (NOTICE): MIT (Apple mlx-lm design in `compiled_decode.py`, `kernels/lane_matmul/` from TensorFold/mlx2, `kernels/qsa_stage1.py`, vendored mlx-vlm), Apache-2.0 (oMLX-derived GDN prefill kernel `gdn_prefill.py`, DeepSeek runtime), Ollama `speculate_depth.go` port (`spec_decode/mtp/draft_k_controller_v2.py`), MTPLX-derived `prompt_lookup.py`, PFlash by michaelasper (`pflash.py`), CC0/MIT image and audio runtimes (irrelevant).
- Rule for this repo: ideas only. No code, kernel source, constants tables or comments are to be copied into Strim. Where a technique originates in an MIT/Apache upstream (TensorFold, oMLX, Ollama, MTPLX), prefer re-deriving from the algorithm description and cite the idea, not the file. Strim is MIT; Apache-2.0 code would additionally need NOTICE handling, which is another reason to write from scratch.
- `docs/THIRD-PARTY.md` already records that `GDNMetal.swift` `blockedKernel` was ported from rapid-mlx `gdn_prefill.py` (Apache-2.0, credit in file header and NOTICE). That is the one existing derivation; every item below should be an independent implementation, and any future port needs its own THIRD-PARTY row.

## 1. Where Strim stands now (post wave 2, f808432)

From `bench/results/h2h-wave2-20261028/summary.md` (Strim only, indicative) and `h2h-final-20261028`:

- Cold prefill 16K/32K: -2.7/-2.9% vs mlx-vlm/rapid-mlx. Cause NOT found. Excluded already: chunk size, fused projections, MTP head cost (L3b: 0.0% at 16K/32K, so the L0 2.8% "head share" was a fenced attribution), GDN kernel (L5 merged +1.2%).
- c=4 512-token aggregate: 67.2 vs 70.6 tok/s (-4.9%). c=8 p95 TTFT +6.1% vs mlx-vlm. c=4 p95 is a TIE.
- Decode: Strim wins 24-41% over rapid-mlx (MTP on), single stream.

Back-of-envelope for the c=4 cell (128 output tokens, 523-token prompts; raw `rapid-mlx/pass1/w4s`): rapid-mlx per-request decode 26.2 tok/s at c=4 means a plain B=4 step of 38.2 ms. Wall = 2.45 s prefill + 128 x 38.2 ms = 7.3 s = 70 tok/s, matching the measured 70.6. Strim: 2.31 s + 128 x 41.4 ms (B=4 step after L10, `speed-w2-L10`) = 7.6 s = 67.4 tok/s, matching the measured 67.2. So the remaining c=4 gap is almost entirely the B=4 decode step: 41.4 vs ~38.2 ms (-3.2 ms needed). Prefill is no longer the problem there.

## 2. What rapid-mlx does, by area

### 2.1 Prefill
- Engine is mlx-lm 0.31.3 `BatchGenerator`; chunk 2048 (`scheduler.py` `SchedulerConfig.prefill_step_size`, `cli_parser.py:1240`). Per chunk: `mx.eval(cache states)` then `mx.clear_cache()` (`mlx_lm/generate.py` `PromptProcessingBatch.prompt`). One prompt chunk per `next()` call, interleaved 1:1 with a decode step. No custom prefill GEMM.
- Adaptive chunk under memory pressure (`scheduler.py` `_select_adaptive_prefill_size`, `_apply_adaptive_prefill_size`): only for prompts >= 32K tokens, shrinks 2048 to 1024/512/256 when Metal footprint reaches 70/80/88% of the cap, never grows back within a prefill. Strim has no equivalent (only after-the-fact `relieveMemoryPressure`, `EngineCore+Memory.swift`).
- GDN prefill: `gdn_prefill.py` wraps mlx-lm's `gated_delta_kernel` with a blocked Metal kernel (state in registers, TB=32 token blocks), design credited to oMLX. Strim already ships a port of it and a faster successor (L5: 2 value rows per thread, +1.2% e2e).
- GDN decode/projection fusion: `gdn_in_proj_fusion.py` (4 projections into 1 qmm, M <= 8, claims +0.9..2.0% decode, byte-exact by probe) and `qwen35_fused_gdn_decode.py` (conv+norm+recurrence in one launch, B=1 only). Strim: killed at L2 (0.1-0.55 ms/pass); fused GDN decode exists.
- `compiled_decode.py`: whole-step `mx.compile` replay with fixed-shape KV slab buckets (1023..16384) for B=1. Python graph-build removal. Strim: host build is 3.1 ms and already hidden by L10 `STRIM_PIPE_LAYERS`; compile was measured -3.1 ms and breaks rollback. Not applicable.
- `pflash.py`: lossy prompt compression (keep 20% of the middle of prompts > 32K, off by default). Rejected by Strim's quality gate; do not copy.
- `singleton_cache_fastpath.py`: keeps plain KVCache at B=1 because mlx-lm's batched cache forces an array mask. Strim keeps per-sequence caches always; this problem does not exist.

Explanation of the 16K/32K gap: nothing found in rapid-mlx that explains it. Same quantized matmuls, same chunk class. Untested candidates listed in item 10 of the ranking.

### 2.2 MTP speculative decode
- Depth controller: `spec_decode/mtp/draft_k_controller_v2.py`, a port of Ollama's EV controller. K = argmax over 0..max_k of E[committed tokens](K) / E[cost](K), cost EWMA per depth (alpha 0.3, +-25% clamp), acceptance EWMA per position (alpha 0.1, trusted after 10 samples), periodic probes of depth+1 (every 4 rounds, backoff to 512), K=0 "park". max_k default 3 (`SchedulerConfig.mtp_max_k`). For greedy requests `reproducible_depth.py` fixes one profile per process/model so identical requests give identical text.
- Strim: acceptance-EWMA hysteresis, depth 2..4, never parks (`SpecStream.round`, `minD = 2`). Strim's rule depends only on the request's own history, so it is already request-deterministic; rapid-mlx needs the fixed-profile workaround because its EV rule uses wall-clock costs and pooled cross-request acceptance. Parking would only matter at acceptance < ~35%, where Strim measured depth 2 still beating depth 0 (41.3 vs 25.2 tok/s on the natural prompt). Low value.
- Concurrency: the vendored MTP loop is B=1 only (`scheduler.py` `_install_mtp_vendored`, docstring "Single-request only"). Once an MTP request emits, `completion_batch_size` is forced to 1 so no one can join (`_lock_singleton_admission`); at B>1 it falls through to plain batched decode. A "continuous self-MTP" path exists but is default-off (`mtp_continuous_batching`, `spec_decode/mtp/continuous_*.py`, lane-level rollback in `ragged_cache.py`). Constrained requests (grammar, tool-bias, reasoning budget) also fall through to plain decode.
- Head context: in the server path `mtp_generate_step` gets the already-prefilled main cache and a single token as "prompt" (`scheduler.py` ~line 2146), so the MTP head cache starts empty at decode time and only sees generated tokens. That is why rapid-mlx pays zero head cost in prefill, and probably part of why its acceptance (and decode speed, 50 vs 67 tok/s) is lower. Strim's L3b windowed head found the same trade-off as neutral on prefill, so it stays killed.
- Prompt-lookup copy drafts: `spec_decode/mtp/prompt_lookup.py`, n-gram >= 8 (max 10), up to 24 copied tokens per block, EV-gated (`CopyDraftGate`), verified in one pass; works under sampling via exact speculative-sampling acceptance. Different design point from the short-suffix lookup Strim measured and rejected (`docs/SWIFT-NEXT.md:115`: coverage 44%/k=1 with 11% acceptance on prose, 1.80 tok/pass bound on code). Strim's own note (`SWIFT-NEXT.md:668`) says the long-copy case "would not show on the current prose-heavy corpus". New evidence is only that a rival ships it for agent edits; no Strim measurement on agent edit transcripts exists.
- Row-invariant "lane" quantized matmul: `kernels/lane_matmul/` (opt-in `RAPID_MLX_LANE_MATMUL=crossover|exact`). A small-M (1-32 rows) quantized matmul on M5 tensor units (Metal 4 `MetalPerformancePrimitives` `matmul2d`, driven through `mx.fast.metal_kernel`): reads each packed weight once for all rows, "16 rows cost about as much as one", same arithmetic for every row count, so a batched row equals the same row computed alone. Crossover vs stock MLX is 8 rows for 2-8 bit weights (their sweep, M5 Max), exactly where Strim L8 found the stock cliffs (M=6, 9, 11 and the M>=13 plateau at ~83 ms for the whole-model projections vs ~32 ms at M=1). This is the one rival technique that attacks Strim's measured batched-decode ceiling directly.

### 2.3 Continuous batching and scheduler
- Admission: FIFO queue into mlx-lm's `BatchGenerator` (`prefill_batch_size` 8, `completion_batch_size` 32, `max_num_seqs` 256 default; h2h used 4). Co-arriving requests are held up to 120 ms (`RAPID_ADMISSION_WINDOW_MS` 8 ms ticks, `engine_core.py` `_await_admission_wave`) so they prefill as one aligned wave. Reason given in code: ragged per-row offsets keep mlx-lm's batched attention on the array-mask slow path (their measured +47% aggregate, one wave vs staggered, B=8, other model). Side effect on metrics: every request in a wave reports the same TTFT (p50 == p95), as seen in the h2h raw data. Strim's per-sequence caches do not have the ragged-offset penalty, so the wave hold is not applicable.
- Decode step coalescing: up to 4 scheduler steps per executor round trip at depth (`engine_core.py` `_step_coalesced`), to cut asyncio hop overhead. Strim's engine loop is one Swift task with no per-token thread hop (L1 trace: HTTP and admission add nothing measurable). Not applicable.
- One-step-ahead decode pipelining: `mlx_lm/generate.py` `GenerationBatch._step` samples on device and calls `mx.async_eval(next_tokens)` BEFORE reading the current tokens back, so step N+1 is encoded and running while the host consumes step N. Strim's `EngineCore.decodeBatch` does forward, then `argMax(...).asArray` (blocking host read), then emit, then the next forward. L10 hides the host graph build inside a pass (asyncEval every 4 layers) but not the inter-step readback/emit gap. L4 measured only 0.1-1.2 ms/pass for the spec path; the plain batched path was not measured.
- `shortest_validated_tail` (`scheduler.py` `_validated_prompt_tail_cost`, `_select_waiting_request`, `_commit_waiting_selection`): when a prompt slot opens, pick among generator-compatible waiting requests the one with the least remaining uncached prompt work, ties by arrival. "Validated" = the request's attached prompt cache is structurally valid (batch dim 1, all layer offsets equal `cached_tokens`, `remaining == prompt[cached:]`, trimmable if fully cached); anything unverifiable is costed as a full cold prompt. Starvation bound: a request passed over `scheduling_max_deferrals` (8) times is forced next. Default is `fcfs`. Effect: cache-hot short continuations jump ahead of cold long prompts (SJF on the cache-adjusted tail).
- Strim: `Scheduler.pick` runs prefills FIFO by arrival within the class (`Scheduler.swift`), no tail-aware ordering.

### 2.4 Prefix cache
- `memory_cache.py` `MemoryAwarePrefixCache` (+ radix index `prefix_cache_index=radix`, `prefix_cache.py`): whole-prompt entries in a token trie, LRU by bytes (20% of available RAM, raised to a floor of 1/3 of post-weights Metal headroom up to 4 GB for one agent session), pressure-driven eviction tick, deep copy on hit. Hybrid (GDN) models: a stored entry is reusable only at its exact length unless `hybrid_state_checkpoints.py` recorded recurrent state at chunk boundaries (<= 4 checkpoints per layer, stride >= 2048, thin by smallest gap); a hit snaps down to the newest checkpoint. Message-boundary snapshots for agent sessions.
- Disk: saved on shutdown, loaded at start (`save_to_disk`/`load_from_disk`: `index.json` with `save_uuid`, `tokens.bin`, `entry_K.safetensors`, `_ckpt.safetensors`, staging dir + atomic swap, disk preflight). `--disable-disk-caches` opt out.
- Strim is ahead: 1,024-token trie blocks each carrying KV delta + GDN state + MTP block (exact at every block, hit == miss bitwise), per-node SHA-256-verified disk spill with no token ids on disk (`PrefixDisk.swift`, opt-in), W5 shared-prefix win 2.7x. h2h replay: both reuse 87.2% of T8. Strim's docs/COMPARISON "disk prefix cache missing" row is stale for the working tree (`PrefixDisk.swift`, `STRIM_PREFIX_DISK=1`); verify its commit state before publishing.
- Host work: `prompt_token_reuse.py` and `prompt_host_cache.py` avoid re-encoding shared prompt text. Strim's session ledger reuses ids by construction (`ARCHITECTURE.md` StrimPrompt). Not needed.

### 2.5 Memory controls
`memory_budget.py` `plan_metal_limit` (auto utilization 0.90-0.97 from measured weight footprint + 8% headroom, fed to `mx.set_memory_limit` and an admission gate that returns 503 when impossible), `--gpu-memory-utilization`, `--cache-memory-percent`, `--resident-memory-limit-gb`, emergency check every 16 steps (`engine_core.py`: `mx.clear_cache()` above threshold), idle prefix-cache release (`idle_cache_clear_seconds`), mlx-lm `wired_limit` context (wires weights to the recommended working set during generation). Strim: footprint-based admission and relief are stronger (phys_footprint, trie shrink, hot-session demotion); no wired-limit call (`Model.wiredLimitGB` is only printed), no idle release, no mid-prefill chunk shrink.

### 2.6 Request-level features
- Structured output: llguidance driven from an mlx-lm decode loop with its own Metal mask kernel (`api/guided.py`, `api/strict_json_schema.py`); tool calls constrained by a compiled grammar (`api/tool_grammar.py`: tool name and argument schema enforced, family wire format, special-token sentinels, compiled-grammar LRU). Runs as a logits processor, which disables MTP for that request.
- Thinking budget: `api/reasoning_budget.py` forces `</think>` by token id once N tokens are spent inside the span (logits override).
- Agent loop guard: `repetition_guard.py` exact token-periodicity detector (period <= 128, 3 repeats) that blocks the extending token or stops the request.
- Tool parsers: ~25 families (`tool_parsers/`); `tool_logits.py` jump-forward bias for structural XML tokens (moot with MTP).
- `response_cache.py`: exact-match full-response cache. `_sampler_fast_path.py`: one fused sorted-space top-p + temperature sampler instead of mlx-lm's two `@mx.compile` stages plus a vocab-sized scatter (their note: ~4.3 ms/token on a 35B MoE at B=1).

### 2.7 Server overheads
FastAPI/uvicorn on an asyncio loop with a single `mlx-step` worker thread; `RequestOutputCollector` aggregates outputs when the producer is faster than the consumer; `--stream-interval` default 1. TTFT in the raw h2h data is batch-synchronous because of the admission wave. Nothing here explains a throughput advantage; Strim's engine-side and client TTFT agree to the ms (L1 trace).

## 3. Findings with Strim sketches

Effort S < 4 h, M < 2 days, L longer. Exactness classes: EXACT (bit-identical to today), NEAR (same distribution or tokens within current batch-parity margins, opt-in until `checkbatchparity` + agentbench pass), NEW-LAW (new numerical law, new reference).

### F1. Tensor-unit row-invariant quantized matmul for 6-32 rows (lane qmm)
- What: `kernels/lane_matmul/matmul.py` (kernel), `installer.py` (routes projections by row count), `__init__.py` (CROSSOVER = 8 rows, modes crossover/exact).
- Why it helps: stock `qmv_wide` re-streams weights once per 5-row tile (steps at M=6, 9, 11) and M>=13 falls to `qmm_splitk` at ~170 GB/s effective (`speed-w2-L8-20261028`). A tensor-unit kernel that reads the packed weights once for up to 32 rows is bound by the 26 ms weight stream, not by M. Row count also becomes irrelevant to numerics (each row computed alone gives the same bits).
- Strim has it: no. L8 found "no cheap exact option" for stock kernels and proposed a 1-line MLX tile-cap change (-5.4 ms at M=8). This is a different mechanism (tensor units), not the killed hand-written GEMV (M=2-4, simd) or prefill GEMM (M>=1024) work.
- Sketch: new `Sources/StrimCore/LaneQMM.swift` + metal source via `MLXFast.metalKernel`, writing our own MSL from the algorithm description (per 16-row fragment, per weight group: tensor-unit product of x-block and unpacked 4-bit q, then `s*P + b*sum(x)`; fixed K-slice split chosen from shape only, slices added in order). Wire in `WeightStore.linear` only when `rows` in [6,32] and the weight is 4-bit gs64 (confirm layout). Order of work: (1) 30-minute feasibility: does a `metalKernel` with `#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>` compile under mlx-swift 0.32.3 (core 0.32.0 JIT)? (2) microbench at the real shapes with `benchqmmstep` (the serial 64-layer chain, not the isolated queue that overstated cliffs in L8) at M=1/4/6/8/12/16. (3) only then integrate.
- Expected gain: B=8 plain batched step 72 -> ~50 ms (projections 56 -> ~36 ms at M=8, plateau 83 -> ~40 ms at M>=13) means c=8 aggregate +25-35% on the decode phase, B>=6 batches generally, and it makes in-batch MTP verify (B x depth rows) and long copy-draft blocks economically possible (re-opening those needs their own gates; "in-batch MTP is a no-go" was about acceptance 0.6-0.7, not cost). No gain at B<=5 and none for c=4.
- Exactness: NEW-LAW (not bitwise equal to stock qmm). Using it for every M (including M=1) would make verify rows equal decode rows and batch rows equal solo rows, a better exactness story than today, but M=1 stock qmv is at 96.8% of roofline (L9), so keep stock for M<=5 and define the lane only for the batch/wide-verify regime; then results depend on batch size across the M=5/6 boundary exactly as today.
- Memory: reads existing packed weights in place if the scale/bias are read from their current arrays (small extra loads); an interleaved (s,b) copy would add ~12% of weight bytes (~1.9 GB) and break the +1 GB rule. Prefer the in-place variant.
- Confidence: medium on the existence and crossover (rival ships it and sweeps 34 checkpoints on an M5 Max, per its own comment), low-medium that Strim's shapes reach the claimed flatness (K=17408 down_proj, N=34816 gate+up). Kill rule: < 10% on the M=8 chain.

### F2. Sampled (temperature > 0) decode: remove per-row full-vocab sort and host sync
- What: rapid-mlx `_sampler_fast_path.py` (single fused sorted-space top-p/temperature sampler; documents the cost of mlx-lm's chain: scatter back to vocab order, two compile boundaries, ~4.3 ms/token).
- Strim has it: no. `Sampler.sample` (`Sources/StrimEngine/Sampler.swift`) does a full-vocab (248K) `sorted` and/or `argSort` + `cumsum` + `categorical` per row, then `.item()`; `decodeBatch` calls `pick` per member, i.e. B sorts and B host syncs per step. Greedy cells (all of h2h) never touch it; real clients usually send temperature (the rapid-mlx desktop default is 0.7).
- Sketch: one batched device op for all rows: `topK`/`argPartition` to K candidates (K = min(top_k or 64..256, V)), temperature + top-p on the K-wide slice only (sort K, not V), Gumbel-max with a position-keyed key as `SpecSampling` already does, single `asArray` for all rows. Files: `Sampler.swift`, `EngineCore.swift` (`pick`, `decodeBatch`). Effort S. Time `Sampler.sample` first (V=248K argSort on M5 Max); if < 0.5 ms/row stop.
- Expected gain: sampled c=4 aggregate +3-10% and sampled single-stream non-speculating decode a few %; zero on greedy cells. Exactness: same distribution; the (seed -> token) mapping changes for top-p/top-k requests when K-truncation differs, document it (sampled outputs are already not bitwise portable).
- Memory: none. Confidence: medium that the cost exists (code path is clear), low on its size.

### F3. B=4 plain decode step: close the 3.2 ms vs the rival's ~38.2 ms
- Observation (derived above): the entire residual c=4 aggregate gap.
- What the rival has that Strim lacks: a single batched attention call per layer (mlx-lm `BatchKVCache` with a left-padded array mask) versus Strim's per-sequence loop (`BatchedAttention.forward`, `Sources/StrimCore/Batch.swift`: per sequence 2 RoPE + append + SDPA, then `concatenated`), plus mlx-lm's one-step-ahead `async_eval` (section 2.3).
- Sketch, in order: (a) measure first: extend `benchdecodeanatomy` to B=4 with a dispatch census of the 16 attention layers (per-seq ops vs the rest); gate: the attention-side overhead must be >= 1.5 ms/step. (b) exact option: batch the RoPE for all sequences with per-sequence array offsets (elementwise, bit-exact; availability of an array-offset `MLXFast.RoPE` in mlx-swift is UNVERIFIED), keep per-sequence SDPA. (c) NEAR option: one SDPA over left-padded KV with an array mask when the lengths are close (changes reduction layout vs the B=1 path, so needs `checkbatchparity` and agentbench). (d) cross-step pipelining for plain batched steps (F4).
- Expected gain: 1-3 ms of 41.4 (2-7% on the c=4 cell); (b) alone is probably 0.5-1 ms. Effort M. Confidence low-medium; the 3.2 ms attribution is an inference from two aggregate numbers.

### F4. Cross-step async pipelining for plain batched decode
- What: `mlx_lm/generate.py` `GenerationBatch._step` (sample on device, `async_eval` the next step's token, only then read the current one). Finish detection lags one step; a finished sequence wastes one row for one step.
- Strim: `decodeBatch` is lock-step with a blocking read per step. L4 (device-fed verify) killed the equivalent for the spec path at 0.1-1.2 ms/pass, and L10 already hides the build; the remaining gap per plain step is readback + emit + the first pipe segment, likely ~0.5-1.5 ms.
- Sketch: feed the lazy `argMax` token array straight into the next `BatchModel.forward` embedding lookup, `asyncEval` it, then read the previous step's ids and emit. On stop/finish, drop the speculative extra row (cache rows must be trimmed or the finished member removed before reuse). Files: `EngineCore.swift` (`decodeBatch`), `Batch.swift`. Effort M.
- Expected gain: +1.5-3.5% at c=4/c=8 (plain B=4..8 steps). Exactness: EXACT (same math). Memory: one extra live logits row per member. Kill: < 1 ms/step saved. Confidence low.

### F5. Constrained decoding that keeps MTP
- What: llguidance-backed `api/guided.py`, `api/tool_grammar.py`; rival falls back to plain decode when a grammar is attached.
- Strim: none (`response_format`, `tool_choice=required` not enforced; `COMPARISON-FEATURES` lists it as the main feature gap).
- Sketch: write a small token-mask engine (JSON-schema subset to a pushdown over bytes, precomputed per-vocab token trie so a mask fill is O(allowed set)), not a binding to Rust (keeps the single-binary claim; the llguidance C API is an alternative, MIT). Apply masks (a) to the target logits for every verify row, advancing the grammar state along the draft chain, and (b) to the draft head's argmax so drafts stay legal. Prefix cache untouched (grammar state is per request). Files: new `Sources/StrimCore/Grammar*.swift`, hooks in `SpecStream.round` and `EngineCore.pick`, schema plumbing in `StrimServer/ChatRequest.swift`. Effort L; do JSON object + schema subset + tool-call grammar first.
- Gain: a feature (and tool-call validity for the agent harness), not a speed cell. Keeping MTP under constraints is a differentiator since the rival drops to plain decode. Exactness: constrained outputs are a new mode; greedy under a mask stays deterministic. Memory: small. Confidence: medium on feasibility, low on schedule.

### F6. Tail-aware (shortest-uncached-work) prefill ordering with a deferral cap
- What: section 2.3. Cost = prompt tokens still to prefill after the trie lookup; forced FIFO after 8 deferrals.
- Sketch: `Scheduler.Entry` gets `remainingPrefill` (set by `EngineCore` after `PrefixStore.lookup`), `pick` chooses `min(remainingPrefill, arrival)` among eligible prefills with a per-entry deferral counter. Files: `Scheduler.swift` (+ tests), a one-line setter in `EngineCore`. Effort S. Interactive/background classes stay above it.
- Gain: p50/p95 TTFT in mixed hot/cold workloads (agent continuations behind a cold 16K prompt). Zero on every h2h cell (homogeneous sizes, FIFO is optimal for equal jobs), so it must be judged on a new mixed cell. Exactness: EXACT (order only). Memory: none. Confidence: medium on benefit for agents, high that it is neutral in the published cells.

### F7. Short-prompt wave co-prefill (opt-in)
- What: rapid-mlx and mlx-vlm prefill co-arriving prompts as one padded batch (their c=8 512-token TTFT is the batch end, 4.36 s vs Strim 4.62 s). Single-stream Strim prefill at M=512 runs ~890 tok/s vs ~1000 at M>=1024 (`PREFILL-SPIKE` chunk table, "512 costs ~5%").
- Strim has pieces: `BatchModel.prefill` + batch-aware GDN kernel (`BATCH-PREFILL-2026-10-26.md`: B=2 S=1024 1.14x, B=4 S=1024 1.04x, negative at 4K, next-token match not exact).
- Sketch: for prompts <= 768 tokens arriving within one scheduler tick, group equal-length (or pad-to-bucket) prompts into one `BatchModel.prefill` wave, then hand each cache to the normal decode path (`BatchedModelCache` split). Files: `EngineCore.swift` (`coldChunk` wave branch), `Scheduler.swift`. Effort M. Measure S=512, B=2/4/8 with the existing `benchbatchprefill` first (not measured below 1024).
- Gain: c=8 512-token p95 TTFT -3..-8%, aggregate +1..2%; none at >= 4K. Exactness: NEAR at best (M changes qmm tiling), so opt-in. Memory: B x chunk transient (~0.8 GB per 1K rows, within +1 GB for B <= 2). Confidence low. Kill: < 3% p95.

### F8. Pressure-adaptive prefill chunk and idle buffer-cache release
- What: section 2.1 and 2.5.
- Sketch: in `EngineCore.coldChunk`, if `ProcessFootprint.bytes()` exceeds 80%/88% of `memoryBudgetBytes` while a prompt >= 32K is mid-prefill, halve the chunk for the remaining chunks (never grow back; trie blocks stay 1024-aligned by splitting a block into sub-chunks, not by changing block boundaries). Idle: `Memory.clearCache()` after N seconds with no work. Effort S.
- Gain: reliability of 32K+ prompts under load (the invalid 32K in-process rows were memory pressure), lower idle footprint. Not a throughput lever. Exactness: sub-chunk splitting inside a block changes qmm tiling, so it is a NEAR path used only under pressure; document as a degradation mode. Confidence: medium.

### F9. Long exact-copy draft blocks, measured offline first
- What: section 2.2. Gate on EV, min n-gram 8, copy up to ~24 tokens.
- Sketch: step 0, zero engine code: replay the agentbench transcripts (Swift/Go tasks) and count the fraction of assistant output tokens inside >= 8-token exact matches against earlier context (file contents, prior tool output). Proceed only if coverage on edit-heavy turns is >= 25%. Then a draft source that bypasses the head when a match exists (`SpecStream.round`), verify as one pass. The verify block must not exceed what the lane qmm (F1) makes cheap, and GDN rollback keeps per-token state at ~144 MiB per extra row (`MemoryModel.gdnBytesPerSequence` math), so blocks beyond ~8 rows break the +1 GB rule unless rollback uses replay instead.
- Gain: potentially 2-3x on copied spans in agent edits; zero on h2h cells. Exactness: NEAR (wide verify). Confidence: low until measured.

### F10. MLX core parity check for the 16K/32K prefill gap
- Observation: rapid-mlx requires `mlx>=0.32.1,<0.33` and was benchmarked on core 0.32.4 (installed `mlx-0.32.4`); Strim's mlx-swift 0.32.3 pins core 0.32.0 (`MLX_VERSION` define in `.build/checkouts/mlx-swift/Package.swift`). A newer core changes SDPA and NAX kernels between patch releases. Gap grows with context (-1..2% at 4K, -3% at 16K/32K), which points at attention or KV handling rather than the dense matmuls.
- Sketch (no engine change): build Strim against a newer MLX core (mlx-swift release or a patched checkout), A/B `benchprefill 16384` ABAB; separately try per-chunk `Memory.clearCache()` and KV preallocation (L6, 0.2-0.5% at 32K) as the other two candidates. Effort S for the A/B. Exactness: the core change may alter bits; gate with `checkprefix`. Confidence: low.

## 4. Ranked top 10

| # | Item | Cell targeted | Effort | Est. gain | Exactness | Memory | Conf. |
|---|---|---|---|---|---|---|---|
| 1 | F1 lane qmm (tensor units, 6-32 rows), gate on MPP compile + `benchqmmstep` | c=8 aggregate, B>=6 | L | +25-35% decode at B=8 | NEW-LAW | 0 (in place) | med/low |
| 2 | F2 sampled decode: top-K slice, batched, one sync | sampled c=4/8 | S | +3-10% sampled | NEAR (RNG map) | 0 | low |
| 3 | F3 B=4 step census, then batched RoPE (exact) | c=4 aggregate | M | +2-7% | EXACT / NEAR | 0 | low/med |
| 4 | F5 constrained decoding that keeps MTP | feature gap | L | n/a (feature) | NEW mode | small | med |
| 5 | F4 cross-step async batched decode | c=4/8 aggregate | M | +1.5-3.5% | EXACT | tiny | low |
| 6 | F6 shortest-uncached-tail prefill order + deferral cap | mixed-workload p50/p95 | S | 0 in h2h, real for agents | EXACT | 0 | med |
| 7 | F8 pressure-adaptive chunk, idle release | 32K+ robustness | S | reliability | NEAR (degraded mode only) | lower | med |
| 8 | F7 short-prompt wave co-prefill | c=8 512 p95 | M | -3..-8% p95 | NEAR | +0.8 GB/row | low |
| 9 | F9 long copy drafts (measure offline first) | agent edit decode | S then L | up to 2-3x on copied spans | NEAR | rollback state | low |
| 10 | F10 MLX core parity A/B | cold 16K/32K prefill | S | 0..3% | maybe changes bits | 0 | low |

Not ranked (no or negative value): fused projections, whole-step `mx.compile`, windowed head, chunk size, hand-written GEMV/GEMM (all already killed by Strim data); PFlash (lossy); admission-wave hold and step coalescing (solve mlx-lm/Python problems Strim does not have); EV parking depth controller (only helps below ~35% acceptance, where Strim still wins at depth 2); response cache (exact-repeat only); KV q8/q4 (memory feature, bf16 default in rapid too, defer as L7).

## 5. Where Strim is already better (do not regress)

- MTP + continuous batching + prefix trie in one engine. rapid-mlx MTP is single-sequence only and locks admission while it runs; constrained requests lose MTP.
- Prefix cache: block-exact at every 1,024 tokens with GDN and MTP state, hit == miss bitwise, 87.2% reuse on replay equal to the rival's whole-prompt+checkpoint scheme, 2.7x on shared-prefix concurrency. Do not coarsen blocks to 2,048 to copy their checkpoint stride.
- Per-sequence KV caches: no ragged-offset slow path, so no admission-wave hold is needed and p50 TTFT stays 25-45% below the rivals. Keep arrival-order service, the gap cap (`STRIM_PREFILL_GAP_MS`) and the priority classes.
- Adaptive depth driven only by the request's own acceptance (deterministic, no wall-clock input); rapid-mlx had to add a fixed per-process schedule to get reproducible greedy output.
- Memory: phys_footprint-based admission and relief, trie shrink order, hot-session demotion; per-node verified disk spill without token ids.
- Session token ledger (no re-encode, no tokenizer-boundary guesswork) and the 1,024-token trie cut at `<|im_start|>assistant`.
- Decode lead (24-41% over rapid-mlx) comes from the fused GDN decode kernel, the draft-vocab head and the L10 pipelined build; nothing in rapid-mlx's decode path is faster for B=1.

## 6. Unverified in this study

- rapid-mlx was not run; the B=4 38.2 ms step is inferred from client-side decode tok/s in `h2h-final` raw data.
- Whether mlx-swift 0.32.3 can JIT-compile a custom kernel that includes `MetalPerformancePrimitives` (gate for F1).
- Whether an array-offset `MLXFast.RoPE` exists in mlx-swift 0.32.3.
- The cause of the 2-3% cold prefill gap at 16K/32K.
- 0.16.8 behavior (vendored copy not read).
