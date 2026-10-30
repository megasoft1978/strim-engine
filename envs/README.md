# Strim agent-task environments

16 offline coding tasks with binary rewards, an OpenEnv server/client, and a
Prime Intellect `verifiers.v1` taskset. This is a local prototype; Linux container
execution and public platform submission still need the owner checks below.
The checkout is required locally. The Docker targets package their own assets.

## Isolation and grading

`materialize()` extracts only the public source workspace. All `test_paths`
(including protected build scripts, TypeScript configuration, and React
`node_modules`) are excluded **before extraction**. Neither snapshots, task
metadata, nor reference solutions are copied to the agent workspace. The reset
prompt explains which paths are withheld and why local test commands may be
unavailable.

The episode ends before grading. `verify()` copies the submitted workspace to a
fresh temporary grading directory, checks the trusted snapshot's protected
hashes against `task.json`, restores the protected paths there, checks them
again, restores the test-discovery control files from the trusted snapshot, and runs
the task's offline verification command in a parseable report mode. The tamper rule
remains fail-closed: changing protected paths fails. The public baseline has no
protected paths, so creating any protected file/directory/link also fails, even
if its contents match a hidden fixture. Symlink submissions fail. The agent's
workspace stays unchanged by grading. Success is `1.0`; tampering, execution
failure, unavailable sandbox, or a 60-second grading timeout gives `0.0`.

### Reward semantics

Reward is `1.0` only on **positive, authenticated evidence**, never on exit status or
agent-writable output:

1. **Edit-set sync.** Before grading, the whole submitted tree is diffed against the
   trusted snapshot. Only the files the reference solution edits (`strim_envs/edit_policy.json`,
   recorded by `python -m strim_envs.expected`; no patch is needed at grade time) plus
   code-extension files under the directories it edits whose names are not test/config/hidden
   are kept. Everything else is restored from the snapshot or deleted: `conftest.py`,
   `sitecustomize.py`, `*.pth`, `node_modules/`, `tsconfig*`, `jest/mocha` config, `.mocharc*`,
   `pom.xml`, `build.gradle`, `.mvn/`, `.rspec-local`, `test_helper.rb`, `build.rs`, `Cargo.toml`,
   `go.mod`/`go.work`, `package.json`, build output, stray test files, ...
   Kept-source edits outside the reference's directories (e.g. a new Java package or a new
   top-level Python module) are discarded; the tasks do not require them.
2. **Trusted runner.** The runner is a grader-owned wrapper (`strim_envs/graders/`) staged
   outside the workspace, read-only inside the sandbox. A per-run random **nonce** is delivered on
   a pre-filled pipe at a random high fd that the wrapper reads and closes **before any agent
   code is loaded**. Results go to a grader-held append-only fd as `<nonce> <json>` records and
   end with a trailer. No report file, stdout, stderr, junit or TAP stream is parsed.
3. **Acceptance.** Exit code 0, every channel line carries the nonce, exactly one trailer
   (`ok`, `total`), no `fail` record, the passed multiset equals the trusted
   `expected_tests.json` (each name exactly once) and `total` equals the expected count. A hard
   exit (`os._exit(0)`, `process.exit(0)`, `exit!`, `Runtime.halt`, `os.Exit`) before or during the
   run writes no trailer and scores `0.0`; forged text on stdout/stderr is ignored.

Per language: Python `py_run.py` (`-I`, custom `TestResult`, also fails if
`unittest`'s core classes were monkeypatched); Node/TS `node_run.mjs` (`node:test` `run()`
with `isolation: 'none'`, so there is no child IPC/stdout stream); React/Bun `bun_run.mjs` with a
grader `bun:test` shim (test files are loaded with their `bun:test` import redirected, so no
JUnit file exists); Ruby `rb_run.rb` (real minitest preloaded, autorun disabled, reporter
records results); Java `StrimRun` (reflective runner compiled by the grader, no
`javatest.sh`); Go builds per-package binaries with `go test -c -overlay`, injecting a
first-initialised guard package (reads the nonce before any package-level code of the package
under test) and a generated `TestMain` that reports `m.Run()`'s code in the trailer, with names from
`go tool test2json` (`go vet` is not run). Rust has no in-process hook in libtest: tests are
listed with `--list` and **each is run in its own process** (`--exact`); the grader requires
exit 0, libtest's "1 passed" summary on grader-held stdout and exactly one `ok` line on
libtest's `--logfile` at a random high fd (no nonce is possible). Only integration tests under
`tests/` are trusted; unit tests in agent-editable sources are not run.

Expected names are recorded once from each task's reference solution and never derived from the
submitted workspace. Submissions are copied with `symlinks=True` and re-scanned: any symlink,
FIFO or other non-regular file gives `0.0`.

**Residual risk (be precise).** Agent code runs in the same process as the test framework.
An attacker that introspects memory, frames, or file descriptors can still forge results: Python
frame walking to the nonce, Ruby `ObjectSpace`, Java reflection, JS monkeypatching of primordials,
Go `//go:linkname`/`unsafe`. For Rust the libtest logfile path and test name are in argv, so code linked into the
test binary can forge a pass without any introspection; Rust has no in-process authentication. The rs-01/rs-02
source denylist (unsafe, link sections, `std::process`, `std::env`, `std::fs`, FFI, ...) is best-effort only, and
hostile policies must use the separate-container path below for those tasks. The wrappers capture trusted references early and freeze/compare what is cheap (Ruby
reporter/Result/Runnable frozen, unittest classes compared), but a perfect in-process defence is
impossible. Mitigation is per-test process isolation (done for Rust; Go reports per package
and is protected by the nonce only) and, for hostile policies, the supported path below.

**Supported hostile-agent path:** run the agent episode and the grade in **separate Linux
containers** with Bubblewrap and a seccomp profile. Grading needs only the final workspace
tree: tar the workspace out of the episode container and call `verify(task_id, workspace)`
in a fresh grader container (the Docker `grader` target; it needs neither the episode nor
reference patches). The Linux `--ro-bind` of the wrapper directory and inherited-fd passing
through `bwrap` were validated on Linux arm64 on 2026-10-30 (see "Docker and submission").

Agent bash commands and grading subprocesses have scrubbed environments and no
network, including loopback. macOS uses `sandbox-exec` to deny the home,
checkout/corpus, and other temporary directories while granting toolchain reads
and episode-local writes. Linux uses Bubblewrap with separate PID/user/network
namespaces and explicit system/toolchain mounts; neither the server directory
nor `/grader` is mounted. There is no unsandboxed fallback. The action API uses
relative paths and refuses symlinks, hardlinks, and nonregular files for host
reads/writes. This is not an independently audited hostile-code service.

**macOS execution is for trusted development only and is refused unless `STRIM_ENVS_TRUSTED_LOCAL=1` is set** (`tests/conftest.py` sets it for local runs; without it every sandboxed command and grade fails closed). The Seatbelt profile is
allow-default with a deny-list: `/Users` (except toolchains), `/Volumes`,
`/Applications` and `/opt/homebrew` stay readable, and parent directory names
remain listable. There is no `RLIMIT_NPROC`, memory or CPU cap beyond
`ulimit -f` (file size). Escaped background processes (`setsid`, double fork)
are tracked by process-tree polling and by working directory inside the
episode's temporary tree, and killed after each command and on `close()`; only
processes the episode itself spawned are targeted. A process that changes its
directory before the host sees it can still outlive a command. The Linux
Bubblewrap PID namespace is the real boundary; use it for untrusted agents.

### Container-boundary fallback (OpenEnv Arena)

If `bwrap` cannot create its namespaces (probe: `bwrap --ro-bind / / --unshare-all --proc /proc --dev /dev true`,
re-probed until it succeeds) **and** `STRIM_ENVS_CONTAINER_BOUNDARY=1` is set, agent commands and grading run as
`/bin/sh -c` in the work dir with a minimal env (toolchain PATH, HOME/TMPDIR in the episode scratch, LANG), a new
session, the same timeout, kill and output caps, and `ulimit -f`. A loud warning is logged on stderr at first use.
Without the variable nothing falls back: the sandbox error is raised. Only the `grader` image sets it. In the arena the
per-episode container is the isolation boundary; `/app` and `/grader` are root-owned and not writable by the server uid.
Leftover processes of the episode are killed (process group, session and cwd walk) before grading.

Residual risk in the fallback: agent commands run as the server uid and have network access. They can read
`/grader` (manifests, expected test names, wrappers), `/proc/<server pid>/fd` and the server's memory-adjacent state, so a
determined agent can learn expected test names and can forge results. A separate agent uid via a privilege-dropping
helper is future work.

## Tasks

| Language | Task IDs | Required toolchain |
| --- | --- | --- |
| JavaScript | js-01, js-02 | Node 24 |
| TypeScript | ts-01, ts-02 | Node 24, TypeScript 5.9.3 |
| React | rx-02, rx-03 | Bun 1.3.0 (React fixtures restored only by grader) |
| Go | tf-02, tf-03 | Go 1.25 |
| Ruby | rb-01, rb-02 | Ruby with minitest |
| Python | py-01, py-02 | Python 3 |
| Rust | rs-01, rs-02 | Rust/Cargo 1.91 |
| Java | jv-01, jv-02 | JDK (no Maven/Gradle downloads) |

These are the previously selected tasks; none occurs in the excluded split
`/tmp/ev1/run2/split.json`. No hard-task corpus is used.

## Run locally

Use Python 3.11–3.14 plus the task toolchains, `git`, and the OS sandbox. Run
commands from the repository root. OpenEnv and Prime use **separate venvs**:
OpenEnv 0.11.0's FastMCP requires MCP below 2, whereas verifiers 0.4.0 pins MCP
2.0.0. Do not install both extras into one environment.

Editable installs find the corpus in this checkout. For an installed wheel or
an exported corpus elsewhere, set `STRIM_ENVS_CORPUS` to the trusted directory
containing `manifest.json` and `tasks/`. Keep that directory outside every agent
workspace. Docker sets it to `/grader` automatically.

```sh
mkdir -p /tmp/env1
python3 -m venv /tmp/env1/venv
TMPDIR=/tmp/env1 /tmp/env1/venv/bin/pip install -e 'envs[openenv,test]'
ENABLE_WEB_INTERFACE=false TMPDIR=/tmp/env1 /tmp/env1/venv/bin/python -m uvicorn \
  strim_envs.openenv_server:app --host 127.0.0.1 --port 8000
```

The adapter subclasses official `Environment`, `Action`, `Observation`, and
`State` and uses official `create_app`. It exposes the standard `/reset`,
`/step`, `/state`, `/health`, `/schema`, and `/ws` routes. Use the official
WebSocket client for persistent episodes: OpenEnv's legacy HTTP reset/step
routes instantiate a separate environment for each request.

```python
from strim_envs.openenv_server import StrimAction, StrimClient

with StrimClient(base_url="http://127.0.0.1:8000").sync() as client:
    result = client.reset(task_id="js-01", seed=42)
    print(result.observation.prompt, result.observation.files)
    result = client.step(StrimAction(operation="read", path="lib/semver.js"))
    print(result.observation.output)
    # Edit source via further actions, then end the episode:
    result = client.step(StrimAction(operation="finish"))
    print(result.done, result.reward)
```

Reset accepts `task_id`; otherwise `seed` selects one of the 16 tasks. Every
reset gets a fresh workspace. Each WebSocket session owns its environment.
Actions are `list` (recursive file listing), `read`, `grep` (literal substring),
`write` (`content`), `edit` (`old_text` must match once, `new_text`), `bash`
(`command`), and `finish`. File actions take `path`. Text outputs are bounded to
65,536 characters, writes to 64 KiB, listings to 2,000 files, and grep scans at
most 1 MiB. Bash accepts a
`timeout` up to 10 seconds, caps file size, and reaps its process group after
each command. An episode also ends at 100 steps or on the first action after
600 seconds. Actions cannot continue after termination. Intermediate rewards
are zero; termination invokes the grader once.

## Prime taskset

The pinned API is `verifiers==0.4.0`, with `TaskData`, `Task`, `Taskset`,
`@vf.stop`, and `@vf.reward`. The package exports `StrimTaskset` for discovery as
`strim-envs`. It uses a single-turn **patch response**: the public files are JSON
context in the prompt, and the final answer is a unified git diff (optionally
in a diff fence). The trusted evaluator applies it to a fresh public workspace,
then uses the same grader. It does not provision a shell for the model. No
reference patch or test contents enter task data. An empty patch grades the
original broken workspace; malformed patches score zero.

```sh
python3 -m venv /tmp/env1/prime-venv
TMPDIR=/tmp/env1 /tmp/env1/prime-venv/bin/pip install -e 'envs[prime]'
# Package/config loading only; no model call:
(cd /tmp/env1 && TMPDIR=/tmp/env1 /tmp/env1/prime-venv/bin/vf-eval strim-envs \
  --env.agent.harness.id null --dry-run)
```

The smoke test uses the official `load_environment` and `Task.score` with real
traces, no mocked reward or runtime. It loads all 16 tasks and scores js-01's
reference, unchanged broken, invalid, and protected-test patches as 1/0/0/0.
Cloud runtime provisioning and a Hub upload have not been tested. Current
upstream docs may describe additions after 0.4.0; this adapter targets the
installed, tested release API.

## Verification

```sh
TMPDIR=/tmp/env1 ENABLE_WEB_INTERFACE=false \
STRIM_PRIME_PYTHON=/tmp/env1/prime-venv/bin/python \
/tmp/env1/venv/bin/python -m pytest envs/tests \
  --basetemp=/tmp/env1/pytest-envs -q
bash packaging/release/check-python-paths.sh
```

`tests/test_hacks.py` holds the reward-hack regressions (for every language: forged passing output plus a hard exit prepended to a source file, a forged JUnit for Bun, writes to inherited fds without the nonce, one control-file injection per language, and the macOS opt-in gate), plus the earlier ones: py-01 `os._exit(0)`,
tf-02 `TestMain` exit, Cargo `autotests = false`, ruby `minitest/autorun`
shadow, js `process.exit(0)` at import, forged TAP output without test names,
a missing expected-test record, a symlink swapped in after the pre-scan, and a
FIFO, plus a Rust argv-driven constructor forgery and a safe-Rust `process::exit(0)` variant; each must score `0.0`, while the reference solution with a tampered
manifest or shadow file still scores `1.0`. `tests/test_episode.py` adds
`setsid`/double-fork escape and unrelated-process-safety checks. Missing
language executables skip their core reference test. The OpenEnv
conformance test starts its own loopback uvicorn process on an OS-assigned
port, connects through the official client, exercises reset/read/bash/finish,
and scores both solved and broken episodes. Other tests cover isolation,
tampering, offline bash, timeouts, source file actions, fresh workspaces, and
reference-free grader asset export. These are headless tests. No GUI, GPU, model
run, or Strim server is needed.

Local results on 2026-10-30: **88 passed** with `STRIM_PRIME_PYTHON` set;
**87 passed, 1 skipped** without it (the Prime test skips with an explicit
reason when `verifiers` is not importable), including all 16 tasks'
reference/broken/tamper checks. OpenEnv static manifest validation,
the Prime config-only dry run, both venv dependency checks, and the Python-path
release gate passed. Linux container validation: see "Docker and submission".

## Docker and submission (owner steps)

Build context is the **repository root**, not `envs/`. The `agent` target
contains only toolchains, without task data or environment source. The trusted
`grader` target includes the server plus selected manifests/snapshots at
`/grader`; it excludes every reference patch. Corpus access during the build is
a read-only BuildKit bind mount, so the full corpus is not copied into a layer.
Never expose a shell in the grader image to an external agent. The OpenEnv API's
bash action instead executes inside Bubblewrap with only its public workspace.

```sh
docker buildx build --check --platform=linux/amd64 --target grader -f envs/Dockerfile .
docker buildx build --platform=linux/amd64 --target agent -f envs/Dockerfile \
  -t REGISTRY/strim-agent:0.0.1 --load .
docker buildx build --platform=linux/amd64 --target grader -f envs/Dockerfile \
  -t REGISTRY/strim-grader:0.0.1 --load .
```

**Linux validation result:** Linux arm64 validation 85 passed, 1 skipped (macOS-only test) on
2026-10-30, in the `grader` target built with `STRIM_VALIDATE_ARM64=1` on Docker Desktop
(`test_core`, `test_episode`, `test_openenv`, `test_hacks`, run with the command below).
This covers every task's reference/broken/tamper check, Bubblewrap fd passing, the
read-only wrapper bind, and cleanup of `setsid` escapees. The amd64 published image has
not been built or run on a native amd64 host; base/toolchain tags still need registry
resolution and a hadolint pass.

Container requirements for validation:

- Nested Bubblewrap needs unprivileged user namespaces and an unmasked `/proc`. On Docker
  that means `--security-opt seccomp=unconfined --security-opt apparmor=unconfined
  --security-opt systempaths=unconfined`, or a runtime that allows both natively. These
  relaxations belong to the trusted grader container only, never to the agent image or
  any container an agent can reach.
- Under amd64 emulation on Apple silicon, `bwrap` fails with `Can't open source /:
  Function not implemented`. Use a native amd64 Linux host for the published image, or the
  arm64 validation build (`--build-arg STRIM_VALIDATE_ARM64=1 --platform=linux/arm64`) to
  check the logic.

Before submitting, the owner must:

1. Start Docker on a disposable Linux/amd64 runner, rerun `--check`, build both
   targets, and run all reference/broken/tamper tests and client conformance in
   the grader container (the grader now runs as unprivileged uid 1001 with
   `/grader` and `/app` world-readable). Use a runner that supports Bubblewrap's unprivileged
   user namespaces. If the sandbox fails, fix the runner policy; no offline
   protection is bypassed by the package.
2. Inspect the agent image and public workspaces for private assets; verify
   Linux network/filesystem isolation, process cleanup, image sizes, and CPU/RAM
   limits with the intended hosting runtime. Pin resolved base/toolchain image
   digests and dependency locks for a reproducible release: `openenv-base:latest`,
   `node:24-bookworm-slim`, `golang:1.25-bookworm`, `rust:1.91-bookworm` and
   `oven/bun:1.3.0` are still unpinned tags (see the TODO in the Dockerfile).
   Node is copied into `/opt/strim-toolchains/node` instead of overlaying the
   base image's `/usr/local`.
3. Publish separately named agent/grader images to the owner's registry. Deploy
   the trusted OpenEnv server on port 8000. `envs/openenv.yaml` provides its local
   app/reward/resource contract. Direct `openenv push envs/` is not a prepared
   standalone upload bundle: this Dockerfile needs the repo build context.
4. For OpenEnv Arena, obtain the current owner submission instructions and
   register the two images, 16 tasks, binary reward, licenses, and example
   results. Confirm the platform's agent/grader separation and submission
   descriptor before upload. For Prime, publish/install this package with its
   `prime` extra and source assets on the trusted evaluator, then follow the
   current Hub/prime-envs owner publishing process. Authentication, registry
   writes, descriptor acceptance, and remote runs remain owner actions.
5. Populate the baseline section from authorized Strim runs and attach measured
   environment/image resource sizes and the Linux validation results.

For step 1, the trusted validation-only mount below supplies the pytest files
and reference patches; neither is present in the published images. Bubblewrap
must hide `/validation` from all sandboxed commands. The grader image includes
pytest, so this check needs no runtime dependency download:

```sh
docker run --rm --platform=linux/amd64 --network=none \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  --security-opt systempaths=unconfined \
  -v "$PWD:/validation:ro" \
  -e PYTHONPATH=/validation/envs \
  -e STRIM_ENVS_CORPUS=/validation/bench/agenttasks \
  --entrypoint /app/venv/bin/python REGISTRY/strim-grader:0.0.1 \
  -m pytest /validation/envs/tests/test_core.py \
  /validation/envs/tests/test_episode.py /validation/envs/tests/test_openenv.py \
  /validation/envs/tests/test_hacks.py \
  --basetemp=/tmp/pytest-envs -p no:cacheprovider -q
```

## Official format sources

Checked against upstream docs and the installed package APIs on 2026-10-30:

- [OpenEnv environment builder/deployment](https://github.com/huggingface/OpenEnv/blob/main/docs/source/getting_started/environment-builder.md)
- [OpenEnv first environment: exact models, environment, factory, client](https://github.com/huggingface/OpenEnv/blob/main/docs/source/guides/first-environment.md)
- [OpenEnv Arena owner entry point](https://huggingface.co/openenvarena)
- [Prime environments: exported tasksets and package workflow](https://github.com/PrimeIntellect-ai/prime-envs)
- [Verifiers tasksets and reward hooks](https://github.com/PrimeIntellect-ai/verifiers/blob/main/docs/tasksets.md)
- [Verifiers evaluator/solver/grader separation](https://github.com/PrimeIntellect-ai/verifiers/blob/main/docs/building-environments.md)

## Baseline

Placeholder: populate from authorized Strim runs. No model or GPU baseline was
run for this implementation.

## License

Environment code: Apache-2.0, like this repository. Selected tasks retain the
licenses recorded in their individual `task.json` files.
