# AgentBench paid pilot 2 (2026-10-28): 18/18 runs completed, 0 infra errors

Command: `lockf -t 3600 -k /tmp/strim-bench.lock strim agentbench run --arms C,P,M --task-ids tf-02,tf-11,me-06,me-07,qa-01,qa-07 --allow-paid --max-parent-runs 12 --lock-held --model models/qwen38-4bit` (release build of the fix commits on top of c2be1ff; engine `strim serve` spawned by the runner, memory watchdog: SIGTERM at phys_footprint > 42 GB or swap +2 GB; never fired, peak footprint 25 GB, swap flat). Parent model alias `sonnet`. 6 tasks x arms C, P, M x 1 rep.

## Result
- Runs completed: 18 of 18 (12 paid parent runs, 6 local arm C). Infra errors: 0 in the kept ledger. Paid parent cost reported: 0.818 USD total (P 0.459, M 0.359).
- Pass rate overall: C 5/6, P 5/6, M 5/6. All three arms failed tf-02 (a test-fix on the Go corpus: `format(1048575)` still wrong); C timed out at 900 s on it. Everything else passed.

| class (2 tasks each) | C | P | M |
|---|---|---|---|
| mechanical-edit | 2/2 | 2/2 | 2/2 |
| repo-qa | 2/2 | 2/2 | 2/2 |
| test-fix | 1/2 | 1/2 | 1/2 |

## Metrics (n = 6 per arm, 1 rep)
- Median parent cost: P 0.0440 USD, M 0.0401 USD (-9%). Median parent tokens: P 33,630, M 40,173 (+19%, i.e. no token saving).
- Delegation net saving (M vs P): none measurable. Total cost -22% is driven by tf-02 (P 0.275 vs M 0.165) where M delegated once; on the other 5 tasks M and P are within noise and M is more expensive on me-06. M delegated in only 1 of 6 runs (the routing guidance did not trigger on these small tasks).
- Wall: median P 20.9 s, M 18.2 s (M/P ~0.87); arm C median 68 s (C/P ~3.3x, dominated by tf-02 at 900 s and me-07 at 136 s).

## Sandbox and permission findings (all fixed before this run, see commits)
- Claude Code scratch: hardcoded `/tmp/claude-<uid>` fails under the M1 profile; `CLAUDE_CODE_TMPDIR=<run dir>/claude-tmp` fixes it with no /tmp access (the user's own `/tmp/claude-<uid>` stays unreadable).
- Codex (soak lane, sandboxed): died on `Failed to synchronize managed preferences` because mach-lookup and posix shm are denied (not caused by M1); now only cfprefsd mach lookup and read-only `apple.cfprefs` shm are allowed. Startup verified live with no model. Not verified: Codex apply_patch edits under the nested seatbelt (needs a model); mcp-clients Codex does not use sandbox-exec.
- Paid login: macOS stores it in the Keychain per `CLAUDE_CONFIG_DIR`; the sandboxed client needs `USER`/`LOGNAME`/host `CLAUDE_CONFIG_DIR` and read of the single file `~/Library/Keychains/login.keychain-db` (new residual risk, documented). Also needed: the mDNSResponder socket for DNS (every paid run hit ENOTFOUND otherwise).
- Runner: stops after 3 consecutive infra errors; infra rows do not count against `--max-parent-runs`; a client error with zero model usage ("Not logged in") is now an infra row instead of a task FAIL.
- Spend before this run: two aborted attempts produced 0 reported cost (not logged in, then ENOTFOUND); their out dirs were discarded.
- Still open: `zscaler.crt` extra-cert load fails (read denied, harmless warning).

## Go/kill reading (success = median parent tokens saved >= 50% at equal pass rate; kill if net savings < 20%)
Pass rates are equal (5/6 each). Token saving is -19% (worse), cost saving about 9%: below the 20% kill line, but n = 6 tasks x 1 rep (pass-rate resolution ~17 pp, one delegation event) cannot support either go or kill. Honest reading: no evidence of savings on small tasks; no evidence against delegation either.

## Stage 2 recommendation (not started)
Do not run the full 120-run stage 2 as planned. First check why M delegates so rarely (1/6): run a small M-only set on the larger tasks (tf-class, the Swift tf-11..18 and longer me tasks) where parent work is substantial, and require a delegation rate before spending on reps. Investigate tf-02 (all arms fail; possibly a hard or mis-specified task).

## Files
ledger.jsonl (18 rows, no tokens, no host paths). Server logs, per-run stderr/streams, server.token and control-token are local only (gitignored).
