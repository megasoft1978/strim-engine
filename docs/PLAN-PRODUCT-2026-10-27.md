# Product plan: prove the token saving, then build the app (Opus review, 2026-10-27)

Supersedes the build order in `PLAN-AGENT-HARNESS-2026-10-26.md`. Everything stays Swift.

## Decision
Prove the token saving before building anything else. Two changes come first:
1. `strim_task` takes a required `verify` command. The harness runs it itself in the worktree and reports `verified | failed | unverified`.
2. A 3-arm benchmark (H, M, P) on 30 real tasks decides whether the MCP stays the differentiator.

The menu-bar app comes after that gate, as a thin client of one launchd-hosted `strim serve`.

## A. Risks and kill criterion
- Measured on a one-line fix: delegated 29.9K total input over 3 turns, alone 25.5K over 5 turns. On small tasks delegation does not save.
- Delegation adds about 3 parent turns (call, apply, verify). Working hypothesis: it wins only when solo work would take 6+ tool turns or 15K+ tokens of tool output. M1 calibrates this.
- Fixed tax: the 4 tool definitions cost about 1.3K tokens, re-read on every parent turn.
- The parent's review burden returns unless the result is machine-verified. A false "done" costs delegation plus the full solo cost.
- Unknown: how subscription weekly limits weigh cache reads and output. Proxy: Claude `total_cost_usd`; Codex uncached + 0.1 x cached + output.
- Go: some task class shows median net parent-cost saving >= 40% (failed delegations and redo counted), pass rate >= P - 5 pp, wall time <= 2.5x P, n >= 10 tasks x 2 reps per arm.
- Kill the MCP as the differentiator if every class stays under 20% after 2 tuning rounds. The product then becomes the fastest local Qwen server plus app.

## B. Architecture: one core, daemon first
- launchd-hosted `strim serve` is the default host. The app is a client and never links MLX.
- `EngineSlot` (StrimHost): optional `EngineClient` with `load`, `unload`, `state`. Test that unload lowers MLX active memory (unverified).
- `RunProfile` in StrimHarness: `.delegated` (40 turns, 15 min, background priority, verify required) and `.interactive` (80 turns, 30 min, live streaming, patch approval). Only difference between chat and MCP.
- Every run is a StrimJobs job; a chat session is a job that accepts `appendUserTurn` (new).
- `StrimControl`: guarded routes on the same server: `GET /v1/strim/status`, SSE `/v1/strim/events`, `POST /v1/strim/load|unload`, jobs list/approve/reject/apply, chat open/append/cancel.
- `StrimAPI`: Codable DTOs only. `StrimApp`: SwiftUI on `StrimAPI`.
- The parent tree is written only by an explicit UI Apply (`git apply --3way`) or by the MCP parent applying the patch.

## C. Self-optimization (harness2-inspired, deterministic)
- Search space: system prompt variants, per-tool guidance, per-class playbooks (test-fix, repo QA, mechanical edit), result formatting caps, compaction prompt and thresholds, thinking on the first planning turn only, temperature 0 vs 0.6. Tool order fixed.
- Never searchable: sandbox profile, HostPolicy, deny lists, redactor, limit ceilings, verify command, MCP surface. A test hashes policy and sandbox sources before and after an evolve run.
- Fitness: hidden verify passes (test files hash-restored); -2 per false-done; tie-break local tokens then wall time.
- Corpus: about 60 tasks mined from git history (revert a commit that has tests) plus repo-QA with file:line answers. Split 60/20/20 train/val/test; test frozen until release.
- Adopt a candidate only if val improves >= 5 pp paired over 2 reps and test does not regress.
- v0 `strim evolve`: coordinate ascent over a hand-written candidate list, no proposer; output `~/.strim/packs/<fingerprint>`. v2 (local-model proposer) only after v0 shows a gain.

## D. Menu-bar app
Stats: host state, model + MTP head, memory (weights, prefix trie, MLX cache, headroom), decode and prefill tok/s, MTP acceptance and depth, prefix-cache hit rate and saved prefill seconds, active and queued jobs by source, tokens today, estimated parent tokens saved (marked as estimate), uptime and last crash.
Controls: load/unload, model picker, pause background jobs, cancel job, open window, copy MCP registration commands, launch at login.
Window: project picker, streaming chat with tool cards and collapsible reasoning, per-turn token ledger, thinking toggle, job queue with verify result, diff view with Apply/Reject, pack fingerprint and evolve results, health.
Do not build: multi-model or cloud backends, marketplace, editor, generic MCP manager, plugins, image or voice input, session sync, Python.

## E. Routing for the parent
Delegate only when all hold: a verify command or file:line check exists; the task fits in about 150 words; expected solo cost >= 6 tool turns or >= 15K tool-output tokens. Never delegate design, cross-cutting refactors, security code, or no-oracle tasks.
Fallback: `verified` -> apply; `failed|limit|unverified` -> do it alone; at most 1 delegation per task. The local model may decline on turn 1.
Claude: heuristics in `integrations/claude/agents/strim-local.md` with `model: haiku` (confirm on this Claude Code version); trust `verified`. Codex: AGENTS.md snippet. Consider merging to 2 tools after measuring.
Measurement: arms P, M, H, C interleaved on the same snapshot; 3 classes x 10 tasks x 2 reps x (P, M) = about 120 parent runs; plus a tax arm (10 non-delegable tasks with and without the MCP).

## F. Tests
Layers: property tests for parsers/paths/redactor; FakeEngine golden replays; job state machine table with cancel at every state (100% transitions); fault injection (engine throw/stall, admission rejection, SIGKILL mid-job, full disk, worktree failure, missing sandbox-exec); client-quirk MCP goldens; engine gates X1-X4; security suite (0 escapes); nightly live E2E; UI view-models against a fake StrimAPI.
Static rule: grep test for `!` unwraps, `try!`, `fatalError` outside Core. Coverage >= 90% lines on policy, sandbox, file tools, redactor, JobManager, MCP.

## G. Delivery order
- M0: finish benchmark and soak; no `Sources/` merges meanwhile.
- M1 (thesis gate): verify argument and status; 30-task corpus in `bench/agenttasks/`; Swift `strim agentbench` (arms H, C, M, P); subagent with routing heuristics; run about 120 parent runs with the budget agreed first.
- M2: manual pack tuning, then evolve v0. Gate: val +5 pp, false-done <= 5%.
- M3: EngineSlot, StrimControl, StrimAPI, launchd plist.
- M4: menu-bar app. M5: chat window. M6: delete Python (any time after M1).
- Cut or defer: `task` subagent, arm X, 35B MoE, disk prefix cache, in-batch MTP, LLM proposer.

Unknowns: weekly-limit weighting, Claude Code `model:` frontmatter and MCP schema deferral, MLX memory on unload, hard-task pass rate of the 27B model, libFuzzer on this toolchain.
