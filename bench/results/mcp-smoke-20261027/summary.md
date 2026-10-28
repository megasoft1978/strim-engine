# MCP smoke 2026-10-27

Setup: `swift build -c release --disable-sandbox` 45.7 s wall (35.9 s compile). `strim serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8211`, engine ready 2.2 s. Note: the model here is the Qwen3.8 4-bit + MTP head from the brief's command, not a 27B. Script: `bench/mcp/smoke.sh` (bash+curl+jq; token never printed or stored; verified by scan of this dir). Raw responses in `raw/`, harness timelines in `events/`.

## Results (one run, warm cache)

| call | http | wall | resp bytes (~tok = B/3.5) | status | turns | prompt/cached/completion tok | first model reply* |
|---|---|---|---|---|---|---|---|
| initialize (2025-06-18) | 200 | 0.8 ms | 365 (104) | | | | |
| notifications/initialized | 202 | 0.7 ms | 0 | | | | |
| tools/list | 200 | 0.6 ms | 3202 (914) | 4 tools: strim_task strim_job strim_cancel strim_ask | | | |
| strim_ask (tiny question) | 200 | 2.94 s | 1052 (300) | done | 3 | 7238/6855/184 | 0.87 s |
| strim_task read (explain slugify) | 200 | 7.65 s | 3023 (863) | done | 3 | 7196/6827/441 | 0.84 s |
| strim_task write (fix_slugify) | 200 | 5.49 s | 2590 (740) | done | 5 | 13479/12846/364 | 1.00 s |
| cancel running job (sleep 1234) | 200 | 6.6 ms | 528 (150) | cancelled | 1 | | |
| cwd=$HOME | 200 | 1.7 ms | 668 (190) | failed (isError=false) | 0 | | |
| bad args (relative cwd / extra field) | 200 | <1 ms | ~155 (44) | isError=true | | | |

*first_event to first usage record in events.jsonl (prefill + first turn decode). All three jobs finished within the 25 s wait_s, so no not-done polls occurred in the main flow; the not-done replies seen elsewhere were one line (~100 B text).

Write task: model read both files, did edit_file (+1 line `re.sub(r"[^a-z0-9\s]", "", text)`), ran the targeted tests then the whole module, then `finish`. Patch 289 B. `git apply --check` + `git apply` on a fresh copy: OK; `python3 -m unittest -q tests.test_text.SlugifyTests` exit 0 (2 tests); tests/test_text.py unchanged; original repo copy untouched (read repo and write repo clean). python3 -m unittest worked inside the sandbox, no denials seen. No parse failures or plain-text-instead-of-tool-call turns in any job. Harness finished the write task correctly.

## Negative paths

| case | result |
|---|---|
| no token | 401 |
| wrong token | 401 |
| Host: evil.example.com | 403 |
| Origin: https://evil.example.com | 403 |
| strim_task cwd=$HOME | job created then `failed` ("refusing the filesystem root, the home directory..."), but MCP `isError=false` (see bug 1) |
| access=write, default maxAccess | accepted (default maxAccess is `write`, so this is by design) |
| access=write with `{"mcp":{"maxAccess":"read"}}` (server restarted) | isError=true, clear message, nothing queued |
| cancel running job | `sleep 1234` child seen before, 0 after; worktree gone from `git worktree list`; job dir keeps events/job/result only; bash tool result `exit code 137` |
| SIGTERM host with a running job | child killed, job reported `cancelled` after restart (not host_restart) |
| SIGKILL host with a running job | after restart job = `failed`, reason `host_restart` (correct) |

## Bugs / observations

1. **cwd=$HOME is not an MCP error**: `Tools.swift`/`Host.swift` return `isError=false` with a "failed" job (jobs created, id consumed) for an invalid cwd. Brief expected isError. Repro: `strim_task {task:"x", cwd:"$HOME"}`. Minor; the validation happens in the harness workspace prep, not in argument parsing (`Tools.cwd`).
2. **Orphan child survives host SIGKILL**: bash tool child (`sleep 1234`, ppid 1) keeps running after `kill -9` of the host and after restart; restart only marks the job `host_restart`. Also its worktree (`~/.strim/worktrees/<uuid>`, plus `.git/worktrees/<uuid>` in the user's repo) is never reclaimed on restart. Files: `HarnessRunner.swift`, `GitWorktree.swift`, `Host.swift` (startup sweep missing). Repro: start `sleep` job, `kill -9` strim, restart, `pgrep -f "sleep 1234"`, `git worktree list`.
3. **Worktree leaked on graceful SIGTERM shutdown with a running job**: `~/.strim/worktrees/a9a19c72-...` and the linked entry in the repo's `.git/worktrees` remained after `kill -TERM` of the host (cancelled job). Suspected: `host.shutdown()` cancels jobs but exits before the runner's cleanup. File: `Host.swift` shutdown / `Cmd_Serve.swift` (`exit(0)` right after await). Repro as above with SIGTERM. I cleaned both with `git worktree remove --force`.
4. **Children inherit SIG_IGN for SIGTERM/SIGINT**: `Cmd_Serve.swift` does `signal(sig, SIG_IGN)` for the dispatch sources; ignored dispositions are inherited across exec, so the orphaned `sleep` ignored `kill -TERM` (needed -9). Cancel works because the harness uses SIGKILL, but any grandchild is unterminable by TERM. Fix: reset to SIG_DFL in the spawn path (`ProcessRunner.swift`, posix_spawn attr SETSIGDEF) .
5. **Transient workspace-prep failure**: one job on `/tmp/fx/r2` (a `cp -r` of a clean 1-commit repo) failed instantly with `workspace preparation failed: git stash create exited 1: ` (empty stderr, `reason: null`), identical retry later succeeded; could not reproduce by running `git stash create` by hand. Suspect stale index stat data after `cp -r` or unlogged stderr. File: `GitWorktree.swift` `baseRevision` (line ~291); at least capture stderr and fall back to HEAD.
6. Cosmetic: the 202 reply status line reads `HTTP/1.1 202 Unknown` (reason phrase missing) in `HTTPMessage.swift`.
7. Structured and text content are both returned (structuredContent duplicates the text), so each result is ~2x the bytes a client reading only `content` pays; clients that forward both to the model double the tokens. Consider measuring what Claude Code/Codex actually forward.
8. Jobs are serial (second queued while first runs); expected, noted for latency planning.

## Success criteria

- 4 tools listed: yes (3.2 KB, ~914 tok to register).
- Write patch applies and passes check: yes.
- First model reply <= 2.5 s warm: yes (0.84 to 1.00 s); whole small jobs 3 to 8 s.
- Crash/hang: none. Model tool-call parse failures: none. Sandbox denials: none.
- Not run: concurrent jobs, long (>25 s) job polling flow, requireApproval, allowedRoots.
