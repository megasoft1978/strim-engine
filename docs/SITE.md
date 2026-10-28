# Site and README generator (`strim site`)

Swift-only generator for `site/index.html` (landing), `site/benchmarks.html` (full results, method, engineering notes), `README.md` and `site/data/results.json` (it replaced `scripts/build_site.py`, removed). Library: `Sources/StrimSite`; CLI glue: `Sources/StrimCLI/Cmd_Site.swift`. No third-party dependencies.

## Commands

```
strim site build          # render site/index.html and README.md, then run the checks (default)
strim site check          # checks only, nothing is written (= build --check)
strim site refresh-soak   # fill soak.* figures from the latest complete 30-minute soak, then build
strim site list-figures   # id, value, unit, source for every figure
```

Flags: `--check`, `--list-figures`, `--refresh-soak` (they work with or without a subcommand). `--root DIR` overrides the repo root (default: nearest parent of the cwd containing `site/data/results.json`). Exit status: 0 clean, 1 on check errors or a fatal input error (message on stderr or `ERROR ...` lines on stdout), 2 on usage errors.

## What it does

- Inputs: `site/data/results.json` (figures), `site/README.template.md`, `bench/results/h2h-final-20261028/{summary.md,results.json}`, source files named by each figure.
- The `final.*` figures and the `final` layout block are regenerated from `summary.md`, cross-checked against `results.json` (cell medians, displayed ratios, the quoted claim ranges), and rewritten into `results.json` (build) or reported as "out of sync" (check).
- Outputs: `site/index.html`, `README.md` (and `results.json` when the final block changed). Every number is a figure id; `{{id|n}}` and `{{@scoreboard}}`, `{{@replay}}`, `{{@soak_line}}` in the README template.
- Checks: figure fields, source path rules, `verify` / `verify_section` / `verify_count` / `verify_md` against the source file, HTML tag balance, duplicate ids, anchors, offline-only links, relative links, README markdown links.
- `--refresh-soak`: latest run under `bench/results/soak-*/*/` (the gitignored `bench/soak/results/` is not scanned) with `run.json` (`elapsed_min` set, not aborted, `duration >= 30` (`aborted` false; dirs named `*invalid*` skipped)) and `summary.txt`; the 13 soak figures are scanned from the summary text with fixed patterns.

## Equivalence

The output was verified byte-identical to the Python generator on the committed inputs (including with a synthetic complete soak and after `--refresh-soak`) before the Python was deleted. Python float `repr`, `json.dumps(indent=1, ensure_ascii=False)`, `html.escape` and `%g` / `.Nf` formatting are reimplemented in `PyJSON.swift` / `Text.swift`. The committed `site/index.html`, `README.md` and `site/data/results.json` are the frozen reference: the test regenerates them and requires byte equality. Page text that named the Python script now names `strim site build` / `strim site check`; the committed outputs were regenerated once for that change and are otherwise the Python generator's output.

Tests (`Tests/StrimSiteTests`): equivalence against the committed files, `check` failing on a corrupted value / dropped figure id / desynced winners table / bad scoreboard cell / missing source / bad template, build-mode writes, soak refresh, unit tests for the number and JSON formatting.

## Redesign (2026-10-28)

README (<= 60 lines, one hero chart `site/assets/h2h-hero.svg`) and the landing page are short front pages; everything cut moved to `site/benchmarks.html` and `docs/CLIENTS.md`. The head-to-head run is ONE constant, `FINAL_REL` in `Sources/StrimSite/Builder.swift`; date, build, rival versions, validity text (sessions polluted, highest load) and the raw-results link are parsed from that run's `summary.md`, so swapping in a clean rerun is a one-line change plus `strim site build`. The terminal transcript on the landing page is captured output in `site/data/demo.json` (not generated; re-capture when CLI output changes). `strim site check` also enforces the README line limit, one chart, install order and visible loss rows.
