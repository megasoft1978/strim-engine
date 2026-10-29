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
