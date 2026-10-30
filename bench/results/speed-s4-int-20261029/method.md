# S4 fork integration protocol

Slice `20261029-5-s4-int`, engine HEAD `a112d0d16895d5612a3f86811ca9a368ca96ddaf`.
The root manifest pins remote `megasoft1978/mlx-swift` exact `0.32.3-strim.1`.
Resolution ran in `/tmp/s4/src-int` with scratch `/tmp/s4/build-int`; its generated
lockfile was copied back. swift-numerics remains 1.1.1. `raw/provenance.txt`
records the wrapper, nested submodule revisions and reverse patch dry-run.

Both source snapshots were created with `git archive HEAD`; only the three owned
integration files were overlaid in the fork snapshot before its fresh release build.
The baseline is a fresh upstream 0.32.3 release build in `/tmp/s4/build-base-int`.
The initial production release binaries were built before adding instrumentation.
No working-tree agentbench changes were included in either snapshot.

For measurement only, the same separate `S4IntegrationBench` executable target was
added to both scratch manifests. `raw/harness.swift` derives from the existing S4
harness, imports the release StrimCore and tokenizer modules, and makes no changes
to engine code or dependencies. It records MLX peak active-memory bytes. The added
quality modes compare full float32 vocab rows (8 per decode step/sequence cell,
64 teacher-forced greedy steps; all verify-width rows) with the unpatched reference,
including float bit patterns, argmax agreement and raw Int32 output SHA-256 hashes.
Full tensors stay under `/tmp/s4/quality-int`; JSONL summaries are retained here.
The full test suite uses the fork snapshot; the additive benchmark target has no tests.

Every GPU command, including the full test run, waits for `lockf -k
/tmp/strim-bench.lock`. The lock file is never removed or bypassed. Models in
`~/.strim/models` are read-only. No HTTP servers, GUI windows or credentials are needed.
Windowless snapshot rendering, if enabled by the suite, does not activate the app.

Quality gates compare each identical batch/chunk policy across arms. Existing
B=1 versus B>1 numerical differences are reported by `checkbatchparity` and must be
unchanged across arms. Existing prefix hot-versus-cold informational differences
are also compared across arms. For CLI logs only timing/load/memory telemetry is
excluded from equality comparisons; tokens, hashes, margins and gate verdicts are kept.
`gates-int.rb` retains the exact normalization and complete raw output per arm.
The concurrent-decode engine gate uses its full default matrix, including sampling.

Two ABBA cycles use fresh processes for decode c=1/4/8, verify widths 3/5/8,
and prefill 4096/16384. Each cell has one excluded warmup plus 3 measured reps.
Decode measures 64 lockstep steps; verify measures 12 fixed-state target passes;
prefill uses fixed 1024-token chunks. Fusion is absent. Rates exclude loading;
decode excludes initial prefill. Peak MLX memory includes the process lifetime.
Each block records start/end UTC and load. The lock is released between blocks.
Hashes/next tokens are checked immediately against the first fresh baseline block;
any changed output stops the run. This is in-process throughput, not HTTP throughput.

Aggregate rates are medians of four block medians per arm. Per-cycle effects use
ratios of geometric arm means; same-arm noise is the maximum absolute within-cycle
A-to-A or B-to-B change. Keep requires c=8 >=+2%, c=1 regression within measured
noise, and identical outputs. Performance conclusions apply only to the measured M5 Max.

Test build note: trying release `--build-tests` after the production build failed
before test execution because non-testable release modules were incompatible with
`@testable` test imports. No tests ran in that attempt. The full `swift test` run
uses its normal debug configuration under `/tmp/s4/build-int`; its build was
prepared with `swift build --build-tests` while waiting for the GPU lock. No test,
oracle, golden, threshold or skip condition was changed.

The standalone harness also includes a copy of `Cmd_Engine.swift`, with one
observability-only addition after a run has finished: `S4_ENGINE` JSON lines
record each policy/mode/prompt/seed and every generated token. The engine gate
calls this same `runEngineBench` implementation through the harness entry point,
using full defaults. Both arms' token arrays are compared, in addition to the
built-in verdicts. No scheduler, generation, sampling or timed section was changed.
The shipping CLI and engine source in the snapshots remain unchanged. The exact
instrumented command source is retained as `raw/engine-harness.swift`.

Full test result: exit 0; XCTest has 113 passed and 14 skipped case lines.
Swift Testing reports 1,677 passed and 31 skipped tests (1,708 total):
18 skips need repository-local model links, 8 are opt-in live app smoke tests,
and 5 existing guards print skips without reason text.
There are no test failures. Raw summary details and every skip are in
`raw/tests.json`; the complete single-run output is `raw/swift-test.log`.
The live GUI smoke suite was not enabled. All executed checks were headless
or windowless snapshot rendering.
