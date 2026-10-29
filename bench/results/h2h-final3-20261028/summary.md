# Head-to-head, final run 3 (2026-10-28/29): Strim 0.1.1 vs rapid-mlx 0.15.7, mlx-vlm 0.7.10, mlx-lm 0.32.2, oMLX 0.4.5.dev1

Protocol: bench/h2h/RUNBOOK.md, unchanged scripts. Model models/qwen38-4bit (Strim and rapid-mlx also models/qwen38-mtp-4bit), thinking off, greedy, 33 cells x 5 engines x 2 passes, pass 1 order strim, rapid-mlx, mlx-vlm, mlx-lm, omlx, pass 2 reversed (ABBA). One engine session at a time under `lockf /tmp/strim-bench.lock`, `caffeinate -dimsu`, 60 s cooldown, memory watchdog (SIGTERM above 42 GB footprint or swap +2 GB), load sampled every 30 s. Quiet gate: 1-min load < 4.5 for 6 consecutive 30 s samples (2 for the later groups of a session) and no foreign process > 60% CPU, max 15 min. Machine: Apple M5 Max 64 GB, AC power. Raw per-cell output: `<engine>/pass<N>/`; machine-readable: `results.json` (schema v2, includes the polluted rapid-mlx records); `results-clean.json` / `summary-clean.md` = same with `H2H_ONLY_CLEAN=1` (non-CLEAN cells dropped).

Strim binary: `/tmp/strim-build-final4/release/strim` = `strim 0.1.1` built from commit ee9f9d8, not rebuilt. Engine sources at HEAD (a8f1824) are identical to ee9f9d8: `git diff --stat ee9f9d8 HEAD -- Sources ':!Sources/StrimSite' Package.swift Package.resolved` is empty (checked before the run, output in preflight.txt).

## Completeness and validity

- All 5 engines x 2 passes x 3 groups ran (30 sessions), every group rc=0, plus 2 reruns. oMLX: the guard/watchdog cells below are flagged, not retried. No other aborts, OOMs or timeouts. `leftover_suspect` flags are only `sleep 30` loops and unrelated shell/agent processes of the coordinator, not engine leftovers.
- Foreign load during the run was brief: Java spike (load 4.68) in rapid-mlx p1 w4 (1 sample, CLEAN), `pe2_apple_host_c` / coordinator screenshot job (>60% CPU) in rapid-mlx p1 w3/w3_32k, a >60% process in mlx-vlm p1 w4s, `systemstats --daily` (98-100% CPU) in the rapid-mlx rerun.
- Swap used at session start was 2.7-2.9 GB in pass 1 and 8.1-9.7 GB in pass 2 (above the ~6 GB runbook target); at the rerun2 start it was 5.08 GB used of 6.14 GB total (the swap file grew from 4 to 6 GB during the run) while about 19 GB of RAM was free and 33 GB inactive: the swapped pages are stale (never touched again, so not paged back in), not memory pressure. Not purged. Swap growth during any cell: max 0 MB. Not a pollution criterion.

### Session status (30 sessions + 2 reruns)

| session | status | note |
|---|---|---|
| all strim, mlx-lm, omlx sessions (18) | CLEAN | gate PASSED; max load 1.1-3.7 |
| mlx-vlm p1 g1, g3; p2 g1-g3 (5) | CLEAN | gate PASSED |
| mlx-vlm p1 g2 (w4,w4s,w6) | POLLUTED, rerun CLEAN | first record: Chrome at 109% CPU in w4s (foreign); rerun (load max 1.92, gate passed) supersedes; both records kept in sessions.jsonl |
| rapid-mlx p1 g2, g3; p2 g1-g3 (5) | CLEAN | |
| rapid-mlx p1 g1 (agree,w3,w3_32k) | POLLUTED, rerun POLLUTED, rerun2 CLEAN | first: coordinator job at 95-100% CPU in w3/w3_32k; rerun: `systemstats --daily` 98-100% CPU in w3_32k. **Deviation from "rerun once":** by coordinator instruction one further rerun ("rerun2") was run after the foreign load (coordinator job + systemstats) was gone: gate PASSED (150 s, load max 1.76), no foreign sample, CLEAN. All three records are kept in sessions.jsonl; summarize.sh uses the latest (rerun2). The polluted records are not averaged or used. The nine decode/prefill/TTFT cells vs rapid-mlx are therefore claim_eligible. |

Rerun budget: mlx-vlm p1 g2 reran once (CLEAN); rapid-mlx p1 g1 reran twice (see above). oMLX cells flagged (not claimable as WIN/LOSS, n/a): w4 in both passes (footprint 46.1 / 49.5 GB, watchdog + oMLX "Hard memory pressure"), w6 pass 2 (43.7 GB watchdog), w5 in both passes (oMLX guard abort, expected). Affected oMLX cells are not claim eligible (c=4/8 agent, 4K, W5 groups).

## Headline: Strim vs best rival (median of 2 passes; ratio = Strim / best rival; TIE within 2%; claim_eligible = Strim and that rival both fully CLEAN)

| cell | unit | Strim | best rival | ratio | verdict | claim_eligible |
|---|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 994.516 | mlx-vlm 1016.76 | 0.9781x | LOSS | yes |
| cold 4K TTFT | s | 4.12972 | mlx-vlm 4.03932 | 1.0224x | LOSS | yes |
| decode 256 tok @ 4K ctx | tok/s | 75.3386 | rapid-mlx 50.1205 | 1.5031x | WIN | yes |
| cold 16K prefill | tok/s | 963.081 | mlx-vlm 988.039 | 0.9747x | LOSS | yes |
| cold 16K TTFT | s | 17.0244 | mlx-vlm 16.5935 | 1.0260x | LOSS | yes |
| decode 256 tok @ 16K ctx | tok/s | 65.1795 | rapid-mlx 45.749 | 1.4247x | WIN | yes |
| cold 32K prefill | tok/s | 884.629 | mlx-vlm 923.193 | 0.9582x | LOSS | yes |
| cold 32K TTFT | s | 37.0607 | mlx-vlm 35.5061 | 1.0438x | LOSS | yes |
| decode 128 tok @ 32K ctx | tok/s | 52.1703 | rapid-mlx 42.169 | 1.2372x | WIN | yes |
| c=4 512-tok prompts aggregate | tok/s | 69.217 | rapid-mlx 71.6904 | 0.9655x | LOSS | yes |
| c=4 512-tok prompts p50 TTFT | s | 1.4931 | mlx-vlm 2.30482 | 0.6478x | WIN | yes |
| c=4 512-tok prompts p95 TTFT | s | 2.29205 | mlx-vlm 2.30494 | 0.9944x | TIE | yes |
| c=8 512-tok prompts aggregate | tok/s | 76.3713 | mlx-vlm 74.6549 | 1.0230x | WIN | yes |
| c=8 512-tok prompts p50 TTFT | s | 2.6835 | mlx-vlm 4.34047 | 0.6183x | WIN | yes |
| c=8 512-tok prompts p95 TTFT | s | 4.60995 | mlx-vlm 4.3407 | 1.0620x | LOSS | yes |
| c=4 agent prompts (~2.8K tok) aggregate | tok/s | 28.7283 | mlx-vlm 28.5687 | 1.0056x | TIE | yes |
| c=4 agent prompts p50 TTFT | s | 7.67754 | mlx-vlm 12.4301 | 0.6177x | WIN | yes |
| c=4 agent prompts p95 TTFT | s | 12.0733 | mlx-vlm 12.4302 | 0.9713x | WIN | yes |
| c=8 agent prompts aggregate | tok/s | 31.1928 | mlx-vlm 31.1774 | 1.0005x | TIE | yes |
| c=8 agent prompts p50 TTFT | s | 13.3427 | rapid-mlx 22.0974 | 0.6038x | WIN | yes |
| c=8 agent prompts p95 TTFT | s | 22.6717 | mlx-vlm 23.0995 | 0.9815x | TIE | yes |
| c=4 4K prompts aggregate (prefill-bound) | tok/s | 13.2369 | mlx-vlm 13.5173 | 0.9793x | LOSS | yes |
| c=4 4K prompts p50 TTFT | s | 10.3625 | mlx-vlm 16.1717 | 0.6408x | WIN | yes |
| c=4 4K prompts p95 TTFT | s | 15.9992 | mlx-vlm 16.1717 | 0.9893x | TIE | yes |
| c=8 4K prompts aggregate (prefill-bound) | tok/s | 13.2936 | mlx-vlm 13.8365 | 0.9608x | LOSS | yes |
| c=8 4K prompts p50 TTFT | s | 18.7503 | rapid-mlx 26.5585 | 0.7060x | WIN | yes |
| c=8 4K prompts p95 TTFT | s | 31.9956 | mlx-vlm 32.0748 | 0.9975x | TIE | yes |
| W5 4 clients, 16K shared prefix aggregate | tok/s | 9.77319 | mlx-vlm 3.47338 | 2.8137x | WIN | yes |
| W5 p50 TTFT | s | 20.2925 | mlx-vlm 70.4808 | 0.2879x | WIN | yes |
| W5 p95 TTFT | s | 22.8346 | mlx-vlm 70.4809 | 0.3240x | WIN | yes |
| agent replay prefill sum T1-T8 | s | 48.9337 | rapid-mlx 49.1317 | 0.9960x | TIE | yes |
| agent replay prefill sum T1-T6 | s | 34.5958 | rapid-mlx 34.7669 | 0.9951x | TIE | yes |
| agent replay T8 cached fraction | frac | 0.872475 | mlx-lm 0.87263 | 0.9998x | TIE | yes |

Honest reading: Strim loses cold prefill/TTFT to mlx-vlm at every context (2-4%, 32K worst, 4.4% on TTFT) and to rapid-mlx at 32K (prefill 0.97x, TTFT 1.03x); against rapid-mlx alone, prefill/TTFT at 4K and 16K are TIE (within 1%). It also loses c=4 512-tok aggregate to rapid-mlx (-3.5%), c=8 512 p95 TTFT to mlx-vlm (+6%), and the prefill-bound 4K aggregates at c=4/c=8 to mlx-vlm (-2%/-4%). It wins decode over rapid-mlx (the best rival): 1.50x / 1.42x / 1.24x at 4K / 16K / 32K, now claim_eligible (rapid-mlx pass 1 = rerun2 CLEAN, pass 2 CLEAN; rapid-mlx passes agree within 1-5%, far inside the 24-50% margin). W5 shared prefix 2.8x, p50 TTFT at every concurrency 0.60-0.71x. Agent replay: TIE with rapid-mlx and mlx-lm. Strim decode at 32K is its noisiest cell (49.1 vs 55.2 tok/s, 11.3% spread, both CLEAN), still far inside the 24% margin. Cold 32K prefill LOSS vs rapid-mlx (-2.8%) is only barely larger than Strim's own pass spread (2.7%), so treat it as a small loss.


## What changed vs earlier runs (Strim median / best-rival numbers; final2 was POLLUTED throughout; final-20261028 = first 3-engine run)

| cell | final (3 eng) strim / rapid / vlm | final2 (polluted) strim / rapid / vlm | final3 strim / rapid / vlm |
| cold 4K prefill | 980.1 / 991.6 / 998.6 | 982.1 / 984.9 / 1001.9 | 994.5 / 996.8 / 1016.8 |
| decode 256 tok @ 4K ctx | 67.1 / 50.5 / 29.5 | 70.7 / 47.7 / 30.7 | 75.3 / 50.1 / 32.7 |
| cold 16K prefill | 950.7 / 969.1 / 980.1 | 951.8 / 961.1 / 970.8 | 963.1 / 972.4 / 988 |
| decode 256 tok @ 16K ctx | 56.5 / 45.5 / 29.4 | 64.9 / 43.7 / 28.9 | 65.2 / 45.7 / 30.9 |
| cold 32K prefill | 879.6 / 904 / 906.6 | 862 / 895.3 / 904.2 | 884.6 / 910 / 923.2 |
| decode 128 tok @ 32K ctx | 52.1 / 36.9 / 25.7 | 57.8 / 38.6 / 27.5 | 52.2 / 42.2 / 29.3 |
| c=4 512-tok prompts aggregate | 60.4 / 70.6 / 66.8 | 65.2 / 68.6 / 65 | 69.2 / 71.7 / 67.3 |
| c=8 512-tok prompts aggregate | 67.4 / 71.2 / 74.3 | 75.1 / 68.4 / 73.1 | 76.4 / 71.8 / 74.7 |
| c=4 agent prompts (~2.8K tok) aggregate | 27.3 / 27.5 / 28.4 | 28 / 26.7 / 27.9 | 28.7 / 27.7 / 28.6 |
| c=8 agent prompts aggregate | 29.5 / 27.9 / 31 | 28.9 / 27 / 30.8 | 31.2 / 28.5 / 31.2 |
| c=4 4K prompts aggregate (prefill-bound) | 12.7 / 13.1 / 13.4 | 13 / 12.9 / 13.2 | 13.2 / 13.2 / 13.5 |
| c=8 4K prompts aggregate (prefill-bound) | 12.9 / 13.1 / 13.8 | 12.9 / 12.8 / 13.6 | 13.3 / 13.2 / 13.8 |
| W5 4 clients, 16K shared prefix aggregate | 9.5 / 3.3 / 3.5 | 9.6 / 3.3 / 3.5 | 9.8 / 3.3 / 3.5 |

- Decode: Strim 75.3 / 65.2 / 52.2 tok/s at 4K/16K/32K (final2 70.7 / 64.9 / 57.8, final 67.1 / 56.5 / 52.1); the 32K figure is lower than final2 and equal to the first run, with a wide pass spread. rapid-mlx 50.1 / 45.7 / 42.2 (clean passes). New rivals decode at 28-34 tok/s (no MTP).
- Prefill: Strim 994 / 963 / 885 tok/s, 0.4-4.2% behind mlx-vlm and 0.6-3.2% behind rapid-mlx; slightly better than both earlier runs (982 / 952 / 862 in final2). No prefill win in any run.
- c=4 / c=8 (512-tok): Strim 69.2 / 76.4 (final2 65.2 / 75.1; final 60.4 / 67.4); the c=4 aggregate gap to rapid-mlx narrowed from -5% to -3.5%. Agent and 4K aggregates are within +-4% of mlx-vlm in all runs; p50 TTFT wins hold (0.60-0.71x).
- Differences between runs are partly machine state (final2 was load-polluted); only final3 is gated.

## Results (ratio = strim / rival; lower-is-better cells (TTFT, time) win with ratio < 1; tie = within 2%)

| cell | unit | strim | rapid-mlx | mlx-vlm | mlx-lm | omlx | strim/rapid-mlx | strim/mlx-vlm | strim/mlx-lm | strim/omlx | vs rapid-mlx | vs mlx-vlm | vs mlx-lm | vs omlx |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 994.5 | 996.8 | 1017 | 949.1 | 896.7 | 1.00x | 0.98x | 1.05x | 1.11x | TIE | LOSS | WIN | WIN |
| cold 4K TTFT | s | 4.13 | 4.12 | 4.039 | 4.327 | 4.58 | 1.00x | 1.02x | 0.95x | 0.90x | TIE | LOSS | WIN | WIN |
| decode 256 tok @ 4K ctx | tok/s | 75.34 | 50.12 | 32.69 | 30.11 | 33.53 | 1.50x | 2.30x | 2.50x | 2.25x | WIN | WIN | WIN | WIN |
| cold 16K prefill | tok/s | 963.1 | 972.4 | 988 | 919.8 | 891.9 | 0.99x | 0.97x | 1.05x | 1.08x | TIE | LOSS | WIN | WIN |
| cold 16K TTFT | s | 17.02 | 16.86 | 16.59 | 17.82 | 18.38 | 1.01x | 1.03x | 0.96x | 0.93x | TIE | LOSS | WIN | WIN |
| decode 256 tok @ 16K ctx | tok/s | 65.18 | 45.75 | 30.93 | 28.68 | 31.42 | 1.42x | 2.11x | 2.27x | 2.07x | WIN | WIN | WIN | WIN |
| cold 32K prefill | tok/s | 884.6 | 910 | 923.2 | 850.8 | 823.7 | 0.97x | 0.96x | 1.04x | 1.07x | LOSS | LOSS | WIN | WIN |
| cold 32K TTFT | s | 37.06 | 36.02 | 35.51 | 38.53 | 39.79 | 1.03x | 1.04x | 0.96x | 0.93x | LOSS | LOSS | WIN | WIN |
| decode 128 tok @ 32K ctx | tok/s | 52.17 | 42.17 | 29.35 | 27.62 | 29.9 | 1.24x | 1.78x | 1.89x | 1.74x | WIN | WIN | WIN | WIN |
| c=4 512-tok prompts aggregate | tok/s | 69.22 | 71.69 | 67.29 | 66.31 | 54.61 | 0.97x | 1.03x | 1.04x | 1.27x | LOSS | WIN | WIN | WIN |
| c=4 512-tok prompts p50 TTFT | s | 1.493 | 2.339 | 2.305 | 2.467 | 3.049 | 0.64x | 0.65x | 0.61x | 0.49x | WIN | WIN | WIN | WIN |
| c=4 512-tok prompts p95 TTFT | s | 2.292 | 2.339 | 2.305 | 2.469 | 3.198 | 0.98x | 0.99x | 0.93x | 0.72x | WIN | TIE | WIN | WIN |
| c=8 512-tok prompts aggregate | tok/s | 76.37 | 71.76 | 74.65 | 67.9 | 58.74 | 1.06x | 1.02x | 1.12x | 1.30x | WIN | WIN | WIN | WIN |
| c=8 512-tok prompts p50 TTFT | s | 2.683 | 5.889 | 4.34 | 6.064 | 5.726 | 0.46x | 0.62x | 0.44x | 0.47x | WIN | WIN | WIN | WIN |
| c=8 512-tok prompts p95 TTFT | s | 4.61 | 9.466 | 4.341 | 9.837 | 6.304 | 0.49x | 1.06x | 0.47x | 0.73x | WIN | LOSS | WIN | WIN |
| c=4 agent prompts (~2.8K tok) aggregate | tok/s | 28.73 | 27.73 | 28.57 | 27.22 | 25.28 | 1.04x | 1.01x | 1.06x | 1.14x | WIN | TIE | WIN | WIN |
| c=4 agent prompts p50 TTFT | s | 7.678 | 13.44 | 12.43 | 13.47 | 13.32 | 0.57x | 0.62x | 0.57x | 0.58x | WIN | WIN | WIN | WIN |
| c=4 agent prompts p95 TTFT | s | 12.07 | 13.44 | 12.43 | 13.47 | 13.47 | 0.90x | 0.97x | 0.90x | 0.90x | WIN | WIN | WIN | WIN |
| c=8 agent prompts aggregate | tok/s | 31.19 | 28.47 | 31.18 | 27.63 | 26.89 | 1.10x | 1.00x | 1.13x | 1.16x | WIN | TIE | WIN | WIN |
| c=8 agent prompts p50 TTFT | s | 13.34 | 22.1 | 23.1 | 22.61 | 25.08 | 0.60x | 0.58x | 0.59x | 0.53x | WIN | WIN | WIN | WIN |
| c=8 agent prompts p95 TTFT | s | 22.67 | 30.98 | 23.1 | 31.68 | 25.69 | 0.73x | 0.98x | 0.72x | 0.88x | WIN | TIE | WIN | WIN |
| c=4 4K prompts aggregate (prefill-bound) | tok/s | 13.24 | 13.16 | 13.52 | 13.1 | n/a | 1.01x | 0.98x | 1.01x | n/a | TIE | LOSS | TIE | n/a |
| c=4 4K prompts p50 TTFT | s | 10.36 | 16.86 | 16.17 | 16.84 | n/a | 0.61x | 0.64x | 0.62x | n/a | WIN | WIN | WIN | n/a |
| c=4 4K prompts p95 TTFT | s | 16 | 16.86 | 16.17 | 16.85 | n/a | 0.95x | 0.99x | 0.95x | n/a | WIN | TIE | WIN | n/a |
| c=8 4K prompts aggregate (prefill-bound) | tok/s | 13.29 | 13.2 | 13.84 | 13.04 | n/a | 1.01x | 0.96x | 1.02x | n/a | TIE | LOSS | TIE | n/a |
| c=8 4K prompts p50 TTFT | s | 18.75 | 26.56 | 32.07 | 26.83 | n/a | 0.71x | 0.58x | 0.70x | n/a | WIN | WIN | WIN | n/a |
| c=8 4K prompts p95 TTFT | s | 32 | 36.24 | 32.07 | 36.57 | n/a | 0.88x | 1.00x | 0.88x | n/a | WIN | TIE | WIN | n/a |
| W5 4 clients, 16K shared prefix aggregate | tok/s | 9.773 | 3.344 | 3.473 | 3.346 | n/a | 2.92x | 2.81x | 2.92x | n/a | WIN | WIN | WIN | n/a |
| W5 p50 TTFT | s | 20.29 | 73.53 | 70.48 | 73.4 | n/a | 0.28x | 0.29x | 0.28x | n/a | WIN | WIN | WIN | n/a |
| W5 p95 TTFT | s | 22.83 | 73.53 | 70.48 | 73.4 | n/a | 0.31x | 0.32x | 0.31x | n/a | WIN | WIN | WIN | n/a |
| agent replay prefill sum T1-T8 | s | 48.93 | 49.13 | 192.5 | 55.02 | 64.84 | 1.00x | 0.25x | 0.89x | 0.75x | TIE | WIN | WIN | WIN |
| agent replay prefill sum T1-T6 | s | 34.6 | 34.77 | 107.7 | 39.31 | 44.9 | 1.00x | 0.32x | 0.88x | 0.77x | TIE | WIN | WIN | WIN |
| agent replay T8 cached fraction | frac | 0.8725 | 0.8723 | 0 | 0.8726 | 0.8525 | 1.00x | n/a | 1.00x | 1.02x | TIE | n/a | TIE | WIN |

## Peak memory per cell (MB; max over passes and sessions; footprint = phys_footprint of the engine process tree, includes Metal buffers)

| cell | strim footprint / RSS | rapid-mlx footprint / RSS | mlx-vlm footprint / RSS | mlx-lm footprint / RSS | omlx footprint / RSS |
|---|---|---|---|---|---|
| warmup | 18422 / 8695 | 20144 / 15608 | 19308 / 16240 | 17556 / 15276 | 18753 / 16136 |
| agree | 17500 / 8700 | 17365 / 15612 | 16858 / 16234 | 17765 / 15280 | 19704 / 17510 |
| w3 | 23305 / 8702 | 22064 / 15622 | 20513 / 16246 | 21703 / 15307 | 24734 / 17344 |
| w3_32k | 28662 / 8704 | 24816 / 15640 | 23461 / 16260 | 27023 / 15319 | 28954 / 18189 |
| w4 | 29992 / 8708 | 31330 / 15619 | 36313 / 16259 | 34431 / 15289 | 49531 / 18950 |
| w4s | 26008 / 8709 | 20402 / 15625 | 24364 / 16271 | 23908 / 15299 | 28148 / 17217 |
| w6 | 29543 / 8711 | 26591 / 15628 | 33765 / 16287 | 31456 / 15300 | 43655 / 18115 |
| w5 | 30763 / 8703 | 33466 / 15607 | 30194 / 16249 | 31388 / 15291 | 40479 / 17346 |
| replay | 27536 / 8707 | 35892 / 15627 | 28642 / 16278 | 37450 / 15317 | 36882 / 18988 |
| **whole run** | **30763 / 8711** | **35892 / 15640** | **36313 / 16287** | **37450 / 15319** | **55210 / 18988** |

## Engines: capabilities and exact launch (engines.sh is the single source; versions are those measured in this run)

| engine | version (measured) | MTP / speculative | prefix cache | cache hits visible via | own memory guard | flags (cwd = repo root) |
|---|---|---|---|---|---|---|
| strim | strim 0.1.1 | yes (qwen38-mtp-4bit head) | yes, default (STRIM_PREFIX_CACHE_MB 12288) | usage.prompt_tokens_details.cached_tokens | none (admission control, max_inflight 8) | `serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth` |
| rapid-mlx | rapid-mlx 0.15.7 | yes (--speculative-config mtp, qwen38-mtp-4bit) | yes, default on | not reported in usage (unknown) | none | `--no-telemetry serve models/qwen38-4bit --port 8651 --max-num-seqs 4 --speculative-config {mtp,qwen38-mtp-4bit}` |
| mlx-vlm | mlx-vlm 0.7.10 | no | no cross-request reuse (0% cached in replay) | none | none | `--model models/qwen38-4bit --port 8651 (server defaults)` |
| mlx-lm | mlx-lm 0.32.2 | no (no speculative decoding) | yes, default in-memory LRU prompt cache | usage.prompt_tokens_details.cached_tokens; server log 'Prompt Cache: N sequences, X GB' | none | `--model models/qwen38-4bit --port 8654 --decode-concurrency 4 --prompt-concurrency 4` |
| omlx | oMLX 0.4.5.dev1 | no (MTP needs oMLX's own checkpoint; stock weights have no MTP head) | yes, default paged SSD prefix cache under the scratch HOME (fresh per session, so no cross-session hits) | usage.prompt_tokens_details.cached_tokens (reported after warm-up; first rows can be unknown) | process memory enforcer (tier balanced, ceiling ~54-56 GB): aborts requests and unloads the model | `serve --model-dir <scratch>/models (symlink to models/qwen38-4bit) --port 8653, HOME=<scratch>/home, defaults otherwise (memory-guard balanced, max-concurrent-requests 8)` |

## Session validity (latest session per engine, pass and cell group; CLEAN = no 2-sample pollution, gate passed; claims only from CLEAN)

| engine | pass | cells | status | gate | polluted cells | flags |
|---|---|---|---|---|---|---|
| strim | 1 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| strim | 1 | w4,w4s,w6 | CLEAN | PASSED |  | shutdown:leftover_suspect |
| strim | 1 | w5,replay | CLEAN | PASSED |  |  |
| strim | 2 | agree,w3,w3_32k | CLEAN | PASSED |  |  |
| strim | 2 | w4,w4s,w6 | CLEAN | PASSED |  | shutdown:leftover_suspect |
| strim | 2 | w5,replay | CLEAN | PASSED |  |  |
| rapid-mlx | 1 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| rapid-mlx | 1 | w4,w4s,w6 | CLEAN | PASSED |  |  |
| rapid-mlx | 1 | w5,replay | CLEAN | PASSED |  |  |
| rapid-mlx | 2 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| rapid-mlx | 2 | w4,w4s,w6 | CLEAN | PASSED |  |  |
| rapid-mlx | 2 | w5,replay | CLEAN | PASSED |  |  |
| mlx-vlm | 1 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| mlx-vlm | 1 | w4,w4s,w6 | CLEAN | PASSED |  | shutdown:leftover_suspect |
| mlx-vlm | 1 | w5,replay | CLEAN | PASSED |  | shutdown:leftover_suspect |
| mlx-vlm | 2 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| mlx-vlm | 2 | w4,w4s,w6 | CLEAN | PASSED |  | shutdown:leftover_suspect shutdown:leftover_suspect shutdown:leftover_suspect |
| mlx-vlm | 2 | w5,replay | CLEAN | PASSED |  | shutdown:leftover_suspect |
| mlx-lm | 1 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| mlx-lm | 1 | w4,w4s,w6 | CLEAN | PASSED |  |  |
| mlx-lm | 1 | w5,replay | CLEAN | PASSED |  |  |
| mlx-lm | 2 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| mlx-lm | 2 | w4,w4s,w6 | CLEAN | PASSED |  |  |
| mlx-lm | 2 | w5,replay | CLEAN | PASSED |  |  |
| omlx | 1 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| omlx | 1 | w4,w4s,w6 | CLEAN | PASSED |  | w4:memory_abort_watchdog w4:engine_guard_abort restart:engine_restart shutdown:leftover_suspect |
| omlx | 1 | w5,replay | CLEAN | PASSED |  | w5:engine_guard_abort restart:engine_restart shutdown:leftover_suspect |
| omlx | 2 | agree,w3,w3_32k | CLEAN | PASSED |  | shutdown:leftover_suspect |
| omlx | 2 | w4,w4s,w6 | CLEAN | PASSED |  | w4:memory_abort_watchdog w4:engine_guard_abort restart:engine_restart w6:memory_abort_watchdog shutdown:leftover_suspect |
| omlx | 2 | w5,replay | CLEAN | PASSED |  | w5:engine_guard_abort restart:engine_restart shutdown:leftover_suspect |

## Flagged cells (never retried silently; n/a in the tables above when an abort, guard, OOM or timeout flag)

- strim pass1 shutdown: leftover_suspect pid 92796 bash /Users/user/.claude-work/skills/_shared/codex-exec.sh new /Users/user/Des
- strim pass1 shutdown: leftover_suspect pid 29621 sleep 30
- strim pass2 shutdown: leftover_suspect pid 3380 sleep 30
- rapid-mlx pass1 shutdown: leftover_suspect pid 711 /bin/zsh -c source /Users/user/.claude-work/shell-snapshots/snapshot-zsh-17930271050
- rapid-mlx pass1 shutdown: leftover_suspect pid 3045 sleep 30
- rapid-mlx pass1 shutdown: leftover_suspect pid 8905 sleep 30
- rapid-mlx pass1 shutdown: leftover_suspect pid 90824 sleep 30
- rapid-mlx pass2 shutdown: leftover_suspect pid 91430 sleep 30
- mlx-vlm pass1 shutdown: leftover_suspect pid 13523 sleep 30
- mlx-vlm pass1 shutdown: leftover_suspect pid 16143 sleep 30
- mlx-vlm pass1 shutdown: leftover_suspect pid 20758 sleep 30
- mlx-vlm pass1 shutdown: leftover_suspect pid 13271 sleep 30
- mlx-vlm pass2 shutdown: leftover_suspect pid 72801 sleep 30
- mlx-vlm pass2 shutdown: leftover_suspect pid 74630 /bin/bash ./run39.sh
- mlx-vlm pass2 shutdown: leftover_suspect pid 75283 /Users/user/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUse
- mlx-vlm pass2 shutdown: leftover_suspect pid 82630 sleep 30
- mlx-vlm pass2 shutdown: leftover_suspect pid 87429 sleep 30
- mlx-lm pass1 shutdown: leftover_suspect pid 29524 sleep 30
- mlx-lm pass2 shutdown: leftover_suspect pid 62627 sleep 30
- omlx pass1 shutdown: leftover_suspect pid 41346 sleep 30
- omlx pass1 w4: memory_abort_watchdog # ABORT cell=w4 footprint_mb=46083 swap_grow_mb=0 1793224941
- omlx pass1 w4: engine_guard_abort 2026-10-28 23:02:32;086 - omlx.process_memory_enforcer - WARNING - Hard memory pressure: requested abort/unload for 'qwen38-4bit' (aborted=3)
- omlx pass1 restart: engine_restart restart_after_flagged_cell
- omlx pass1 shutdown: leftover_suspect pid 44813 sleep 30
- omlx pass1 w5: engine_guard_abort 2026-10-28 23:06:41;606 - omlx.process_memory_enforcer - WARNING - Hard memory pressure: requested abort/unload for 'qwen38-4bit' (aborted=3)
- omlx pass1 restart: engine_restart restart_after_flagged_cell
- omlx pass1 shutdown: leftover_suspect pid 48234 sleep 30
- omlx pass2 shutdown: leftover_suspect pid 51937 sleep 30
- omlx pass2 w4: memory_abort_watchdog # ABORT cell=w4 footprint_mb=49531 swap_grow_mb=-439 1793225740
- omlx pass2 w4: engine_guard_abort 2026-10-28 23:15:43;199 - omlx.process_memory_enforcer - WARNING - Hard memory pressure: requested abort/unload for 'qwen38-4bit' (aborted=3)
- omlx pass2 restart: engine_restart restart_after_flagged_cell
- omlx pass2 w6: memory_abort_watchdog # ABORT cell=w6 footprint_mb=43655 swap_grow_mb=-871 1793225848
- omlx pass2 shutdown: leftover_suspect pid 55487 sleep 30
- omlx pass2 w5: engine_guard_abort 2026-10-28 23:19:59;152 - omlx.process_memory_enforcer - WARNING - Hard memory pressure: requested abort/unload for 'qwen38-4bit' (aborted=3)
- omlx pass2 restart: engine_restart restart_after_flagged_cell
- omlx pass2 shutdown: leftover_suspect pid 58888 sleep 30

## Cache-hit reporting (usage-reported cached tokens, per engine; rows without a value = engine did not report)

| engine | cell | rows | rows with a hit | cached tokens | unreported rows |
|---|---|---|---|---|---|
| strim | w5 | 8 | 6 | 92160 | 0 |
| strim | replay | 16 | 14 | 278154 | 0 |
| rapid-mlx | w5 | 8 | 0 | 0 | 8 |
| rapid-mlx | replay | 16 | 14 | 277998 | 2 |
| mlx-vlm | w5 | 8 | 0 | 0 | 0 |
| mlx-vlm | replay | 16 | 0 | 0 | 0 |
| mlx-lm | w5 | 8 | 0 | 0 | 0 |
| mlx-lm | replay | 16 | 14 | 278273 | 0 |
| omlx | w5 | 8 | 0 | 0 | 6 |
| omlx | replay | 16 | 14 | 262144 | 0 |

## Run conditions

- strim pass1: 3 sessions; first load { 1.77 2.53 3.57 }; swap used at start 2883.38M; swap growth max 0 MB; watchdog aborts: none
- strim pass2: 3 sessions; first load { 1.20 1.46 1.46 }; swap used at start 8052.38M; swap growth max 0 MB; watchdog aborts: none
- rapid-mlx pass1: 5 sessions; first load { 2.94 3.15 3.36 }; swap used at start 2731.19M; swap growth max 0 MB; watchdog aborts: none
- rapid-mlx pass2: 3 sessions; first load { 1.54 1.45 1.49 }; swap used at start 8172.38M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass1: 4 sessions; first load { 1.56 1.69 2.36 }; swap used at start 2731.19M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass2: 3 sessions; first load { 1.30 1.21 1.27 }; swap used at start 9262.62M; swap growth max 0 MB; watchdog aborts: none
- mlx-lm pass1: 3 sessions; first load { 2.05 1.76 1.92 }; swap used at start 2731.19M; swap growth max 0 MB; watchdog aborts: none
- mlx-lm pass2: 3 sessions; first load { 1.13 1.26 1.39 }; swap used at start 9703.12M; swap growth max 0 MB; watchdog aborts: none
- omlx pass1: 3 sessions; first load { 1.26 1.17 1.36 }; swap used at start 2723.19M; swap growth max 0 MB; watchdog aborts: w4 idle 
- omlx pass2: 3 sessions; first load { 1.12 1.35 1.47 }; swap used at start 9710.06M; swap growth max 0 MB; watchdog aborts: w4 w6 

## Greedy agreement (sanity only; 8 fixed prompts, 64 tokens, near-ties diverge)

- strim pass1 vs pass2 (self): 8/8 identical; mean common-prefix fraction 1
- strim vs rapid-mlx (pass1): 7/8 identical; mean common-prefix fraction 0.91; (pass2): 7/8 identical; mean common-prefix fraction 0.91
- strim vs mlx-vlm (pass1): 6/8 identical; mean common-prefix fraction 0.79; (pass2): 6/8 identical; mean common-prefix fraction 0.79
- strim vs mlx-lm (pass1): 6/8 identical; mean common-prefix fraction 0.83; (pass2): 6/8 identical; mean common-prefix fraction 0.83
- strim vs omlx (pass1): 7/8 identical; mean common-prefix fraction 0.91; (pass2): 7/8 identical; mean common-prefix fraction 0.91
- rapid-mlx vs mlx-vlm (pass1): 7/8 identical; mean common-prefix fraction 0.88
- rapid-mlx vs mlx-lm (pass1): 7/8 identical; mean common-prefix fraction 0.93
- rapid-mlx vs omlx (pass1): 8/8 identical; mean common-prefix fraction 1
- mlx-vlm vs mlx-lm (pass1): 6/8 identical; mean common-prefix fraction 0.81
- mlx-vlm vs omlx (pass1): 7/8 identical; mean common-prefix fraction 0.88
- mlx-lm vs omlx (pass1): 7/8 identical; mean common-prefix fraction 0.93

## Agent replay detail (8 turns; median over passes)

| turn | prompt tok | strim TTFT s | strim cached tok | rapid-mlx TTFT s | rapid-mlx cached tok | mlx-vlm TTFT s | mlx-vlm cached tok | mlx-lm TTFT s | mlx-lm cached tok | omlx TTFT s | omlx cached tok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4092 | 4.09 | 0 | 4.10 | n/a | 4.01 | 0 | 4.67 | 0 | 4.47 | 0 |
| 2 | 9347 | 5.51 | 4085 | 5.54 | 4064 | 9.30 | 0 | 5.50 | 4093.5 | 8.21 | 2048 |
| 3 | 14628 | 5.80 | 9340 | 5.88 | 9334 | 14.81 | 0 | 6.75 | 9348.5 | 7.76 | 8192 |
| 4 | 19885 | 6.12 | 14621 | 6.08 | 14614 | 20.53 | 0 | 7.15 | 14629.5 | 7.15 | 14336 |
| 5 | 25157 | 6.42 | 19878 | 6.49 | 19862 | 26.50 | 0 | 7.48 | 19886.5 | 8.98 | 18432 |
| 6 | 30379 | 6.66 | 25150 | 6.67 | 25142 | 32.53 | 0 | 7.76 | 25158.5 | 8.34 | 24576 |
| 7 | 35638 | 7.07 | 30372 | 7.12 | 30358 | 39.13 | 0 | 7.74 | 30380.5 | 10.33 | 28672 |
| 8 | 40839 | 7.27 | 35631 | 7.25 | 35625 | 45.69 | 0 | 7.97 | 35639.5 | 9.61 | 34816 |

## Pass-to-pass noise (|pass1-pass2| / mean, percent, over all cells above; TIE band is 2%)

| engine | cells | median spread | p90 spread | max spread (cell) |
|---|---|---|---|---|
| strim | 33 | 0.9% | 2.7% | 11.7% (decode 128 tok @ 32K ctx) |
| rapid-mlx | 33 | 0.4% | 1.0% | 4.8% (decode 256 tok @ 4K ctx) |
| mlx-vlm | 32 | 0.5% | 0.8% | 1.7% (W5 p50 TTFT) |
| mlx-lm | 33 | 0.2% | 0.4% | 4.1% () |
| omlx | 18 | 0.2% | 2.5% | 8.1% (c) |
