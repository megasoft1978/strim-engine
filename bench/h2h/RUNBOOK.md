# Head-to-head, 5 engines: runbook for the clean window

Engines: Strim (MTP), rapid-mlx 0.15.7 (MTP), mlx-vlm 0.7.10, mlx-lm (installed in .venv-sprint: 0.32.2; the brief said 0.31.2, the table records what is measured),
oMLX 0.4.5.dev1 (/Applications/oMLX.app, `omlx` in /opt/homebrew/bin). Same weights for all MLX engines: `models/qwen38-4bit` (+ `models/qwen38-mtp-4bit` for Strim and rapid-mlx).
Launch lines, capabilities, ports and timeouts live in `engines.sh`; the summary prints the same table (`## Engines`). No GPU work was run while preparing this.

## 0. Validate the tooling first (no GPU, ~4 min, can run any time)

```
H2H_DRYRUN=1 bench/h2h/run.sh /tmp/h2h-dry 1,2          # 5 engines x 2 passes x 3 groups against stub servers, 30 sessions
H2H_JSON=/tmp/h2h-dry/results.json bench/h2h/summarize.sh /tmp/h2h-dry > /tmp/h2h-dry/summary.md
```
Dry-run knobs (test only): `H2H_FAKE_LOAD_FILE=<file with a number>` replaces the load reading, `H2H_NO_FOREIGN=1` hides foreign-CPU processes,
`H2H_STUB_GUARD_ENGINE=omlx` (oMLX-style hard memory abort in W5), `H2H_STUB_HANG_ENGINE=<e>` (+ `H2H_CELL_TIMEOUT_<E>=5`), `H2H_STUB_ORPHAN_ENGINE=<e>`,
`H2H_MAX_FOOTPRINT_MB=1` (watchdog abort). The stub (`stub/stub.swift`, compiled with swiftc into `$H2H_SCRATCH`, default /private/tmp/h2h-scratch) is not part of the product.

## 1. Preflight checklist (all must hold; write the output into `<OUT>/preflight.txt`)

1. Power and thermals: on AC (`pmset -g batt` says AC Power), Low Power Mode off (`pmset -g | grep lowpowermode` = 0), `pmset -g therm` shows no CPU/GPU speed limit or "Thermal warning level" other than none, machine idle for 5 min after any previous GPU job (fans down).
2. Display and sleep: run everything under `caffeinate -dimsu` (below). Do not lock the screen, no screensaver, no external display hot-plug.
3. Quiet machine: quit browsers, IDEs, Docker, RustDesk/Mica/Stats-type background apps, Python/Java jobs, other agents. Check:
   `ps -Ao %cpu,pid,command -r | head -12` (nothing above ~5% sustained), `sysctl -n vm.loadavg` (target 1-min load < 3; the run gate itself waits for < 4.5).
   **Quit oMLX.app (menu-bar app) and any `omlx serve`/`omlx-cli`**: pass.sh refuses to start the oMLX arm while one is running (`omlx_already_running`).
   No other GPU job: `lsof /tmp/strim-bench.lock` empty; all runs go through `lockf /tmp/strim-bench.lock`.
4. Spotlight: `mdutil -s /` (the baseline `mds` load was 3.5-4.2 in earlier runs and is why the gate threshold is 4.5). Turning it off needs root: `sudo mdutil -i off /` before and `sudo mdutil -i on /` after.
   Do it only if the user is present and allows sudo; otherwise leave it on and note "Spotlight indexing on" in the summary. Never run it from an unattended agent.
5. Swap: `sysctl vm.swapusage` used < ~6 GB and not growing (the watchdog aborts a cell at +2 GB growth). Free disk > 50 GB (oMLX SSD cache goes to the scratch HOME).
6. Models and binaries: `ls models/qwen38-4bit models/qwen38-mtp-4bit`; `.venv-sprint/bin/mlx_lm.server`, `.venv-sprint/bin/mlx_vlm.server`, `rapid-mlx --version` = 0.15.7, `omlx --version` = 0.4.5.dev1.
   Strim: build the exact commit to test into a dedicated dir and record it: `git rev-parse HEAD`; `swift build -c release --scratch-path /tmp/strim-build-final4`; `STRIM_BIN=/tmp/strim-build-final4/release/strim`.
7. Ports free: 8203 (strim), 8651 (rapid-mlx, mlx-vlm), 8653 (omlx), 8654 (mlx-lm): `lsof -nP -iTCP:8203,8651,8653,8654 -sTCP:LISTEN` empty.
8. Tooling check: `H2H_DRYRUN=1` run from section 0 passes (all `rc=0`, results.json written).
9. Cooldown: 60 s idle between engine sessions (run.sh does this; `H2H_COOLDOWN`).

## 2. Run (foreground shell, Metal needs a foreground session)

```
OUT=bench/results/h2h-final4-$(date +%Y%m%d)
mkdir -p $OUT && { date; pmset -g batt; pmset -g therm; sysctl vm.swapusage vm.loadavg; mdutil -s /; ps -Ao %cpu,pid,command -r | head -12; } > $OUT/preflight.txt 2>&1
STRIM_BIN=/tmp/strim-build-final4/release/strim caffeinate -dimsu bench/h2h/run.sh $OUT 1,2 strim,rapid-mlx,mlx-vlm,mlx-lm,omlx g1,g2,g3 2>&1 | tee $OUT/run.log
H2H_JSON=$OUT/results.json bench/h2h/summarize.sh $OUT > $OUT/summary.md
```
W6 prompts are pinned to revision 2df65e7 (`H2H_PROMPTS_REV`), replay fixture is `bench/results/final-20261026/synthetic-8turn.json`; both unchanged from the 3-engine run.

### ABBA order (position balanced; run.sh reverses the list on even passes)

| pass | order |
|---|---|
| 1 | strim, rapid-mlx, mlx-vlm, mlx-lm, omlx |
| 2 | omlx, mlx-lm, mlx-vlm, rapid-mlx, strim |

Each engine runs its three groups back to back (g1 = agree,w3,w3_32k; g2 = w4,w4s,w6; g3 = w5,replay), each group a short fresh engine process (fresh caches; oMLX gets a fresh scratch HOME and SSD cache every session).

### Wall time

- Cells: about 7 min per engine and pass in the 3-engine run; oMLX and mlx-lm are likely a bit slower (guard abort and restart add 1-2 min): 5 x 2 x 7 = 70 min, 75-80 min with the slower arms.
- Cooldown 9 x 60 s = 9 min. Quiet gate (4 x 30 s before the first group of an engine session, 2 x 30 s before the others) = 10 x 90 s + 20 x 30 s = 25 min if the machine is quiet at once; more if the gate has to wait (cap 15 min per session, then the session is flagged POLLUTED).
- Plan for about 110 min wall with a quiet machine, plus about 10 min per rerun session.

## 3. Validity rules

- Per session (one engine, one pass, one group) `sessions.jsonl` gets one record with `status`:
  - CLEAN: gate passed, no 2 consecutive samples with 1-min load > 4.5 (`H2H_POLLUTE_LOAD`) or a foreign process > 60% CPU (samples every 30 s plus one at every cell start and end, in `load.csv`).
  - POLLUTED: the pollution rule fired for any cell, or the gate timed out (`gate.txt`). Rerun that session once (`bench/h2h/pass.sh ENGINE PASS CELLS OUT` under `lockf /tmp/strim-bench.lock`, same arguments, after the machine is quiet again); the later record supersedes the earlier one in summarize.sh. If the rerun is POLLUTED too, the cell stays unverified.
  - INVALID: engine did not start, port busy, oMLX already running, warm-up failed, unkillable leftover process, too many restarts. Fix the cause, rerun once.
- Flagged cells (not a pollution matter, never retried silently): `memory_abort_watchdog` (footprint > 42 GB or swap +2 GB), `engine_guard_abort` (oMLX "Hard memory pressure", expected in W5 as in the 2026-10-26 run), `engine_oom`, `cell_timeout` (per-engine, `CELL_TIMEOUT` 900 s, oMLX 1200 s). The cell is n/a for that engine and pass, the engine is restarted and re-warmed before the next cell, raw output stays. Do not rerun a flagged cell to "fix" it; report it.
- After every session check `leftover_process` / `leftover_suspect` flags and `ps -Ao pid,ppid,command | grep -i -E "omlx|mlx_lm|mlx_vlm|rapid|strim serve"` is empty before the next engine (oMLX spawns helpers; the watchdog records every pid in the tree, `watch.csv` column 6 = tree size).
- `footprint_blind` flag: memory numbers for that session are not trusted.

## 4. Claim policy

- Claims (WIN/LOSS in any text, site or README) only from cells whose sessions are all CLEAN for both engines: `results.json` `cells[].claim_eligible.<engine> == true` for the rival and for strim. Everything else is reported as "unverified" with the reason.
- TIE = ratio within 2% (`H2H_TIE_PCT`); the pass-to-pass noise table must show the engine's own spread below the claimed margin.
- oMLX W5 (and any flagged cell) is stated as n/a with the flag, never as a loss by default.
- Versions as measured (`## Engines` table) go next to every number; no MTP for mlx-vlm, mlx-lm and oMLX is stated, since the decode lead is MTP plus kernels together.
- `H2H_ONLY_CLEAN=1 summarize.sh` produces the publishable summary (non-CLEAN cells dropped); the plain run keeps them for diagnosis.
