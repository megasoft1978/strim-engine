# Concurrency plan: batched decode in serve (2026-10-27)

Data: `bench/results/conc-batch-20261027/` (sweep `sw-*`, rapid-mlx `rapid-sw`, exactness `ag*`, 4K `k4-*`).
Model Qwen3.8-27B 4-bit, M5 Max 64 GB, load average 2-7 from other jobs (absolute numbers are lower than the quiet-machine quick-h2h; compare within a table).

## What runs today when 4 requests decode

The brief's premise ("serve interleaves instead of lockstep batching") is wrong. `Scheduler` + `EngineCore.decodeBatch` already run
a lockstep `BatchModel.forward` over all decoding sequences (join, leave, cancel, interactive-before-background, prefill chunk
alternating with a decode unit, per-request memory in `admitted`). Trace of c=4 (`trace0`): r2..r5 join one batch after their
prefills and step together, one token per sequence per unit. Default policy `auto` ends up equal to `batch` (c=4: 56.7 vs 57.4);
`roundrobin` (time-sliced per-stream MTP) is clearly worse (c=4 48.8, c=8 48).

Where c=4 time goes (512-token prompts, 128 out, unit timing in `unit-bd`): 4 prefills ~2.2 s + 128 batched steps x 43.7 ms = 5.6 s
= 8.2 s wall (62 tok/s). rapid-mlx: 7.4 s (batched prefill finishing together at 2.5 s, then 38 ms/step with in-batch MTP).
The aggregate ceiling is the batched step: B=1 plain step 34 ms (weight bandwidth), B=4 was 49.5 ms, so 4 tokens per 49.5 ms = 81 tok/s
decode-only, minus prefill. The extra 15 ms over B=1 came from GDN at B>1: tensor recurrence (8 dependent ops per layer) and
`depthwise` conv, because the fused Metal kernels are B=1-only.

## Options and measured verdict

(a) Lockstep batched decode in the scheduler: already there. Gain comes only from cheaper steps.
**Landed (default ON, `STRIM_BATCH_DECODE=0` opts out): batch-dimension GDN decode and conv kernels** (`GDNMetal.runBatch`, `convSiluBatch`; one dispatch
for all sequences, grid.y = batch, same per-row arithmetic as the B=1 kernel, so bitwise equal per sequence; `checkbatchparity` shows it
identical to the per-sequence `STRIM_GDN_BATCH_METAL` loop). `benchbatch` 512 ctx: B=4 49.5 -> 42.3 ms/step (81 -> 95 tok/s), B=2 +8%.
Served: c=4 57.4 -> 63.3, c=8 66.2 -> 73.1 tok/s (both prompt flavors agree within 1%).

(b) MTP inside the batch: NO-GO, re-checked with this data. Acceptance is 0.60-0.70 on both flavors (repeated-text prompts do not
inflate it), about 2.7 tokens/pass solo. In a batch the verify pass costs S=2: x1.52, S=3: x2.1 at B=4 (docs/BATCH-MTP), and the
batched kernels do not record states for rollback, so E[tokens] = 1.65 (S=2) or 2.07 (S=3) never repays it (<= 1.09x before draft
cost). Hand M=2..4 GEMV was already measured 5x slower than MLX qmm (SWIFT-NEXT). Not started.

(c) Prefill/decode interleave: unchanged. One prefill chunk then one decode unit; p50 TTFT stays ahead of rapid-mlx
(c=4: 1.3-1.6 s vs 2.3-2.9 s; c=8: 2.3-2.9 vs 2.5-5.9 s). Batched prefill is not worth it: rapid-mlx's batched 2072-token prefill took
2.5 s, our serial 4 x 518 takes ~2.2 s. Kill criterion for any scheduler change: single-stream decode or TTFT regresses > 3%.

## Result vs rapid-mlx (same machine state, 2 reps each, aggregate tok/s)

| cell | strim batch (before) | strim + STRIM_BATCH_DECODE | rapid-mlx | verdict |
|---|---|---|---|---|
| c=4 512, repeated | 58.3 | 63.3 | 71.3 | LOSS 0.89x |
| c=4 512, realistic | 57.4 | 63.3 | 67.9 | LOSS 0.93x |
| c=8 512, repeated | 65.7 | 72.5 | 71.6 | WIN 1.01x (tie) |
| c=8 512, realistic | 66.2 | 73.1 | 69.9 | WIN 1.05x |

Plainly: at c=4 nothing we measured beats rapid-mlx on aggregate decode throughput, on either flavor. The remaining gap (~0.5 s of
7.4 s) is the 43.7 -> ~36 ms step (floor is 34 ms B=1 plus ~2.5 ms of GDN state traffic at B=4), i.e. M=4 qmm efficiency
(MLX 250-420 GB/s at M=4 vs 400-780 at M=1) and the per-sequence attention loop. Both are separate kernel projects.

## Exactness (8 fixed realistic prompts, greedy, vs each prompt's own single-stream MTP run)

| run | 96 tok, 1.5K chars | 128 tok, 6K chars |
|---|---|---|
| batch (tensor GDN), batch of 8 / 4+4 | 6/8, 6/8 | 6/8, 6/8 |
| `STRIM_BATCH_DECODE=1` | 8/8, 8/8 | 7/8, 7/8 |
| `STRIM_GDN_BATCH_METAL=1` | 8/8, 8/8 | not run |

Divergences are single near-ties (first diff after 200-350 chars). `checkbatchparity` (teacher-forced, ctx 512, margins in `checkbatchparity.txt`):
B=4 tokens 128/128 (baseline) vs 127/128 (flag, margin 0.125); B=8 254/256 vs 252/256, every mismatch margin <= 0.125 against logit
drift 2-5 (qmm M>1 tiling, not GDN). The flag does not add drift of its own (GDN part is bitwise B=1); the residual drift is the
M>1 quantized matmul, which batching cannot avoid without giving up the bandwidth gain. Not yet run: multi-step agentbench tasks.

## State

Default ON since this change (`STRIM_BATCH_DECODE=0` opts out; only B>1 decode with S<512 is affected, B=1 and prefill code paths are untouched).
Gates passed before the flip:
- Exactness: table above (8/8, 7/8 vs 6/8, 6/8). Teacher-forced on the same 8 real 6K-char prompts (B=8, 128 steps, `parity-real-6k.txt`): mismatches vs plain single-stream 4/1024 with the kernels vs 7/1024 without; every mismatch has top1-top2 margin 0 or 0.125 (one bf16 ulp at these logit magnitudes) against max logit diff 4.5. The char-234 divergence of prompt 4 (6K run) is not a plain-single-stream mismatch (seq 4 has none with the kernels); it is vs the MTP solo reference, i.e. MTP-verify vs plain drift of the same near-tie class.
- 4K (`k4-*`, 2 reps): single-stream decode 66.6 (batch) / 67.7 (kernels) / 66.9 (auto) tok/s, TTFT 4.16 s in all; c=4 12.6/12.7/12.3, c=8 12.9/13.1/12.8 aggregate; peak footprint 37.9-38.9 GB (< 40), no watchdog abort.
- ABAB on the merged tree (`ab-*`, old HEAD build vs merged default, default policy, aggregate tok/s, 2 passes): c=1 realistic 48.8/46.3 vs 48.3/51.1 (noise, B=1 code unchanged); c=4 realistic 55.5/54.3 vs 59.3/61.7, repeated 55.1/55.6 vs 61.2/59.8; c=8 realistic 62.8/61.8 vs 65.2/64.3, repeated 60.8/62.0 vs 65.4/67.6; p50 TTFT unchanged (c=4 1.8 s, c=8 3.3 s). Machine was busier than the first sweep, hence lower absolutes. Peak footprint 24.6-25.6 GB.

Tests: `BatchStateTests` (join, leave, cancel, mixed prefill+decode, background pause, admission accounting), `GDNBatchDecodeTests` (kernel parity; needs a metallib, like GDNBlockedTests). `checkbatchparity` takes `STRIM_PARITY_IDS=FILE` (one prompt of comma-separated ids per line) for real prompts; `bench/results/conc-batch-20261027/gen_ids.sh` builds them.

## Next lever for c=4 (not implemented): the M=4/8 quantized matmul, 43.7 ms vs 34 ms floor

Per step the batched path moves the same ~14 GB of weights as B=1 but MLX runs `qmm` for M=2..8 at 250-420 GB/s against 400-780 GB/s for
the M=1 `qmv` (`benchgvS`; a hand GEMV was 5x worse, so do not retry that). Experiments, each judged by `benchbatch ... 512 24 4` ms/step
and then `checkbatchparity` margins:
1. Fuse projections that share an input so each weight stream is one larger matmul: attention q/k/v (one [N=q+k+v] weight), GDN
   in_proj_qkv/z (and b/a, tiny), MLP gate/up. Needs a load-time weight concat (memory-neutral) and changes split-K selection, so re-baseline
   exactness.
2. Pad M=4 -> 8 or 16 rows (zero rows) to land on the better-tiled qmm variant; measure per shape (K=5120/17408), cost is only compute.
3. Batched RoPE with per-sequence array offsets and a single padded SDPA with an additive length mask for the 16 attention layers
   (replaces 4 x (2 RoPE + append + SDPA) dispatches per layer; `checkbatchparity kvbench` already times the layouts).
Kill criterion: < 2 ms/step at B=4 (< 5%) after 1-2; then stop and accept the c=4 deficit.

Follow-up (listed, not done): agentbench-style multi-step quality run with the default-on kernels against single-stream.
