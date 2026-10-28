# Plan: Swift agent harness, taskbar app, MCP subagent (Opus advisor, 2026-10-26)

Scope: Qwen3.8-27B only. Swift only; all Python removed after porting. Items marked (unverified) were not checked.

## Decisions
1. Discard the Python strimd MCP (`service/strimd.py` `/mcp`, port 8200: one-shot tools, no agent loop, no jobs, no auth, no sandbox, non-compliant protocol handling, wrong workspace, nothing listening).
2. New Swift targets: `StrimHarness` (agent loop over `EngineClient`), `StrimJobs` (async jobs), `StrimMCP` (streamable-HTTP `/mcp` route inside `StrimOpenAIServer`), `StrimHost` (composition). Same process and engine as `strim serve`; same bearer token and loopback Host/Origin checks.
3. No stdio shim. Register over HTTP:
   - Claude Code: `claude mcp add -t http strim http://127.0.0.1:8203/mcp -H "Authorization: Bearer <token>"`
   - Codex: `codex mcp add strim --url http://127.0.0.1:8203/mcp --bearer-token-env-var STRIM_TOKEN`
   - Build `strim mcp-stdio` (relay to loopback) only if a target client lacks HTTP.
4. One engine host at a time (two 27B copies do not fit). Menu-bar app hosts engine + server + MCP + jobs; `strim serve` is the headless host with the same code; a host lock keeps them exclusive.
5. Harness is a rewrite, not a port. Reuse only the content rules of `harness/qwen/AGENTS.md`.

## MCP surface (4 tools)
| tool | args | behaviour |
|---|---|---|
| `strim_task` | `task`, `cwd` (abs), `context?`, `files?[]`, `access: read\|write` (default read), `wait_s` 0-25, `budget?` | queue background job; return job or final result if done within `wait_s` |
| `strim_job` | `job_id`, `wait_s`, `events_since?` | status (`queued\|running\|paused_interactive\|awaiting_approval\|done\|failed\|cancelled\|limit`), progress, final result |
| `strim_cancel` | `job_id` | cancel engine session, kill bash process group |
| `strim_ask` | `question`, `cwd?`, `files?[]` | read-only, <=4 tool turns, 40 s; becomes a job on overrun |

Result: `status`, `summary` (<=1.5K chars), `files_changed[{path,+,-}]`, `patch` (inline <=16 KB) + `patch_path` (`~/.strim/jobs/<id>/patch.diff`), `base`, `commands[{cmd,exit}]`, `usage`. The parent applies the patch; Strim never writes to the parent's tree. Tool descriptions teach delegation (self-contained verifiable routine work; patch is untrusted).

Protocol: POST `/mcp`, single or array; JSON reply, or SSE with `notifications/progress` every 5 s when a progressToken is given; notifications get 202; GET 405; DELETE 200; negotiate 2025-03-26 / 2025-06-18 / 2025-11-25; `ping`; tool failures as `isError` results; `structuredContent` plus text.

## Harness core
- Loop: fixed `SessionConfig` (all tools, `.disableWhenTools`); append turn, generate, consume `GenEvent` tool calls, dispatch sequentially, append `.tool` results; ends on `finish` or plain text.
- Tools: `read_file`, `list_files`, `grep`, `edit_file` (unique exact match), `write_file`, `bash`, `finish`; `task` subagent in W6.
- Prompt: byte-identical system + tool schemas first (prefix-cache stable), then user#1 (env block, AGENTS.md, skill index, task, context). Access level enforced at run time, not by changing the tool list. Warm the trie with `prefetch` at host start.
- Context (27B): soft 24K tokens, compact above 28K; tool results capped 8K chars; per-turn max 4096.
- Limits: 40 turns, 15 min, 60K generated tokens; repeated identical call x3 aborts; 5 consecutive tool errors abort; cancel kills process group.
- Events: `HarnessEvent` AsyncStream to UI, `events.jsonl`, trajectory.

## Security
Local model output is untrusted and prompt-injectable via file contents.
- Bash under `sandbox-exec` with a generated inline profile: `deny network*`, writes only to worktree + job tmp, reads of `~/.ssh ~/.aws ~/.gnupg ~/.strim/token ~/.claude* ~/.codex Keychains ~/.config/gh ~/.netrc` denied. Verified: network denied; named profiles unusable; write-deny result possibly confounded by agent sandbox (retest). Apple deprecation and nested sandboxes (SwiftPM) unverified.
- Env scrubbed (`PATH LANG TMPDIR HOME=<jobtmp>/home`), 120 s default timeout, output cap.
- File tools: realpath containment under roots + deny list (`.env* *.pem id_* .git/config .git/hooks`).
- Access: `read` = no writes; `write` = edits inside job git worktree only; parent tree untouched until Approve. Non-git: APFS clone.
- Headless MCP: `mcp.maxAccess` default `write` (worktree only), `mcp.requireApproval` default off.
- Redact secrets in tool output and results. Control-token injection already neutralised.

## App
SwiftPM SwiftUI: `MenuBarExtra` + window. Chat (streaming, reasoning, tool cards), project picker, Jobs (app/MCP), diff view approve/reject (plain `git apply` after `--check`; no `--3way`), settings, health. App = interactive priority, MCP jobs = background (`paused_interactive`). `scripts/make-app.sh` builds and ad-hoc signs `Strim.app`. Unknowns: metallib location in bundle; relative draft-vocab lookup (install `<model>/draft_vocab.json`).

## Harness2 (vendor/harness2)
Adopt: component pack on disk (system, guardrails, memory, tool guidance, subagents, skills; always-on <=~3K tokens); Codex-compatible `AGENTS.md` + `.agents/skills/*/SKILL.md` (index in prompt, bodies lazy); in-process read-only `task` subagent (fork of system prefix, 1 level, 1 concurrent); pack fingerprint per job/bench row; `events.jsonl` trajectories; optional `strim evolve` (propose/probe/compose, deterministic test checks as judge, k<=2, background priority).
Do not adopt: its Python, OpenCode/Codex substrates, Linux/Node/Docker benchmarks, cloud proposers, disabled sandbox, LLM judging without ground truth, wide parallel k.

## Tests and bench
Unit with `FakeEngine`/`RawClient` (no GPU). Live under `lockf -k /tmp/strim-bench.lock`: curl smoke, then real Claude Code and Codex (isolated config dirs). `strim agentbench`: arms H (harness via jobs), C (Claude Code+Strim), X (Codex+Strim), interleaved; soak toy tasks + harder set. Accept: H >= 85% on mathkit, median wall <= C. Security suite: injected README/comments, traversal/symlink, network, destructive commands, planted token; assert no network, no writes outside worktree, parent tree hash unchanged, token redacted.

## Waves
- W0 scaffolding (targets, interfaces, FakeEngine copy)
- W1 harness core: policy+redactor, sandbox+runner, file tools, worktree, loop+compaction, pack loader
- W2 jobs + MCP: JobManager, protocol/route, tools/render, server registration + `strim mcp-config`, Claude subagent def + Codex snippet + docs
- W3 live smoke + real clients
- W4 app: StrimHost, app shell, chat, jobs/diff, settings, make-app
- W5 `strim agentbench`, hard tasks, security suite, run
- W6 `task` subagent, optional `strim evolve`
- W7 Python port-then-delete

## Python port-then-delete (delete only after the gate passes)
| Python | Swift replacement | gate |
|---|---|---|
| `service/strimd.py`, `strim_front.py`, `bench/smoke_service.py`, `test_mcp_gate.py`, `test_priority*.py`, `test_strim_front.py` | `strim serve` + `/mcp` | W3 smoke; Swift priority + MCP tests |
| `bench/test_tool_bridge.py` | adapter tests + tokenizer id test (248058/248059/248066/248067) | green |
| `integrations/harness2/run_local_codex.sh` | rewrite for 8203 or delete | n/a |
| `harness/qwen/scripts/context_pack.py` | `strim pack` | identical output on fixture repo |
| `bench/soak/soak.py` | `strim soak` | 10-min run each, outcomes +-1 |
| `bench/agent_replay.py` | `strim replay` | TTFT within 5% over 3 interleaved runs |
| `bench/scoreboard.py`, `compare.py`, `screen.py` | `strim bench http` | medians within 5% |
| `bench/tasks/run_task.py` | `strim agentbench` | W5 |
| `bench/tokenizer_oracle.py`, `bench/oracle/*.py`, longctx `tokenize.py` | committed fixtures as data + `strim tokenize` | Swift parity tests green |
| `ref_*.py`, `probe_ref.py`, `speed.py`, `needle.py`, `lookup_stats.py`, `bench/spike/*` | frozen reference outputs | files committed |
| `bench/download.py` | `strim download` (aria2c + sha256) | same digest |
| `scripts/build_site.py` | `strim site` | byte-identical site + README |
| `scripts/gen_draft_vocab.py` | frozen `bench/draft_vocab_48k.json` | committed |
| `scripts/mcp_stats.py` | `/metrics` job counters | present |
Accepted loss: oracle fixtures cannot be regenerated after deletion. Order: server/MCP, then soak/replay/bench, then oracles/refs.

## Kill criteria
- H < Codex/Claude arm - 10 pp after tuning: keep jobs/MCP, swap executor to `codex exec` against `strim serve`.
- `sandbox-exec` breaks toolchains or is removed: disable bash in MCP mode; app approves each command.
- App-hosted engine UI-rebuild warm-up > 15 s or > 1 crash/week: launchd host.
- `strim evolve` < 5 pp over 3 runs: drop.

## Risks
Interactive chat starves MCP jobs; patch text can inject the parent agent; post-fix trie memory unverified so 2 jobs + chat may be refused by admission; nested sandbox for SwiftPM; no enforced `tool_choice` (plain-text answers end the turn).

## Unverified
Codex default tool timeout; whether progress resets client timeouts; `structuredContent` rendering; MCP tasks support; real cause of Codex `mcp__strim` failure; Claude `headersHelper` usage; sandbox-exec deprecation; metallib path in bundle; signing identity; post-fix memory per trie node; `swift build/test` on HEAD.

## Addendum: final Opus plan (details added after the first draft)
- Server hook: `StrimOpenAIServer.addGuardedRoute(method, path, handler)` (wraps `guarded()`), so StrimServer does not depend on StrimMCP; the exact `/mcp` route must win over the catch-all `/` prefix route (test it). Pack text is embedded as Swift string constants, not a resource bundle.
- Tool order is fixed: read_file, list_files, grep, edit_file, write_file, bash, task, finish. Prompt segments: 0 system (tools + pack, no dates/paths/access level, 3-4K tokens), 1 user#1 (env, AGENTS.md, skill index, context, task), then append-only turns. Compaction above 28K tokens (soft 24K): new session with identical segments 0-1, a model-written `<progress>` summary (<=1.5K tokens) and the last 2 turns.
- Job states: queued -> preparing -> [awaiting_approval] -> running <-> paused_interactive -> finalizing -> done|limit|failed; cancel from any non-terminal state -> cancelling -> cancelled; persisted non-terminal jobs become failed(host_restart) at start; retention 7 days / newest 50. Job folder `~/.strim/jobs/<id>/` (0700): job.json, events.jsonl, patch.diff, result.json, transcript.txt.
- Scheduling: app chat = interactive, MCP jobs/ask/subagents = background (background pauses while interactive runs; paused time not counted against limits); one MCP job at a time (2 hot sessions); admission rejection retries 3x at 10 s. Prefetch of the fixed system prompt at host start.
- Limits: UI 80 turns / 30 min / 120K tokens; MCP 40 / 15 min / 60K; strim_ask 4 turns / 40 s.
- Acceptance: harness >= 85% (34/40) on toy tasks (Claude Code+Strim 17/20, Codex+Strim 16/20 in the partial soak); hard set H >= C - 5 pp; median wall <= C; Claude-parent delegation >= 8/10; parent tokens per delegated task <= 3K; job first token <= 2.5 s; per-turn first token p50 <= 1.0 s / p90 <= 2.5 s; app chat first token <= 0.8 s warm; single-job decode >= 55 tok/s; security suite 0 escapes (hard gate).
- Open questions for the user (defaults in brackets): app chat edits via worktree+diff approval [yes]; MCP may request access=write without per-job approval [yes, worktree only]; token stored in Claude MCP config header [accept for now]; launch at login [default on]; signing [ad-hoc].

## Addendum 2: goal = save Anthropic/Codex subscription tokens (user, 2026-10-26)
The MCP exists to extend weekly limits of the Claude and Codex subscriptions by moving routine work to the free local model. Requirements added:
- **Parent-token budget is a first-class metric.** Bench arm M (Claude/Codex parent delegating via strim_task) vs arm P (same parent doing the same task alone): measure parent input+output tokens and cost per task (from the client's JSON usage), pass rate, wall time. Success = median parent tokens saved >= 50% at equal pass rate after counting failed delegations that the parent redoes; report net savings including retries. Kill if net savings < 20%.
- **Polling must be nearly free.** A not-done `strim_job` reply is a one-line status (<= ~60 tokens, no progress dump); `wait_s` max 25 but prefer a blocking `strim_task` wait; progress goes via MCP progress notifications (not model tokens). Budget: <= 3K parent tokens per delegated task including tool schemas.
- **Small, stable tool surface** (4 tools, short descriptions) because the schemas cost parent tokens every session. Results: short summary + patch_path; inline patch only when small (cap lower than 16 KB if it hurts the budget).
- **Delegation guidance** in tool descriptions and the Claude subagent definition targets high-token-volume work: file exploration, test-fix loops, repo questions, boilerplate. The local agent does the reading/iterating; the parent only reviews a short summary and diff.
- Risk: a failed delegation costs the parent extra tokens; the summary must state status honestly (limit/failed) so the parent can bail early.

> Note (2026-10-27): the scripts named in this plan that were Python (service/strimd.py, bench/spike, bench/test_*.py, context_pack.py, oracle scripts) were removed 2026-10-27; they are in the history bundle.
