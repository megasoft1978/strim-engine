# Plan: speed wave 2 (2026-10-28)

Goal: more speed (prefill first, then decode, single and concurrent) with memory growth none or reasonable.
Baseline: `bench/results/h2h-final-20261028/summary.md`. All gains below are estimates; nothing here was benchmarked. UNVERIFIED marks items not confirmed.

## 1. Evidence, rules, done criteria

**Numbers**
- M5 Max 64 GB: dense GEMM plateau 62-63 TF/s (`docs/PREFILL-SPIKE-2026-10-26.md` s2); qmm4 reaches 51-58 TF/s (0.90-0.98 of bf16); streaming 530 GB/s measured (`docs/SWIFT-PERF.md`), 614 spec. Theoretical peak TFLOPS UNVERIFIED.
- FLOP/token: linear layers 48.7 GFLOP; the 54 GFLOP figure includes attention and head. Lane 0 must state which it uses.
- Prefill is near the roofline: in-process 4K ~1007 tok/s (~49 TF/s) vs qmm ceiling ~1070-1150. Realistic prefill headroom 3-8%; the rival gap is 1-3%.
- Chunk size is dead (2048/4096: -0.2..+0.3%, `bench/results/perf-profile-20261027/summary.md`).
- GDN recurrence upper bound from the tensor-path ablation: skipping it gives 1057 vs 1007 tok/s at 4K, 1004 vs 949 at 16K, i.e. at most ~5.5%. `STRIM_SKIP_REC` is a no-op on the blocked path (`GDN.swift:140,370`).
- The 32K in-process rows (209-386 tok/s) are invalid (memory pressure); never quote them.
- Decode: batched GDN kernels on; B=4 step 43.7 ms vs ~34 ms floor (`docs/PLAN-CONCURRENCY-2026-10-27.md`).

**Rules for every lane**
- Memory: peak phys_footprint grows at most +1 GB on any cell, stays under ~40 GB, swap growth 0 (`STRIM_MEM_TRACE`, h2h memory table).
- Quality, exact tier: bit-identical hashes within one chunking policy. Gates: `gen 16`, depth-0 `benchspec` EXACT, `checkprefix 4096/8192 +MTP`, `enginebench --only=concurrent-decode`.
- Quality, near-identical tier: opt-in until it also passes `checkbatchparity` margins, a logit-diff check and the agentbench subset (Swift/Go corpus) vs the reference path.
- Process: A/B interleaved ABAB under `lockf -k /tmp/strim-bench.lock`, load average recorded; a win must exceed 2x observed CV and the ABBA pass-to-pass noise.
- Non-goals: new quant formats, W4A8, ANE, new model variants.

## 2. Lanes (ranked by expected gain / risk)

### L0. Measurement (first)
- Hypothesis: nobody knows per-op prefill shares; every prefill idea is a guess.
- Files: new `Sources/StrimCore/OpTimer.swift`; marker-only edits in `Layer.swift:78`, `GDN.swift:261`, `Attention.swift:14`, `EngineCore.swift:719` (`coldChunk`); `benchprefill` printer `StrimCLI/main.swift:939`; new `Tests/StrimCoreTests/OpTimerTests.swift`.
- Design: `OpTimer.on` is a `static let` from `STRIM_OPTIME` (off path = one branch). On: eval(inputs), time, run, eval(output), accumulate by (region, layer type). Calibrate fence cost, subtract. Report GFLOP and bytes per region, TF/s and GB/s vs 62.7 TF/s / 530 GB/s. Reconciliation (sum of regions + fence vs uninstrumented wall) within 5%. Add a GEMM roofline microbench: bf16 8192^3 and the real qmm shapes (N=34816 fused gate/up, 5120->5120, 10240, 6144, K=17408) at M=512/1024/4096.
- Decode/concurrent: fences distort 100 us ops; use env + `xcrun xctrace record --template "Metal System Trace"` (per-kernel export feasibility UNVERIFIED: 30-minute feasibility test first). Report decode gap = wall - kernel sum.
- Free knob sweep (no code): `MLX_MAX_OPS_PER_BUFFER` in {default,50,200,500} and `MLX_MAX_MB_PER_BUFFER` on 4K prefill and B=1/B=4 decode; accept >=2% beyond noise.
- Memory 0, quality none. Effort <= 2.5 h; kill/report if reconciliation > 5% after one calibration pass.

### L1. Concurrency p95 TTFT
- Hypothesis: `Scheduler.pick` alternates one prefill chunk with one decode unit (`Scheduler.swift:132-165`), delaying the last prefill by early joiners' decode steps; other queueing may also contribute (UNKNOWN: trace first via the unit trace in `EngineCore.runOneUnit` (`:639`), split queue/prefill/decode per request).
- Then try: while prefills are pending, at most 1 decode unit per K prefill units, K adaptive to decoder count, with an inter-token-gap cap.
- Files: `Sources/StrimEngine/Scheduler.swift` and tests only (no `EngineCore.swift` edits).
- Gain: p95 TTFT -3..-12% at c=4/8 (512-token), aggregate 0..+2%. Memory 0.
- Quality: token math same, batch membership timing changes M per step; gate with `checkbatchparity` (no worse than `bench/results/conc-batch-20261027/ab`) + agentbench subset.
- A/B: h2h c=4/c=8 cells (512-token, 2.8K agent, 4K prompts), 3 reps ABAB. Accept p95 >= 8% better and aggregate >= -1%. Kill: single-stream decode or p50 TTFT regresses > 3%, or p95 gain < 3%. Effort 2 h.

### L2. Fused projections (after L0 lands markers)
- Hypothesis: widening N moved MLP into the wide-GEMV regime (-5.6 ms/pass, `docs/SWIFT-NEXT.md` "gate+up fused"); same for GDN `in_proj_qkv`+`in_proj_z` (16384 rows) and attention q/k/v (14336 rows). Counter-evidence: isolated 4-projection fusion gave ~0.5 ms/pass at S=1 (`SWIFT-PERF.md`).
- Memory neutral if originals are dropped via `WeightStore.drop` as `mlpFused` does (`Weights.swift:233-260`); verify with a footprint check.
- Files: new `Sources/StrimCore/WeightsFused.swift`; call sites `GDN.swift:~270`, `Attention.swift:19-25`. Owns GDN.swift/Attention.swift until L5.
- Gain: B=1 decode +0..1.5%, B=4 step -0..2.5 ms, prefill ~0 (M large uses qmm_nax fixed 64x64x64 tile).
- Quality: rows independent so bit-identical if the kernel variant does not change; M>1 could switch variants (UNVERIFIED). Hash-test at M=1/4/8/1024; if different, opt-in or kill.
- Experiments: `benchgvS` microbench, then `benchbatch 512 24 4`; also test padding M 4->8. Accept >= 2 ms/step at B=4 or >= 3% at B=1; kill below 2 ms at B=4. Effort 3 h.

### L3. MTP head cost in cold prefill (after L2)
- Hypothesis: head prompt seed costs 1.7-1.9% of prefill. In `coldChunk` (`EngineCore.swift:743-762`): (a) skip head prefill when MTP is not wanted (UNKNOWN: where `j.mtp` is set), (b) else run the head over only the last W=2-4K tokens and keep trie MTP blocks for the tail (touches `PrefixStore.lookup requireMTP`).
- Gain +1.0..1.7% (no MTP) / +0.5..1.5% (windowed). Memory lower.
- Quality: drafts only, verify unchanged. Gate: acceptance must not drop > 2 points at 4K/16K/32K, decode tok/s regression <= 1%. Kill: gain < 0.8% or acceptance drop. Files: `EngineCore.swift`, `PrefixCache.swift`. Effort 3 h.

### L4. Decode host syncs / GPU-index decode (after L0 gap numbers)
- Hypothesis: each spec round does a host read for the draft feed (`SpecStream.swift:176`) and one for verify predictions; ~3-5 ms gap per ~40 ms pass (UNVERIFIED). GPU-index path feeds `embedding(indices:)` (`Weights.swift:180`) from device draft tokens.
- Gain +2..5% decode (the +8-12% needs array RoPE offsets and masked-kL SDPA, availability UNVERIFIED and would reset the exactness reference: owner decision).
- Try the embedding-only version first (EXACT at depth 0). Files: `SpecStream.swift`, `QwenModel.swift`, `MTP.swift`. Memory 0.
- Accept: >= 2 ms/pass saved (STRIM_TIMING gap), EXACT hashes, >= 2% e2e. Kill: < 1.5 ms/pass. Effort 4 h.

### L5. GDN prefill kernel + elementwise fusion (conditional)
- Run only if L0 measures GDN non-GEMM share >= 6% of prefill (recurrence alone is capped at ~5.5%).
- Sweep `TB`/`DB` in the blocked kernel (`GDNMetal.swift:214-215`, 256-thread groups) with the f32 reduction order unchanged; separately fuse surrounding elementwise ops (`SWIFT-NEXT.md:660-668`), summation order kept so results are bit-identical. Files: `GDNMetal.swift`, `Layer.swift` (`Fused.*`).
- Gain +1..3% prefill (optimistic 5%). Gate: layer-tensor parity incl. B>1 and chunk tails, then exact tier. Kill: recurrence < 15% faster and e2e < 2%. Effort 4 h.

### L6. KV preallocation (low priority, memory-positive)
- `AttentionCache.append` regrows by concatenation (`Cache.swift:32-41`, step 256): a full-KV copy per chunk (~4 ms/chunk at 16K positions, ~0.4% of 32K prefill) and a transient KV doubling that may cut peak by 1-2 GB at 32K (UNVERIFIED).
- Reserve capacity = prompt length rounded to 256 at job start; hit and miss must use the same capacity (SDPA widening depends on it, UNVERIFIED).
- Gain +0.2..0.5% at 32K. Accept: exact hashes and peak not higher. Files: `Cache.swift`, `PrefixCache.swift` restore path.

### L7. Deferred
- Spec depth per batch size: in-batch MTP is a no-go (acceptance 0.6-0.7). Leave unless L0 shows something new.
- Lazy KV q8: memory feature, changes numerics, opt-in; defer.

## 3. Rejected / do not do
- Chunk size above 1024 for prefill (+0.1..0.3%, costs trie granularity).
- Hand-written 4-bit GEMV / M=2-4 GEMV (5x slower than MLX).
- Custom 4-bit prefill GEMM chasing the plateau (NO-GO, qmm already 0.90-0.98 of dense); dequant+bf16 GEMM only for M=4096 (+5% on few shapes, not bit-identical, loses below M=1024); cooperative-register dequant spike (4 days, MLX feasibility unknown).
- `mx.compile` of the whole model (-3.1 of 36 ms, breaks rollback).
- Overlapping CPU graph build with GPU (graph build is 2.6 ms per decode pass, negligible vs ~1 s prefill chunk).
- Truncated draft-vocab lm_head: already shipped (`Weights.swift:110-175`, `STRIM_DRAFT_VOCAB`); verify must stay full vocab (~1 ms).
- Fusing GDN projections for prefill (compute-bound, fixed tile, ~0).
- In-batch MTP, tree verify, prompt-lookup, fixed depth 4, 8-bit head (dead per docs).
- Batched B-way prefill (4K experiment regressed and changed tokens).
- Mixed-precision / sensitive-layer quantization for speed (no speed evidence; heavy quality gate).
- Disk-persisted prompt cache (product feature, not throughput).

## 4. Order of work (6-8 h machine time, <= 3 lanes in parallel)
- 0-2.5 h: L0 and L1 in parallel (disjoint files).
- 2.5-5.5 h: L2 and L4 in parallel (L2 owns GDN.swift/Attention.swift/WeightsFused.swift; L4 owns SpecStream.swift/QwenModel.swift/MTP.swift); L5 only if L0 passes its 6% gate (owns GDNMetal.swift/Layer.swift).
- 5.5-8 h: L3 (after L2), L6 if time allows, integration run.
- GPU benches serialize via `lockf -k /tmp/strim-bench.lock`; ~40% of machine time is benchmarking.

## 5. Integration tests
1. `swift build -c release` and smoke `swift test`.
2. Exact tier: `strim gen 16`, depth-0 `benchspec`, `checkprefix 4096/8192 +MTP`, `enginebench --only=concurrent-decode`, `checkbatchparity`.
3. Full h2h rerun on the changed build, same cells and ABBA protocol; memory table must show peak growth <= +1 GB per cell, peak < 40 GB, swap growth 0.
4. Agentbench subset (Swift/Go) for any near-identical-tier lane.

## 6. Opus consult
Not warranted now (all lanes measurable and reversible). Only if L4's embedding-only version gains < 2% and the masked-kL SDPA path looks necessary, since that resets the exactness reference. Digest then: "Qwen3.8-27B MTP spec decode, depth-0 EXACT reference today. Gap per round X ms of Y. Embedding-index path gained Z. Adopting masked kL SDPA plus array RoPE offsets changes SDPA arithmetic and resets the exactness reference. Gate options: near-identical tier with greedy agreement, logit diff, agentbench pass rate. Accept or reject?"

## Unknowns
xctrace per-kernel export; MLX Swift array RoPE offsets; whether the quantized kernel variant at M>1 changes with N; theoretical peak TFLOPS; the real queueing split behind the c=4 p95 gap; whether `j.mtp` exists only when MTP is wanted.
