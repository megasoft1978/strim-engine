# Real Claude Code + Codex -> Strim MCP, 2026-10-27

Setup: `swift build -c release --disable-sandbox`; `strim serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8212 --token-file ~/.strim/token` under `lockf -k /tmp/strim-bench.lock`. Claude Code 2.1.311, Codex 0.164.0. Driver: `bench/mcp/clients.py` (`python3 -I`); per-run streams, stderr and rows in `runs/`; registration transcripts in `register_claude.txt` and `runs/codex_*/register.txt`. Token never printed or stored (grep of this dir and the script: 0 hits).

Isolation deviations (honest):
- Claude: `claude mcp add` with the exact printed command (plus `-s user`) was run in an isolated CLAUDE_CONFIG_DIR and verified (`claude mcp list`: Connected). But an isolated config dir has no login (`claude auth status`: loggedIn false; keychain creds are per config dir), so the model runs used the normal CLAUDE_CONFIG_DIR for auth only, with `--strict-mcp-config --mcp-config <0600 temp json>` (same URL + Bearer header), `--setting-sources ""`, `--no-session-persistence`. User config was not modified. Parent model alias `sonnet`. Builtin tools identical in all runs (`--tools Read,Edit,Write,Glob,Grep,Bash`); MCP runs allow only the 4 strim tools, Read, `git apply`/`git diff`/unittest/git status.
- Codex: isolated CODEX_HOME in a temp dir, `codex mcp add strim --url ... --bearer-token-env-var STRIM_TOKEN`, STRIM_TOKEN only in the child env, auth.json copied into the temp home (deleted with it), `approval_policy="never"`, `-s workspace-write`.

## Runs (n=1 each, real subscriptions)

Claude token columns: uncached input / cache-creation / cache-read / output. "Parent total in" = sum of the first three.

| run | client | server | prompt | success (deterministic check) | parent in (uncached/create/read) | out | cost | strim_job polls | wall | patch applied |
|---|---|---|---|---|---|---|---|---|---|---|
| claude_a_ask_stock | Claude | stock | strim_ask about slugify | FAIL: parent got no answer | 8 / 9568 / 27849 | 452 | $0.0456 | 2 (+1 events_since) | 13.6 s | n/a |
| claude_a_ask | Claude | patched* | same | PASS (answer correct, 1 sentence) | 4 / 9439 / 9106 | 290 | $0.0416 | 0 | 11.4 s | n/a |
| claude_b_fix_delegated | Claude | patched* | strim_task fix_slugify, git apply, test | PASS (unittest SlugifyTests, tests unchanged) | 6 / 4058 / 25879 | 582 | $0.0247 | 0 (done within wait_s) | 14.5 s | yes |
| claude_c_fix_alone | Claude | none | same fix, parent alone | PASS | 6 / 3934 / 21531 | 750 | $0.0254 | n/a | 8.3 s | n/a (Edit) |
| claude_d_nomcp_hello | Claude | none | "Reply ok" | n/a | 2 / 2556 / 5148 | 4 | $0.0108 | | 3.2 s | |
| claude_e_mcp_hello | Claude | patched* | "Reply ok" | n/a | 2 / 2655 / 6358 | 4 | $0.0113 | | 2.6 s | |
| codex_a_ask | Codex | stock | list tools, strim_ask | FAIL: all 4 tools listed, call rejected "MCP tool call requires approval, but approval policy is never" | 46813 total (42880 cached) | 227 | n/a | 0 | 14.1 s | n/a |
| codex_b_fix | Codex | stock | strim_task fix_slugify, apply, test | PASS (check ok, tests unchanged) | 81462 total (76160 cached) | 475 | n/a | 1 | 25.9 s | yes (`git apply patch_path`) |

*patched = scratch copy of the repo (scratchpad, not in the repo) with `structuredContent` omitted from tools/call results in `MCPRoute.render`; nothing under Sources/ was edited. Total Claude parent runs: 6 of 6 allowed; Codex 2 of 3.

## Findings

Claude Code 2.1.311 forwards only `structuredContent` to the model when it is present. The stock server returns text = full result and structuredContent = `{"job_id","status","done"}` (+`patch_path`), so Claude saw only `{"job_id":"...","status":"done","done":true}` for every finished job and could not read the answer (run a stock: it polled twice, asked for events, then gave up). With structuredContent removed the same prompt passed. Codex forwards `content` and works with the stock server. This means the stock Swift MCP does not work with real Claude Code today, which the curl smoke could not reveal.

Token comparison, fix_slugify, Claude parent (n=1):
- Delegated: out 582, total input 29943 (cache dominated), cost $0.0247, 3 turns.
- Parent alone: out 750, total input 25471, cost $0.0254, 5 turns.
- Net: no meaningful parent saving on this trivial task (-22% output tokens, +18% input tokens, -3% cost: all within cache and sampling noise). The task is a 1-line fix, below the break-even; the saving case (long exploration/test loops) was not tested here. The local job itself took 5.8 s (13.5k prompt / 364 completion local tokens, zero Anthropic cost).

tools/list cost to the parent: first-turn total input (uncached+create+read) 7706 without MCP vs 9015 with the 4 strim tools = +1309 tokens (~914 est. tool JSON plus Claude's per-tool wrapper/prompt text). Billed as cache read after the first turn.

Codex: 0.164 did NOT show the README's `unsupported call: mcp__strim` error. It listed `strim_ask, strim_cancel, strim_job, strim_task` and invoked them. The first run failed on approval (see bug 2), the second succeeded with `default_tools_approval_mode = "approve"` appended to the isolated `[mcp_servers.strim]` config. `integrations/harness2/README.md` note is stale or specific to that harness config.

## Bugs

1. Claude Code reads only structuredContent: result invisible to the parent. Repro: `strim serve`, `claude mcp add ...`, `claude -p "Use strim_ask ... " --allowedTools mcp__strim__strim_ask mcp__strim__strim_job`; strim_job returns text with the summary but structuredContent `{job_id,status,done}`; `runs/claude_a_ask_stock/stream.jsonl` shows tool_result = the structured JSON only. Suspect `Sources/StrimMCP/ResultRender.swift` (`structuredJSON`, comment "Minimal on purpose") and `MCPRoute.swift:188`. Fix options: drop structuredContent, or put the same full text/summary/patch_path/status in it (verified: omitting it makes Claude Code pass). Also contradicts smoke finding 7 (it assumed clients forward both).
2. Codex rejects every strim call under `approval_policy=never` / `codex exec`: "MCP tool call requires approval". Tools declare no annotations (`grep annotations Sources/StrimMCP`: none). Suspect `Tools.swift` tool definitions: add `annotations` (`readOnlyHint:true` for strim_ask/strim_job, `openWorldHint:false`; `destructiveHint:false` for strim_task/strim_cancel) and document `default_tools_approval_mode="approve"` in `strim mcp-config --codex` output and `integrations/codex/strim-mcp.toml`.
3. `strim mcp-config --claude` output omits `-s user`: default local scope is per project path, so the registration is invisible from other directories. Minor (`Cmd_*` mcp-config).
4. Tool-description gap: the parent polled strim_job although strim_task had already returned the finished result (Codex run: 1 redundant poll; Claude stock run: polled because the result was invisible). Minor; consider stating in the strim_task description that `done:true` needs no poll.
5. Smoke bugs 1 to 5 from `bench/results/mcp-smoke-20261027/summary.md` not re-tested.

## Caveats

- n=1 per cell; parent output varies run to run; Claude prompt-cache state differs between runs (cache_read vs cache_create shifts between runs, e.g. runs d/e), so compare totals and cost, not the split. Cost is computed by Claude Code, Codex reports no cost; Codex tokens include its ~40k fixed system prompt.
- The parent-saving claim is not supported by this test (trivial task); do not cite it as evidence of savings.
- Three of the Claude runs used a patched scratch build, not the shipped binary; stock Claude result is the FAIL row.
- The test itself consumed 6 Claude parent runs (about $0.15 total by Claude Code's estimate) and 2 Codex runs from the user's subscriptions.
- Isolated Claude config could not be used for model runs (no login); isolation was via strict MCP config and empty setting sources only.

## Rerun after fixes (720308a, 023ba21), 2026-10-27

Stock release build of HEAD (no patched copy), `strim serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8213` under `lockf -k /tmp/strim-bench.lock`, server pid killed at end. Same driver (`STRIM_RERUN=1 STRIM_PORT=8213 python3 -I bench/mcp/clients.py ...`), same isolation as above (Claude: normal config dir for auth only + strict MCP config; Codex: temp CODEX_HOME with the config from `strim mcp-config --codex`, i.e. `default_tools_approval_mode="approve"`). Per-run files in `rerun/runs/`, registration in `rerun/register_claude.txt` and `rerun/runs/codex_*/register.txt`. Token grep of bench/mcp and this dir: 0 hits. n=1 each. Budget used: 2 Claude parent runs of 3, 2 Codex runs of 2.

| run | client | success | parent tokens | polls | wall |
|---|---|---|---|---|---|
| claude_a_ask | Claude | PASS (answer read correctly via text) | in 4 / create 9352 / read 9039; out 270; $0.0410 | 0 | 9.6 s |
| claude_b_fix_delegated | Claude | PASS (git apply ok, SlugifyTests pass, tests unchanged) | in 6 / create 4062 / read 25972; out 623; $0.0251 | 0 | 13.3 s |
| codex_a_ask | Codex | PASS (4 tools listed, strim_ask completed, no approval error) | 46903 in (42880 cached); out 229 | 0 | 16.5 s |
| codex_b_fix | Codex | PASS (check ok, patch applied, tests unchanged) | 96386 in (91392 cached); out 474 | 1 | 25.7 s |

Findings:
- Bug 1 (Claude reads only structuredContent): fixed. Stock server now works with real Claude Code; before: FAIL, now PASS in both runs. Matches the earlier patched-copy numbers (a: 11.4 s, b: 14.5 s).
- Bug 2 (Codex approval): fixed by the printed config line. Both Codex calls ran under `approval_policy="never"` with no rejection. Not tested without the line (the tool annotations alone were not isolated).
- DONE prefix: Claude 0 polls in both runs (strim_task finished inside wait_s and returned the result). Codex fix run: 1 poll, which was legitimate: strim_task returned "running turn 1/40 ... (poll strim_job)" and the single strim_job(wait_s=50) returned "DONE ...". Codex ask run 0 polls.
- Bug 3: `strim mcp-config --claude` now prints `-s user`. Run verbatim (token via `$(cat ~/.strim/token)`) in an isolated CLAUDE_CONFIG_DIR: add rc 0, `claude mcp list` Connected, `mcp get`: Scope User config (available in all your projects). Works. Model runs still use the normal config dir for auth (isolated dir has no login), as before.
- Printed port: `--port 8213` is reflected in both printed commands.
- No new bugs found. Caveats from above unchanged (n=1, trivial task, cache split noise; Codex tokens include ~40k fixed prompt; the delegated-vs-alone saving claim is still unsupported).
- Driver change: `bench/mcp/clients.py` gained env `STRIM_RERUN` (outputs to `rerun/`), `STRIM_PORT`, and no longer double-adds `-s user` when already printed.

## Harness change after these runs (Swift port, 44253a5 and later)

- These runs used the retired Python driver: the baseline arm had Bash (go test, git diff/status) and the MCP arm had the token in its whole environment. Both are removed. Neither Claude arm has a shell now; the harness runs the fixture check after the client exits.
- The baseline `claude_c_fix_alone` case cannot self-test (no shell). Its verdict is the harness check, not the model report, so its PASS/FAIL here is not comparable to a rerun.
- The Claude client now runs under sandbox-exec; live results from the sandboxed client are not yet recorded (no live run was made).
