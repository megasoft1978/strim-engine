# bench — Phase 0 measurement harness

Everything here is throwaway measurement code, not product code.

## Environment

The system Python has the scientific stack (transformers 5.16.1, numpy, tokenizers,
huggingface_hub) but MLX 0.31.1. Phase 0 needs MLX 0.32.4 / mlx-lm 0.32.2, so the venv is
built with `--system-site-packages` and only the MLX wheels are installed locally:

Historical (Python env removed 2026-10-27; the repo has no Python tooling now):

```text
uv venv .venv-sprint --python /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 --system-site-packages
uv pip install --python .venv-sprint/bin/python --no-deps wheelhouse/*.whl
```

PyPI is throttled to ~200 KB/s per connection here, so the wheels in `wheelhouse/` were
fetched with `aria2c -x8` (4–20× faster). Same for the checkpoints:
`aria2c -x 4 -s 4 -k 1M -c -d <dir> -o <file> <url>` (direct URL `https://huggingface.co/<repo>/resolve/<revision>/<filename>`).
Python bench scripts (`download.py`, `speed.py`, `run_task.py`, `ref_*.py`) were removed; use `strim download`, `strim enginebench` / `strim bench http`, and `strim agentbench`.

## Scripts

| Script | Purpose |
|---|---|
| `prompt_seed.txt` | coding-ish text used to build 4k/16k/64k prompts |

## Commands

```sh
# speed and memory measurement: use `strim enginebench` / `strim bench http` (see docs/BENCH.md)
```

Results are appended as JSON lines to `--out`. Run one process at a time on a quiet
machine; record the checkpoint, quant, context, and whether anything else was running.

## `strim agentbench`: paid arms (P, M) and credentials

The paid arms run the real Claude Code under `sandbox-exec` with file tools plus a scoped Bash (see "Paid-arm Bash" below; the
harness still runs the verify command itself after the client exits). The sandbox must still let Claude read `~/.claude/.credentials.json` and reach the network to
log in, so a prompt-injected task repo could in principle make the client's own tool layer misuse them. Residual risk: the file
tools are denied for `~/.claude*` by permission rule, not by the sandbox. Run paid arms only on corpora you control. Arm M passes
the Strim bearer token through the `STRIM_MCP_TOKEN` environment variable; `mcp.json` holds no secret.

Sandboxed client scratch: the sandbox denies `/tmp`, `/var/tmp` and `$TMPDIR` (security review M1), but Claude Code hardcodes
`/tmp/claude-<uid>` for its scratch unless `CLAUDE_CODE_TMPDIR` is set. Every sandboxed Claude child (agentbench C/P/M, soak,
mcp-clients) therefore gets `CLAUDE_CODE_TMPDIR=<run dir>/claude-tmp` (0700, inside its own writable run dir); the shared
`/tmp/claude-<uid>` of interactive sessions stays unreadable. The sandboxed Codex (soak) additionally gets the cfprefsd mach
services and read-only `apple.cfprefs` shared memory, which it needs to load its configuration. Startup regression tests:
`SoakClientStartupTests` (skipped when `claude` / `codex` are not installed; no model, no paid call).

Runner stop rule: `strim agentbench run` aborts after 3 consecutive infra errors (event `infra_stop`). Infra-error rows that
spent nothing do not count against `--max-parent-runs` and are rerun on resume.

Paid-client login: on macOS the login is a Keychain item named after `CLAUDE_CONFIG_DIR`, so the paid arms (P, M) and the
mcp-clients Claude lane pass `USER`, `LOGNAME` and the host's `CLAUDE_CONFIG_DIR` and the profile re-allows the mDNSResponder socket (DNS) and exactly
`~/Library/Keychains/login.keychain-db` (one literal file; the directory and `~/.claude*` stay denied, no Bash tool, items are
released by securityd under their own access control). Residual risk: the sandboxed client can read that database file. A client
that reports an error with zero model usage (for example `Not logged in`) is recorded as an infra error, not a task FAIL.

### Paid-arm Bash (owner decision 2026-10-28)

Without a shell the P/M parent could not run the task's tests (pilot 2 follow-up), so P is a handicapped baseline and M's routing
rule is confounded. P and M now get a Bash tool, but it cannot execute repository code (`PaidBash.swift`, `RunTests.swift`):
- Why not plain `go test`: `sandbox-exec` cannot be nested and cannot tell the client from its Bash child, so any Bash child has the
  client's network and can read its OAuth credential file / login keychain database. `go test`/`swift test` run parent-written code
  (`TestMain`, `init`, build plugins), so they would let that code exfiltrate the subscription credential.
- What Bash may run: `ls cat head tail wc grep diff pwd`, `git status`, and `runtests`. Denied (deny beats allow): `go`, `swift`, `rg`
  (`--pre` runs commands), `git diff|log|grep|show` (`--ext-diff`, `--output`), curl, wget, ssh, scp, nc, sudo, sh/bash/zsh, python, env/printenv,
  `rm -r*`, git push/remote/config. No sed/awk/find/cp/mv/touch/mkdir (file tools edit).
- `runtests go test|vet|build ...` / `runtests swift test|build ...` is a script (in `<run dir>/bin`, first on `PATH`) that sends its args
  to a per-run loopback service in the HOST process (random token). The host validates them (only those runner subcommands; `-exec`,
  `-toolexec`, `-vettool`, `-overlay`, `--scratch-path` ... refused), runs them in the verify-style sandbox (all network denied,
  no reads of home/credentials/keychain/other runs/the task dir, writes only in the worktree and a scratch dir), 300 s timeout, 80 calls
  per run, output capped to 20000 chars. Tests: `PaidBashTests` (a Go test program under `runtests` cannot read a credential canary, other
  runs, hidden files, dial loopback or the internet, or write outside; refused requests; rule set vs injection forms).
- Client profile (shared by its Bash children): writes only in the worktree and run dir; home, `~/.ssh`, `~/.strim`, `~/.aws`,
  `~/.claude*` (except the login files the client needs), Keychains dir, other runs' dirs and shared temp areas unreadable; the task's
  `test_paths` are write-denied (reads stay open) and are still hash-checked and restored before grading. Local arms' profiles unchanged.
- Env: allow-listed client env (minimal `PATH`, `HOME`, `USER`, `TMPDIR`, Claude vars, `STRIM_MCP_TOKEN` for M), `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`,
  per-command timeout 120 s (max 300 s), output cap 20000 chars (`BASH_*` variables).
- Preflight: P/M runs call `SelfCheck.checkPaidBash` (live sandbox probes, rule set, runtests refusals, `go version` through the service) and
  abort as an infra error on failure.

Residual risk, stated plainly: (1) the Bash child still has the client's network and can read the OAuth credential file and login keychain database. It cannot run
code through an allowed tool, but if Claude Code's command matcher were bypassed (an injection form it mis-parses), arbitrary code would run with that
access. The tests model the matcher conservatively (`strictPermits`) but cannot prove Claude Code's parser. (2) `HOME` is the real home (login needs it) and
`STRIM_MCP_TOKEN` is in the client env (arm M); only the deny profile protects them. (3) Test code run by `runtests` can write anywhere in the worktree (hash restore
covers `test_paths` only) and use the CPU for 300 s. (4) The env scrub, `BASH_*` limits and the `runtests` call path from the real client are unexercised until the first
paid run (no client was launched here). Run P/M only on corpora you control. Stronger option not built: an egress proxy allow-listing Anthropic hosts so the Bash child has no general network.
