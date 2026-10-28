# Agent task corpus

Nine languages, 51 tasks (see `manifest.json`: `languages`, `counts` and the per-language class `balance`).
Go and Swift keep their original sets; TypeScript, JavaScript (Node), React, Rust, Java, Ruby and Python are original tiny projects (MIT)
written for this benchmark, each with an injected bug, a missing feature, or a code-reading question.

| language | tasks | test-fix | feature-impl | repo-qa | other | verify command (runs offline in the sandbox) |
|---|---|---|---|---|---|---|
| go | 12 | tf-02..05, 21, 22, 24 | | qa-01, qa-07 | me-06..08 | `go test -count=1 ./...` |
| swift | 11 | tf-11..20, 23 | | | | `swift test --build-system native --disable-sandbox` |
| typescript | 4 | ts-01, ts-02 | ts-03 | ts-04 | | `tsc --noEmit -p . && node --test` (Node type stripping, no build) |
| javascript | 4 | js-01, js-02 | js-03 | js-04 | | `node --test` (node:test) |
| react | 4 | rx-01, rx-02 | rx-03 | rx-04 | | `bun test` (JSX; react 18.3.1 + react-dom/server vendored in `node_modules`, server-rendered markup assertions, no DOM) |
| rust | 4 | rs-01, rs-02 | rs-03 | rs-04 | | `cargo test --offline --quiet` (std only) |
| java | 4 | jv-01, jv-02 | jv-03 | jv-04 | | `./scripts/javatest.sh` (javac + tiny assert runner, no Maven or JUnit; see `shared/javatest.sh`) |
| ruby | 4 | rb-01, rb-02 | rb-03 | rb-04 | | `ruby -Ilib -Itest test/all_test.rb` (minitest, stdlib) |
| python | 4 | py-01, py-02 | py-03 | py-04 | | `python3 -I -B -m unittest discover -s tests -t .` (stdlib unittest) |

Each language has a single-file bug, a multi-file bug (2-3 injected bugs across files), a small feature whose tests already exist, and a repo-QA question
answered as `path:line` (the oracle accepts a small line window).

| class | what | verify |
|---|---|---|
| `test-fix` | tests kept, source bug present in the snapshot | `verify_cmd` fails on the snapshot and passes with `solution.patch` |
| `feature-impl` | tests for a missing feature are in the snapshot | same as `test-fix` |
| `mechanical-edit` | rename / move / add-parameter; tests already use the new API | `verify_cmd` = tests (+ grep checks) |
| `repo-qa` | question with a checkable answer, no edits | `verify_cmd` greps `$ANSWER_FILE`; `known_answer` accepted, `wrong_answer` and empty rejected |

Per task dir: `task.json` (has `language`), `snapshot.tar.gz`, `solution.patch` (validation only, never shown to agents), `setup.patch` (mined tasks).
`test_paths` are restored from the snapshot and hash-checked (`test_sha256`) before `verify_cmd`; for React that includes the vendored `node_modules`.
`shared/` holds files copied into several tasks (the Java runner script).

## Commands

- `strim agentbench validate [--task-ids a,b] [--languages go,rust] [--pilot-per-language N]` offline check (CPU only, no model): table, exit 1 on any BAD, verify must stay under 60 s.
- `strim agentbench prepare [--write]` recompute `tree_sha256`/`test_sha256` and regenerate `manifest.json` (run it WITHOUT `--task-ids`, it rewrites the manifest from the tasks it sees).
- `strim agentbench run ... --languages ts,python` or `--pilot-per-language 2` selects a balanced set. The pilot takes, per language, tasks round-robin over the classes in the order
  test-fix, feature-impl, repo-qa, mechanical-edit (ids sorted), so `--pilot-per-language 2` is 18 tasks (2 per language, a mix of test-fix / feature-impl / repo-qa).

## Hermetic runners and sandbox

Verify commands run through `Verifier.verify` in the verify sandbox: no network (loopback included), writes only in the worktree and a scratch dir, no reads of the home except
exact toolchain dirs. The host resolves the toolchains (`Sources/StrimAgentBench/Toolchains.swift`): node/npm/tsc from `~/.nvm/versions/node/<latest>`, cargo/rustc from
`~/.rustup/toolchains/stable-*`, ruby from `~/.rbenv/versions/3.*`, a JDK from `/opt/homebrew/opt/openjdk@*` or `/Library/Java`, python from
`/Library/Frameworks/Python.framework/Versions/3.*`, bun and deno from `/opt/homebrew/bin`. Read grants under the home are only `.nvm/versions`, `.rustup/toolchains`, `.rbenv/versions`
(never `~/.cargo`, `~/.npmrc`, `~/.config`, `~/.gem`, `~/.m2`, `~/.docker`, `~/.netrc`, `~/.aws`, `~/.ssh`, user site-packages or pip caches). Caches live in the scratch dir
(`CARGO_HOME`, `npm_config_cache`, `DENO_DIR`, `BUN_INSTALL_CACHE_DIR`); `PYTHON*`, `RUBYOPT`, `NODE_OPTIONS`, `RUSTC_WRAPPER`, `JAVA_TOOL_OPTIONS` are cleared.

Paid arms (P, M) cannot run these tools from Bash; they call `runtests <runner> ...`, validated by `RunTestsGrammar` (flag whitelists per runner, relative paths only; refuses `npm install`,
`npx <remote>`, `node -e`, `bun x`, `cargo run|install|--config|+toolchain`, `ruby -e|-r`, `python3 -c|-m pip` and anything not `-I ... -m unittest`, absolute paths and `..`).
Allowed: `node --test`, `bun test`, `deno test`, `cargo test|build|check --offline`, `ruby -I.. test/x.rb`, `tsc --noEmit -p`, `npm test|run <script>`, `npx --no-install <local bin>`,
`javatest` (fixed `scripts/javatest.sh`), `python3 -I -m unittest ...`, plus the existing `go` and `swift` forms. `Tests/StrimAgentBenchTests/RunTestsLanguageTests.swift` proves,
per toolchain, that credential canaries, other runs, loopback and the internet are unreachable and writes outside the worktree fail while the tests still run.

## Known limits

- Arm H (the harness job sandbox) has a fixed system PATH and no toolchain read grants, so only Go and Swift tasks can run their verify command inside H; the other languages are graded by the
  verifier and usable by arms C, P, M. Giving H the same toolchain dirs needs a change in `StrimHarness` (`ProcessRunner.defaultPath`, `SandboxProfile.extraReadable`), not done here.
- React tests render to static markup (no DOM, no hooks effects); interaction logic is tested through pure helpers.
- Java uses JDK 11+ syntax only (no records, text blocks or switch expressions).
