| 1 | fix_median | fix even-length `Median` bug | `go test ./...`; test file unchanged |
| 2 | grep_callers | list files calling `Slugify(` (excluding definition) | `notes/slugify_callers.txt` = {cli.go, text_test.go} |
| 3 | rename_word_count | rename `WordCount` to `CountWords` everywhere | `go test ./...`; no `WordCount` text left |
| 4 | add_docstrings | doc comments for exported funcs in `text.go` | every exported func/type documented; `go test ./...` |
| 5 | run_tests_report | read the code, list the failing tests in `notes/failing_tests.txt` | file lists exactly TestMedianEven and TestSlugifyPunctuation |
| 6 | refactor_normalize | extract `normalize` helper in `text.go` | `go test ./...`; `func normalize(` present; at most one `strings.ToLower(` |
| 7 | add_clamp | `Clamp(x, lo, hi)` in `util.go` plus tests | host hidden test (range + panic) and `go test ./...` |
| 8 | explain_cli | explain `cmd/mathkit` in `notes/cli_flow.md` | file mentions args and slugify |
| 9 | fix_slugify | fix punctuation handling in `Slugify` | `go test ./...`; test file unchanged |
| 10 | add_load_numbers | `LoadNumbers(path)` in `numbers.go` plus tests | host hidden test with temp files and `go test ./...` |
| 11 | add_stdev | sample `Stdev` in `stats.go` plus tests | host hidden test (2.13808993..., error for one value) and `go test ./...` |

Each Go module is a few files and `go test ./...` finishes in a few seconds (a warm build cache is seeded once per soak).
# strim soak harness

`strim soak` drives real `claude -p` (Claude Code 2.1.310) and `codex exec` (0.164.0) clients against
`strim serve` on 127.0.0.1, records per-task outcomes and server health, and writes a summary.
Implementation: `Sources/StrimSoak/` (entry `SoakEntry`, session loop `SoakSession`, summary `SoakSummary`);
the CLI wiring is `Sources/StrimCLI/Cmd_Soak.swift`. The Python harness it replaces is gone; the fixtures are Go.

## Usage

    .build/release/strim soak [--duration 30] [--arms both|claude|codex]
        [--max-tasks N] [--task-timeout 240] [--concurrent-every 6] [--poll 15]
        [--port 8203] [--token-file ~/.strim/token] [--ready-timeout 900]
        [--model DIR] [--head DIR] [--out DIR] [--tmp-root DIR] [--only id,id]
        [--claude-bin PATH] [--codex-bin PATH] [--lock-path PATH] [--lock-wait-s S]
    .build/release/strim soak --list-tasks
    .build/release/strim soak --summarize bench/soak/results/<ts>
    .build/release/strim soak --help

- Run from the repo root, or pass `--model`/`--head`. Defaults: `models/qwen38-4bit` and `models/qwen38-mtp-4bit`.
  The model id clients request is the model directory's name.
- All paths are absolute once parsed (relative to the cwd at launch, `~` expanded).
- Default run: 30 min. No new task starts after the deadline; a running task finishes or hits its cap.
- `--task-timeout` is capped at 240 s.
- `--concurrent-every N`: after every N sequential tasks, one claude and one codex task run at the same time (0 disables).
  The codex half goes out as background priority.
- GPU lock: the run takes an exclusive `flock` on `STRIM_BENCH_LOCK` or `/tmp/strim-bench.lock` (or `--lock-path`)
  before it starts the server, the same lock the agentbench jobs use. `--lock-wait-s` bounds the wait (default: wait).
  The lock file must be a regular file owned by you, created 0600; symlinks are refused.
- Ctrl-C (or SIGTERM) kills the client process groups, stops the server with SIGINT (30 s grace, then SIGKILL),
  and writes the summary with `aborted: true` (exit 130).
- Refuses to start if the port already accepts connections.

## What it does

- Starts `strim serve <model> <head> --port <port> --token-file <file>` itself with `STRIM_SERVER_LOG=1`,
  output appended to `<out>/server.log`. Waits for `/health` 200 before the run.
- Reads the bearer token from the token file (serve creates it if missing). The token is never printed,
  never put on a command line, never written to results (log and summary text is redacted), and reaches the
  clients via env only.
- Each task: fresh toy repo (`mathkit`, a small from-scratch Go module with a seeded bug or a reading/notes task) in a
  temp dir, one client run, then a deterministic check. Passing repos are deleted; failing ones are kept and their path is recorded.
  New soaks use these Go fixtures. The committed results under `bench/results/soak-20261027/` come from the earlier
  fixture soak and are historical; the task ids, count (12) and explain / fix / refactor / test mix are unchanged.
- Clients are isolated and sandboxed: the whole client process runs under `sandbox-exec` (the `ClaudeSandbox` profile:
  writes only in the task repo and a per-run scratch dir (the client's config dir is a fresh per-run copy of `<out>/isolated/` inside scratch; nothing shared is writable); reads of the home and secrets
  denied; network only to loopback on the serve port). The environment is explicit and minimal (PATH, HOME/TMPDIR in
  scratch, `CLAUDE_CONFIG_DIR`/`CODEX_HOME` under `<out>/isolated/`, base URL, token); nothing is inherited from the
  host. Without `sandbox-exec` the soak refuses to start a client.
- Permissions (least that works):
  - claude: `--permission-mode dontAsk`, `--tools Read,Edit,Write,Glob,Grep`. No Bash tool and no git: prefix
    allowlists are not a boundary (`go test` runs arbitrary code, a writable `.git/config` runs code).
  - codex: `-s workspace-write -C <temp repo>`, `approval_policy=never`, `features.shell_tool=false`,
    `features.unified_exec=false` (edits through apply_patch only), custom provider
    `model_providers.strim` (`wire_api="responses"`, `env_key=STRIM_SOAK_TOKEN`).
  - The tests run in the harness, not in the client: after the client exits, a diff allowlist checks the repo (only the
    task's source files changed, test files unchanged by hash, no symlinks or special files, no `.git`, notes are text
    only). Only then host-owned hidden tests are added and `go test ./...` runs under the verify sandbox (same profile as
    the agentbench verifier: no home reads, no network including loopback, cleared env with HOME/TMPDIR/GOCACHE/GOPATH in
    scratch, output through a host-held fd). A violation executes nothing.
- Poll every `--poll` seconds: `/health` (no auth), `/metrics` (bearer). Records RSS (`ps`), health code,
  engine/session counters, `requests_total`/`requests_failed`, MLX bytes, and scans `server.log` for
  `error`, `unhealthy`, `insufficient memory`.
- Crash = unexpected exit of the serve process. The harness logs it with the log tail and restarts the server.

## Task list (checks run on the host after the client exits)

| # | id | task | check |
|---|----|------|-------|
| 0 | explain_stats | explain `stats.go` in `notes/stats_explained.md` | file mentions Mean, Median, Variance; stats.go unchanged |
| 1 | fix_median | fix even-length `Median` bug | `go test ./...`; test file unchanged |
| 2 | grep_callers | list files calling `Slugify(` (excluding definition) | `notes/slugify_callers.txt` = {cli.go, text_test.go} |
| 3 | rename_word_count | rename `WordCount` to `CountWords` everywhere | `go test ./...`; no `WordCount` text left |
| 4 | add_docstrings | doc comments for exported funcs in `text.go` | every exported func/type documented; `go test ./...` |
| 5 | run_tests_report | read the code, list the failing tests in `notes/failing_tests.txt` | file lists exactly TestMedianEven and TestSlugifyPunctuation |
| 6 | refactor_normalize | extract `normalize` helper in `text.go` | `go test ./...`; `func normalize(` present; at most one `strings.ToLower(` |
| 7 | add_clamp | `Clamp(x, lo, hi)` in `util.go` plus tests | host hidden test (range + panic) and `go test ./...` |
| 8 | explain_cli | explain `cmd/mathkit` in `notes/cli_flow.md` | file mentions args and slugify |
| 9 | fix_slugify | fix punctuation handling in `Slugify` | `go test ./...`; test file unchanged |
| 10 | add_load_numbers | `LoadNumbers(path)` in `numbers.go` plus tests | host hidden test with temp files and `go test ./...` |
| 11 | add_stdev | sample `Stdev` in `stats.go` plus tests | host hidden test (2.13808993..., error for one value) and `go test ./...` |

Each Go module is a few files and `go test ./...` finishes in a few seconds (a warm build cache is seeded once per soak).
Checks include "must stay unchanged" file hashes so a client cannot pass by editing tests.
A task passes only if its check passes and the client exits 0 within the cap.
Alternation: client = claude/codex by (position + cycle) parity, so each task runs under both clients over passes.

## Output (`bench/soak/results/<ts>/`, git-ignored; the summaries the site uses are committed under `bench/results/soak-20261027/`)

- `tasks.jsonl`: one row per client run: seq, phase (`seq`/`conc`), priority, client, task, wall_s, exit_code,
  timed_out, server_requests (delta of requests_total; shared across the pair in `conc` rows),
  check_ok/check_detail, pass, client turns/is_error/subtype, result snippet, stderr tail (token redacted),
  workdir (failures only).
- `server.jsonl`: `sample` rows every poll, plus `crash`, `restart`, `restart_failed`, `unhealthy`,
  `http_5xx`, `log_hit`, `server_up`, `server_stopped`.
- `server.log`: serve stdout/stderr, including `[serve] ... ttft=...ms` lines (used for the TTFT trend).
- `run.json`: flags, start time, elapsed_min, aborted.
- `summary.txt`: pass rate per client and phase, timeouts, longest task, crashes/restarts, 5xx, log hits,
  RSS min/max/quartile medians and slope (MB/h), TTFT quartile medians and p90, failure list, server error events.
  The site generator (`StrimSite/Soak.swift`) reads these lines by pattern, so the text format is fixed.
- `isolated/` and `tasks/<id>/client.{stdout,stderr}`: client logs and isolated config dirs.

## Tests

`swift test --filter StrimSoakTests` (or `swift build --target StrimSoakTests --scratch-path <dir>` then run the
xctest bundle). Covers argument parsing, client argv/env/output parsing, child behaviour, planted test code contained by the sandbox
(no home read, no write outside, no loopback), allowlist violations and a missing `sandbox-exec` executing nothing,
number handling, RSS slope, quartiles, a golden check that the committed `run2` summary is reproduced byte for byte
(apart from the usage line), and a 5-second soak against a fake server and a stub client launcher.
No GPU and no network are needed for the tests.

## Known limits

- The live soak with real models has not been re-run under the Swift command; the earlier run data in
  `bench/results/soak-20261027/` is the reference. The Codex arm with shell tools disabled and both clients under
  `sandbox-exec` have not been exercised live either.
- Priority: `strim serve` reads `x-strim-priority: background|interactive` (default interactive).
  In each concurrent round the codex request goes out as background (`http_headers` in the provider config);
  claude goes out interactive via `ANTHROPIC_CUSTOM_HEADERS`. Rows record `priority`.
- Ctrl-C/SIGTERM handling is untested end to end.
- Claude Code logs `[claude-code:unrecognized_model]` for `qwen38-4bit` on stderr; the run still works.
- `requests_total` is per-process; a crash resets it. Shared-window request counts in `conc` rows are approximate.
- Temp repos live in `$TMPDIR` (or `--tmp-root`); failing repos are not deleted.
