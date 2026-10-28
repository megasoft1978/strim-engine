# AgentBench paid pilot 2026-10-28: ABORTED, infra error on every run

Command: `lockf -t 3600 -k /tmp/strim-bench.lock strim agentbench run --arms C,P,M --task-ids tf-02,tf-11,me-06,me-07,qa-01,qa-07 --allow-paid --max-parent-runs 12 --lock-held --model models/qwen38-4bit` (release build of HEAD c2be1ff; 6 tasks x arms C, P, M = 12 parent runs + 6 local runs).
Dry run first (arms H,C, all 17 tasks, no paid): ok. `agentbench validate`: 17/17 ok (12 test-fix, 3 mechanical, 2 repo-qa; corpus is Go for tf-02..05/me/qa, Swift for tf-11..18).

## Result
- Runs completed: 0 of 18. Infra errors: 18 of 18 (all 12 paid parent runs and all 6 arm C runs).
- Cause: the sandboxed Claude Code client (2.1.311) exits in 0.3 to 7 s with `EPERM: operation not permitted, mkdir '/tmp/claude-501'`. The sandbox profile denies writes to /tmp (security fix M1 made `$TMPDIR`, `/tmp`, `/var/tmp` unreadable/unwritable), but Claude Code hardcodes /tmp/claude-<uid> for its scratch dir. Also harmless: `zscaler.crt` extra-cert load fails (read denied).
- No parent request reached the API: stream.jsonl is empty for every run, no cost was reported. Paid spend: 0 USD reported.
- Credentials: never read or printed here; sandbox-level login question (OAuth file readable under sandbox) was not exercised because startup dies earlier. Codex shell_tool=false: not exercised (arm X not in this pilot).
- The runner did not stop after 3 consecutive infra errors; it ran all 18. No dollar budget or median expected parent cost is documented (docs only say "budget agreed first"); the hard cap used was `--max-parent-runs 12`.
- Memory watchdog: engine footprint ~6.3 GB, swap flat; no kill.

## Metrics
Pass rate, median parent cost, delegation net saving, wall-clock ratio: not measurable (n=0). Verify-gated outcomes: none (verify never ran).

## Go/kill reading (docs/PLAN-AGENT-HARNESS Addendum 2: success = median parent tokens saved >= 50% at equal pass rate; kill if net savings < 20%)
No data, so neither go nor kill. This is a harness bug, not evidence about delegation.

## Stage 2 recommendation
Do not start stage 2 (up to 120 runs). Fix first: allow the sandbox to write `/tmp/claude-<uid>` (or point the client at a run-scoped dir if Claude Code supports it) without re-opening /tmp reads, make the runner abort after 3 consecutive infra errors, and make infra-error paid rows not count against `--max-parent-runs` (current ledger rows count against the cap, so a rerun in this out dir would skip these 18 keys; use a fresh --out). Then re-run this 12-run pilot. Small n warning applies to any result: 6 tasks x 1 rep per arm gives pass-rate resolution of ~17 pp.

## Files
ledger.jsonl (18 infra rows, paths scrubbed). Server logs and per-run stderr are local only (gitignored). Tokens and client configs removed.
