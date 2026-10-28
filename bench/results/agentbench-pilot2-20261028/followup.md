# AgentBench pilot 2 follow-up analysis (2026-10-28)

Analysis only, from `ledger.jsonl`, the per-run `stream.jsonl` transcripts and the sources. No runs, no network, no engine. Parent thinking blocks are redacted in the streams (empty text, signature only), so decisions are inferred from tool calls and visible text, not from quoted reasoning.

## Headline finding: the paid arms had no Bash
`Executors.swift` gives Bash only to the local arm C (`hasBash = false` for paid P/M; `--disallowedTools Bash`). The init event of every P/M stream lists tools `Edit, Glob, Grep, Read, Write` (+ the 4 `mcp__strim__*` in M). Consequences:
- P/M parents on test-fix tasks cannot run the test suite, cannot see the failing assertion, and cannot verify. The task prompt tells them to run `go test` / `swift test`; the first call is a Bash attempt that errors (`No such tool available: Bash. Bash is disabled for this session, in subagents as well as here.`) in tf-02-M, tf-11-M, tf-11-P. Every P/M final message says "I couldn't run the tests / unverified".
- In arm M, the only way to run anything is `strim_task`. That inverts the routing heuristic: "solo cost >= 6 turns" is meaningless when solo cannot run the verify at all. It is also not the real-world condition (a real Claude Code user has Bash).
- The pilot therefore measured "edit blind" (P) vs "edit blind + optional delegation" (M), not P vs M under realistic conditions.

## (1) Why tf-02 fails in every arm
Verdict: genuine difficulty (two-site fix), made unwinnable-in-practice for P/M by the missing Bash. Not a task bug or unfair verify.
- Task is sound: `solution.patch` touches two files, `bigbytes.go` (`humanateBigBytes`, promote when `val >= base-0.5`) and `bytes.go` (`humanateBytes`, promote after rounding). Corpus `validate` requires verify to fail on snapshot and pass with the patch. Tests are hash-checked; no tampering flagged (`tests_tampered=false`).
- Final verify output in all three arms: `bigbytes_test.go:185: format(1048575) = "1024 KiB", want "1.0 MiB"` (package `humanize` FAIL, `english` ok). That is the `big.Int` path in `bigbytes.go`, which none of the arms fixed.
- P (19 turns, $0.275) and M (17 turns, $0.165): both read all ~15 source files, then edited only `bytes.go` (the `bytes_test.go` failure they could infer by reading `TestBytesPromoteRoundedUnits`). P additionally added a `math/big` helper `roundScaled`. M read `bigbytes.go` and wrote "I found nothing else obviously wrong". Neither could discover the `format(1048575)` failure without running tests; both disclosed it was unverified.
- C (local Qwen, with Bash): found both files at call 3-6 (read `bigbytes_test.go`, `big.go`, `oomm`), then spent ~135 tool calls in an edit/test loop on `oomm` rounding semantics (round-half-up vs even, a compiled-test-binary inspection detour, stale-cache hypothesis) and hit the 900 s timeout. So the 4B model understood the problem but could not converge: genuine difficulty for it.
- Task difficulty note: `est_solo_turns: 7` in task.json is optimistic for a two-file numeric edge-case fix with float/big.Int rounding.

## (2) Why arm M delegated 1/6
Counts: me-06 0, me-07 0, qa-01 0, qa-07 0, tf-11 0, tf-02 1 (a failed attempt). Evidence per run:
- me-06 (9 turns), me-07 (7): grep, 3-5 Edits, one Grep to confirm, done. Parent knew the whole job after one grep; "I don't have a shell tool, so I'll check with Grep" (me-06). Solo cost ~37-47K tokens, but the model judged it tiny. No `strim_*` call.
- qa-01 (2 turns), qa-07 (4): one or two Greps answered the question. Far below 6 turns / 15K tool-output tokens (parent total 23-33K is almost all cache-read of system prompt + the 4 tool schemas).
- tf-11 (6 turns): first call `swift test` -> Bash unavailable; then Glob, Read source, Read test, one Edit, "Bug: when full, append overwrites at the tail, which equals head, but head isn't advanced." A 1-file fix visible by reading; did not delegate to run the test even though it said "I haven't run the tests".
- tf-02 (17 turns): the one delegation. Call 1 Bash fails; call 2 `strim_task` "Run `go test -count=1 ./...` and report the failures verbatim" with `cwd=/var/folders/.../runs/tf-02-M-1`. Result: `cwd ... is outside the allowed roots (mcp.allowedRoots in ~/.strim/config.json)`. The parent never retried (heuristic: "at most one delegation per task"; failure -> "do the task yourself") and read 15 files by hand. Note the path was `/var/...` while the run dir is `/private/var/...` (symlink); allowedRoots likely holds one spelling. Never reached the model; the "delegation" cost nothing and saved nothing. The M-vs-P tf-02 gap (-$0.11) is read-count variance, not delegation.
Diagnosis (ranked):
1. Task sizes below threshold: 5 of 6 tasks needed 2-11 turns, and the heuristic says do-it-yourself under 6 turns. Largely correct behavior for the prompt; not a heuristic bug per se.
2. Missing Bash makes the "oracle" half of the pitch unusable for the parent: the only tool that can run verify is the delegate, yet the guidance frames delegation as optional token-saving. The one task that clearly needed it (tf-02) is the one where delegation was attempted, and it broke on a config guard.
3. Heuristic too strict in combination: all 4 conditions must hold, includes "fits in 150 words" and "at least 6 turns" (an estimate the parent cannot make before starting) and "at most one delegation, do not retry" after a trivially fixable error. A cwd/config error is treated like a model failure.
4. Tool description is attractive enough ("free local coding agent that reads and iterates so you spend no tokens"), but ends "Skip vague, tiny or security-sensitive work", which pushes the same direction as the system prompt. Not the primary cause; 4 schemas add ~1.3K tokens/turn (plan section A), which is the +19% token tax visible on qa-01 (23.5K vs 26.3K total is flat; me-06 +20%).
5. The `strim-local.md` subagent file is not used by the harness: M passes the guidance via `--append-system-prompt` and calls the MCP tools from the parent directly (init `agents` list has no strim-local). So the `model: haiku` subagent path in plan section E was not exercised at all.

## (3) Per-task table (one rep each; parent tokens = in+cache+out; cost = parent USD; turns = parent tool turns; C = local, no paid cost, tokens = local prompt+completion)
| task | class | P pass / turns / tokens / $ / wall | M pass / turns / tokens / $ / wall / deleg | C pass / turns / tokens / wall |
|---|---|---|---|---|
| me-06 | mech-edit | ok / 10 / 39,077 / 0.0433 / 24.5s | ok / 9 / 46,871 / 0.0588 / 20.9s / 0 | ok / 9 / 42,080 / 57.9s |
| me-07 | mech-edit | ok / 11 / 41,582 / 0.0447 / 26.0s | ok / 7 / 36,965 / 0.0337 / 18.9s / 0 | ok / 23 / 174,453 / 136.2s |
| qa-01 | repo-qa | ok / 3 / 26,252 / 0.0469 / 15.3s | ok / 2 / 23,497 / 0.0465 / 12.5s / 0 | ok / 5 / 19,159 / 24.1s |
| qa-07 | repo-qa | ok / 3 / 20,479 / 0.0204 / 14.6s | ok / 4 / 32,910 / 0.0228 / 14.3s / 0 | ok / 5 / 19,529 / 20.2s |
| tf-02 | test-fix | FAIL / 19 / 213,109 / 0.2751 / 79.6s | FAIL / 17 / 172,564 / 0.1645 / 44.2s / 1 (errored) | FAIL (timeout) / n/a / n/a / 900.3s |
| tf-11 | test-fix | ok / 6 / 28,183 / 0.0289 / 17.3s | ok / 6 / 43,381 / 0.0323 / 17.4s / 0 | ok / 10 / 67,332 / 78.4s |
| total | | 5/6, 0.459 | 5/6, 0.359 | 5/6 |
Tokens in M exceed P on 4 of 6 tasks (me-06, qa-07, tf-11 clearly): with no delegation the tool-schema/guidance overhead is a pure tax. Savings anywhere come from fewer reads, not from delegation.

## (4) Proposed changes (not applied)
Harness / corpus (fix before spending anything):
1. Give P and M a scoped Bash (verify-command prefixes via `BashAllow.allowedPrefixes`, as arm C has), or explicitly document and test the no-Bash condition as its own arm. Without this, P is a handicapped baseline and M's value is confounded. If paid-credential risk is the reason for no Bash, allow only `go test`/`swift test`/`git apply` under the existing sandbox profile.
2. Make `mcp.allowedRoots` match the real (`/private/var/...`) spelling or canonicalize `cwd` with `realpath` in the MCP before the check; add a harness preflight that does one `strim_task` dry call from the run dir. Treat a cwd/config error as infra, not a delegation.
3. tf-02: keep (valid, hard). Add a hint-free split: also include a one-file test-fix of similar difficulty so one failing task does not decide a class. Update `est_solo_turns` to ~15 for tf-02. Corpus pass rate on easy tasks is saturated (5/6 everywhere), so it cannot discriminate arms.
4. Add tasks where solo cost is large by construction: Swift tf-12..18 (never run), Go tf-03..05, plus 2-3 new "long loop" tasks (multi-failure suites, 3+ files, slow verify), and non-delegable controls (tax arm).
Routing text:
5. Reword `routingGuidance` and `strim-local.md`: drop the "estimate 6 turns" gate; use observable triggers: "a verify command exists AND the first read shows the fix spans >1 file or the verify output is long/iterative" or simply "if you cannot run the tests yourself, delegate the run-and-fix loop". Allow one retry for config/path errors (non-model failures). Show the exact `cwd` string to use.
6. Tool description: lead with the benefit for the parent ("runs the test-fix loop and returns a verified patch; you only apply it"), remove "Skip ... tiny" from the tool text (keep it in the routing prompt only), and cut the 4 schemas' size (merge `strim_job`/`strim_cancel`, plan already considers 2 tools) to reduce the per-turn tax.
Task classes to test next: test-fix (multi-file, Swift and Go), long mechanical-edit (10+ files), repo-qa with deep traversal (multi-hop). Skip single-grep QA and one-file renames: the parent finishes in 2-9 turns and delegation cannot win there.

## Stage 2 recommendation
Do NOT run the 120-run stage 2. Run a pilot 3 first after changes 1, 2 (required) and 5 (recommended):
- Scope: 6 harder tasks (tf-02, tf-03, tf-12, tf-14, one long me, one multi-hop qa) x arms P, M x 2 reps = 24 paid runs.
- Cost: pilot averaged $0.068/run (0.818/12) but was dominated by trivial tasks; test-fix runs cost $0.16-0.28 each. Estimate $0.12-0.20 avg on harder tasks: 24 runs about $3-5 (call it $5 cap with Bash enabled, which adds turns). Local arm C is free.
- Gate before any larger spend: M delegation rate >= 50% on these tasks and zero config-error delegations. Only then scale reps. Full stage 2 at this per-run price (120 runs at 0.07-0.2) would be roughly $8-24, still cheap in money but pointless until the baseline is fair.
- Go/kill math remains undecidable at n=6x1; the pilot's "-19% tokens / -9% cost" is mostly noise plus the schema tax.
