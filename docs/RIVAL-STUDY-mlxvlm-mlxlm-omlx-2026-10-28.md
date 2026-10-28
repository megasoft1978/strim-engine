# Rival study: mlx-vlm, mlx-lm, oMLX (2026-10-28)

Read-only, idea-level study. No code copied; every item is a description of behaviour that Strim would reimplement independently. Nothing here was benchmarked by this study; all gains are estimates and say so.

## Licenses (recorded first)

| Project | Version read | License | Evidence |
|---|---|---|---|
| mlx-vlm | 0.7.10 (.venv-sprint) | MIT | `mlx_vlm-0.7.10.dist-info/METADATA` (License + classifier) |
| mlx-lm | 0.32.2 (.venv-sprint), 0.31.2 (global python3.12) | MIT | both `METADATA` files |
| oMLX | 0.4.5.dev1 (/Applications/oMLX.app, Python source in Contents/Resources/omlx) | Apache-2.0 | `# SPDX-License-Identifier: Apache-2.0` header in every omlx/*.py read; no LICENSE file found in the bundle. GitHub repo NOT fetched, so 0.7.x is unexplored |
| MLX / mlx-swift Cmlx | .build/checkouts/mlx-swift (0.32.x) | not re-checked here | only read for behaviour |

Strim already ships an Apache-2.0-derived kernel (docs/BLOCKED-GDN-PREFILL-2026-10-26.md). Everything below is a behaviour description, not a port.

## Why mlx-vlm prefills 16K/32K about 3% faster (answer first)

The per-layer math is not different. mlx-vlm qwen3_5 (`models/qwen3_5/language.py`: `Qwen3_5DecoderLayer`, `Qwen3_5GatedDeltaNet`, `Qwen3_5Attention`, `Qwen3_5MLP`) is plain stock MLX: unfused gate/up (two projections), `mx.compile(shapeless)` swiglu, `mx.fast.rms_norm`, `mx.fast.scaled_dot_product_attention` with the cache, a sequential (not chunked) GDN recurrence kernel on Metal. Strim already has fused gate/up, compiled elementwise chains, a blocked GDN kernel, last-token lm_head. Settings differ little: prefill step 2048 (`generate/common.py: DEFAULT_PREFILL_STEP_SIZE`) vs Strim 1024 (Strim measured chunk size as dead, +-0.3%); per-chunk `mx.eval(cache states)` + `mx.clear_cache()` (`generate/ar.py` ~l.506-513).

Numbers already in the repo explain the gap without any kernel difference:
- Strim L0 summary: the MTP head costs 2.8% of cold prefill at both 4K and 16K (head GEMMs + attention + mtp_other).
- h2h: 16K TTFT Strim 17.24 s vs mlx-vlm 16.73 s = 0.51 s = 3.0%; L0 plain 16K wall 17.3 s x 2.8% = 0.49 s. 32K: 1.10 s of 37.3 s = 2.9%.
- mlx-vlm ran WITHOUT MTP in h2h, so it never pays this cost. rapid-mlx (MTP on) is only about 1.2% behind mlx-vlm, so its head work is cheaper than Strim's.
- Strim in-process 4K prefill (1025 tok/s, L0) already exceeds mlx-vlm's served 4K (998.6).

Conclusion (medium-high confidence, not A/B proven): the cold-prefill loss is mostly the MTP head seed in `coldChunk`, i.e. plan lane L3, not a GEMM, GDN or SDPA deficit. Two other unapplied differences found below (wired limit, packed GDN kernel) are second-order candidates.

## Findings

Each: what / why it helps / Strim has it? / sketch (files, size, gain cell, exactness, memory) / confidence.

### F1. MTP head over a window, empty drafter cache at nonzero position
- What: `speculative/drafters/qwen3_5_mtp/qwen3_5_mtp.py: set_shared_kv` sets `_next_position = kv_valid_len` when the drafter cache is empty, so the drafter can start at the current position with no prompt-length head prefill; `prefill_from_target_hidden` is the optional full seed. Needs only the last hidden states.
- Why: removes head work proportional to prompt length.
- Strim: head seeded over the whole prompt in `coldChunk` (EngineCore.swift ~l.743-762); this is exactly lane L3.
- Sketch: L3(b): run the head over the last W (2-4K) tokens only, rope positions kept absolute, keep hidden only for the window (memory lower: 10 KB/token). Files EngineCore.swift, PrefixCache.swift (`requireMTP`). Size M. Gain +1.4..2.8% cold prefill on 4K/16K/32K and flips 16K/32K LOSS to TIE. Exactness: drafts only, verify unchanged, token output is verify-exact; acceptance must be gated (-2 points max). Memory: lower. Confidence: medium-high on the gain, medium on acceptance (mlx-vlm does not publish acceptance for a windowed head: unverified).

### F2. Wired limit / residency sets are never enabled in Strim
- What: `mlx_lm/generate.py: wired_limit` and `utils.py: maybe_set_recommended_wired_limit` call `mx.set_wired_limit(max_recommended_working_set_size)`; mlx-vlm's server generator enters it (`generate/ar.py` l.2594 `self._wire_stack.enter_context(wired_limit(model, [self._stream]))`); oMLX raises it to 56 GB (bench/omlx-home/.omlx/logs/server.log: "Metal wired limit raised: 0.0GB -> 56.0GB"; `process_memory_enforcer.py: _apply_metal_wired_limit`).
- MLX source (Cmlx, `backend/metal/allocator.cpp: set_wired_limit`, `resident.cpp: ResidencySets::insert/resize`): wired limit defaults to 0, and with capacity 0 no allocation is added to a residency set (`if (total_wired_ + bytes > capacity_) return;`).
- Strim: `EngineConfig.wiredLimitGB` (Model.swift l.22-28) is printed (main.swift:1850) but no code calls `mlx_set_wired_limit` or `WiredMemoryManager` (grep of Sources: none). Machine has `iogpu.wired_limit_mb=57344`, so a 40-48 GB request is legal.
- Why it may help: weights (15 GB) and KV stay resident across all command buffers, lowering per-commit residency work. Effect size unknown: it is the one MLX serving setting every rival uses and Strim does not. Could help prefill chunks (about 22 command buffers per chunk) and decode.
- Sketch: S. In EngineCore load path call the Cmlx wired-limit API (or a WiredMemoryManager ticket) with min(weights + KV budget + 4 GB, iogpu cap); env opt-out `STRIM_NO_WIRE=1`. ABBA 4K/16K prefill, B=1 MTP decode, c=4 cell. Gain: 0..3% prefill, 0..2% decode (UNVERIFIED, could be 0). Exactness: bit-identical (no math change). Memory: wired pages cannot be reclaimed under system pressure; footprint number unchanged but risk of starving other apps; cap at weights+budget, not the full 56 GB. Confidence: low-medium on gain, high that it is cheap to test.

### F3. Packed GDN recurrence kernel (8 value rows per SIMD-group)
- What: `models/qwen3_5/gated_delta.py: _make_gated_delta_packed_kernel` / `gated_delta_kernel` (same in `mlx_lm/models/gated_delta.py`, synced from mlx-lm PR 1559): for Dk=128, scalar gate, T>1, fp32 gate+state: 4 lanes per value row, each lane keeps 32 contiguous state floats, 8 rows per SIMD-group, reductions are an explicit butterfly (xor 1,2,4 in-lane, xor 1,2 across lanes). Documented as bit-identical to the generic simd_sum kernel on current Apple GPUs. Chunked parallel scan (`gated_delta_chunked`) exists only for non-Metal backends; on Metal both rivals run a sequential kernel, same family as Strim's blocked kernel.
- Why: halves reduction count per row per token.
- Strim: blocked kernel (48-token blocks in threadgroup memory, 8 threads per row, `GDNMetal.swift`), recurrence is 4.3-4.5% of prefill (L0). Not directly comparable; no data that packed beats blocked.
- Sketch: S-M, microbench-only first (`benchgvS`-style, T=1024, B=1, Hv=48): one new kernel variant in GDNMetal.swift that keeps the existing f32 reduction order if packed order equals it (check bit equality against current kernel on random tensors; if not equal, it is a different exactness tier). Gain ceiling about 1-2% prefill (recurrence 2x faster = 2.2%), likely less. Memory 0. Confidence low. Fits lane L5 time-box.

### F4. Exact multi-row speculative verify via singleton-equivalent quantized kernels
- What: mlx-vlm `speculative/ops/linear.py: _target_verify_linear`, `models/quantized_verifier.py: optimized_affine_linear / singleton_quantized_linear / optimized_affine_linears`, `models/exact_speculative_verify.py`, `models/qwen3_5/speculative_verifier.py: Qwen3_5BatchInvariantForward`. Verify of T tokens is computed with custom Metal kernels (4-bit, T 2..8: streamed or token-tiled qmv that reads weights once for up to 8 rows) or per-row gather_qmm, so each row's reduction order equals single-token decode. Purpose: verify output identical to depth-0 decode.
- Strim: documented limitation: verify is not bit-identical to per-token math, 4-5 of 8 prompts token-identical (STATUS.md known limit 2). Strim previously found a hand M=2-4 GEMV 5x slower than MLX; mlx-vlm's kernels were not timed here (UNEXPLORED: their speed, and whether they match MLX qmv_wide bits).
- Why it matters: quality/product claim ("MTP output equals non-speculative output"), not speed.
- Sketch: L. Reproduce the idea: a verify-only qmv kernel with MLX qmv's per-row accumulation order for M<=5 (MLX picks qmv_wide for M>=2, tiles of up to 5 vectors; `quantized.cpp: qmv_wide`, `dispatch_qmv`). Files QGEMV.swift, SpecStream.swift/QwenModel.swift. Gain: 0% speed expected (risk -1..-3%); value is exactness. Exactness class: would upgrade "near-identical" to exact for depth>0. Memory 0. Confidence: low on speed, medium that it is feasible.

### F5. Batched decode attention across sequences (replace the per-sequence loop)
- What: mlx-vlm keeps one left-padded batch KV (`models/cache.py` BatchKVCache) and, for batched decode, `models/qwen3_5/language.py: _qwen3_5_ragged_decode_attention / _qwen3_5_left_padded_attention` with custom ragged SDPA vector kernels (one-pass and two-pass) that read K/V by stride and skip per-row padding; block count chosen per device and length (`_qwen3_5_sdpa_vector_plan/_blocks`). One RoPE, one append, one SDPA dispatch for all rows.
- Strim: `Batch.swift: BatchedAttention.forward` loops over sequences (per-seq RoPE on q and k, in-place append, SDPA) = about 7+ dispatches x B x 16 layers per step (PLAN-CONCURRENCY names this loop as a remaining gap). L9: attention glue 1.0 ms at B=1.
- Sketch: M-L. Try the cheap version first: one batched `MLXFast.scaledDotProductAttention` over a padded [B,...] KV with an array mask (q_len=1 uses MLX's vector kernel, which accepts array masks), RoPE with per-row offsets (array-offset availability UNVERIFIED in mlx-swift). Full version needs a ragged kernel. Gain: 2-5 ms per B=8 step (estimate: ~2-6% of c=8 aggregate decode), closes part of the -5..-9% c=8 gap. Exactness: padded/masked SDPA is not bit-identical to the B=1 vector kernel unless block count and order match; near-identical tier. Memory: padded KV transient or ragged kernel (none). Confidence low-medium.

### F6. Pad decode M to the qmm threshold (MLX dispatch fact)
- What (MLX source, `backend/metal/quantized.cpp`): `QuantizedMatmul::eval_gpu` uses `get_qmv_batch_limit`; for arch gen >=17 non-'d' (M5 Max) it returns 13 for any D or O above 4096 (25 and 33 for smaller). Below the limit M>=2 goes to `qmv_wide`, which tiles at most 5 input vectors per threadgroup (`n_tiles = ceil(M/5)`): M=8 reads the weights twice, M=4 and 5 once. M>=13 goes to qmm (NAX, `bm=32` when M<=32).
- Why it matters: B=6..10 decode steps stream the weights twice (about 30 GB vs 15 GB per step), consistent with L9's "B=8 at 49-56% of roofline".
- Sketch: S, experiment only: microbench qmm4 at M=4,5,8,13 on the real shapes (benchgemm) and time a B=8 step with rows padded to 13 versus unpadded; extends L2's "pad M 4->8". Gain: only c>=6 cells, 0..10% of the step if qmm at M=13 beats two qmv_wide passes (plan notes qmm at small M is 250-420 GB/s, so may lose). Exactness: different kernel, near-identical tier. Memory: negligible. Confidence low.

### F7. Fused residual + RMSNorm (and qk-norm+RoPE) Metal kernels
- What: mlx-lm 0.32.2 and mlx-vlm 0.7.10 ship `kernels/norm_add_norm.py`, `qk_norm_rope.py`, `qk_norm.py`, `rms_norm_sigmoid_gate.py` ("Copyright Apple 2026"). Checked users: recurrent_gemma, rwkv7, muse_spark, vision towers; NOT used by qwen3_5 in either package, so they do not explain mlx-vlm's speed.
- Strim: separate resid + norm ops (OpTimer: norm+resid+act+lm_head = 2.3% of 4K prefill).
- Sketch: S-M, `Layer.swift` fused kernel: read x and mixed, write bf16 h (rounded exactly as today) and normalized n2 in one pass. Gain 0.2-0.5% prefill, 0.2-0.4 ms decode (L9 estimate). Exact if h is rounded to bf16 before the norm. Memory 0. Confidence medium, small value; already listed in L9.

### F8. Interleave rule: one decode step per prefill chunk, prefill rows batched
- What: mlx-lm `generate.py: BatchGenerator._next` runs one decode step, then one prefill chunk for the whole prefill batch (`PromptProcessingBatch.prompt`, right-padded B>1 forward, `prefill_batch_size` 8, step 2048); returns early if the decode batch is full. oMLX `scheduler.py: _advance_chunked_prefills / _step_prefill_chunk` advances every in-flight prefill one chunk per step, and `_adaptive_chunk_size` / `prefill_transient_tracker.py` shrink the chunk from an EWMA of bytes per token when memory headroom is low.
- Strim: same alternation (Scheduler.pick); batched B-way prefill regressed (BATCH-PREFILL doc). The adaptive memory-aware chunk is new relative to Strim admission.
- Sketch: nothing for speed (lane L1 owns p95). The EWMA transient-bytes idea is an S memory-safety item for Scheduler.swift/Admission.swift (per-token transient measured from footprint deltas), 0% speed.  Confidence medium.

### F9. Hybrid-cache boundary snapshots stored off GPU (oMLX)
- What: `cache/boundary_snapshot_store.py` writes non-sliceable layer state (GDN `ArraysCache`) to SSD during prefill with an async writer thread and reads it back per block; `paged_ssd_cache.py` is a block-level safetensors SSD tier; `_StoreCacheGate` caps in-flight stores; mlx-vlm `apc.py` does hash blocks (16 tokens) plus restorable checkpoints with a size-capped SSD tier.
- Strim: trie of 1,024-token chunks with KV+GDN+MTP state, memory only; disk persistence is out of scope per PLAN-SPEED-WAVE2 section 3 (product feature).
- Note: both rivals state their prefix caches are exact for K/V but cold-vs-warm logits can differ (apc.py header); Strim's hit==miss bitwise guarantee is stronger.

### F10. MTP in batches with aligned rows (oMLX) and confirmed-prefix snapshot
- What: `patches/mlx_lm_mtp/batch_generator.py` (`_batch_rows_aligned_for_mtp`, `_is_mtp_batch_eligible`) runs MTP row-wise only when every row sits at the same cache position, otherwise plain batching; `qwen35_model.py: _patch_gated_delta_net` splits a GDN call into confirmed prefix and draft suffix and snapshots (conv, ssm) between them for rollback (depth 1 only).
- Strim: in-batch MTP is a documented NO-GO (acceptance 0.6-0.7, verify x1.52 at B=4); per-token GDN history handles depth 2-4. Not re-proposed.

### Other items seen (not recommended)
- SpecPrefill (`oMLX patches/specprefill.py`): draft-model attention scoring, prefill only top-K% tokens with original RoPE positions. Lossy; a GDN state cannot skip tokens without changing the recurrence. Opt-in/inexact class only; not proposed.
- oMLX `patches/sdpa256_attention.py`: pure-MLX flash-style tiled SDPA for head_dim 256 because older MLX lacks a fused 256 kernel. Not needed: Strim's MLX (`scaled_dot_product_attention.cpp: use_fallback`) uses the fused NAX split-d kernel for D=256 when q_len>=1024, causal, no array mask, NAX present. Fact worth keeping: prefill chunks with 9 <= S < 1024 take the unfused path (full score matrix); Strim's 1024 chunk sits exactly on the threshold, so do not lower the chunk size, and short remainders/short prompts (c=4 512-token prompts) use unfused SDPA with small kL (cost small, unmeasured).
- Exact-decode helpers in mlx-vlm (`_qwen3_5_decode_depthwise_conv` compiled f32 conv, `_precise_swiglu` f32): Strim already computes these in f32.

## Unexplored (do not treat as checked)
- oMLX 0.7.x on GitHub (only the installed 0.4.5.dev1 bundle was read); most of `scheduler.py` (437 KB) beyond prefill chunking, `engine_pool`, `memory_monitor`, `oq.py` quantization.
- mlx-vlm DFlash, EAGLE3, DDTree drafters; TurboQuant KV cache; `models/cache.py` BatchKVCache internals; ragged SDPA kernel bodies beyond planning code.
- mlx-lm 0.32.2 `BatchGenerator` MTP/`cache.py` internals beyond the prompt/generation batch flow.
- Speed of mlx-vlm's verify kernels (F4); whether wired limit changes anything on this machine (F2); lm_head/embedding quant bits in rival configs (same model files for all engines, so unlikely to differ).
- rapid-mlx source was out of scope.

## Ranked top 10 (value / risk)

1. F1 windowed MTP head seed (L3b): explains the 2.8-3% cold prefill gap; flips 16K/32K LOSS to TIE. M.
2. F2 enable wired limit / residency sets: 5-line experiment, rivals all do it, Strim never does. S. Gain unknown (0-3%).
3. F1a skip the head entirely when MTP is not requested (L3a): same cost, trivial case. S.
4. F5 batched decode attention (one SDPA/RoPE/append for all rows): c=8 aggregate +2-6%. M-L.
5. F3 packed GDN recurrence microbench: up to 1-2% prefill; fits L5. S-M.
6. F6 M-padding to the qmm threshold for B=6..12 decode: microbench first. S.
7. F7 fused residual+RMSNorm kernel: 0.2-0.5%. S-M.
8. F4 singleton-equivalent verify kernels: exactness upgrade, not speed. L.
9. F8 EWMA transient-bytes adaptive chunk for admission: memory safety, 0% speed. S.
10. F9 off-GPU boundary snapshots / disk tier: product feature; out of the speed wave.

## What Strim already does better (evidence in repo)
- Cross-request prefix cache with exact hit==miss and GDN+MTP state (mlx-vlm showed cached=0 in h2h; W5 2.7x).
- Decode speed 1.24-2.27x over both MTP-less and MTP rivals (h2h); pipelined graph build (L10).
- Chunk-invariant linear (ChunkInvariantLinear.swift) and tests; rivals' apc.py and oMLX document cold/warm drift.
- Last-token-only lm_head in prefill (mlx-lm `PromptProcessingBatch.prompt` runs the model without a last-token restriction and mlx-vlm needs `logits_to_keep=1`), truncated draft vocab, fused gate/up, compiled elementwise chains, per-token GDN rollback for depth 2-4 (oMLX supports depth 1 snapshots only).
- Batched GDN/conv Metal kernels in decode, priority admission with memory budget, single 34 MB binary.
