# Head-to-head, final run (2026-10-28): Strim vs rapid-mlx vs mlx-vlm

Model: Qwen3.8-27B-class 4-bit (models/qwen38-4bit), thinking off, greedy decode, 1 rep per pass, 2 passes (pass 1 order strim, rapid-mlx, mlx-vlm; pass 2 reversed, ABBA). One engine at a time under `lockf /tmp/strim-bench.lock`. Machine: Apple M5 Max, 64 GB, macOS 27.0.1. Runner: bench/h2h/{run,pass,summarize,watchdog,agree,agent-prompts}.sh (shell + jq + awk, no Python). Raw per-cell output: `<engine>/pass<N>/`; machine-readable: `results.json`.

## Completeness and validity

- 3 engines x 2 passes x 8 cells (agree, w3, w3_32k, w4, w4s, w6, w5, replay) plus warmup per session: all 48 cells present, every cell rc=0, 0 request errors in any raw.jsonl, 0 engine restarts, 0 watchdog aborts, no timeouts. Nothing had to be rerun.
- Order: valid ABBA, sessions contiguous (pass 1 00:44-01:05, pass 2 01:07-01:31), no out-of-order pass.
- Memory: peak footprint 36.2 GB (mlx-vlm w4), 33.3 GB (rapid-mlx w5), 30.8 GB (Strim w4); all under the 42 GB abort limit. Swap growth 0 MB in every session (baseline swap used 5.7-5.8 GB of 7 GB, constant, pre-existing). No engine swapped; none invalid.
- Load average: pass 2 clean (1-min load 1.7-2.9 all engines). Pass 1 was NOT clean for the rivals: rapid-mlx p1 1-min load 3.1-9.1, mlx-vlm p1 8.0-14.6 (Strim p1 2.0-5.6). Some other CPU work (builds/other agents) ran during rival pass 1; GPU was not shared (lock held, no other benchmark). Sensitivity check, verdicts recomputed per single pass: only 6 of 33 cells change verdict between pass 1 and pass 2 (cold 4K prefill/TTFT vs mlx-vlm TIE->LOSS, cold 32K vs mlx-vlm TIE->LOSS, c=4 4K p95 vs rapid-mlx TIE->WIN, c=8 4K aggregate vs rapid-mlx TIE->LOSS); all are in the 2-4% band. Concurrency and decode conclusions are unchanged.
- Strim build: /tmp/strim-snap-final = exactly commit 2df65e7 (0 differing files; binary built 00:42, before the 00:44 start). It predates the security/http hardening commits c76f18f, b793f4f, 58b3396 (server limits, admission math clamp, connection caps), 0296e34 (GDN license comment) and the harness security fixes (b11dfce..db3ac1b). Engine hot paths (EngineCore, GDN kernels, prefix cache) are unchanged apart from a one-line EngineCore tweak and an admission-math change in c76f18f; HEAD was not rebenchmarked.
- Versions: Strim 0.1.0 (2df65e7), rapid-mlx 0.15.7, mlx-vlm 0.7.10.
- Flags: Strim `serve models/qwen38-4bit models/qwen38-mtp-4bit --no-auth` (MTP head on, admission on, max_inflight 8, prefix cache default). rapid-mlx `--max-num-seqs 4 --speculative-config {"method":"mtp",...}` (MTP ON, text lane; max-num-seqs 4 so c=8 queues). mlx-vlm `mlx_vlm.server` defaults (NO MTP, continuous batching, no cross-request prefix cache: cached=0 everywhere).

## Headline: Strim vs best rival (median of 2 passes; ratio = Strim / best rival; TIE = within 2%)

| cell | unit | Strim | best rival | ratio | verdict |
|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 980.124 | mlx-vlm 998.63 | 0.98x | TIE |
| cold 4K TTFT | s | 4.19034 | mlx-vlm 4.11329 | 1.02x | TIE |
| decode 256 tok @ 4K ctx | tok/s | 67.1442 | rapid-mlx 50.5042 | 1.33x | WIN |
| cold 16K prefill | tok/s | 950.749 | mlx-vlm 980.118 | 0.97x | LOSS |
| cold 16K TTFT | s | 17.2443 | mlx-vlm 16.7276 | 1.03x | LOSS |
| decode 256 tok @ 16K ctx | tok/s | 56.5412 | rapid-mlx 45.5313 | 1.24x | WIN |
| cold 32K prefill | tok/s | 879.633 | mlx-vlm 906.573 | 0.97x | LOSS |
| cold 32K TTFT | s | 37.2644 | mlx-vlm 36.1606 | 1.03x | LOSS |
| decode 128 tok @ 32K ctx | tok/s | 52.0858 | rapid-mlx 36.8902 | 1.41x | WIN |
| c=4 512-tok prompts aggregate | tok/s | 60.4239 | rapid-mlx 70.6407 | 0.86x | LOSS |
| c=4 512-tok prompts p50 TTFT | s | 1.82454 | mlx-vlm 2.32064 | 0.79x | WIN |
| c=4 512-tok prompts p95 TTFT | s | 2.83174 | mlx-vlm 2.32071 | 1.22x | LOSS |
| c=8 512-tok prompts aggregate | tok/s | 67.3717 | mlx-vlm 74.3057 | 0.91x | LOSS |
| c=8 512-tok prompts p50 TTFT | s | 3.28835 | mlx-vlm 4.35757 | 0.75x | WIN |
| c=8 512-tok prompts p95 TTFT | s | 5.70068 | mlx-vlm 4.35865 | 1.31x | LOSS |
| c=4 agent prompts (~2.8K tok) aggregate | tok/s | 27.2956 | mlx-vlm 28.3994 | 0.96x | LOSS |
| c=4 agent prompts p50 TTFT | s | 8.12118 | mlx-vlm 12.4893 | 0.65x | WIN |
| c=4 agent prompts p95 TTFT | s | 12.6037 | mlx-vlm 12.4894 | 1.01x | TIE |
| c=8 agent prompts aggregate | tok/s | 29.4962 | mlx-vlm 30.9557 | 0.95x | LOSS |
| c=8 agent prompts p50 TTFT | s | 14.2857 | rapid-mlx 22.3886 | 0.64x | WIN |
| c=8 agent prompts p95 TTFT | s | 23.8921 | mlx-vlm 23.2928 | 1.03x | LOSS |
| c=4 4K prompts aggregate (prefill-bound) | tok/s | 12.738 | mlx-vlm 13.4474 | 0.95x | LOSS |
| c=4 4K prompts p50 TTFT | s | 10.7364 | mlx-vlm 16.2458 | 0.66x | WIN |
| c=4 4K prompts p95 TTFT | s | 16.6405 | mlx-vlm 16.2459 | 1.02x | LOSS |
| c=8 4K prompts aggregate (prefill-bound) | tok/s | 12.8833 | mlx-vlm 13.7853 | 0.93x | LOSS |
| c=8 4K prompts p50 TTFT | s | 19.5204 | rapid-mlx 26.7876 | 0.73x | WIN |
| c=8 4K prompts p95 TTFT | s | 33.5139 | mlx-vlm 32.1872 | 1.04x | LOSS |
| W5 4 clients, 16K shared prefix aggregate | tok/s | 9.45998 | mlx-vlm 3.47416 | 2.72x | WIN |
| W5 p50 TTFT | s | 20.6874 | mlx-vlm 70.4212 | 0.29x | WIN |
| W5 p95 TTFT | s | 23.3563 | mlx-vlm 70.422 | 0.33x | WIN |
| agent replay prefill sum T1-T8 | s | 49.6885 | rapid-mlx 49.4481 | 1x | TIE |
| agent replay prefill sum T1-T6 | s | 35.1093 | rapid-mlx 34.9725 | 1x | TIE |
| agent replay T8 cached fraction | frac | 0.87247 | rapid-mlx 0.87228 | 1x | TIE |

Per-rival table, memory, conditions, agreement, replay detail and pass-to-pass noise follow (generated by bench/h2h/summarize.sh).

## Results (ratio = strim / rival; lower-is-better cells (TTFT, time) win with ratio < 1; tie = within 2%)

| cell | unit | strim | rapid-mlx | mlx-vlm | strim/rapid-mlx | strim/mlx-vlm | vs rapid-mlx | vs mlx-vlm |
|---|---|---|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 980.1 | 991.6 | 998.6 | 0.99x | 0.98x | TIE | TIE |
| cold 4K TTFT | s | 4.19 | 4.142 | 4.113 | 1.01x | 1.02x | TIE | TIE |
| decode 256 tok @ 4K ctx | tok/s | 67.14 | 50.5 | 29.54 | 1.33x | 2.27x | WIN | WIN |
| cold 16K prefill | tok/s | 950.7 | 969.1 | 980.1 | 0.98x | 0.97x | TIE | LOSS |
| cold 16K TTFT | s | 17.24 | 16.92 | 16.73 | 1.02x | 1.03x | TIE | LOSS |
| decode 256 tok @ 16K ctx | tok/s | 56.54 | 45.53 | 29.44 | 1.24x | 1.92x | WIN | WIN |
| cold 32K prefill | tok/s | 879.6 | 904 | 906.6 | 0.97x | 0.97x | LOSS | LOSS |
| cold 32K TTFT | s | 37.26 | 36.26 | 36.16 | 1.03x | 1.03x | LOSS | LOSS |
| decode 128 tok @ 32K ctx | tok/s | 52.09 | 36.89 | 25.73 | 1.41x | 2.02x | WIN | WIN |
| c=4 512-tok prompts aggregate | tok/s | 60.42 | 70.64 | 66.76 | 0.86x | 0.91x | LOSS | LOSS |
| c=4 512-tok prompts p50 TTFT | s | 1.825 | 2.401 | 2.321 | 0.76x | 0.79x | WIN | WIN |
| c=4 512-tok prompts p95 TTFT | s | 2.832 | 2.401 | 2.321 | 1.18x | 1.22x | LOSS | LOSS |
| c=8 512-tok prompts aggregate | tok/s | 67.37 | 71.22 | 74.31 | 0.95x | 0.91x | LOSS | LOSS |
| c=8 512-tok prompts p50 TTFT | s | 3.288 | 5.925 | 4.358 | 0.56x | 0.75x | WIN | WIN |
| c=8 512-tok prompts p95 TTFT | s | 5.701 | 9.53 | 4.359 | 0.60x | 1.31x | WIN | LOSS |
| c=4 agent prompts (~2.8K tok) aggregate | tok/s | 27.3 | 27.51 | 28.4 | 0.99x | 0.96x | TIE | LOSS |
| c=4 agent prompts p50 TTFT | s | 8.121 | 13.54 | 12.49 | 0.60x | 0.65x | WIN | WIN |
| c=4 agent prompts p95 TTFT | s | 12.6 | 13.54 | 12.49 | 0.93x | 1.01x | WIN | TIE |
| c=8 agent prompts aggregate | tok/s | 29.5 | 27.88 | 30.96 | 1.06x | 0.95x | WIN | LOSS |
| c=8 agent prompts p50 TTFT | s | 14.29 | 22.39 | 23.29 | 0.64x | 0.61x | WIN | WIN |
| c=8 agent prompts p95 TTFT | s | 23.89 | 31.71 | 23.29 | 0.75x | 1.03x | WIN | LOSS |
| c=4 4K prompts aggregate (prefill-bound) | tok/s | 12.74 | 13.08 | 13.45 | 0.97x | 0.95x | LOSS | LOSS |
| c=4 4K prompts p50 TTFT | s | 10.74 | 16.97 | 16.25 | 0.63x | 0.66x | WIN | WIN |
| c=4 4K prompts p95 TTFT | s | 16.64 | 16.97 | 16.25 | 0.98x | 1.02x | TIE | LOSS |
| c=8 4K prompts aggregate (prefill-bound) | tok/s | 12.88 | 13.09 | 13.79 | 0.98x | 0.93x | TIE | LOSS |
| c=8 4K prompts p50 TTFT | s | 19.52 | 26.79 | 32.19 | 0.73x | 0.61x | WIN | WIN |
| c=8 4K prompts p95 TTFT | s | 33.51 | 36.54 | 32.19 | 0.92x | 1.04x | WIN | LOSS |
| W5 4 clients, 16K shared prefix aggregate | tok/s | 9.46 | 3.313 | 3.474 | 2.85x | 2.72x | WIN | WIN |
| W5 p50 TTFT | s | 20.69 | 74.2 | 70.42 | 0.28x | 0.29x | WIN | WIN |
| W5 p95 TTFT | s | 23.36 | 74.2 | 70.42 | 0.31x | 0.33x | WIN | WIN |
| agent replay prefill sum T1-T8 | s | 49.69 | 49.45 | 193.6 | 1.00x | 0.26x | TIE | WIN |
| agent replay prefill sum T1-T6 | s | 35.11 | 34.97 | 108 | 1.00x | 0.32x | TIE | WIN |
| agent replay T8 cached fraction | frac | 0.8725 | 0.8723 | 0 | 1.00x | n/a | TIE | n/a |

## Peak memory per cell (MB; max over passes and sessions; footprint = phys_footprint of the engine process tree, includes Metal buffers)

| cell | strim footprint / RSS | rapid-mlx footprint / RSS | mlx-vlm footprint / RSS |
|---|---|---|---|
| warmup | 18177 / 8696 | 20644 / 15616 | 19327 / 16233 |
| agree | 18044 / 8701 | 17351 / 15599 | 16514 / 16231 |
| w3 | 23606 / 8704 | 21994 / 15608 | 21133 / 16260 |
| w3_32k | 28172 / 8704 | 24421 / 15628 | 22246 / 16278 |
| w4 | 30831 / 8709 | 30681 / 15623 | 36187 / 16263 |
| w4s | 26209 / 8710 | 21297 / 15629 | 24419 / 16273 |
| w6 | 28412 / 8712 | 29010 / 15631 | 31068 / 16289 |
| w5 | 27406 / 8703 | 33311 / 15614 | 31128 / 16285 |
| replay | 27089 / 8707 | 29008 / 15638 | 22903 / 16314 |
| **whole run** | **30831 / 8712** | **33311 / 15638** | **36187 / 16314** |

## Run conditions

- strim pass1: 3 sessions; first load { 1.99 3.28 2.75 }; swap used at start 5795.88M; swap growth max 0 MB; watchdog aborts: none
- strim pass2: 3 sessions; first load { 1.89 1.95 2.73 }; swap used at start 5715.88M; swap growth max 0 MB; watchdog aborts: none
- rapid-mlx pass1: 3 sessions; first load { 3.10 3.63 3.12 }; swap used at start 5763.88M; swap growth max 0 MB; watchdog aborts: none
- rapid-mlx pass2: 3 sessions; first load { 1.69 2.36 3.31 }; swap used at start 5723.88M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass1: 3 sessions; first load { 10.75 6.19 4.43 }; swap used at start 5747.88M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass2: 3 sessions; first load { 2.46 4.03 4.46 }; swap used at start 5723.88M; swap growth max 0 MB; watchdog aborts: none

## Greedy agreement (sanity only; 8 fixed prompts, 64 tokens, near-ties diverge)

- strim pass1 vs pass2 (self): 8/8 identical; mean common-prefix fraction 1
- strim vs rapid-mlx (pass1): 7/8 identical; mean common-prefix fraction 0.91; (pass2): 7/8 identical; mean common-prefix fraction 0.91
- strim vs mlx-vlm (pass1): 6/8 identical; mean common-prefix fraction 0.79; (pass2): 6/8 identical; mean common-prefix fraction 0.79
- rapid-mlx vs mlx-vlm (pass1): 7/8 identical; mean common-prefix fraction 0.88

## Agent replay detail (8 turns; median over passes)

| turn | prompt tok | strim TTFT s | strim cached tok | rapid-mlx TTFT s | rapid-mlx cached tok | mlx-vlm TTFT s | mlx-vlm cached tok |
|---|---|---|---|---|---|---|---|
| 1 | 4091.5 | 4.13 | 0 | 4.11 | n/a | 4.01 | 0 |
| 2 | 9346.5 | 5.58 | 4084.5 | 5.56 | 4064 | 9.29 | 0 |
| 3 | 14627.5 | 5.89 | 9339.5 | 5.91 | 9333 | 14.80 | 0 |
| 4 | 19884.5 | 6.22 | 14620.5 | 6.12 | 14613 | 20.52 | 0 |
| 5 | 25156.5 | 6.53 | 19877.5 | 6.53 | 19861 | 26.65 | 0 |
| 6 | 30378.5 | 6.76 | 25149.5 | 6.74 | 25141 | 32.77 | 0 |
| 7 | 35637.5 | 7.19 | 30371.5 | 7.18 | 30357 | 39.44 | 0 |
| 8 | 40838.5 | 7.39 | 35630.5 | 7.29 | 35624 | 46.10 | 0 |

## Pass-to-pass noise (|pass1-pass2| / mean, percent, over all cells above; TIE band is 2%)

| engine | cells | median spread | p90 spread | max spread (cell) |
|---|---|---|---|---|
| strim | 33 | 0.5% | 1.3% | 8.6% (decode 256 tok @ 16K ctx) |
| rapid-mlx | 33 | 0.3% | 1.4% | 26.3% (decode 128 tok @ 32K ctx) |
| mlx-vlm | 32 | 0.3% | 2.5% | 25.7% (decode 128 tok @ 32K ctx) |

## Where Strim loses (data and hypotheses)

1. Cold prefill is 2-3% slower than both rivals, growing with context (4K -1% to -2%, 16K -3%, 32K -3%; 32K TTFT 37.3 s vs 36.2 s). Consistent in both passes, small but real. Hypothesis: all three engines are MLX/Metal-bound at ~900-1000 tok/s on the same quantized matmuls, so Strim's remaining gap is dispatch/chunking overhead in its own GDN/attention prefill path, not a different algorithm. Unverified.
2. Concurrent aggregate throughput on short prompts: c=4 512-token prompts 60.4 vs 70.6 tok/s (rapid-mlx, -14%), c=8 67.4 vs 74.3 (mlx-vlm, -9%). Strim's aggregate stays at about its single-stream decode rate (~60-67 tok/s with MTP): requests are admitted and prefetched in a staggered way but decode is not batched across sequences, while the rivals batch decode (their per-request decode is 13-26 tok/s while concurrent). Hypothesis: no multi-sequence batched decode with MTP.
3. Tail TTFT at high concurrency: p95 TTFT is worse than the best rival on 512-token c=4 (+22%) and c=8 (+31%), and 3-4% on c=8 agent/4K prompts, even where p50 is 25-45% better. The same staggering that gives low p50 (requests are served nearly in series) pushes the last request out. Caveat: rival p50 and p95 are almost identical (all requests in a batch report the same TTFT, e.g. rapid-mlx 2.45 s x4, mlx-vlm 4.36 s x7), which suggests batch-synchronous first-token delivery or buffering; their p50 is therefore a weaker number than Strim's per-request TTFT, and with n=4/8 requests per cell p95 is just the maximum.
4. Aggregate on 4K prompts (c=4/8, prefill-bound, 5-7% behind mlx-vlm) follows from #1 and #2, not an extra problem. Agent-prompt aggregate (c=4 -4%, c=8 -5% vs mlx-vlm) is the same effect.
5. Not a loss but not a win: agent replay (8 turns, 40.8K tokens) prefill sum 49.7 s vs 49.4 s rapid-mlx (TIE); both reuse 87.2% of T8 tokens. mlx-vlm has no prefix reuse (193.6 s).

## Supported claim wording

"On Qwen3.8 4-bit on an M5 Max, Strim decodes 24-41% faster than rapid-mlx (MTP on) and 1.9-2.3x faster than mlx-vlm at 4K-32K context, serves four clients sharing a 16K prefix 2.7-2.9x faster (first token ~21 s vs 70-74 s), and has the lowest median first-token latency at 4-8 concurrent requests (21-44% lower). It ties rapid-mlx on 8-turn agent replay (cached prefix reuse) and on cold prefill within 1-3%. It is slightly slower (2-3%) on cold prefill at 16K-32K, 4-14% lower on aggregate throughput with concurrent requests, and has a 22-31% worse p95 first-token latency at c=4/8 on 512-token prompts."

Do not claim: "fastest cold prefill", "highest concurrent throughput", or "best tail latency".

## Caveats

- 2 passes, 1 rep per pass: medians over two values are means; pass-to-pass spread is 0.3-0.5% median, ~1.3-2.5% at p90, but decode at 16K/32K can swing up to 8.6% (Strim) and 26% (rapid-mlx, mlx-vlm); the decode WIN margins (24-41% and 1.9-2.3x) exceed that. Prefill gaps of 2-3% sit at the noise edge of the 2% TIE band.
- Rival pass 1 ran under higher system load than Strim pass 1 (see above); pass 2 did not. Conclusions hold in both passes except the six borderline cells listed.
- rapid-mlx used MTP and max-num-seqs 4; mlx-vlm had no MTP and no prefix cache (its decode and replay numbers reflect that, so it is the weakest comparison on those cells). Defaults were used otherwise; rival tuning (e.g. larger max-num-seqs, prefix cache flags) was not explored.
- TTFT definitions differ in practice (rival batch-synchronous TTFT, see loss #3); aggregate tok/s is the only fully comparable concurrency number.
- Greedy agreement is a sanity check only: Strim vs rapid-mlx 7/8 identical on 64 tokens, vs mlx-vlm 6/8; Strim self-consistent 8/8.
- Strim build predates the final server hardening commits (see above); engine code is otherwise HEAD.
- Single model, single machine, thinking off, synthetic agent prompts (W6) and a synthetic 8-turn fixture.
