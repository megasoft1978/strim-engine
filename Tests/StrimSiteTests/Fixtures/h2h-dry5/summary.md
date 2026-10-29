## Results (ratio = strim / rival; lower-is-better cells (TTFT, time) win with ratio < 1; tie = within 2%)

| cell | unit | strim | rapid-mlx | mlx-vlm | mlx-lm | omlx | strim/rapid-mlx | strim/mlx-vlm | strim/mlx-lm | strim/omlx | vs rapid-mlx | vs mlx-vlm | vs mlx-lm | vs omlx |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| cold 4K prefill | tok/s | 1.18e+05 | 1.086e+05 | 1.364e+05 | 3.935e+05 | 1.342e+05 | 1.09x | 0.87x | 0.30x | 0.88x | WIN | LOSS | LOSS | LOSS |
| cold 4K TTFT | s | 0.04036 | 0.04426 | 0.03591 | 0.0236 | 0.03601 | 0.91x | 1.12x | 1.71x | 1.12x | WIN | LOSS | LOSS | LOSS |
| decode 256 tok @ 4K ctx | tok/s | 1962 | 1299 | 987.7 | 986.8 | 926.7 | 1.51x | 1.99x | 1.99x | 2.12x | WIN | WIN | WIN | WIN |
| cold 16K prefill | tok/s | 1.797e+05 | 1.912e+05 | 1.776e+05 | 1.841e+05 | 4.695e+04 | 0.94x | 1.01x | 0.98x | 3.83x | LOSS | TIE | LOSS | WIN |
| cold 16K TTFT | s | 0.1064 | 0.1001 | 0.1077 | 0.1041 | 0.4075 | 1.06x | 0.99x | 1.02x | 0.26x | LOSS | TIE | LOSS | WIN |
| decode 256 tok @ 16K ctx | tok/s | 1971 | 1311 | 993.2 | 1006 | 925.5 | 1.50x | 1.98x | 1.96x | 2.13x | WIN | WIN | WIN | WIN |
| cold 32K prefill | tok/s | 1.893e+05 | 1.779e+05 | 1.839e+05 | 1.844e+05 | 7.384e+04 | 1.06x | 1.03x | 1.03x | 2.56x | WIN | WIN | WIN | WIN |
| cold 32K TTFT | s | 0.2023 | 0.2155 | 0.2082 | 0.2077 | 0.5187 | 0.94x | 0.97x | 0.97x | 0.39x | WIN | WIN | WIN | WIN |
| decode 128 tok @ 32K ctx | tok/s | 1972 | 1247 | 1005 | 990.9 | 932.7 | 1.58x | 1.96x | 1.99x | 2.11x | WIN | WIN | WIN | WIN |
| c=4 512-tok prompts aggregate | tok/s | 6971 | 5033 | 3610 | 3687 | 3396 | 1.39x | 1.93x | 1.89x | 2.05x | WIN | WIN | WIN | WIN |
| c=4 512-tok prompts p50 TTFT | s | 0.007846 | 0.01209 | 0.01182 | 0.009793 | 0.01249 | 0.65x | 0.66x | 0.80x | 0.63x | WIN | WIN | WIN | WIN |
| c=4 512-tok prompts p95 TTFT | s | 0.007856 | 0.0121 | 0.01183 | 0.009807 | 0.01252 | 0.65x | 0.66x | 0.80x | 0.63x | WIN | WIN | WIN | WIN |
| c=8 512-tok prompts aggregate | tok/s | 1.526e+04 | 1.031e+04 | 7496 | 7675 | 7082 | 1.48x | 2.04x | 1.99x | 2.15x | WIN | WIN | WIN | WIN |
| c=8 512-tok prompts p50 TTFT | s | 0.002677 | 0.008988 | 0.006746 | 0.00477 | 0.00697 | 0.30x | 0.40x | 0.56x | 0.38x | WIN | WIN | WIN | WIN |
| c=8 512-tok prompts p95 TTFT | s | 0.002747 | 0.009098 | 0.006835 | 0.004824 | 0.007031 | 0.30x | 0.40x | 0.57x | 0.39x | WIN | WIN | WIN | WIN |
| c=4 agent prompts (~2.8K tok) aggregate | tok/s | 5526 | 4421 | 3221 | 3282 | 3045 | 1.25x | 1.72x | 1.68x | 1.81x | WIN | WIN | WIN | WIN |
| c=4 agent prompts p50 TTFT | s | 0.02396 | 0.02668 | 0.02593 | 0.02624 | 0.02926 | 0.90x | 0.92x | 0.91x | 0.82x | WIN | WIN | WIN | WIN |
| c=4 agent prompts p95 TTFT | s | 0.02715 | 0.02711 | 0.03029 | 0.02694 | 0.0293 | 1.00x | 0.90x | 1.01x | 0.93x | TIE | WIN | TIE | WIN |
| c=8 agent prompts aggregate | tok/s | 1.168e+04 | 9312 | 6789 | 6738 | 6304 | 1.25x | 1.72x | 1.73x | 1.85x | WIN | WIN | WIN | WIN |
| c=8 agent prompts p50 TTFT | s | 0.0203 | 0.01755 | 0.01984 | 0.02129 | 0.02083 | 1.16x | 1.02x | 0.95x | 0.97x | LOSS | LOSS | WIN | WIN |
| c=8 agent prompts p95 TTFT | s | 0.02192 | 0.02068 | 0.02229 | 0.0239 | 0.0233 | 1.06x | 0.98x | 0.92x | 0.94x | LOSS | TIE | WIN | WIN |
| c=4 4K prompts aggregate (prefill-bound) | tok/s | 3506 | 2957 | 2475 | 2505 | 2299 | 1.19x | 1.42x | 1.40x | 1.53x | WIN | WIN | WIN | WIN |
| c=4 4K prompts p50 TTFT | s | 0.03926 | 0.04178 | 0.03755 | 0.03732 | 0.04167 | 0.94x | 1.05x | 1.05x | 0.94x | WIN | LOSS | LOSS | WIN |
| c=4 4K prompts p95 TTFT | s | 0.04066 | 0.04179 | 0.03894 | 0.03807 | 0.04168 | 0.97x | 1.04x | 1.07x | 0.98x | WIN | LOSS | LOSS | WIN |
| c=8 4K prompts aggregate (prefill-bound) | tok/s | 7784 | 6452 | 5095 | 5171 | 4868 | 1.21x | 1.53x | 1.51x | 1.60x | WIN | WIN | WIN | WIN |
| c=8 4K prompts p50 TTFT | s | 0.03209 | 0.03413 | 0.03439 | 0.0334 | 0.03568 | 0.94x | 0.93x | 0.96x | 0.90x | WIN | WIN | WIN | WIN |
| c=8 4K prompts p95 TTFT | s | 0.03287 | 0.03477 | 0.03509 | 0.03426 | 0.03592 | 0.95x | 0.94x | 0.96x | 0.92x | WIN | WIN | WIN | WIN |
| W5 4 clients, 16K shared prefix aggregate | tok/s | 1767 | 1629 | 1431 | 1411 | n/a | 1.08x | 1.23x | 1.25x | n/a | WIN | WIN | WIN | n/a |
| W5 p50 TTFT | s | 0.01341 | 0.1112 | 0.1125 | 0.01447 | n/a | 0.12x | 0.12x | 0.93x | n/a | WIN | WIN | WIN | n/a |
| W5 p95 TTFT | s | 0.09745 | 0.1129 | 0.1139 | 0.1015 | n/a | 0.86x | 0.86x | 0.96x | n/a | WIN | WIN | WIN | n/a |
| agent replay prefill sum T1-T8 | s | 0.2131 | 0.7304 | 0.7392 | 0.2377 | 1.777 | 0.29x | 0.29x | 0.90x | 0.12x | WIN | WIN | WIN | WIN |
| agent replay prefill sum T1-T6 | s | 0.1555 | 0.4366 | 0.4409 | 0.1826 | 1.101 | 0.36x | 0.35x | 0.85x | 0.14x | WIN | WIN | WIN | WIN |
| agent replay T8 cached fraction | frac | 0.8655 | n/a | n/a | 0.8655 | 0.8655 | n/a | n/a | 1.00x | 1.00x | n/a | n/a | TIE | TIE |

## Peak memory per cell (MB; max over passes and sessions; footprint = phys_footprint of the engine process tree, includes Metal buffers)

| cell | strim footprint / RSS | rapid-mlx footprint / RSS | mlx-vlm footprint / RSS | mlx-lm footprint / RSS | omlx footprint / RSS |
|---|---|---|---|---|---|
| warmup | 2 / 6 | 2 / 6 | 2 / 6 | 2 / 6 | 3 / 7 |
| agree | n/a | n/a | n/a | n/a | n/a |
| w3 | 2 / 6 | 2 / 7 | 2 / 6 | 2 / 6 | 4 / 8 |
| w3_32k | 2 / 6 | 2 / 6 | 2 / 6 | 2 / 6 | 5 / 9 |
| w4 | 2 / 6 | 2 / 6 | 2 / 6 | 2 / 6 | 3 / 7 |
| w4s | n/a | n/a | 3 / 7 | 3 / 7 | 5 / 9 |
| w6 | 3 / 7 | 3 / 7 | n/a | n/a | n/a |
| w5 | 3 / 7 | 2 / 6 | 2 / 6 | 2 / 7 | 3 / 7 |
| replay | n/a | 4 / 8 | 4 / 8 | n/a | 5 / 9 |
| **whole run** | **3 / 7** | **4 / 8** | **4 / 8** | **3 / 7** | **5 / 9** |

## Engines: capabilities and exact launch (engines.sh is the single source; versions are those measured in this run)

| engine | version (measured) | MTP / speculative | prefix cache | cache hits visible via | own memory guard | flags (cwd = repo root) |
|---|---|---|---|---|---|---|
| strim | strim dry-run stub | yes (qwen38-mtp-4bit head) | yes, default (STRIM_PREFIX_CACHE_MB 12288) | usage.prompt_tokens_details.cached_tokens | none (admission control, max_inflight 8) | `serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth` |
| rapid-mlx | rapid-mlx dry-run stub | yes (--speculative-config mtp, qwen38-mtp-4bit) | yes, default on | not reported in usage (unknown) | none | `--no-telemetry serve models/qwen38-4bit --port 8651 --max-num-seqs 4 --speculative-config {mtp,qwen38-mtp-4bit}` |
| mlx-vlm | mlx-vlm dry-run stub | no | no cross-request reuse (0% cached in replay) | none | none | `--model models/qwen38-4bit --port 8651 (server defaults)` |
| mlx-lm | mlx-lm dry-run stub | no (no speculative decoding) | yes, default in-memory LRU prompt cache | usage.prompt_tokens_details.cached_tokens; server log 'Prompt Cache: N sequences, X GB' | none | `--model models/qwen38-4bit --port 8654 --decode-concurrency 4 --prompt-concurrency 4` |
| omlx | omlx dry-run stub | no (MTP needs oMLX's own checkpoint; stock weights have no MTP head) | yes, default paged SSD prefix cache under the scratch HOME (fresh per session, so no cross-session hits) | usage.prompt_tokens_details.cached_tokens (reported after warm-up; first rows can be unknown) | process memory enforcer (tier balanced, ceiling ~54-56 GB): aborts requests and unloads the model | `serve --model-dir <scratch>/models (symlink to models/qwen38-4bit) --port 8653, HOME=<scratch>/home, defaults otherwise (memory-guard balanced, max-concurrent-requests 8)` |

## Session validity (latest session per engine, pass and cell group; CLEAN = no 2-sample pollution, gate passed; claims only from CLEAN)

| engine | pass | cells | status | gate | polluted cells | flags |
|---|---|---|---|---|---|---|
| strim | 1 | agree,w3,w3_32k | CLEAN | OFF |  | shutdown:leftover_suspect |
| strim | 1 | w4,w4s,w6 | CLEAN | OFF |  | shutdown:leftover_process |
| strim | 1 | w5,replay | CLEAN | OFF |  |  |
| strim | 2 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| strim | 2 | w4,w4s,w6 | CLEAN | OFF |  |  |
| strim | 2 | w5,replay | CLEAN | OFF |  |  |
| rapid-mlx | 1 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| rapid-mlx | 1 | w4,w4s,w6 | CLEAN | OFF |  |  |
| rapid-mlx | 1 | w5,replay | CLEAN | OFF |  |  |
| rapid-mlx | 2 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| rapid-mlx | 2 | w4,w4s,w6 | CLEAN | OFF |  |  |
| rapid-mlx | 2 | w5,replay | CLEAN | OFF |  |  |
| mlx-vlm | 1 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| mlx-vlm | 1 | w4,w4s,w6 | CLEAN | OFF |  |  |
| mlx-vlm | 1 | w5,replay | CLEAN | OFF |  |  |
| mlx-vlm | 2 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| mlx-vlm | 2 | w4,w4s,w6 | CLEAN | OFF |  |  |
| mlx-vlm | 2 | w5,replay | CLEAN | OFF |  |  |
| mlx-lm | 1 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| mlx-lm | 1 | w4,w4s,w6 | CLEAN | OFF |  |  |
| mlx-lm | 1 | w5,replay | CLEAN | OFF |  |  |
| mlx-lm | 2 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| mlx-lm | 2 | w4,w4s,w6 | CLEAN | OFF |  |  |
| mlx-lm | 2 | w5,replay | CLEAN | OFF |  |  |
| omlx | 1 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| omlx | 1 | w4,w4s,w6 | CLEAN | OFF |  |  |
| omlx | 1 | w5,replay | CLEAN | OFF |  | w5:engine_guard_abort restart:engine_restart |
| omlx | 2 | agree,w3,w3_32k | CLEAN | OFF |  |  |
| omlx | 2 | w4,w4s,w6 | CLEAN | OFF |  |  |
| omlx | 2 | w5,replay | CLEAN | OFF |  | w5:engine_guard_abort restart:engine_restart |

## Flagged cells (never retried silently; n/a in the tables above when an abort, guard, OOM or timeout flag)

- strim pass1 shutdown: leftover_suspect pid 72194 /bin/zsh -c source /Users/user/.claude-work/shell-snapshots/snapshot-zsh-17930168498
- strim pass1 shutdown: leftover_process 73256 
- omlx pass1 w5: engine_guard_abort stub - omlx.process_memory_enforcer - WARNING - Hard memory pressure: requested abort/unload (usage 54.5 GB; ceiling 56.0 GB)
- omlx pass1 restart: engine_restart restart_after_flagged_cell
- omlx pass2 w5: engine_guard_abort stub - omlx.process_memory_enforcer - WARNING - Hard memory pressure: requested abort/unload (usage 54.5 GB; ceiling 56.0 GB)
- omlx pass2 restart: engine_restart restart_after_flagged_cell

## Cache-hit reporting (usage-reported cached tokens, per engine; rows without a value = engine did not report)

| engine | cell | rows | rows with a hit | cached tokens | unreported rows |
|---|---|---|---|---|---|
| strim | w5 | 8 | 6 | 113664 | 0 |
| strim | replay | 16 | 14 | 199680 | 0 |
| rapid-mlx | w5 | 8 | 0 | 0 | 8 |
| rapid-mlx | replay | 16 | 0 | 0 | 16 |
| mlx-vlm | w5 | 8 | 0 | 0 | 8 |
| mlx-vlm | replay | 16 | 0 | 0 | 16 |
| mlx-lm | w5 | 8 | 6 | 113664 | 0 |
| mlx-lm | replay | 16 | 14 | 199680 | 0 |
| omlx | w5 | 8 | 0 | 0 | 8 |
| omlx | replay | 16 | 14 | 199680 | 0 |

## Run conditions

- strim pass1: 3 sessions; first load { 3.73 5.35 6.81 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none
- strim pass2: 3 sessions; first load { 4.35 4.84 6.35 }; swap used at start 2971.38M; swap growth max 0 MB; watchdog aborts: none
- rapid-mlx pass1: 3 sessions; first load { 3.81 5.27 6.75 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none
- rapid-mlx pass2: 3 sessions; first load { 3.70 4.75 6.34 }; swap used at start 2971.38M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass1: 3 sessions; first load { 3.54 5.14 6.67 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none
- mlx-vlm pass2: 3 sessions; first load { 4.27 4.91 6.43 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none
- mlx-lm pass1: 3 sessions; first load { 3.69 5.10 6.63 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none
- mlx-lm pass2: 3 sessions; first load { 3.90 4.89 6.45 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none
- omlx pass1: 3 sessions; first load { 3.46 4.98 6.56 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none
- omlx pass2: 3 sessions; first load { 3.38 4.86 6.48 }; swap used at start 2979.38M; swap growth max 0 MB; watchdog aborts: none

## Greedy agreement (sanity only; 8 fixed prompts, 64 tokens, near-ties diverge)

- strim pass1 vs pass2 (self): 8/8 identical; mean common-prefix fraction 1
- strim vs rapid-mlx (pass1): 8/8 identical; mean common-prefix fraction 1; (pass2): 8/8 identical; mean common-prefix fraction 1
- strim vs mlx-vlm (pass1): 8/8 identical; mean common-prefix fraction 1; (pass2): 8/8 identical; mean common-prefix fraction 1
- strim vs mlx-lm (pass1): 8/8 identical; mean common-prefix fraction 1; (pass2): 8/8 identical; mean common-prefix fraction 1
- strim vs omlx (pass1): 8/8 identical; mean common-prefix fraction 1; (pass2): 8/8 identical; mean common-prefix fraction 1
- rapid-mlx vs mlx-vlm (pass1): 8/8 identical; mean common-prefix fraction 1
- rapid-mlx vs mlx-lm (pass1): 8/8 identical; mean common-prefix fraction 1
- rapid-mlx vs omlx (pass1): 8/8 identical; mean common-prefix fraction 1
- mlx-vlm vs mlx-lm (pass1): 8/8 identical; mean common-prefix fraction 1
- mlx-vlm vs omlx (pass1): 8/8 identical; mean common-prefix fraction 1
- mlx-lm vs omlx (pass1): 8/8 identical; mean common-prefix fraction 1

## Agent replay detail (8 turns; median over passes)

| turn | prompt tok | strim TTFT s | strim cached tok | rapid-mlx TTFT s | rapid-mlx cached tok | mlx-vlm TTFT s | mlx-vlm cached tok | mlx-lm TTFT s | mlx-lm cached tok | omlx TTFT s | omlx cached tok |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 3008 | 0.03 | 0 | 0.03 | n/a | 0.03 | n/a | 0.03 | 0 | 0.03 | 0 |
| 2 | 6804 | 0.03 | 2816 | 0.04 | n/a | 0.04 | n/a | 0.03 | 2816 | 0.03 | 2816 |
| 3 | 10599 | 0.02 | 6656 | 0.06 | n/a | 0.06 | n/a | 0.03 | 6656 | 0.03 | 6656 |
| 4 | 14394 | 0.02 | 10496 | 0.08 | n/a | 0.08 | n/a | 0.03 | 10496 | 0.34 | 10496 |
| 5 | 18189 | 0.03 | 14336 | 0.10 | n/a | 0.10 | n/a | 0.03 | 14336 | 0.34 | 14336 |
| 6 | 21984 | 0.03 | 18176 | 0.12 | n/a | 0.12 | n/a | 0.03 | 18176 | 0.34 | 18176 |
| 7 | 25782 | 0.03 | 21760 | 0.14 | n/a | 0.14 | n/a | 0.03 | 21760 | 0.33 | 21760 |
| 8 | 29578 | 0.03 | 25600 | 0.16 | n/a | 0.16 | n/a | 0.03 | 25600 | 0.34 | 25600 |

## Pass-to-pass noise (|pass1-pass2| / mean, percent, over all cells above; TIE band is 2%)

| engine | cells | median spread | p90 spread | max spread (cell) |
|---|---|---|---|---|
| strim | 33 | 3.0% | 8.9% | 14.1% () |
| rapid-mlx | 32 | 5.0% | 18.8% | 45.7% (c) |
| mlx-vlm | 32 | 1.9% | 8.3% | 33.1% (cold 4K TTFT) |
| mlx-lm | 33 | 3.2% | 38.4% | 139.6% (cold 4K prefill) |
| omlx | 30 | 0.8% | 7.6% | 24.0% (cold 4K TTFT) |
