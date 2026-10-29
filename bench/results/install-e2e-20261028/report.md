# Install end-to-end test (2026-10-28, M5 Max 64 GB, v0.1.0 public release)

Real user path on this Mac: Homebrew tap install, first run, `strim pull` (background), serve with brew binary, curl installer. Machine NOT quiet: 1-min load 5-18 during the run (design worker, other h2h job, download), so perf is indicative.

## Timeline (local time)
- 20:02:32 start. Load average 18.5 / 12.4 / 9.4 at start.
- 20:02-20:03 `brew tap` + `brew install`: 18.5 s wall.
- 20:03:48 `strim pull` started (pid 21541). Default dir `~/.strim/models` did not exist, so the default was used.
- 20:05:04 SIGINT sent (ignored, see rough edges), SIGTERM 5 s later: clean exit, `.part.state` saved. 20:05:24 restarted (pid 26202): resumed.
- 20:13:20 GPU lock acquired (waited ~6 min behind an h2h rapid-mlx pass), serve tests done by 20:13:56.
- 20:10-20:12 curl installer into a temp prefix (58.7 s wall), then the prefix was deleted.
- 20:14 shard 1 of 3 (5.34 GB) verified ok after 527 s of pull time. Download left running.

## Step 1: brew install: PASS
- Install: `/opt/homebrew/Cellar/strim/0.1.0: 14 files, 41.9MB, built in 1 second`; libexec 40 MB (binary + 2 SwiftPM bundles incl. metallib). Bottle/binary only, no compile.
- `which strim` = /opt/homebrew/bin/strim (a 2-line bash wrapper exec'ing Cellar/.../libexec/strim). `strim --version` = `strim 0.1.0`.
- Man page: none. Shell completion (bash/zsh/fish): none.
- `strim doctor`: device Device(gpu, 0), matmul ok, models dir `/Users/user/.strim/models`, lists 4bit/6bit/8bit/oq4e dirs as `absent`, ends with `missing the default 4bit model: run \`strim pull\``. Good, actionable.
- Left installed.

## Step 2: first run and pull: PASS (resume works)
- `~/.strim` before: jobs/ worktrees/ worktrees-host-objects/ control-token host.lock token (token files already existed from earlier use; "token created on first start" could not be verified here).
- `strim pull --list`: 4 tiers with pinned revisions, sizes, headroom note. Clear.
- Throughput (du of ~/.strim/models, 30 s samples in pull-samples-snapshot.csv): about 8-9 MB/s (480-520 MB/min) in minutes 1-5, ~8 MB/s sustained over the first 10 min (5.3 GB at +10 min). Pull CPU 1-8 %, RSS 25-30 MB while downloading (310 MB while hashing a finished shard). 16.3 GB total => about 35 min at this rate, not 2 h.
- Resume: SIGTERM at 1.09 GB done; restart showed per-segment `done` of ~300 MB each in the state file, i.e. continued from the .part, not from zero. The 3 small files were re-"checking"ed (fast). Final hash verification of the complete set is still pending (download not finished at report time). Shard 1: `ok qwen38-4bit/model-00001-of-00003.safetensors 5.34 GB 527.0s`.
- Still running: pid 26202, log `bench/results/install-e2e-20261028/pull.log`. Check: `tail -3 bench/results/install-e2e-20261028/pull.log; du -sh ~/.strim/models; ps -p 26202`. When done the log ends with the serve line.

## Step 3: serve with brew binary: PASS
Command: `strim serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203` (second session with `--no-auth` for bench, because `strim bench http scoreboard` has no token option).
- Startup: ready (/health 200) within ~3 s (models mmapped, page cache warm from previous runs; a cold first start from a fresh pull will be slower, untested).
- `~/.strim/token`: exists, mode 600 (existed since Oct 26).
- /health: `{"status": "ok", "engine": "up"}` (no auth needed).
- No token: 401 `authentication_error` with `WWW-Authenticate: Bearer` on /v1/models, /v1/chat/completions, /v1/messages. Wrong token: 401. PASS.
- OpenAI chat, Bearer token, non-stream: 0.55 s, stream with usage: 1.65 s, valid.
- Anthropic /v1/messages: x-api-key (non-stream, system + content blocks) 0.62 s, text "Hello there, my friend."; Bearer stream 0.28 s with proper message_start/ping/content_block_delta/message_stop events; /v1/messages/count_tokens works. PASS.
- Decode (W3, 4096 ctx prompt, 256 new tokens, greedy, thinking off, 1 rep each, via `strim bench http scoreboard --workloads W3 --w3-sizes 4096 --w3-gen 256`; same cell as bench/h2h/pass.sh w3 but only the 4K size, no separate warm-up):

| run | decode tok/s | TTFT s (cold 4K) | 1-min load at start |
|---|---|---|---|
| 1 | 73.93 | 4.117 | 9.6 |
| 2 | 77.93 | 4.111 | 9.2 |
| 3 | 72.85 | 4.101 | 8.4 |
| median | 73.93 | 4.111 (=996 tok/s prefill) | |

Frozen build (h2h-final2, median of 2 passes, polluted): decode 70.72 tok/s, cold 4K prefill 982 tok/s, TTFT 4.18 s (pass 1 alone: 74.02 / 4.156). Brew v0.1.0 binary is on par or slightly faster (+4.5 % median vs final2) even with load 8-10 and a download running. Not a clean measurement (n=3 single runs, load > 3).
- Memory: peak footprint 16.4 GB (auth session, a few tiny requests), 19.8 GB during the three 4K W3 runs (watchdog, 5 s samples, limit 42 GB; swap used steady at 3113 MB, no growth). The doc says ~31 GB peak at larger contexts; not exercised here.
- Stop: SIGTERM, exit in 2 s both times; `pgrep -fl "strim serve"` empty.

## Step 4: curl installer: PASS
`curl -fsSL -o install.sh https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh; /bin/bash install.sh --prefix <tmp>`: 58.7 s wall (download of the tarball while the model pull ran), `Checksum OK`, `strim 0.1.0`, 40 MB, prints PATH hint, next steps and an exact uninstall line. `bin/strim --version` OK. Temp prefix deleted.

## Rough edges
1. Brew output is dominated by 70+ lines of "taps are not trusted / brew trust ..." for OTHER taps on this machine (Homebrew tap-trust feature). Not a Strim problem, but the strim tap itself was not flagged; a new user with a clean Homebrew will not see this. Worth checking that `brew tap megasoft1978/strim` does not itself require `brew trust` on a fresh machine.
2. `strim --version` prints 7 lines of config (model, quant, context, prefill, mtp, wired 44 GB) plus "check the GPU and model files with: strim doctor". The first line is parseable, but a version flag normally prints one line. `strim doctor` repeats the same block before its checks.
3. `strim pull` is not interruptible by SIGINT when started as a background job (shell ignores SIGINT for background jobs, so this may be an artifact of the test; SIGTERM works and persists state). No message is printed on termination.
4. Non-tty progress is one line per finished file only; a 5 GB shard shows nothing for ~9 min (documented in INSTALL.md, but a user redirecting to a log sees a frozen log). The resumed run also prints `checking ...` for small files without saying "resuming from X MB".
5. No man page and no shell completion (nothing in Cellar). `strim --help` is an "unknown option" error: `strim serve --help` and `strim bench http scoreboard --help` also fail with `unknown option --help` instead of usage.
6. Default chat request with a small max_tokens (32) returns empty `content` and the text under `reasoning_content`, finish_reason `length`: thinking is on by default, so a "hi" smoke test with a small budget looks broken to a new user. The Claude Code path (Anthropic endpoint) with the same budget returned text fine.
7. `strim serve` prints a warning on every start: `mcp.allowedRoots is not set; delegated jobs are limited to /Users/user`. Fine for power users, noise for first-time users.
8. Server logs `auth: DISABLED (--no-auth), loopback dev only` clearly; good. `strim bench http scoreboard` cannot send a token, so benchmarking an authenticated server requires `--no-auth`.
9. The README hero chart says Strim 61.9 tok/s decode at 4K; measured here 73.9 and frozen h2h-final2 70.7. Check whether the chart is intentionally an older/different run.
10. GPU lock contention: another h2h job held /tmp/strim-bench.lock; the serve test waited about 6 min for it (expected, not a product issue).

## Commands run
```
brew tap megasoft1978/strim && brew install megasoft1978/strim/strim
which strim; strim --version; strim doctor; strim pull --list
nohup strim pull > pull.log 2>&1 &     # kill -INT, kill -TERM, restart same command (appends)
lockf -t 3600 -k /tmp/strim-bench.lock bench/results/install-e2e-20261028/serve-test.sh   # serve + curl checks + 3x W3
curl -fsSL -o install.sh https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh
/bin/bash install.sh --prefix <tmp>; <tmp>/bin/strim --version; rm -rf <tmp>
```
Files here: brew.txt, doctor.txt, pull-list.txt, ls-before.txt, resume-test.txt, pull-samples-snapshot.csv, pull-snapshot-2014.txt, serve-test.sh/.out, serve/ (server logs, watchdog CSVs, W3 summaries), curl-install.txt, install.sh, sampler.sh.
