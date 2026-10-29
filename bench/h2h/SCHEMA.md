# results.json schema (bench/h2h/summarize.sh, `H2H_JSON=<file>`)

Version 2 is a strict superset of the version used by `bench/results/h2h-final-20261028` and `h2h-final2-20261028` (those files keep
working unchanged; summarize.sh re-run on them reproduces every old key byte for byte and only adds the new ones). Nothing is renamed.

## Existing keys (unchanged)

```
tie_pct: 2
engines: ["strim", "rapid-mlx", "mlx-vlm", "mlx-lm", "omlx"]      # engines[0] is the reference (Strim); any number >= 2, any names
cells: [ {
  id, cell (label), unit, better: "higher"|"lower",
  median:     { <engine>: number|null },                             # median over passes of the per-pass value; null = n/a
  per_pass:   { <engine>: [number, ...] },                           # only passes that produced a valid value (flagged passes are left out)
  vs_rivals:  { <rival engine>: { ratio_strim_over_rival: number|null, verdict: "WIN"|"TIE"|"LOSS"|"n/a" } }   # every engine except engines[0]
} ]
```

`vs_rivals` is keyed by every non-reference engine, so five engines give four entries per cell. The summary.md tables use the same engine names as
column headers (`<engine>`, `strim/<rival>`, `vs <rival>`, `<engine> footprint / RSS`), so a parser keyed on the `engines` array needs no change
for new engines.

## New keys (all additive)

| key | where | meaning |
|---|---|---|
| `schema_version` | top | `2` |
| `run_dir` | top | basename of the results directory |
| `only_clean` | top | true when summarize.sh ran with `H2H_ONLY_CLEAN=1` (non-CLEAN cells were dropped before the medians) |
| `claim_policy` | top | `{claims_only_from_clean_sessions, tie_pct, rerun_polluted_once, pollution_rule, excluded_flags[]}` |
| `engine_meta` | top | `{ <engine>: {port, mtp, prefix_cache, cache_hits_visible_via, own_memory_guard, flags, version, model} }` strings; `version` is the measured one (`n/a` for runs before versions.txt) |
| `sessions` | top | every session record (`<engine>/pass<N>/sessions.jsonl`): `{engine, pass, session, cells[], start, end, gate: PASSED|TIMEOUT|OFF, status: CLEAN|POLLUTED|INVALID, polluted_cells[], load_max, pollute_load, dryrun, completed, flags[{cell,flag,detail}]}`. A later record for the same engine, pass and cell supersedes an earlier one (rerun) |
| `flags` | top | flat list of all session flags: `{engine, pass, session, cell, flag, detail}` |
| `cells[].group` | per cell | cell group the metric belongs to: `w3 w3_32k w4 w4s w6 w5 replay` |
| `cells[].excluded_passes` | per cell | `{ <engine>: [pass numbers] }` passes whose cell was flagged (abort, guard, OOM, timeout) and therefore left out of `per_pass`/`median` |
| `cells[].session_status` | per cell | `{ <engine>: ["CLEAN", "POLLUTED", ...] }` one entry per pass, status of the latest session that ran this cell; `UNKNOWN` for runs without sessions.jsonl |
| `cells[].claim_eligible` | per cell | `{ <engine>: true|false|null }` true only if every pass is present, none excluded and every session CLEAN; `false` for UNKNOWN runs |

Flags (`flags[].flag`): `memory_abort_watchdog` (our footprint/swap watchdog killed the engine), `engine_guard_abort` (the engine's own guard aborted
requests, oMLX "Hard memory pressure"), `engine_oom` (OOM text in the server log), `cell_timeout`, `cell_rc` (client exited non-zero), `engine_restart`
(engine restarted before the next cell; the flagged cell is never rerun inside the session), `start_failed`, `port_busy`, `omlx_already_running`,
`leftover_process` (a process outlived the engine and was killed; detail = pids), `leftover_unkillable` (session INVALID), `gate_timeout`
(session POLLUTED), `footprint_blind` (footprint(1) read 0 while RSS was non-zero: memory numbers untrustworthy). The first four are the exclusion flags.

## What the site generator must read (Sources/StrimSite is not touched by this change)

- `FinalSync.swift` reads `results.json` for `cells[].per_pass.strim` (pass count), `median.<engine>`, `vs_rivals.<rival>` and cross-checks them against the
  summary.md Results table by engine-name column headers. Everything it needs for N engines is already generic in the data; the engine list and the
  rival labels (`"rapid-mlx": "..."`, `"mlx-vlm": "..."` in `FinalSync.swift` ~l.130 and the rival pages ~l.225, `Pieces.swift` `ver.*` figures,
  `Page.swift` run command line) are hard-coded and need entries for `mlx-lm` and `omlx`: label text from `engine_meta.<engine>.flags/mtp/prefix_cache`, version from `engine_meta.<engine>.version`.
- Headline regimes (`Headline.swift`) use cell ids only (`d4k c4k_pf aw5 ...`) and `vs_rivals` per rival; no change in ids.
- New: show `claim_eligible` / `session_status` and refuse to emit a WIN/LOSS claim for an engine/cell where it is not `true` (render TIE-or-"unverified");
  show `excluded_passes` / `flags` as footnotes (oMLX W5 guard abort is expected to appear there as an n/a cell).
- Memory table rows come from summary.md `## Peak memory per cell` (`<engine> footprint / RSS` columns); `watch.csv` gained a sixth column `nprocs`
  (process-tree size; > 1 for oMLX/rapid-mlx helpers), the first five columns are unchanged.
