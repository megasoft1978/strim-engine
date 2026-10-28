# Strim MCP: delegate routine work to the local model

Strim exposes a streamable-HTTP MCP server at `http://127.0.0.1:<port>/mcp` inside `strim serve` (same process, engine, bearer token and loopback Host/Origin checks as the OpenAI API). The goal is to save Claude/Codex subscription tokens: the local agent does the reading and iterating, the parent reviews a short summary and a patch.

## Setup

1. `strim serve <model>` (prints the MCP URL; default port 8203). Only one host may run at a time (`~/.strim/host.lock`); a second one fails with the holder's pid.
2. Register the client (the token is read by your shell from `~/.strim/token`, never printed by Strim):
   - Claude Code: `strim mcp-config --claude` prints two commands. Prefer `claude mcp add -s local -t http strim http://127.0.0.1:8203/mcp -H "Authorization: Bearer $(cat ~/.strim/token)"`, run inside the project that should delegate: it is stored in your private Claude config for that project directory only, so sessions elsewhere never pay the ~1.3K-token tool-schema cost. The same command with `-s user` registers for all projects. Do not use `-s project`: it writes the token header into `.mcp.json` inside the repo.
   - Codex: `strim mcp-config --codex` prints `export STRIM_TOKEN=$(cat ~/.strim/token)` and `codex mcp add strim --url http://127.0.0.1:8203/mcp --bearer-token-env-var STRIM_TOKEN`. A config snippet is in `integrations/codex/strim-mcp.toml` (`tool_timeout_sec = 60`). The output also lists `default_tools_approval_mode = "approve"` for `[mcp_servers.strim]` in `~/.codex/config.toml`: under `approval_policy=never` Codex otherwise rejects every call with "MCP tool call requires approval". The tradeoff: it auto-approves delegation to a sandboxed, worktree-only agent (your tree is only changed when you apply a patch). Drop the line if you prefer a prompt per call.
   - Use `--port N` if you serve on another port.
3. Claude Code only: copy `integrations/claude/agents/strim-local.md` to `~/.claude/agents/` (or `.claude/agents/`) so a subagent delegates proactively.

## Real-client check

`strim mcp-clients run NAME --model DIR [--head DIR] [--port 8212]` runs one case with a real Claude Code or Codex client against a private `strim serve` (its own token file, stopped afterwards). Clients get isolated config: Claude a `--mcp-config` file with `--strict-mcp-config` whose header is `Bearer ${STRIM_MCP_TOKEN}` (the token is only in the child environment, never in a file). Neither Claude arm has a shell tool: Bash prefix rules were bypassable (`go test` runs arbitrary code via TestMain, go:generate, cgo, GOFLAGS, -exec), so none is granted. The MCP arm has Read and Edit only, scoped to the fixture (Edit only of `text.go`), plus the strim tools. The baseline arm has Read/Edit/Write/Glob/Grep scoped to the fixture and no token. Every deny and allow path is emitted in each realpath spelling (`/var` and `/private/var`, `/tmp` and `/private/tmp`); the secret dir (mkdtemp 0700 outside the repo), the evidence runs dir and the home dir are denied, and `.git` is not writable. The Claude client itself runs under `sandbox-exec` (the `ClaudeSandbox` profile): writes only in the fixture and a private TMPDIR, no reads of the home, outbound network only. The permission rules are defense in depth; the sandbox is the boundary. Codex gets a temp `CODEX_HOME` with `bearer_token_env_var = "STRIM_MCP_TOKEN"`, `default_tools_approval_mode = "approve"` and `[shell_environment_policy] exclude = ["STRIM_MCP_TOKEN"]`; Codex is not sandboxed by this harness beyond its own `workspace-write`.

Known limitations: the baseline arm cannot self-test (no shell), so its prompt asks only for the edit; the harness runs `go test` for every fix case afterwards and the verdict is the harness's. The real Claude client needs outbound network, so its sandbox cannot be narrowed to loopback; the client has no tool that reaches the network, so this is not an exfiltration path, but it is not verified live. Sandboxed Claude startup and login, Claude's `${VAR}` header expansion and Codex's `exclude` runtime effect are unverified: no live run has been made. If the client cannot start under the sandbox, the run fails (no unsandboxed fallback). Your real Claude and Codex configs are not modified; the Codex `auth.json` is copied into the temp home. Evidence goes to `bench/results/mcp-clients-20261027/runs/NAME/` (`row.json`, `stream.jsonl`, `stderr.txt`, `register.txt`, `repo_changes.txt`, `check_output.txt`), with the token redacted. `strim mcp-clients list` shows the cases: `claude_a_ask`, `claude_b_fix_delegated`, `claude_c_fix_alone`, `claude_d_nomcp_hello`, `claude_e_mcp_hello`, `codex_a_ask`, `codex_b_fix`. Fix cases are checked against a toy Go module with `go test ./...`: first an allowlist (only `text.go` may differ from the template, test files byte-identical, no git commands run), then the test under the harness sandbox (writes only in the fixture and scratch, no reads of home or secrets, no network, cleared environment), fail-closed if `sandbox-exec` is missing. The baseline `claude_c_fix_alone` case has no shell and is checked by the same harness step. It makes model calls on your subscriptions, so run it deliberately.

## Tools

| tool | use |
|---|---|
| `strim_task` | queue a background job (`task`, absolute `cwd`, `access` read or write, `verify`, `wait_s` 0-25); returns the result if it finishes within `wait_s` |
| `strim_job` | status/result of a job (`job_id`, `wait_s`); not-done replies are one short line |
| `strim_cancel` | cancel a job and kill its process group |
| `strim_ask` | read-only repo question, at most 4 tool turns / 40 s; becomes a job on overrun |

`verify` (optional, strongly recommended, at most 500 chars) is a shell command Strim itself runs in the job worktree after the agent finishes (or hits a limit) and before the patch is collected: same sandbox as `bash` (no network, no secrets), 120 s cap, redacted and capped output. The agent cannot see it edited or change it. The result records `verify: {status: verified|verified_modified_tests|failed|unverified, exit_code, output_tail, touched_sensitive}` (tail at most 600 chars, in `result.json` and `job.json`); no `verify` means `unverified`. The reply starts `DONE strim job <id> verify=<status> ...` and says to apply only if `verify=verified`, otherwise do the task yourself. What `verified` proves: the command passes on the agent's own tree, nothing more. The agent can edit tests, scripts or build config the command runs, so Strim hardens this: verify runs with a fresh `HOME` and `TMPDIR` (never shared with agent commands), no agent process outlives its `bash` call, and the patch (collected before verify, so verify output never lands in it) is checked for integrity-sensitive paths: `tests/`, `test_*`, `*_test.*`, `*Tests*/`, `spec/`, `Makefile`, `package.json`, `Package.swift`, `pytest.ini`, `setup.cfg`, `pyproject.toml`, `tox.ini`, `conftest.py`, `.github/`, `scripts/`, and any path named in the verify command. If the command passes but the patch touches such files, the status is `verified_modified_tests` (shown as `verify=verified-but-tests-touched`, with up to 5 paths in `verify.touched_sensitive`) and the reply says to review those files before applying. Touched paths come from git itself on the host (`git diff --cached --name-status -z -M` against the base, both sides of renames), never from patch text; an unparseable, non-UTF8 or odd path (control characters, absolute, `..`, `.git`) and non-git workspaces fail closed (`unverifiable:...` in `touched_sensitive`). `.gitignore`, `.gitattributes`, `.gitmodules`, `.npmrc` and `.env*` count as sensitive. Files the agent left in the worktree that git ignores (so they are not in the patch) are listed with `git ls-files -o --ignored --exclude-standard -z`; any left after skipping well-known cache dirs (`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.build`, `.swiftpm`, `node_modules`, `target`) downgrade the status and appear as `ignored:<path>`. Regenerable caches (`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`) are deleted from the worktree (lstat walk, symlinks never followed) right before verify, so planted `.pyc` files cannot run. Dependency/build dirs (`node_modules`, `.build`, `.swiftpm`, `target`) are exempt only if they existed before the agent ran: a newly created one, or one whose entry count (top two levels) changed, downgrades the status and shows as `ignored:<dir>/ (new)` or `ignored:<dir>/ (entries changed)`. Residual: a modified file deep inside a pre-existing dependency dir (below the second level, content change with the same entry counts) is not detected; neither are `.pyc` files planted in untracked locations other than the purged cache dirs. The benchmark judge re-verifies on a clean checkout with the original tests restored; do the same for anything you rely on. Strim itself verifying on a clean checkout (patch applied, tests restored) is the stronger option and is deferred until the bench shows false-done results.

Supported languages for `verify` and for the agent's own `bash` test runs: Go and Swift (as before), plus TypeScript/JavaScript/React (`node --test`, `bun test`, `deno test`, `tsc --noEmit`, `npm test`, `npm run <script>`), Rust (`cargo test --offline`), Java (`sh scripts/javatest.sh`-style repo script; direct `java`/`javac` are refused for the agent), Ruby (`ruby -Ilib -Itest test/x_test.rb`) and Python (`python3 -I -m unittest ...`). Toolchains are resolved by Strim on the host (nvm/rustup/rbenv version dirs, Homebrew, python.org, a JDK), run offline with caches in the per-job tmp, with no network and no access to credentials or `~/.cargo`, `~/.npm`, `~/.m2` and similar. The agent's `bash` accepts a language runner only in the test-run forms the paid benchmark arms accept (no `npm install`, `npx <pkg>`, `node -e`, `python3 -c`, `pip`, `cargo run/install`, absolute paths or `..`); your `verify` command itself is not restricted. See `docs/SECURITY-REVIEW-2026-10-28-exec.md` (addendum).

A job the model refuses up front (`finish` with `declined: true` and a reason) ends with status `declined`: a one-line reply, no patch, no verify.

A result has `status` (`done|failed|cancelled|limit|declined`), a short `summary`, `files_changed`, an inline `patch` when small, `patch_path` (`~/.strim/jobs/<id>/patch.diff`), `base`, `commands` and `usage`.

CLI: `strim jobs list`, `strim jobs show <id>` (read `~/.strim/jobs`, no server needed), `strim jobs cancel <id> [--port N]` (needs the running server).

Result format: Claude Code forwards only `structuredContent` to the model when a result carries it, which would hide the summary and patch. So the server returns the full result as text only (no `structuredContent`), and the text is already token-lean. The four tool names are `strim_task`, `strim_job`, `strim_cancel`, `strim_ask` (Claude Code shows them as `mcp__strim__<name>`).

To disable: `claude mcp remove strim -s user`; `codex mcp remove strim`; or stop `strim serve`.

## Host settings

`~/.strim/config.json` (kept 0600):

```json
{"mcp": {"requireApproval": false, "maxAccess": "write", "allowedRoots": []}}
```

- `maxAccess`: `read` rejects any `access=write` request with an error result before it is queued.
- `allowedRoots`: a job's `cwd` (symlinks resolved) must be inside one of them. Empty or unset means your home directory (`strim serve` prints a warning). Credential and host-state directories under home (`~/.strim`, `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config`, `~/.docker`, `~/.kube`, `~/.claude*`, `~/.codex*`, `~/Library`) are always refused as `cwd`, whatever the roots say.
- `requireApproval`: jobs wait in `awaiting_approval` until approved.

## Security model

- The local model is untrusted and prompt-injectable through file contents. Everything it does runs under constraints:
  - Bash runs under `sandbox-exec`: no network, writes only to the job worktree and job tmp, no reads of credentials (`~/.ssh`, `~/.aws`, `~/.strim/token`, ...); scrubbed environment; timeouts.
  - File tools are contained to the job workspace (realpath checks, deny list for `.env*`, keys, `.git/config`, hooks).
  - Every job works in an isolated git worktree (APFS clone for non-git dirs); your tree is never written. `access=read` is the default and writes nothing.
  - Secrets (including the Strim token) are redacted from tool output and results.
- The patch is untrusted input to the parent agent. Review it before applying: `git apply --check`, then `git apply`, then run the verify command.
- The server binds to 127.0.0.1 only and requires the bearer token; keep `~/.strim/token` private. The token ends up in the client's MCP config (header or env var).

## When to delegate

Delegate only when all hold: a verify command exists (the shell command that proves the task is done) or the answer is checkable by file:line; the task fits in about 150 words; solo cost would be at least 6 tool turns or 15K tokens of tool output. Never delegate design, cross-cutting refactors, security code, or tasks with no oracle.

- Always pass `verify`. On `verify=verified`, apply with `git apply --check`, then `git apply`.
- On `failed`, `limit`, `unverified`, or a declined task, do it yourself. At most one delegation per task.
- Token tax: the four tools cost about 1.3K tokens per turn in every session where they are registered. Do not register the MCP in sessions that never delegate. Register with `-s local` (Setup) rather than the user scope, so only the project that delegates pays the cost.
- Claude Code: `integrations/claude/agents/strim-local.md` (`model: haiku`). Codex: `integrations/codex/AGENTS-strim.md`, merged into `AGENTS.md`.

## Saving parent tokens

- Delegate high-volume, verifiable work: exploring files, test-fix loops, repo questions, boilerplate. Do not delegate tiny edits or design decisions.
- Give a self-contained task with the verify command; one `strim_task` with `wait_s` 25 beats many polls.
- Poll with `strim_job` `wait_s: 25`; ignore progress. Progress notifications do not cost model tokens.
- Review the summary and `patch_path`, not the whole transcript. If the job ended `failed` or `limit`, stop early instead of retrying blindly.
