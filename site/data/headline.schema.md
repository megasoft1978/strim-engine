# headline.json and features.json

`site/data/headline.json` holds every number the comparison charts and scoreboards use (hero speed-up chart, memory chart, latency chart, scoreboard, README table). It is generated, never hand-edited:

```
strim site build     # rewrites headline.json, site/assets/h2h-*.svg, the chart block in site/assets/style.css, site/index.html, README.md
strim site check     # fails if any of those differs from what the inputs generate
```

Inputs: `bench/results/h2h-final-20261028/{summary.md,results.json}` through the `final.*` figures in `site/data/results.json` (those are re-parsed and cross-checked on every run), and the per-cell memory table of `summary.md`. `run` also carries `raw_dir` and `validity` (clean, sessions, polluted, load_max, swap_growth_max_mb, text). Inputs of the figures are `bench/results/<FINAL_REL>/...`. To use a later head-to-head run: point `FINAL_REL` in `Sources/StrimSite/Builder.swift` at the new directory, run `strim site build`, review the diff, and run `swift test --filter StrimSiteTests` (the golden test compares the committed outputs byte for byte). No chart code or number lives anywhere else.

## headline.json

```
schema        "strim-headline/1"
run           id, date, source (summary.md path), machine, model, strim_build, rapid_mlx, mlx_vlm, passes, reps_per_pass, tie_band_pct
engines       { strim|rapid-mlx|mlx-vlm : { label } }
hero.rows     [ { regime, cells: [cell id] } ]            order and grouping of the hero chart
cells[]       id, regime, label (summary.md row), short (chart label), unit, better ("higher"|"lower"),
              values   { engine : median over passes }    as printed in summary.md
              speedup  { rival  : factor }                Strim advantage, > 1 is better for Strim for every unit (seconds are inverted); values[strim] vs values[rival], 3 decimals
              verdict  { rival  : WIN|TIE|LOSS|n/a }      copied from summary.md (2% tie band)
              source   path and the summary.md section/row the numbers come from
memory        unit, source, abort_limit_gb, whole_run { engine : GB }, whole_run_verdict { rival : verdict },
              strim_lowest_cells, cells_total, cells [ { id, label, values { engine : GB } } ]   phys_footprint, max over passes and sessions
scoreboard    regimes [ { id, label, metric, cells: [cell id | "whole_run"], vs { rival : { WIN, TIE, LOSS } } } ], total { rival : { WIN, TIE, LOSS } }
```

Each cell is counted once in the scoreboard (cold prefill by tok/s, not again as time to first token; replay by the 8-turn sum). Memory counts as one cell (whole-run peak, lower is better, 2% band).

## features.json

Hand-filled functionality matrix; each row names its evidence file in `source`, and `strim site check` requires the file to exist and every status to be valid.

```
rows[]   id, group, label, readme (true: row also appears in the README table), source,
         strim | rapid-mlx | mlx-vlm : { s: yes|partial|no|notfound|unknown|info, n: short note }
```

`notfound` = no evidence found in what was checked (not proof of absence); `unknown` = not verified; `info` = plain fact with no verdict (sizes, licence). Fill an unverified rival cell with `unknown`, never a guess. The current content comes from `docs/COMPARISON-FEATURES-2026-10-28.md`.
