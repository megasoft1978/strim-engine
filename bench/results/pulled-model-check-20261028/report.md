# Pulled model == benchmarked model, and live app screenshots (2026-10-28)

Machine: M5 Max 64 GB, busy with other workers' builds (load 2-5, see per-run lines). Brew binary `strim 0.1.0` (/opt/homebrew/bin/strim). All GPU work under `lockf -t 3600 -k /tmp/strim-bench.lock`, memory watchdog `bench/h2h/watchdog.sh` (5 s, SIGTERM at 42 GB footprint or +2 GB swap; never triggered), one server at a time, servers stopped with SIGTERM afterwards. Results are indicative.

## JOB 1

### 1a SHA-256 (openssl dgst -sha256 -r; full list in sha256.txt): ALL MATCH
| file | sha256 (pulled == repo models/) |
|---|---|
| qwen38-4bit/model-00001-of-00003.safetensors | 6cc1508e96fb5d0865dfd5753a79f4ec60651bf3e2a82844a7e8ae9c60528c0d |
| qwen38-4bit/model-00002-of-00003.safetensors | 83f2a20ca8058f486a3634a27faf99587f4cd3c156a83dee34fb99e6ac178670 |
| qwen38-4bit/model-00003-of-00003.safetensors | 31b8c91ef899f79efaaa69e3d2c096f6e2ebeb2ff20e29222abbd9ebc79e560a |
| qwen38-mtp-4bit/model.safetensors | 76663c101e7e8ea9c0ae17bcb95183cd7f733ce424c912b8b264a7b1c48e4cc6 |

The three main hashes also equal the ones pinned in `~/.strim/models/qwen38-4bit/.strim-pull.json`.

### 1b Greedy text, byte for byte: 3/3 MATCH
`strim serve <dir>/qwen38-4bit <dir>/qwen38-mtp-4bit --port 8231`, three servers one after another (pulled cold, pulled warm restart, repo `models/`), same binary. Requests: `temperature 0, max_tokens 64, stream false, chat_template_kwargs {"enable_thinking": false}`, prompts: (1) sky-is-blue explanation, (2) Swift Fibonacci code prompt, (3) planets list. `cmp` of the content of all three runs: identical for p1, p2, p3 (files `serve/*.p{1,2,3}.txt`, raw responses `.json`). Note: p2 is truncated at 64 tokens by design.

### 1c Serve start to first token (script job1.sh, `serve/*.timing`)
| run | start to /health | start to first streamed token |
|---|---|---|
| pulled dir, first serve | 2.36 s | 2.48 s |
| pulled dir, restart (warm) | 1.46 s | 1.57 s |
| repo `models/` dir | 2.45 s | 2.56 s |

Caveat: not a truly cold cache. `purge` needs sudo (not available), and the pulled files had been read recently (pull verification, earlier serve tests, partial hashing). The weights are mmapped, so "ready" is fast either way; the first request after /health costs about 0.11 s. Load average at start 3.5-3.9.
(An earlier attempt on port 8203 was discarded: another worker's stub server answered on that port. Re-run on 8231 with a port-busy guard.)

## JOB 2 method (live app screenshots, no invented numbers)
1. `host.sh`: brew binary, pulled models, port 8203, under the lock + watchdog (peak footprint 18.4 GB, swap steady 2923 MB).
2. `warm.sh`: 8 real OpenAI-endpoint requests (thinking off, shared system prompt; log in live/warm.log).
3. `mcp_job.sh`: real harness job via the MCP endpoint (`strim_task`, access write, `verify: go test ./...`) in a throwaway git repo `~/strim-live-demo` (Go module, `Mean` divides by `len(xs)-1`, `TestMean` fails; under $HOME because `/tmp` is outside the default mcp.allowedRoots). Result: done, `verify=verified`, 5 turns, 11 s wall, 14.4k prompt tokens (11.4k cached) + 286 completion, patch +1/-1 in stats.go (live/mcp_task.txt). Plus one real `strim_ask` job (read-only question). Neither patch was applied.
4. Snapshot tool, new flags (Sources/StrimApp/Snapshots.swift): `--live <controlURL> --token-file <path>` use the real `HTTPControlClient` and `AppModel` (same views, polling 1 s); optional `--project`, `--model-path`, `--mtp-path` (Settings display), `--select-job <title substring>`, `--chat-prompt` (repeatable, sent through the app's real chat backend: chat/open + chat/append + SSE deltas), `--chat-timeout`. The chat transcript is written to `chat-transcript.json`, status/jobs as seen to `live-status.json`, `live-jobs.json`. Default (`--snapshots` alone) behavior unchanged.
```
STRIM_BIN=/tmp/strim-build-live/release/StrimApp   # built from a git-archive snapshot, nice -n 19
$STRIM_BIN --snapshots docs/img/app-live --live http://127.0.0.1:8203 --token-file ~/.strim/control-token \
  --project ~/strim-live-demo --model-path ~/.strim/models/qwen38-4bit --mtp-path ~/.strim/models/qwen38-mtp-4bit \
  --select-job "Fix the failing" \
  --chat-prompt "Read stats.go and stats_test.go, run go test once, and explain in two sentences why TestMean fails. Do not edit any file." \
  --chat-prompt "Now write the minimal fix as a diff in your reply. Do not edit any file."
```
5. Real window: `STRIM_APP_TEST=1 StrimApp` (opens the main window, default host 8203 / ~/.strim/control-token), `screencapture -x -o -l <CGWindowID> docs/img/app-live/real-window-status.png`.
Load average at capture: 1.9-2.6 (1 min).

## Numbers shown (server-reported, snapshot run, live/live-status.json)
Status: state busy (the open chat session counts as 1 active job), decode 78.7 tok/s, prefill 520.7 tok/s, MTP acceptance 88.7 % (depth 3.62), prefix-cache hits 82.4 %, prefill saved 50.5 s, tokens today / generated locally 2023 (shown 2.0k), queue 1 active / 0 queued, uptime 1m 23s (server-reported; it appears to count from the first request, the process had run longer), memory weights 14.3 GB, prefix trie 1.0 GB, MLX cache 1.0 GB, headroom 16.1 GB (of 32.4 GB admitted), fingerprint 1d5aeeb1a74c3fc3. Real-window capture a minute later: 78.7 tok/s, prefill 520.7, MTP 89 % / 3.62, prefix 82 %, 16.3 GB of 32.4 GB, uptime 1m 52s.
Chat (chat-live-*): turn 1 prompt 8.3k (6.9k cached), 255 completion, 36.9 tok/s over the turn incl. tools; turn 2 prompt 3.1k (3.1k cached), 233 completion, 72.5 tok/s. Tools shown: read_file x2, bash `go test`, finish. Reasoning collapsed in chat-live-*, expanded in chat-live-expanded-*.
Jobs: selected job j_7wxtngv33y (mcp, done, verified, 5 turns, 275 local tokens, +1 -1 stats.go), also strim_ask job j_z6mvf3wywi and chat sessions. Older cancelled/limit jobs from earlier days come from ~/.strim/jobs history.
Settings: real paths /Users/user/.strim/models/..., control token path masked (eye icon), host http://127.0.0.1:8203.

## Findings (not fixed, out of scope)
- Chat view flattens newlines inside a fenced diff block (diff renders on 3 lines) and leaks a literal `</think>` into the assistant text; the final `finish` tool call is shown as a tool card with the summary only in its args.
- `/tmp` is outside the default delegated-job roots, so a /tmp throwaway repo is refused until `mcp.allowedRoots` is set.
- `--help` is not supported by `strim serve`, `strim` without args prints config, as noted in install-e2e.
