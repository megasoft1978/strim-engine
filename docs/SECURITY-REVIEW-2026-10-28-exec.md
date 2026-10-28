# Security review 2026-10-28: process launches and model-influenced code (section 1 only)

Scope: every place that spawns a process or runs model-edited code, and whether the earlier fixes still hold. Read-only review of HEAD (82ca794) plus one repro in a snapshot (`git archive HEAD` to /tmp, scratch path /tmp/strim-build-sec). Sections 2-4 (server/auth, release hygiene, supply chain) were handled by other workers. Not verified: nothing was run against a live model or GPU; sandbox behaviour was checked only with a small `sandbox-exec` probe and the unit repro below.

## Status (updated after fixes)

| Finding | Status | Commit |
|---|---|---|
| H1 | fixed: `SensitiveDirs` refusal in validateCwd, checkProjectDir, HostPolicy and clone source; clone scrub uses root name, control-token/docker/kube/aws rules; control token registered with the redactor; `strim serve` defaults `allowedRoots` to home (tests inject `[]`). Residual: any project under a non-denied home dir is still allowed by default. | b11dfce |
| M1 | fixed: profile denies reads of `$TMPDIR`, `/tmp`, `/var/tmp`; job tmp, workspace and the tag allow file re-allowed; mcp-clients Claude config re-allowed by single file. Residual: the Codex arm's `secret` dir is 0700 mkdtemp in `$TMPDIR` (unreadable to sandboxed jobs now) but not moved. Follow-up: M1 broke the sandboxed clients at startup (Claude `EPERM mkdir /tmp/claude-501`, Codex `managed preferences` via the denied mach/shm services; all 18 pilot runs were infra errors). Fixed without widening reads: `CLAUDE_CODE_TMPDIR` points Claude at `<run dir>/claude-tmp` (0700, in the writable run dir, removed after); Codex gets only cfprefsd mach lookup and read-only `apple.cfprefs` shm. `/tmp/claude-<uid>` of interactive sessions stays denied. Paid arms also need their Keychain login: the profile re-allows the single literal file `~/Library/Keychains/login.keychain-db` (residual: readable by the sandboxed client; the file is encrypted at rest and items stay under securityd access control; paid arms have no shell tool) and the arms pass `USER`/`LOGNAME`/`CLAUDE_CONFIG_DIR`. Startup regression tests added (`SoakClientStartupTests`, `LoginSandboxTests`). Runner stops after 3 consecutive infra errors and infra rows no longer use up `--max-parent-runs`. | 0169424, (this commit) |
| M2 | fixed: paid arms have no Bash tool or allow rules. Residual: OAuth credential file stays readable by the sandboxed client (login needs it); file tools are denied `~/.claude*` by permission rule only, documented in `bench/README.md`. | db3ac1b |
| M3 | fixed: `mcp.json` references `${STRIM_MCP_TOKEN}`, 0600 in the run dir, removed afterwards. No per-run narrow-scope token exists server-side (residual). | db3ac1b |
| M4 | fixed: `agents.sh` needs `STRIM_UNSAFE_LOCAL_AGENT=1` (warning, throwaway config dir); `run_local_codex.sh` deleted (obsolete). | db3ac1b |
| L1-L5, I1-I3 | not addressed | |
| Weak tests | added: makeWorkDir 0700/0600, mcp-clients closed tool set and Codex argv, symlinkEscape exact 400 `unsafe_patch`, Verifier `cat` ran-and-denied. These cover already-correct code, so they pass on old code. | (this commit) |

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 1 |
| Medium | 4 |
| Low | 5 |
| Info | 3 |

## High

### H1. A delegated job may use `~/.strim`, `~/.aws`, `~/.docker` ... as `cwd`: control token and other secrets reach the model and the MCP caller
- Where: `Sources/StrimHarness/HarnessRunner.swift:340-358` (`validateCwd` only refuses `/`, home and ancestors), `Sources/StrimMCP/Tools.swift:162-176` (`checkProjectDir`, same rule), `Sources/StrimHost/HostConfig.swift:89-100` (`allowedRoots` empty means any cwd; default is empty, `docs/MCP.md:46`), `Sources/StrimHarness/GitWorktree.swift:522-528` (`isSecretPath`), `:589` (`scrubClone`), `:495` (`copyUntracked`).
- Scenario: Claude Code or Codex is connected over MCP with the API token and `default_tools_approval_mode = "approve"` (shipped in `integrations/codex/strim-mcp.toml`). A prompt-injected parent calls `strim_ask(cwd="/Users/me/.strim", question="print control-token")`. A non-git cwd is cloned (`cp -R`) into the worktree dir and scrubbed with `isSecretPath`, which matches paths relative to the clone root, so the `.strim/token` rule (needs `.strim` as a parent segment) never fires, and `control-token`, `~/.aws/credentials`, `~/.docker/config.json`, `~/.kube/config`, `~/.ssh/config` are not on any list. The sandbox re-allows reads under the worktree, the file tools' deny list does not know these names, and the host redactor registers only the API token (`Host.swift:133`), so the 64-hex control token is returned as plain text. The control token unlocks `approve` (git apply into any repo the job record names), `load`, `unload`. This defeats the control-token scoping fix. If `$HOME` is itself a git repo (it is on this machine), the `files:["…/.strim/control-token"]` path through `copyUntracked` leaks it as well.
- Evidence (repro, snapshot test run with real code): `validateCwd` accepted a fake `~/.strim` dir; clone contained `["control-token","token"]`; `control-token in clone: CONTROLTOKEN`; `WorkspacePolicy` allowed reading both. Note even `token` leaked, because the clone root is `.strim` itself.
- Minimal patch:
  1. Add one function `SensitiveDirs.refuse(realCwd, home)` and call it in `HarnessRunner.validateCwd`, `Tools.checkProjectDir` and `HostPolicy.violation`: reject when the canonical cwd equals or is inside `$HOME/{.strim,.ssh,.aws,.gnupg,.config,.docker,.kube,.claude*,.codex*,.netrc dir,Library}` or inside `/Library/Keychains`.
  2. In `isSecretPath` also match `control-token`, `token` under a directory literally named `.strim`, `credentials`, `config.json` under `.docker`, `hosts.yml`, and run `scrubClone` with the clone root's own name prepended to the parts.
  3. `Redactor.register(secret:)` the control token at host start (`Host.swift`, next to line 133).
  4. Ship `allowedRoots` non-empty by default, or require it on first `strim serve` (print a one-line warning when empty).
  5. Add a test: cwd=`<fakehome>/.strim` is refused by all three entry points (none exists today).

## Medium

### M1. Sandbox read model is a deny-list for home only; everything else is readable
- `Sources/StrimHarness/Sandbox.swift:114` (`(allow default)`), `:160-165`. Probe: with `(deny file-read* (subpath "/Users"))` a sandboxed `cat` of a file in `$TMPDIR` (`/private/var/folders/.../T`) succeeded; the same `cat` of `~/.strim/token` failed.
- Scenario: any secret the user's tools leave in `/private/var/folders/*/T`, `/private/tmp`, `/var/tmp` (for example the Codex arm of `mcp-clients run` copies `auth.json` into `$TMPDIR/mcpc-secret-*/codex-home`, `MCPClientsRun.swift:83,152-156`) is readable by the model's bash while a job runs concurrently. Output is returned through the redactor, which does not know the format.
- Fix: also deny reads of `/private/var/folders`, `/private/tmp`, `/var/tmp` and re-allow `jobTmp` and the `strim-tags` allow file (needed by `JobTags.contains`, `ProcessRunner.swift:339-364`). Verify swiftc/git/clang still run; document if not. Move the bench secret dirs under a path the profile denies.

### M2. AgentBench paid arms (`strim agentbench`, arms P/M) give Claude a Bash prefix allowlist, the OAuth credential file, and open egress
- `Sources/StrimAgentBench/Executors.swift:126-133,178-184`, `ClaudeSandbox.swift:40-48,72-76`. The profile appends `(allow file-read* (literal ~/.claude/.credentials.json))` after the secret denies (last match wins) and `(allow network-outbound (remote ip))`. Allowed Bash prefixes include `sed`, `awk`, `find`, `cp`, `mv` and the verify binary (`go`), all of which run arbitrary code (`awk system()`, `find -exec`, `go test` TestMain). The soak and mcp-clients lanes removed Bash for exactly this reason (comments in `SoakClients.swift:56-60`, `MCPClientsConfig.swift:92-96`); this lane did not.
- Scenario: a task repo (user-supplied corpus) with an injected instruction makes Claude run `awk 'BEGIN{system("curl ...")}'`-style code (curl is denied by prefix, `awk system` is not) and post the credential. Bench-only and opt-in, but it ships.
- Fix: drop Bash from paid arms (as the other lanes did) or run the paid arm without the credentials literal and with a pre-fetched token proxy; at minimum remove `sed|awk|find|cp|mv` and document the risk in `bench/README.md`.

### M3. `.paidWithMCP` writes the bearer token into a file inside the client's sandbox roots
- `Executors.swift:166-175`: `mcp.json` (0600) with the raw token in `runDir`, which is readable and writable by the client. `MCPClientsConfig.swift:1-5` documents why this was already fixed for the other lane (env expansion). Impact limited to a private bench server token; fix by using `${STRIM_MCP_TOKEN}` as `MCPClientsConfig.claudeConfigJSON` does.

### M4. Shipped scripts run a local, injectable model with no sandbox
- `scripts/agents.sh:59` (`claude --dangerously-skip-permissions`, real `CLAUDE_CONFIG_DIR`, strim token exported as `ANTHROPIC_API_KEY`), `integrations/harness2/run_local_codex.sh:21,31` (`sandbox_mode = "danger-full-access"`, `--dangerously-bypass-approvals-and-sandbox`, port 8200 and `/v1/strim/switch` from the retired daemon). Any file in the target workspace can steer the model into arbitrary commands as the user. Delete the harness2 script (stale), and in `agents.sh` drop the flag or print a warning and use a throwaway config dir.

## Low

- L1. `Sources/StrimAgentBench/Proc.swift:229` `scrubbedEnvironment` is a name deny-list (`TOKEN`, `SECRET`, `PASSWORD`, `API_KEY`, `AWS_*` ...). `DATABASE_URL`, `STRIPE_KEY`, `NPM_CONFIG_*` pass into the Verifier and the P/M arms. Use an allowlist as `SoakArgvs.clientEnv` does.
- L2. `MCPClientsConfig.swift:70-78` `cleanEnvironment` strips only client-auth prefixes; the Codex arm (`MCPClientsRun.swift:152-160`, no `sandbox-exec`, relies on Codex `workspace-write` which can read the whole disk) inherits `AWS_*`, `GITHUB_TOKEN` etc. Prompt is host-authored on a host-built fixture, so low.
- L3. `MCPClientsFixture.swift:64-75` runs `/usr/bin/git` (xcrun shim) with the full inherited environment (`GIT_*`, user global config) to build the fixture; harmless on the template, but use `SandboxProfile.trustedGitPath` plus a scrubbed env.
- L4. `Sources/StrimTokenizer/DraftVocabBuilder.swift:192-198` runs `/usr/bin/env git -C <root> ls-files` with PATH lookup and inherited env on a user-chosen repo (new, uncommitted `draft-vocab` command). A repo-local `core.fsmonitor` could run. Use the hardened runner.
- L5. `scripts/ab_bench.sh:54,79,99` writes predictable `/tmp/ab_*_ids.txt`; a local user can pre-plant symlinks. Use `mktemp -d`. Also `SoakClients` kills only the process group (`SoakSystem.swift:38`, no tag-based tree kill like `ProcessRunner`), so a setsid'd client child can outlive the run and race the allowlist/verify; affects bench integrity, not the host.

## Info

- I1. `LaunchAgent.swift:107` has `ds.st_mode & S_ISVTX == 0 || true`: dead condition (always refuses world-writable dirs, which is the safe direction). Group-writable ancestors (e.g. `/opt/homebrew/bin`, group admin) are not checked.
- I2. `PatchApplier.swift:4-5` doc comment says `--3way`; code correctly uses plain `git apply`. Fix the comment.
- I3. A patch may legitimately add execution surfaces (`.envrc`, `.husky/*`, `.github/workflows/*`, `package.json` scripts). The approve flow is bound to the reviewed SHA-256 but does not flag these paths; consider a warning in the app diff view.

## Launch-site inventory (verdicts)

| Site | Sandboxed | Env | Args from model? | Verdict |
|---|---|---|---|---|
| `StrimHarness/ProcessRunner.swift:57-137` (bash tool, verify) | `sandbox-exec -p` per job, net/mach/signal denied, writes confined, git control paths denied | rebuilt (`PATH`, `HOME`=jobTmp/home, `TMPDIR`), `STRIM_JOB` marker, ulimits | command string | OK; see M1 (read scope), H1 (what the workspace contains) |
| `StrimHarness/GitWorktree.swift:863-884` (host git) | n/a (host) | scrubbed, `-c` hardening, `GIT_CONFIG_GLOBAL=/dev/null` | paths validated; quarantine object dir | OK |
| `StrimControl/PatchApplier.swift:244-262` (host git apply) | n/a | scrubbed + hardening | patch bytes validated twice, `RepoSafety` scan, SHA-256 bound | OK |
| `StrimHarness/FileTools.swift` (in-process file tools) | realpath, O_NOFOLLOW, fd re-check, nlink check | n/a | path | OK (deny list misses `.npmrc`, `.docker`, `*.key`: Low) |
| `StrimAgentBench/Verifier.swift:~175` (verify_cmd) | `sandbox-exec`, loopback denied, fail closed, probe first | `scrubbedEnvironment` + fake HOME | task-defined cmd | OK; L1 |
| `StrimSoak/SoakVerify.swift`, `SoakClients.swift`, `SoakSystem.swift:26-44,137` | allowlist before exec, hidden tests O_EXCL, `go test` sandboxed; clients under loopback-only profile | explicit allowlist env | argv fixed | OK; L5 |
| `StrimMCPClients/MCPClientsRun.swift`, `MCPClientsFixture.swift` | Claude arm sandboxed (egress open), Codex arm relies on Codex sandbox | inherited minus prefixes | prompts fixed | OK with L2, L3 |
| `StrimAgentBench/Executors.swift` (Claude arms) | sandboxed; local arm loopback only, paid arms open egress + creds | deny-list env | Bash allowlist | M2, M3 |
| `StrimAgentBench/Corpus.swift:66`, `Executors.swift:102,267`, `Runner.swift:77` (`/usr/bin/git apply`) | no | `Proc.capture` env | patch from local model | Low: `git apply` into a bench workdir; no hooks run by apply |
| `StrimAgentBench/Verifier.swift` tar extract | n/a | n/a | repo fixtures | OK (bsdtar default path safety, trusted fixtures) |
| `StrimEvolve/*` | no process launches (uses bench runner) | n/a | n/a | OK |
| `StrimTokenizer/DraftVocabBuilder.swift:192` | no | inherited | repo path | L4 |
| `StrimAppCore/Services.swift:191,222` (spawn `strim serve`, `strim mcp-config`) | no | inherited | binary resolved and validated, args from settings | OK |
| `StrimControl/LaunchAgent.swift` | writes plist only (never runs launchctl) | HOME/PATH fixed | label validated, binary validated | OK; I1 |
| `StrimSoak/SoakSystem.swift:137` (`ps`) | no | n/a | pid | OK |
| `scripts/*.sh`, `integrations/*` | no | inherited | n/a | M4, L5 |

## Verified fixed (with test strength)

1. Control-token scoping: `ControlSupport.swift:80-110`, `ControlGuard.check`; `ControlTokenTests` hits every control route over real HTTP with the API token (403), control token on API routes (401), wrong/missing (one message). Strong. Gap: no test that the model path cannot read the token file (H1).
2. RepoSafety/PatchApplier: `riskyConfig` tests plant `fsmonitor = touch MARK`, hooksPath, filter attributes, config.worktree and assert nothing executes: strong. `symlinkEscape` asserts only `status >= 400` plus unchanged outside file: weak assertion on status, strong on effect.
3. install-agent validation: `LaunchAgentTests` label and binary tests are direct and would fail on the old behaviour. Strong. `Cmd_InstallAgent` itself has no test.
4. Verifier sandbox + env clear: `VerifierSandboxTests` plant files in a fake home and use `! cat ...` shell negations; they pass if `cat` fails for any reason, but the files exist and `test -f src.txt` guards that the sandbox did not break everything, so acceptable. The `ConfusedDeputyTests` link test is strong. No test asserts credential-like env vars are dropped from `scrubbedEnvironment` beyond the named list (L1).
5. Soak verify allowlist + hidden-test fail-closed: `plantedEntryAtHiddenPath...`, `hiddenWriteFailureIsAFailedResult` (asserts no go cache dir created, i.e. nothing ran), `plantedTestCodeIsContained` (token/outside-write/loopback all denied by real planted Go test). Strong.
6. Per-run client config dirs: `CLIClientLauncher.prepareConfig` copies a template into scratch per run; `SoakClientsTests` covers it. Not re-read in detail.
7. MCP clients: no Bash, deny rules, 0700 mkdtemp: argv tests (`claudeArgvHasNoShellOnEitherArm`, `denyRulesCover...`) check strings only, not client behaviour: weak by nature. `makeWorkDir` (mkdtemp, `MCPClientsRun.swift:210-214`) has no test for mode 0700 (mkdtemp guarantees it). Weak.

Weak tests, ranked: MCP-clients 0700 (untested), MCP-clients argv (string-level), `symlinkEscape` (status only), Verifier `! cat` pattern, no test for H1.
