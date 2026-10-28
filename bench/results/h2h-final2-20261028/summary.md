# Head-to-head, final run 2 (2026-10-28): Strim ac35bd9 vs rapid-mlx 0.15.7 vs mlx-vlm 0.7.10

Same protocol as bench/results/h2h-final-20261028 (model models/qwen38-4bit + models/qwen38-mtp-4bit, thinking off, greedy, 8 cells x 3 engines x 2 passes, pass 1 order strim, rapid-mlx, mlx-vlm; pass 2 reversed = ABBA; one engine at a time under `lockf /tmp/strim-bench.lock`). Machine: Apple M5 Max, 64 GB. Runner: bench/h2h/{run,pass,watchdog,agree,summarize}.sh unchanged, with two run-time deviations: `STRIM_BIN=/tmp/strim-build-final2/release/strim` (exactly commit ac35bd9, version 0.1.0, not rebuilt; the SwiftPM bundles sit next to the binary, so mlx.metallib resolved with no copying) and agent prompts generated from revision 2df65e7 instead of HEAD (byte-identical to the previous run's agent-prompts.json, so W6 is the same workload; HEAD's source files have changed since). Raw per-cell output: `<engine>/pass<N>/`; machine-readable: `results.json` (same schema as the previous run).

## Completeness and validity

- 3 engines x 2 passes x 8 cells plus warmup per session: all cells present, every cell rc=0, 0 request errors in any raw.jsonl, 0 engine restarts, 0 watchdog aborts, no timeouts. No rerun was performed.
- Rival versions/flags unchanged and not upgraded: rapid-mlx 0.15.7 (`rapid-mlx --no-telemetry serve models/qwen38-4bit --port 8651 --max-num-seqs 4 --speculative-config {"method":"mtp","model":"models/qwen38-mtp-4bit"}`), mlx-vlm 0.7.10 (`.venv-sprint/bin/mlx_vlm.server --model models/qwen38-4bit --port 8651`, no MTP, no prefix cache). These launch lines are the ones hard-coded in bench/h2h/pass.sh, identical to the previous run. Strim: `serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth` (MTP on, admission on, max_inflight 8, prefix cache default).
- **The machine was NOT quiet. All six engine/pass sessions are POLLUTED under the protocol rule (1-min load > 3 from non-engine work) and none is CLEAN.** Pre-existing GUI load (WindowServer, RustDesk, Mica) kept the idle 1-min load at about 3-5 before the run; from about 18:24 a foreign Python profiler job (4 processes at ~99% CPU) and later a Java job pushed it to 6-12. By coordinator instruction no wait and no rerun was done; reruns are to be scheduled by the coordinator when the machine is quiet.
- Memory: peak footprint 37.98 GB (mlx-vlm w4), 35.42 GB (rapid-mlx w5), 30.40 GB (Strim w4); all under the 42 GB limit. Swap growth max 680 MB (Strim pass 2, a load-polluted session), 0 elsewhere; none invalid.

### Load and cleanliness per session (max 1-min load recorded at a cell start, per 3-cell group g1/g2/g3)

| session | time (local) | g1 / g2 / g3 max load | status | rerun needed |
|---|---|---|---|---|
| strim pass 1 | 17:55-18:01 | 3.3 / 4.7 / 4.8 | POLLUTED (mild; GUI baseline, no foreign job yet) | yes |
| rapid-mlx pass 1 | 18:01-18:08 | 4.4 / 4.9 / 6.2 | POLLUTED | yes |
| mlx-vlm pass 1 | 18:08-18:18 | 11.3 / 7.5 / 6.2 | POLLUTED (heavy) | yes |
| mlx-vlm pass 2 | 18:18-18:27 | 11.8 / 4.8 / 5.7 | POLLUTED (heavy, g1) | yes |
| rapid-mlx pass 2 | 18:27-18:34 | 6.9 / 6.7 / 6.4 | POLLUTED (foreign job) | yes |
| strim pass 2 | 18:35-18:41 | 7.5 / 7.7 / 11.3 | POLLUTED (foreign job + Java, worst) | yes |

Effect visible in the data: Strim pass-to-pass spread is 1.7% median / 9.3% p90 (previous run 0.5% / 1.3%), and the replay T8 TTFT median is 10.2 s vs 7.4 s for rapid-mlx (previous run 7.39 s vs 7.29 s) because Strim pass 2 ran at load 11. Rival spreads stayed small (rapid-mlx 0.5% median). Strim pass 2 is the most damaged session; Strim numbers below are therefore pessimistic in the cells where the two passes differ most. Treat this run as indicative only; the clean-publishable run requires the reruns (priority: strim pass 2, mlx-vlm pass 1/2, rapid-mlx pass 2, then the pass 1 sessions).

## Headline: Strim vs best rival (median of 2 passes; ratio = Strim / best rival; TIE = within 2%; verdicts as reported in results.json)

| cell | unit | Strim | best rival | ratio | verdict |
|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 982.083 | mlx-vlm 1001.91 | 0.98x | TIE |
| cold 4K TTFT | s | 4.182 | mlx-vlm 4.099 | 1.02x | TIE |
| decode 256 tok @ 4K ctx | tok/s | 70.72 | rapid-mlx 47.747 | 1.48x | WIN |
| cold 16K prefill | tok/s | 951.756 | mlx-vlm 970.803 | 0.98x | TIE |
| cold 16K TTFT | s | 17.226 | mlx-vlm 16.889 | 1.02x | TIE |
| decode 256 tok @ 16K ctx | tok/s | 64.904 | rapid-mlx 43.688 | 1.49x | WIN |
| cold 32K prefill | tok/s | 861.992 | mlx-vlm 904.194 | 0.95x | LOSS |
| cold 32K TTFT | s | 38.041 | mlx-vlm 36.253 | 1.05x | LOSS |
| decode 128 tok @ 32K ctx | tok/s | 57.805 | rapid-mlx 38.581 | 1.5x | WIN |
| c=4 512-tok prompts aggregate | tok/s | 65.19 | rapid-mlx 68.609 | 0.95x | LOSS |
| c=4 512-tok prompts p50 TTFT | s | 1.517 | mlx-vlm 2.352 | 0.65x | WIN |
| c=4 512-tok prompts p95 TTFT | s | 2.326 | mlx-vlm 2.352 | 0.99x | TIE |
| c=8 512-tok prompts aggregate | tok/s | 75.105 | mlx-vlm 73.114 | 1.03x | WIN |
| c=8 512-tok prompts p50 TTFT | s | 2.723 | mlx-vlm 4.419 | 0.62x | WIN |
| c=8 512-tok prompts p95 TTFT | s | 4.717 | mlx-vlm 4.42 | 1.07x | LOSS |
| c=4 agent prompts (~2.8K tok) aggregate | tok/s | 28.021 | mlx-vlm 27.867 | 1.01x | TIE |
| c=4 agent prompts p50 TTFT | s | 7.979 | mlx-vlm 12.642 | 0.63x | WIN |
| c=4 agent prompts p95 TTFT | s | 12.439 | mlx-vlm 12.642 | 0.98x | TIE |
| c=8 agent prompts aggregate | tok/s | 28.937 | mlx-vlm 30.78 | 0.94x | LOSS |
| c=8 agent prompts p50 TTFT | s | 13.531 | rapid-mlx 23.144 | 0.58x | WIN |
| c=8 agent prompts p95 TTFT | s | 24.524 | mlx-vlm 23.406 | 1.05x | LOSS |
| c=4 4K prompts aggregate (prefill-bound) | tok/s | 12.991 | mlx-vlm 13.204 | 0.98x | TIE |
| c=4 4K prompts p50 TTFT | s | 10.525 | mlx-vlm 16.503 | 0.64x | WIN |
| c=4 4K prompts p95 TTFT | s | 16.259 | mlx-vlm 16.503 | 0.99x | TIE |
| c=8 4K prompts aggregate (prefill-bound) | tok/s | 12.946 | mlx-vlm 13.58 | 0.95x | LOSS |
| c=8 4K prompts p50 TTFT | s | 19.098 | rapid-mlx 27.227 | 0.7x | WIN |
| c=8 4K prompts p95 TTFT | s | 32.929 | mlx-vlm 32.646 | 1.01x | TIE |
| W5 4 clients, 16K shared prefix aggregate | tok/s | 9.553 | mlx-vlm 3.45 | 2.77x | WIN |
| W5 p50 TTFT | s | 20.707 | mlx-vlm 70.93 | 0.29x | WIN |
| W5 p95 TTFT | s | 23.329 | mlx-vlm 70.931 | 0.33x | WIN |
| agent replay prefill sum T1-T8 | s | 52.771 | rapid-mlx 50.237 | 1.05x | LOSS |
| agent replay prefill sum T1-T6 | s | 35.242 | rapid-mlx 35.487 | 0.99x | TIE |
| agent replay T8 cached fraction | frac | 0.872 | rapid-mlx 0.872 | 1x | TIE |

Tally vs best rival: 13 WIN, 12 TIE, 8 LOSS (previous run: 12 WIN, 6 TIE, 15 LOSS, same cells). POLLUTED sessions: do not publish these as final.

## Change vs previous run (2df65e7 vs ac35bd9; Strim median old -> new; best rival and verdict vs best rival old -> new)

Both runs were load-polluted to different degrees (the previous run's pass 1 rival sessions, this run's all sessions), so deltas under about 5% are not attributable to code.

| cell | Strim old | Strim new | delta | old best rival | new best rival | verdict old -> new |
|---|---|---|---|---|---|---|
| cold 4K prefill | 980.12 | 982.08 | 0.2% | mlx-vlm 998.63 | mlx-vlm 1001.91 | TIE -> TIE |
| cold 4K TTFT | 4.19 | 4.18 | -0.2% | mlx-vlm 4.11 | mlx-vlm 4.1 | TIE -> TIE |
| decode 256 tok @ 4K ctx | 67.14 | 70.72 | 5.3% | rapid-mlx 50.5 | rapid-mlx 47.75 | WIN -> WIN |
| cold 16K prefill | 950.75 | 951.76 | 0.1% | mlx-vlm 980.12 | mlx-vlm 970.8 | LOSS -> TIE |
| cold 16K TTFT | 17.24 | 17.23 | -0.1% | mlx-vlm 16.73 | mlx-vlm 16.89 | LOSS -> TIE |
| decode 256 tok @ 16K ctx | 56.54 | 64.9 | 14.8% | rapid-mlx 45.53 | rapid-mlx 43.69 | WIN -> WIN |
| cold 32K prefill | 879.63 | 861.99 | -2% | mlx-vlm 906.57 | mlx-vlm 904.19 | LOSS -> LOSS |
| cold 32K TTFT | 37.26 | 38.04 | 2.1% | mlx-vlm 36.16 | mlx-vlm 36.25 | LOSS -> LOSS |
| decode 128 tok @ 32K ctx | 52.09 | 57.8 | 11% | rapid-mlx 36.89 | rapid-mlx 38.58 | WIN -> WIN |
| c=4 512-tok prompts aggregate | 60.42 | 65.19 | 7.9% | rapid-mlx 70.64 | rapid-mlx 68.61 | LOSS -> LOSS |
| c=4 512-tok prompts p50 TTFT | 1.82 | 1.52 | -16.9% | mlx-vlm 2.32 | mlx-vlm 2.35 | WIN -> WIN |
| c=4 512-tok prompts p95 TTFT | 2.83 | 2.33 | -17.9% | mlx-vlm 2.32 | mlx-vlm 2.35 | LOSS -> TIE |
| c=8 512-tok prompts aggregate | 67.37 | 75.1 | 11.5% | mlx-vlm 74.31 | mlx-vlm 73.11 | LOSS -> WIN |
| c=8 512-tok prompts p50 TTFT | 3.29 | 2.72 | -17.2% | mlx-vlm 4.36 | mlx-vlm 4.42 | WIN -> WIN |
| c=8 512-tok prompts p95 TTFT | 5.7 | 4.72 | -17.3% | mlx-vlm 4.36 | mlx-vlm 4.42 | LOSS -> LOSS |
| c=4 agent prompts (~2.8K tok) aggregate | 27.3 | 28.02 | 2.7% | mlx-vlm 28.4 | mlx-vlm 27.87 | LOSS -> TIE |
| c=4 agent prompts p50 TTFT | 8.12 | 7.98 | -1.8% | mlx-vlm 12.49 | mlx-vlm 12.64 | WIN -> WIN |
| c=4 agent prompts p95 TTFT | 12.6 | 12.44 | -1.3% | mlx-vlm 12.49 | mlx-vlm 12.64 | TIE -> TIE |
| c=8 agent prompts aggregate | 29.5 | 28.94 | -1.9% | mlx-vlm 30.96 | mlx-vlm 30.78 | LOSS -> LOSS |
| c=8 agent prompts p50 TTFT | 14.29 | 13.53 | -5.3% | rapid-mlx 22.39 | rapid-mlx 23.14 | WIN -> WIN |
| c=8 agent prompts p95 TTFT | 23.89 | 24.52 | 2.6% | mlx-vlm 23.29 | mlx-vlm 23.41 | LOSS -> LOSS |
| c=4 4K prompts aggregate (prefill-bound) | 12.74 | 12.99 | 2% | mlx-vlm 13.45 | mlx-vlm 13.2 | LOSS -> TIE |
| c=4 4K prompts p50 TTFT | 10.74 | 10.53 | -2% | mlx-vlm 16.25 | mlx-vlm 16.5 | WIN -> WIN |
| c=4 4K prompts p95 TTFT | 16.64 | 16.26 | -2.3% | mlx-vlm 16.25 | mlx-vlm 16.5 | LOSS -> TIE |
| c=8 4K prompts aggregate (prefill-bound) | 12.88 | 12.95 | 0.5% | mlx-vlm 13.79 | mlx-vlm 13.58 | LOSS -> LOSS |
| c=8 4K prompts p50 TTFT | 19.52 | 19.1 | -2.2% | rapid-mlx 26.79 | rapid-mlx 27.23 | WIN -> WIN |
| c=8 4K prompts p95 TTFT | 33.51 | 32.93 | -1.7% | mlx-vlm 32.19 | mlx-vlm 32.65 | LOSS -> TIE |
| W5 4 clients, 16K shared prefix aggregate | 9.46 | 9.55 | 1% | mlx-vlm 3.47 | mlx-vlm 3.45 | WIN -> WIN |
| W5 p50 TTFT | 20.69 | 20.71 | 0.1% | mlx-vlm 70.42 | mlx-vlm 70.93 | WIN -> WIN |
| W5 p95 TTFT | 23.36 | 23.33 | -0.1% | mlx-vlm 70.42 | mlx-vlm 70.93 | WIN -> WIN |
| agent replay prefill sum T1-T8 | 49.69 | 52.77 | 6.2% | rapid-mlx 49.45 | rapid-mlx 50.24 | TIE -> LOSS |
| agent replay prefill sum T1-T6 | 35.11 | 35.24 | 0.4% | rapid-mlx 34.97 | rapid-mlx 35.49 | TIE -> TIE |
| agent replay T8 cached fraction | 0.87 | 0.87 | -0% | rapid-mlx 0.87 | rapid-mlx 0.87 | TIE -> TIE |

Notes: decode at 4K/16K/32K is +5% / +15% / +11% over the previous Strim figures (L16 draft-depth policy landed between the builds; new best-rival decode is lower, 47.8 / 43.7 / 38.6 tok/s, so ratios go to 1.48x / 1.49x / 1.50x). Cold 32K prefill/TTFT remain a LOSS vs both rivals (-4% to -5%), the one cold-path gap that persists. Verdict changes: 8 cells improve (mostly LOSS -> TIE inside the 2% band, c=8 512-tok aggregate LOSS -> WIN); agent replay prefill sum T1-T8 goes TIE -> LOSS, caused by one slow Strim pass-2 replay under load 11 (T1-T6 is still TIE), not a cache-reuse change (T8 cached fraction 0.8725 identical). c=4 512-tok aggregate remains a LOSS to rapid-mlx (0.95x).

## W5 shared prefix and replay

W5 (4 clients, 16K shared prefix): Strim 9.55 tok/s aggregate vs 3.45 (mlx-vlm best) = 2.77x WIN; p50 TTFT 20.7 s vs 70.9 s (0.29x); p95 23.3 s vs 70.9 s. Replay: all three engines see identical prompt sizes; Strim and rapid-mlx reuse 87.2% of T8 tokens, mlx-vlm 0%; mlx-vlm replay prefill sum 194.9 s.

## Results (ratio = strim / rival; lower-is-better cells (TTFT, time) win with ratio < 1; tie = within 2%)

| cell | unit | strim | rapid-mlx | mlx-vlm | strim/rapid-mlx | strim/mlx-vlm | vs rapid-mlx | vs mlx-vlm |
|---|---|---|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 982.1 | 984.9 | 1002 | 1.00x | 0.98x | TIE | TIE |
| cold 4K TTFT | s | 4.182 | 4.17 | 4.099 | 1.00x | 1.02x | TIE | TIE |
| decode 256 tok @ 4K ctx | tok/s | 70.72 | 47.75 | 30.69 | 1.48x | 2.30x | WIN | WIN |
| cold 16K prefill | tok/s | 951.8 | 961.1 | 970.8 | 0.99x | 0.98x | TIE | TIE |
| cold 16K TTFT | s | 17.23 | 17.06 | 16.89 | 1.01x | 1.02x | TIE | TIE |
| decode 256 tok @ 16K ctx | tok/s | 64.9 | 43.69 | 28.88 | 1.49x | 2.25x | WIN | WIN |
| cold 32K prefill | tok/s | 862 | 895.3 | 904.2 | 0.96x | 0.95x | LOSS | LOSS |
| cold 32K TTFT | s | 38.04 | 36.61 | 36.25 | 1.04x | 1.05x | LOSS | LOSS |
| decode 128 tok @ 32K ctx | tok/s | 57.8 | 38.58 | 27.5 | 1.50x | 2.10x | WIN | WIN |
| c=4 512-tok prompts aggregate | tok/s | 65.19 | 68.61 | 64.96 | 0.95x | 1.00x | LOSS | TIE |
| c=4 512-tok prompts p50 TTFT | s | 1.517 | 2.381 | 2.352 | 0.64x | 0.65x | WIN | WIN |
| c=4 512-tok prompts p95 TTFT | s | 2.326 | 2.381 | 2.352 | 0.98x | 0.99x | WIN | TIE |
| c=8 512-tok prompts aggregate | tok/s | 75.1 | 68.39 | 73.11 | 1.10x | 1.03x | WIN | WIN |
| c=8 512-tok prompts p50 TTFT | s | 2.723 | 6.097 | 4.419 | 0.45x | 0.62x | WIN | WIN |
| c=8 512-tok prompts p95 TTFT | s | 4.717 | 9.838 | 4.42 | 0.48x | 1.07x | WIN | LOSS |
| c=4 agent prompts (~2.8K tok) aggregate | tok/s | 28.02 | 26.73 | 27.87 | 1.05x | 1.01x | WIN | TIE |
| c=4 agent prompts p50 TTFT | s | 7.979 | 13.81 | 12.64 | 0.58x | 0.63x | WIN | WIN |
| c=4 agent prompts p95 TTFT | s | 12.44 | 13.81 | 12.64 | 0.90x | 0.98x | WIN | TIE |
| c=8 agent prompts aggregate | tok/s | 28.94 | 26.95 | 30.78 | 1.07x | 0.94x | WIN | LOSS |
| c=8 agent prompts p50 TTFT | s | 13.53 | 23.14 | 23.41 | 0.58x | 0.58x | WIN | WIN |
| c=8 agent prompts p95 TTFT | s | 24.52 | 32.58 | 23.41 | 0.75x | 1.05x | WIN | LOSS |
| c=4 4K prompts aggregate (prefill-bound) | tok/s | 12.99 | 12.95 | 13.2 | 1.00x | 0.98x | TIE | TIE |
| c=4 4K prompts p50 TTFT | s | 10.53 | 17.14 | 16.5 | 0.61x | 0.64x | WIN | WIN |
| c=4 4K prompts p95 TTFT | s | 16.26 | 17.14 | 16.5 | 0.95x | 0.99x | WIN | TIE |
| c=8 4K prompts aggregate (prefill-bound) | tok/s | 12.95 | 12.85 | 13.58 | 1.01x | 0.95x | TIE | LOSS |
| c=8 4K prompts p50 TTFT | s | 19.1 | 27.23 | 32.65 | 0.70x | 0.59x | WIN | WIN |
| c=8 4K prompts p95 TTFT | s | 32.93 | 37.18 | 32.65 | 0.89x | 1.01x | WIN | TIE |
| W5 4 clients, 16K shared prefix aggregate | tok/s | 9.553 | 3.27 | 3.45 | 2.92x | 2.77x | WIN | WIN |
| W5 p50 TTFT | s | 20.71 | 75.08 | 70.93 | 0.28x | 0.29x | WIN | WIN |
| W5 p95 TTFT | s | 23.33 | 75.08 | 70.93 | 0.31x | 0.33x | WIN | WIN |
| agent replay prefill sum T1-T8 | s | 52.77 | 50.24 | 194.9 | 1.05x | 0.27x | LOSS | WIN |
| agent replay prefill sum T1-T6 | s | 35.24 | 35.49 | 108.6 | 0.99x | 0.32x | TIE | WIN |
| agent replay T8 cached fraction | frac | 0.8725 | 0.8723 | 0 | 1.00x | n/a | TIE | n/a |

## Peak memory per cell (MB; max over passes and sessions; footprint = phys_footprint of the engine process tree, includes Metal buffers)

| cell | strim footprint / RSS | rapid-mlx footprint / RSS | mlx-vlm footprint / RSS |
|---|---|---|---|
| warmup | 18457 / 8695 | 20334 / 15598 | 19469 / 16244 |
| agree | 17983 / 8702 | 17194 / 15586 | 16284 / 16265 |
| w3 | 23512 / 8704 | 24218 / 15595 | 20512 / 16278 |
| w3_32k | 28571 / 8705 | 26970 / 15613 | 22831 / 16296 |
| w4 | 30397 / 8706 | 30611 / 15604 | 37982 / 16243 |
| w4s | 26011 / 8408 | 22046 / 15610 | 22424 / 16067 |
| w6 | 28786 / 8421 | 28640 / 15614 | 31137 / 16104 |
| w5 | 27987 / 8702 | 35419 / 15609 | 30474 / 16276 |
| replay | 28072 / 8706 | 29624 / 15215 | 28100 / 16297 |
| **whole run** | **30397 / 8706** | **35419 / 15614** | **37982 / 16297** |

## Run conditions

- strim pass1: 3 sessions; first load { 3.27 4.81 4.96 }; swap used at start 4856.31M; swap growth max 0 MB; watchdog aborts: none
- strim pass2: 3 sessions; first load { 5.68 5.83 5.76 }; swap used at start 4800.81M; swap growth max 680 MB; watchdog aborts: none
- rapid-mlx pass1: 3 sessions; first load { 4.28 4.45 4.72 }; swap used at start 4840.31M; swap growth max 0 MB; watchdog aborts: none
- rapid-mlx pass2: 3 sessions; first load { 6.29 5.38 5.58 }; swap used at start 4808.81M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass1: 3 sessions; first load { 8.52 5.89 5.14 }; swap used at start 4824.31M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass2: 3 sessions; first load { 10.70 7.96 6.52 }; swap used at start 4808.81M; swap growth max 0 MB; watchdog aborts: none

## Greedy agreement (sanity only; 8 fixed prompts, 64 tokens, near-ties diverge)

- strim pass1 vs pass2 (self): 8/8 identical; mean common-prefix fraction 1
- strim vs rapid-mlx (pass1): 7/8 identical; mean common-prefix fraction 0.91; (pass2): 7/8 identical; mean common-prefix fraction 0.91
- strim vs mlx-vlm (pass1): 6/8 identical; mean common-prefix fraction 0.79; (pass2): 6/8 identical; mean common-prefix fraction 0.79
- rapid-mlx vs mlx-vlm (pass1): 7/8 identical; mean common-prefix fraction 0.88

## Agent replay detail (8 turns; median over passes)

| turn | prompt tok | strim TTFT s | strim cached tok | rapid-mlx TTFT s | rapid-mlx cached tok | mlx-vlm TTFT s | mlx-vlm cached tok |
|---|---|---|---|---|---|---|---|
| 1 | 4090 | 4.16 | 0 | 4.18 | n/a | 4.03 | 0 |
| 2 | 9345 | 5.59 | 4083 | 5.65 | 4064 | 9.34 | 0 |
| 3 | 14626 | 5.93 | 9338 | 5.98 | 9333 | 14.84 | 0 |
| 4 | 19883 | 6.21 | 14619 | 6.19 | 14613 | 20.62 | 0 |
| 5 | 25155 | 6.56 | 19876 | 6.64 | 19861 | 26.79 | 0 |
| 6 | 30377 | 6.80 | 25148 | 6.85 | 25141 | 33.02 | 0 |
| 7 | 35636 | 7.32 | 30370 | 7.33 | 30357 | 39.84 | 0 |
| 8 | 40837 | 10.21 | 35629 | 7.42 | 35624 | 46.46 | 0 |

## Pass-to-pass noise (|pass1-pass2| / mean, percent, over all cells above; TIE band is 2%)

| engine | cells | median spread | p90 spread | max spread (cell) |
|---|---|---|---|---|
| strim | 33 | 1.7% | 9.3% | 12.8% (c) |
| rapid-mlx | 33 | 0.5% | 1.5% | 7.9% (decode 256 tok @ 4K ctx) |
| mlx-vlm | 31 | 1.1% | 2.4% | 10.2% (decode 256 tok @ 16K ctx) |

## Caveats

- All six sessions POLLUTED by non-engine CPU load (see table); numbers are indicative, not publishable as the final head-to-head. Do not average these with a rerun; publish the clean rerun and keep this one as the polluted record.
- 2 passes, 1 rep per pass; medians of two values are means.
- rapid-mlx used MTP and max-num-seqs 4; mlx-vlm had no MTP and no prefix cache. TTFT definitions differ in practice (rival batch-synchronous TTFT), so rival p50 equals p95; aggregate tok/s is the only fully comparable concurrency number.
- Greedy agreement is a sanity check only (Strim self 8/8; vs rapid-mlx 7/8; vs mlx-vlm 6/8; unchanged from the previous run).
- Single model, single machine, thinking off, synthetic agent prompts and 8-turn fixture.
