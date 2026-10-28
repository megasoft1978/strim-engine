agentbench report: 120 runs

== mechanical-edit (10 tasks) ==
arm  n   pass         med parent $  med parent tok  med local tok  med wall s  false-done  redo
H    20  15/20 (75%)  -             -               69937          30          0 (0%)      0   
C    20  15/20 (75%)  -             -               223173         82          1 (5%)      0   

== repo-qa (10 tasks) ==
arm  n   pass          med parent $  med parent tok  med local tok  med wall s  false-done  redo
H    20  18/20 (90%)   -             -               17551          8           1 (5%)      0   
C    20  20/20 (100%)  -             -               29798          13          0 (0%)      0   

== test-fix (10 tasks) ==
arm  n   pass        med parent $  med parent tok  med local tok  med wall s  false-done  redo
H    20  2/20 (10%)  -             -               78502          78          0 (0%)      0   
C    20  2/20 (10%)  -             -               1018709        224         0 (0%)      0   
wrote /Users/user/Desktop/Freelance/strim-engine/bench/results/agentbench-20261028/results.json

## H arm: harness verify status vs bench judge
(joined from job records by workdir; `h_verify_vs_judge.json` has per-run rows; QA runs have no verify command so are `unverified`)

| job verify status | judge pass | judge fail |
|---|---|---|
| verified | 6 | 0 |
| verified-but-tests-touched | 0 | 0 |
| failed (job done) | 4 | 0 |
| unverified (done) | 17 | 1 |
| limit (verify failed/unverified) | 0 | 22 |

- verified -> judge pass: 6/6 (100%, small n, all non-Python or simple tasks).
- 4 `failed` rows where the judge passed: harness flaw, job verify ran `python3 -m pytest` without PYTHON -> "No module named pytest" (job sandbox lacks the venv); the patch was fine.
- No false-done by verify (verified never wrong), but verify is unusable on Python tasks in this setup.

## Failure triage (60 failed of 120 runs; counts by cause)
- Harness flaw, Python tasks (no pytest for agents): H 15, C 16 failed runs on Python tasks. H: job verify and the agent's own `python3 -m pytest` fail with "No module named pytest" (jobs tf-07-H-1, tf-09-H-2 searched the disk for interpreters). C: Bash allowlist denies the literal verify command (`${PYTHON:-python3}` form denied 34x, `python3 -m pytest` form 16x), 90 Bash permission denials in total; the model recorded memory notes "Bash is denied in this environment". So Python test-fix/mechanical results (pass 10%) understate the model; treat as invalid for Python until fixed.
- Model failure, Go tasks (Go env works, real compile/test errors): H 8, C 4, plus C timeouts 3 (900 s).
- Model failure, repo-qa: H 2 (qa-02-H-2 limit, qa-08-H-2 wrong answer; one is a false-done 5%), C 0.
- Harness limit hits: H test-fix jobs end `limit` (turn limit 40 or "identical bash call repeated"), often after the model could not run tests.
- Infra errors: 0.
- Wrong solution still fails: validate.sh shows all 30 unsolved snapshots fail verify (bad=0 means each fails unsolved and passes with the solution).

## Bugs found
1. Python tasks: agents cannot run pytest (H job sandbox, C allowlist). Repro: any tf-0[6-9]/tf-10/tf-01 run; see `Sources/StrimAgentBench/ClaudeSandbox.swift` (`BashAllow`, `${PYTHON:-python3}` handling) and `Executors.swift` (verify arg passed to `strim_task` still contains `${PYTHON:-python3}`, job env has no PYTHON/venv). Suggested: substitute the absolute venv python into the prompt/verify command and allowlist it.
2. Relative `--model`/`--head` fail: server is spawned with the output dir as cwd (`LocalServer.spawn`, `Cmd_AgentBench.swift`). Use absolute paths.
3. Ledger lacks harness verify status for H (`Executors.swift` only keeps `claimedDone`); recovered post hoc from `~/.strim/jobs`.
4. `--tasks N` takes the first N ids sorted (all `me-*`), not one per class.
