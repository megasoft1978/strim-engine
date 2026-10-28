# Quick head-to-head: Strim vs rapid-mlx vs mlx-vlm (2026-10-27)

Qwen3.8-27B MLX 4-bit g64, Apple M5 Max 64 GB, thinking off, greedy, `ignore_eos`. Harness: `strim bench http scoreboard|replay` (same as final-20261026), prompts distinct per run. Two passes per engine (n=2 per cell, 1 rep each), order strim, rapid-mlx, mlx-vlm then reversed; one engine at a time under `lockf /tmp/strim-bench.lock`. Cell = median of per-pass medians.

Engines and flags (same as final run): strim `serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth` (MTP depth 3; binary = HEAD 181cba3 engine sources; CLI main.swift of that snapshot differs only by a debug env line); rapid-mlx 0.15.7 `--max-num-seqs 4 --speculative-config mtp` (so c=8 runs as two waves of 4); mlx-vlm 0.7.10 plain (no MTP). llama.cpp (GGUF) and oMLX skipped (out of scope / mlx-vlm was the faster MLX rival).
Cells: decode and TTFT from cold 4K/16K prompts with 256 output (32K: 128 output); c=4/8 "4K" = distinct cold 4K prompts, 64 out (prefill-bound); c=4/8 "512" = distinct 512-token prompts, 128 out (decode-bound; extra cell added to isolate batching); W5 = 4 clients, same 16K prefix, 64 out; replay = 8-turn agent fixture, 48 out/turn. Verdict tie = within 3%.

## Results (ratio = strim / rival; for TTFT/time cells lower is better)

| cell | unit | strim | rapid-mlx | mlx-vlm | strim/rapid | strim/vlm | vs rapid | vs vlm |
|---|---|---|---|---|---|---|---|---|
| cold 4K prefill tok/s | tok/s | 980 | 984 | 1001 | 1.00x | 0.98x | tie(<3%) | tie(<3%) |
| cold 4K TTFT | s | 4.19 | 4.18 | 4.10 | 1.00x | 1.02x | tie(<3%) | tie(<3%) |
| decode 256 tok @ 4K ctx | tok/s | 64.9 | 49.4 | 31.3 | 1.31x | 2.07x | WIN | WIN |
| cold 16K prefill tok/s | tok/s | 951 | 960 | 968 | 0.99x | 0.98x | tie(<3%) | tie(<3%) |
| cold 16K TTFT | s | 17.25 | 17.08 | 16.95 | 1.01x | 1.02x | tie(<3%) | tie(<3%) |
| decode 256 tok @ 16K ctx | tok/s | 56.4 | 44.6 | 29.6 | 1.26x | 1.90x | WIN | WIN |
| cold 32K prefill tok/s | tok/s | 882 | 894 | 902 | 0.99x | 0.98x | tie(<3%) | tie(<3%) |
| cold 32K TTFT | s | 37.2 | 36.7 | 36.3 | 1.01x | 1.02x | tie(<3%) | tie(<3%) |
| decode 128 tok @ 32K ctx | tok/s | 47.9 | 40.8 | 28.5 | 1.17x | 1.68x | WIN | WIN |
| c=4 4K-prompt aggregate tok/s | tok/s | 12.38 | 12.93 | 13.32 | 0.96x | 0.93x | LOSS | LOSS |
| c=4 4K-prompt p50 TTFT | s | 10.8 | 17.2 | 16.4 | 0.63x | 0.66x | WIN | WIN |
| c=4 512-prompt aggregate tok/s (decode-bound) | tok/s | 57.3 | 70.3 | 66.0 | 0.82x | 0.87x | LOSS | LOSS |
| c=4 512-prompt p50 TTFT | s | 1.59 | 2.36 | 2.37 | 0.67x | 0.67x | WIN | WIN |
| c=8 4K-prompt aggregate tok/s | tok/s | 12.64 | 12.92 | 13.63 | 0.98x | 0.93x | tie(<3%) | LOSS |
| c=8 4K-prompt p50 TTFT | s | 19.7 | 27.1 | 32.6 | 0.73x | 0.61x | WIN | WIN |
| c=8 512-prompt aggregate tok/s (decode-bound) | tok/s | 64.0 | 70.3 | 73.4 | 0.91x | 0.87x | LOSS | LOSS |
| c=8 512-prompt p50 TTFT | s | 2.87 | 6.00 | 4.44 | 0.48x | 0.65x | WIN | WIN |
| W5 4x16K shared aggregate tok/s | tok/s | 9.01 | 3.29 | 3.44 | 2.74x | 2.62x | WIN | WIN |
| W5 p50 TTFT | s | 21.2 | 74.6 | 71.1 | 0.28x | 0.30x | WIN | WIN |
| replay prefill sum T1-T8 | s | 52.8 | 50.1 | 195.5 | 1.06x | 0.27x | LOSS | WIN |
| replay prefill sum T1-T6 | s | 37.6 | 35.4 | 109.0 | 1.06x | 0.34x | LOSS | WIN |
| replay T8 cached frac | frac | 0.87 | 0.87 | 0.00 | 1.00x | n/a | tie(<3%) | n/a |

| cell | strim footprint / RSS | rapid-mlx footprint / RSS | mlx-vlm footprint / RSS |
|---|---|---|---|
| agree | 20935 / 8702 | 17408 / 15620 | 16708 / 16250 |
| w3_4k_16k | 26016 / 8703 | 23985 / 15628 | 20485 / 16264 |
| w3_32k | 33622 / 8706 | 25452 / 15647 | 22311 / 16268 |
| w4_c4_c8 | 39213 / 8717 | 30602 / 15651 | 37273 / 16281 |
| w4s_c4_c8 | 35315 / 8717 | 20505 / 15658 | 22105 / 16283 |
| w5 | 41964 / 8718 | 36795 / 15659 | 30621 / 16294 |
| replay | 36771 / 8705 | 33897 / 15669 | 27334 / 16306 |


W5 strim: the second pass was memory-aborted (see below), so the table uses pass 1 only (9.01); a fresh-engine re-run (2 reps, `strim/w5-fresh-engine/`) gave 9.27 tok/s, TTFT 20.9 s, peak footprint 37.1 GB. Rivals do not share the prefix between concurrent requests (all four TTFT 71-75 s); strim cached 15360 of 16907 tokens on 3 of 4.

## Memory

Peak footprint / RSS per cell in MB (max over passes) below. Watchdog (5 s): system swap and engine process-tree RSS plus `phys_footprint` (Metal buffers do not show in RSS: strim RSS is ~8.7 GB while its footprint is 20-42 GB). Abort at max(RSS, footprint) > 40 GB or swap growth > 2 GB.

| cell | strim footprint / RSS | rapid-mlx footprint / RSS | mlx-vlm footprint / RSS |
|---|---|---|---|
| agree | 20935 / 8702 | 17408 / 15620 | 16708 / 16250 |
| w3_4k_16k | 26016 / 8703 | 23985 / 15628 | 20485 / 16264 |
| w3_32k | 33622 / 8706 | 25452 / 15647 | 22311 / 16268 |
| w4_c4_c8 | 39213 / 8717 | 30602 / 15651 | 37273 / 16281 |
| w4s_c4_c8 | 35315 / 8717 | 20505 / 15658 | 22105 / 16283 |
| w5 | 41964 / 8718 | 36795 / 15659 | 30621 / 16294 |
| replay | 36771 / 8705 | 33897 / 15669 | 27334 / 16306 |

- Baseline swap used was 7.5 GB at start (5.5 GB for pass 2); over 4 GB, mostly other apps. It stayed flat during every cell (no engine grew swap), but it can slow all engines equally.
- One abort: strim pass 2, cell w5 (footprint 41.96 GB, RSS 8.7 GB, swap flat). The process had served 16K/32K/c=4/c=8 cells with a 12 GB prefix cache before W5, so footprint accumulates (21 GB at start, 39 GB at c=4 4K); the engine was restarted for the replay cell. Fresh-engine W5 peaked at 37.1 GB. Strim footprint is the highest of the three in every cell (rapid-mlx peak 36.8, mlx-vlm 37.3 GB).
- 32K ran on all engines (strim peak 33.6 GB < 35 GB gate).

## Run conditions
- strim pass1: start load { 3.32 3.27 2.72 }, swap used 7550.94M, memory-aborted cells: none
- strim pass2: start load { 2.73 2.52 2.80 }, swap used 5493.25M, memory-aborted cells: ['w5']
- rapid-mlx pass1: start load { 5.39 4.42 3.36 }, swap used 7489.06M, memory-aborted cells: none
- rapid-mlx pass2: start load { 3.00 2.65 2.99 }, swap used 5501.25M, memory-aborted cells: none
- mlx-vlm pass1: start load { 4.95 4.61 3.80 }, swap used 7481.06M, memory-aborted cells: none
- mlx-vlm pass2: start load { 1.96 3.04 3.40 }, swap used 5549.25M, memory-aborted cells: none


## Greedy agreement (sanity only, 8 prompts, first 64 tokens; kernel near-ties diverge)
- strim p1 vs strim p2 (self): 8/8 identical; mean common-prefix fraction 1.00
- strim vs rapid-mlx: 7/8 identical; mean common-prefix fraction 0.91
- strim vs mlx-vlm: 6/8 identical; mean common-prefix fraction 0.79
- rapid-mlx vs mlx-vlm: 7/8 identical; mean common-prefix fraction 0.88

## Where strim loses and why (from this data)

1. Concurrent decode throughput (512-token prompts): c=4 57.3 vs 70.3 (rapid-mlx, 0.82x) / 66.0 (vlm); c=8 64.0 vs 70.3 / 73.4 (0.87-0.91x). Evidence: strim per-request decode 17.5 tok/s at c=4 and 9.8 at c=8, i.e. aggregate about equals its single-stream 65 tok/s (time-sliced, no batching gain); rapid-mlx keeps 25.8 tok/s per request at c=4 (about 103 tok/s decode-only). Hypotheses: server decode is per-request/interleaved rather than the lockstep `BatchModel` path (docs/BATCH-DECODE.md measured 2.86x at B=4 without MTP); MTP inside the batch is not implemented (docs/BATCH-MTP: phase 1 only); MTP verify per stream costs more under contention.
2. Prefill-bound concurrency (4K prompts): c=4 12.4 vs 12.9 / 13.3, c=8 12.6 vs 12.9 / 13.6 (0.93-0.98x). Single-stream cold prefill is a tie (about 950-1000 tok/s for all three at 4K-32K), so there is no prefill advantage to compensate; the 2-7% is likely scheduling/chunk overhead across 4-8 interleaved prefills (strim TTFT spread is wide: min 4.2 s, max 35 s at c=8, but p50 is far better than rivals).
3. Agent replay prefill sum 52.8 vs 50.1 s (rapid-mlx, +6%). Evidence: strim cached counts lag rapid-mlx by 600-1000 tokens each turn (turn 2: 3072 vs 4064 cached of 9348; turn 8: 35632 vs 35625 converges) with the 1024/1536 prefix-cut policy, costing about 0.6-1.0 s on turns 2-4 and 7 (6.7 vs 5.7 s on turn 2). Hypotheses: cut granularity (min 1024 / max 1536) vs rapid-mlx block-level caching; first-turn cut placement; cache insert only at cut points.

## Claim check ("fastest on a 64 GB Mac")

Defensible for single-stream decode (1.17-1.31x over rapid-mlx, 1.7-2.1x over mlx-vlm at 4K/16K/32K) and shared-prefix multi-client (2.6-2.7x, p50 TTFT 0.3x) and p50 TTFT under concurrency. Not defensible as a blanket claim: cold prefill is a tie, concurrent decode throughput loses 9-18%, agent replay loses 6% to rapid-mlx, and strim has the highest memory footprint (near the 40 GB abort line after long mixed sessions).

## Reproduce / caveats

`run_all.sh` drives `run_pass.sh` (one engine per pass under the GPU lock). The run used a local-only Python watchdog (swap + RSS/footprint, 5 s) and a Python greedy-agreement helper plus a Python aggregator; per the repo's Swift-only rule none are committed, so `run_pass.sh` calls them from `$R/watchdog.py` and `$R/agree.py` and will not run as-is without equivalents. Raw data (`raw.jsonl`, `watch.csv`, `agree.json`, `steps.log`, server logs) is per `<engine>/pass<N>/<cell>/`. Machine load average at pass start 2.0-5.4 (others running); n=2 reps so treat differences under 3-5% as noise. Host paths are scrubbed to `/Users/user`.
