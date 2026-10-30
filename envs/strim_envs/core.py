"""Trusted task materialization and fail-closed, offline verification."""
from __future__ import annotations

import collections
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
CORPUS = Path(os.environ.get("STRIM_ENVS_CORPUS", ROOT / "bench" / "agenttasks"))
TASK_IDS = ("js-01", "js-02", "ts-01", "ts-02", "rx-02", "rx-03",
            "tf-02", "tf-03", "rb-01", "rb-02", "py-01", "py-02",
            "rs-01", "rs-02", "jv-01", "jv-02")
SKIP = {".git", "__pycache__", ".pytest_cache"}


def task(task_id: str) -> dict:
    if task_id not in TASK_IDS:
        raise ValueError("unknown task")
    manifest = json.loads((CORPUS / "manifest.json").read_text())
    if task_id not in {item["id"] for item in manifest["tasks"]}:
        raise ValueError("task missing from manifest")
    return json.loads((CORPUS / "tasks" / task_id / "task.json").read_text())


def _materialize(task_id: str, destination: Path, *, grading: bool) -> None:
    spec = task(task_id)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    archive = CORPUS / "tasks" / task_id / spec["snapshot"]
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            p = Path(member.name)
            if p.is_absolute() or ".." in p.parts or not (member.isfile() or member.isdir()):
                raise ValueError("unsafe snapshot member")
        protected = spec["test_paths"]
        for name in protected:
            safe_relative(name)
        # Filter before extraction: protected data never lands in the agent view.
        visible = [m for m in members if not any(
            Path(m.name) == Path(p) or Path(p) in Path(m.name).parents
            for p in protected)]
        if any(Path(m.name).name in {"solution.patch", "task.json", "snapshot.tar.gz"}
               for m in visible):
            raise ValueError("grading artifact in snapshot")
        chosen = members if grading else visible
        if hasattr(tarfile, "data_filter"):
            tar.extractall(destination, members=chosen, filter="data")
        else:
            tar.extractall(destination, members=chosen)


def materialize(task_id: str, destination: Path) -> None:
    """Create only the agent view; hidden tests and solutions are never extracted."""
    _materialize(task_id, destination, grading=False)


def safe_relative(name: str) -> Path:
    path = Path(name)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError("unsafe relative path")
    return path


def hashes(root: Path, paths: list[str]) -> dict[str, str]:
    result = {}
    for name in paths:
        safe_relative(name)
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and not (Path(directory) / d).is_symlink())
        for filename in sorted(files):
            file = Path(directory) / filename
            if file.is_symlink():
                continue
            rel = file.relative_to(root).as_posix()
            if any(rel == p or rel.startswith(p + "/") for p in paths):
                result[rel] = hashlib.sha256(file.read_bytes()).hexdigest()
    return result


def _quote(path: Path) -> str:
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


def _sandbox(work: Path, scratch: Path, command: str, tools: Path | None = None) -> list[str]:
    """Sandbox argv. ``tools`` (grader-owned) is readable but never writable inside."""
    work.relative_to(scratch)
    if sys.platform == "darwin" and Path("/usr/bin/sandbox-exec").is_file():
        if os.environ.get("STRIM_ENVS_TRUSTED_LOCAL") != "1":
            raise RuntimeError("macOS Seatbelt profile is not hostile-safe; set STRIM_ENVS_TRUSTED_LOCAL=1 "
                               "for trusted local development only, or use Linux bwrap")
        home = Path.home()
        allowed = [home / ".nvm/versions", home / ".rustup/toolchains", home / ".cargo/bin", home / ".rbenv/versions", home / ".rbenv/shims"]
        profile = '(version 1)(allow default)(deny network*)(deny file-write*)'
        for p in (home, Path('/private/tmp'), Path('/tmp'), Path('/private/var/folders'),
                  Path(tempfile.gettempdir()).resolve(), CORPUS.resolve(), ROOT):
            profile += '(deny file-read* (subpath ' + _quote(p) + '))'
        profile += '(allow file-read-metadata (literal ' + _quote(home) + '))'
        profile += '(allow file-write* (literal "/dev/null"))'
        # Re-enable installed toolchains within denied private roots; keep the
        # checkout, grader and sibling temporary episodes unreadable.
        for p in (Path('/usr'), Path('/bin'), Path('/sbin'), Path('/System'),
                  Path('/Library/Java'), Path('/opt/homebrew'), Path('/private/etc'), Path('/dev')):
            profile += '(allow file-read* (subpath ' + _quote(p) + '))'
        for parent in (home / '.nvm', home / '.rustup', home / '.cargo', home / '.rbenv'):
            profile += '(allow file-read-metadata (literal ' + _quote(parent) + '))'
        for p in allowed:
            if p.exists():
                profile += '(allow file-read* (subpath ' + _quote(p) + '))'
        # Grant the fixed episode root only. Never resolve an agent-controlled
        # workspace symlink and accidentally grant access to its target.
        for p in (scratch,):
            profile += '(allow file-read* file-write* (subpath ' + _quote(p.resolve()) + '))'
            for parent in p.resolve().parents:
                profile += '(allow file-read-metadata (literal ' + _quote(parent) + '))'
                if parent != home and parent != Path('/'):
                    profile += '(allow file-read-data (literal ' + _quote(parent) + '))'
        if tools is not None:
            profile += '(allow file-read* (subpath ' + _quote(tools.resolve()) + '))'
            # Descriptor paths for runners that cannot adopt an inherited fd directly.
            profile += '(allow file-write* (regex #"^/dev/fd/[0-9]+$"))'
            # Last match wins: the trusted wrappers are read-only to everything inside.
            profile += '(deny file-write* (subpath ' + _quote(tools.resolve()) + '))'
        # Agent commands may signal only targets inside their own sandbox.
        profile += '(deny signal)(allow signal (target same-sandbox))'
        return ["/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", command]
    if sys.platform.startswith("linux") and _bwrap_usable():
        argv = ["bwrap","--die-with-parent", "--new-session", "--unshare-all"]
        for name in ("/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt/strim-toolchains"):
            if Path(name).exists():
                argv += ["--ro-bind", name, name]
        argv += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--bind", str(scratch), str(scratch)]
        if tools is not None:
            argv += ["--ro-bind", str(tools), str(tools)]
        return argv + ["--chdir", str(work), "/bin/sh", "-c", command]
    if sys.platform.startswith("linux") and os.environ.get("STRIM_ENVS_CONTAINER_BOUNDARY") == "1":
        # Explicit opt-in only (set in the grader image). No namespace sandbox could be created
        # (nested container without user namespaces), so the per-episode container is the
        # isolation boundary. Callers supply the minimal env, cwd and a new session/process
        # group; the command keeps its ``ulimit -f`` prefix, timeout and output caps.
        global _WARNED
        if not _WARNED:
            _WARNED = True
            print("STRIM-ENVS WARNING: bwrap unavailable; STRIM_ENVS_CONTAINER_BOUNDARY=1 so agent "
                  "commands run UNSANDBOXED as the server uid (the container is the only boundary)",
                  file=sys.stderr, flush=True)
        return ["/bin/sh", "-c", command]
    raise RuntimeError("offline verification sandbox unavailable")


_WARNED = False
_BWRAP_OK = False


def _bwrap_usable() -> bool:
    """Probe whether bwrap can create its namespaces; only success is cached (failure re-probes)."""
    global _BWRAP_OK
    if _BWRAP_OK:
        return True
    if not shutil.which("bwrap"):
        return False
    try:
        probe = subprocess.run(
            ["bwrap", "--ro-bind", "/", "/", "--unshare-all", "--proc", "/proc", "--dev", "/dev", "true"],
            stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return False
    _BWRAP_OK = probe.returncode == 0
    return _BWRAP_OK


EXPECTED = Path(__file__).with_name("expected_tests.json")
POLICY = Path(__file__).with_name("edit_policy.json")
GRADERS = Path(__file__).with_name("graders")
OUTPUT_LIMIT = 16 * 1024 * 1024

# --- Allowed edit set -------------------------------------------------------------
# Everything in the submitted tree that is not an allowed edit is restored from (or
# removed to match) the trusted base before grading, so discovery/runner control files
# (conftest.py, sitecustomize.py, *.pth, node_modules/, tsconfig*, jest/mocha config,
# pom.xml, build.gradle, .rspec-local, test_helper.rb, build.rs, ...) cannot survive.
# Allowed: the files the reference solution edits, plus code-extension files under the
# directories it edits whose names do not look like tests, config or hidden files.
CODE_EXT = {
    "javascript": {".js", ".mjs", ".cjs", ".jsx"},
    "typescript": {".ts", ".tsx", ".mts", ".cts", ".js", ".mjs", ".cjs", ".jsx"},
    "react": {".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx"},
    "go": {".go"}, "ruby": {".rb"}, "python": {".py"}, "rust": {".rs"}, "java": {".java"},
}
BLOCKED_DIRS = {"node_modules", "target", "vendor", "testdata", "__pycache__", "build", "dist",
                "bin", "scripts", "test", "tests", "spec", "specs", "__tests__", "fixtures"}
BLOCKED_NAMES = {"conftest.py", "sitecustomize.py", "usercustomize.py", "setup.py", "build.rs",
                 "test_helper.rb", "spec_helper.rb", "package.json", "Rakefile", "Gemfile", "Makefile"}
TEST_LIKE = re.compile(r"(^|[._-])(test|tests|spec|specs)([._-]|$)", re.I)
CONFIG_LIKE = re.compile(r"\.(config|setup|conf)\.|^(tsconfig|jsconfig|jest|mocha|babel|bunfig|vitest)", re.I)


def edit_policy(task_id: str) -> dict:
    record = json.loads(POLICY.read_text()).get(task_id)
    if not record or not record.get("files"):
        raise ValueError("no trusted edit-policy record")
    return record


def _permitted(rel: str, policy: dict, language: str) -> bool:
    if rel in policy["files"]:
        return True
    pure = PurePosixPath(rel)
    name = pure.name
    if name.startswith(".") or name in BLOCKED_NAMES or TEST_LIKE.search(name) or CONFIG_LIKE.search(name):
        return False
    if pure.suffix not in CODE_EXT[language]:
        return False
    if any(part.startswith(".") or part in BLOCKED_DIRS or TEST_LIKE.search(part) for part in pure.parts[:-1]):
        return False
    return any(d == "." or rel.startswith(d + "/") for d in policy["dirs"])


def _files(root: Path) -> set[str]:
    found = set()
    for directory, _dirs, names in os.walk(root, followlinks=False):
        for name in names:
            found.add((Path(directory) / name).relative_to(root).as_posix())
    return found


def _sync_to_base(base: Path, work: Path, policy: dict, language: str) -> None:
    """Make work equal to base everywhere except at allowed edits."""
    base_files, work_files = _files(base), _files(work)
    for rel in work_files - base_files:
        if not _permitted(rel, policy, language):
            (work / rel).unlink()
    for rel in base_files:
        if _permitted(rel, policy, language) and (work / rel).is_file():
            continue
        target = work / rel
        if target.is_symlink() or target.is_file():
            target.unlink()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(base / rel, target)
    base_dirs = {p.relative_to(base).as_posix() for p in base.rglob("*") if p.is_dir()}
    for directory, dirs, names in os.walk(work, topdown=False, followlinks=False):
        rel = Path(directory).relative_to(work).as_posix()
        if rel != "." and rel not in base_dirs and not os.listdir(directory):
            os.rmdir(directory)


def expected_tests(task_id: str) -> collections.Counter:
    names = json.loads(EXPECTED.read_text()).get(task_id)
    if not names:
        raise ValueError("no trusted expected-test record")
    return collections.Counter(names)


def _copy_regular(src, dst):
    """Copy one regular file without following links or blocking on special files."""
    fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("special file in workspace")
        with open(dst, "xb") as target:
            shutil.copyfileobj(source, target)
        os.chmod(dst, stat.S_IMODE(info.st_mode))
    return dst


def _only_plain(root: Path) -> bool:
    """True when root holds only real directories and regular files."""
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in (*dirs, *files):
            mode = os.lstat(Path(directory) / name).st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                return False
    return True


# --- Trusted result channel -------------------------------------------------------
# The grader runs the language's runner through a grader-owned wrapper (graders/, staged
# read-only outside the workspace). A per-run nonce is delivered on a pre-filled pipe
# that the wrapper reads and closes before any agent code loads; the wrapper writes
# ``<nonce> <json>`` records to a grader-held append-only file descriptor and finishes
# with an ``end`` trailer. Reward needs a valid trailer, exit 0, every record carrying
# the nonce, every expected test passed exactly once and runner total == expected count.
# Rust (libtest) and the nonce-less `end` of Go are described in the README.


class _Grade:
    def __init__(self, work: Path, scratch: Path, tools: Path, env: dict, deadline: float):
        self.work, self.scratch, self.tools, self.env, self.deadline = work, scratch, tools, env, deadline
        self.nonce = secrets.token_hex(16)
        self.path = scratch.parent / "channel"
        fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
        self.cfd = fcntl.fcntl(fd, fcntl.F_DUPFD, secrets.randbelow(50) + 90)
        os.close(fd)
        placeholder = os.open(os.devnull, os.O_RDONLY)
        self.nfd = fcntl.fcntl(placeholder, fcntl.F_DUPFD, secrets.randbelow(50) + 150)
        os.close(placeholder)

    def close(self) -> None:
        for fd in (self.cfd, self.nfd):
            try:
                os.close(fd)
            except OSError:
                pass

    def run(self, command: str, stdout=None, extra_env: dict | None = None) -> int | None:
        """Run one sandboxed command; None on timeout or lack of time."""
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            return None
        reader, writer = os.pipe()
        os.write(writer, self.nonce.encode())
        os.close(writer)
        os.dup2(reader, self.nfd)
        os.close(reader)
        argv = _sandbox(self.work, self.scratch, "ulimit -f 4000000; " + command, self.tools)
        env = {**self.env, **(extra_env or {})}
        with tempfile.TemporaryFile() as sink:
            process = subprocess.Popen(
                argv, cwd=self.work, env=env, stdin=subprocess.DEVNULL,
                stdout=stdout if stdout is not None else sink, stderr=sink,
                pass_fds=(self.nfd, self.cfd), start_new_session=True)
            try:
                return process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                return None
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()

    def raw(self) -> str:
        return self.path.read_bytes()[:OUTPUT_LIMIT].decode("utf-8", errors="replace")

    def records(self) -> list[dict] | None:
        """Parsed channel records; None if any line lacks the nonce or is not an object."""
        records = []
        prefix = self.nonce + " "
        for line in self.raw().splitlines():
            if not line.startswith(prefix):
                return None
            try:
                record = json.loads(line[len(prefix):])
            except ValueError:
                return None
            if not isinstance(record, dict):
                return None
            records.append(record)
        return records


def _judge(records: list[dict] | None, code: int | None, ends: int = 1) -> collections.Counter | None:
    """Passed-test multiset from a trailer-protected channel, or None on any irregularity."""
    if code != 0 or not records:
        return None
    trailers = [r for r in records if r.get("k") == "end"]
    if len(trailers) != ends or any(r is not records[-1] for r in trailers[-1:]):
        return None
    if any(r.get("k") not in ("pass", "end") or not isinstance(r.get("n", ""), str) for r in records):
        return None
    if any(t.get("ok") is not True for t in trailers):
        return None
    names = collections.Counter(r["n"] for r in records if r["k"] == "pass")
    if sum(t.get("total", -1) for t in trailers) != sum(names.values()):
        return None
    return names


def _q(path) -> str:
    return shlex.quote(str(path))


def _grade_python(g: _Grade, spec: dict) -> collections.Counter | None:
    m = re.fullmatch(r"python3 -I -B -m unittest discover -s (\S+) -t (\S+)", spec["verify_cmd"])
    if not m:
        raise ValueError("unexpected verify command")
    code = g.run(f"exec python3 -I -B {_q(g.tools / 'py_run.py')} {g.nfd} {g.cfd} {m[1]} {m[2]}")
    return _judge(g.records(), code)


def _grade_node(g: _Grade, spec: dict) -> collections.Counter | None:
    prefix, sep, rest = spec["verify_cmd"].rpartition("node --test")
    if not sep or rest or prefix.strip() not in ("", "tsc --noEmit -p . &&"):
        raise ValueError("unexpected verify command")
    code = g.run(f"{prefix}node {_q(g.tools / 'node_run.mjs')} {g.nfd} {g.cfd} 'test/**/*.test.*'")
    return _judge(g.records(), code)


def _grade_bun(g: _Grade, spec: dict) -> collections.Counter | None:
    if spec["verify_cmd"] != "bun test":
        raise ValueError("unexpected verify command")
    code = g.run(f"exec bun {_q(g.tools / 'bun_run.mjs')} {g.nfd} {g.cfd} "
                 f"{_q(g.tools / 'bun_shim.mjs')} 'test/**/*.test.*'")
    return _judge(g.records(), code)


def _grade_ruby(g: _Grade, spec: dict) -> collections.Counter | None:
    m = re.fullmatch(r"ruby -Ilib -Itest (\S+)", spec["verify_cmd"])
    if not m:
        raise ValueError("unexpected verify command")
    code = g.run(f"exec ruby {_q(g.tools / 'rb_run.rb')} {g.nfd} {g.cfd} {m[1]}")
    return _judge(g.records(), code)


def _grade_java(g: _Grade, spec: dict) -> collections.Counter | None:
    if spec["verify_cmd"] != "./scripts/javatest.sh":
        raise ValueError("unexpected verify command")
    suite = (g.work / "src/test/java/tests/AllTests.java").read_text()
    classes = sorted(set(re.findall(r"\b([A-Z]\w*)\.class\b", suite)))
    if not classes:
        raise ValueError("no test classes")
    qualified = " ".join("tests." + name for name in classes)
    command = ('OUT="$TMPDIR/javatest-classes"; rm -rf "$OUT"; mkdir -p "$OUT"; '
               'javac -encoding UTF-8 -Xlint:none -d "$OUT" $(find src -name "*.java") && '
               f'exec java -ea -cp {_q(g.tools / "java")}:"$OUT" StrimRun {g.nfd} {g.cfd} {qualified}')
    code = g.run(command)
    return _judge(g.records(), code)


# Best-effort denylist; hostile policies must use the separate Linux container grader.
_RUST_FORBIDDEN = re.compile(
    r'\bunsafe\b|link_section|std::process|process::exit|std::env|env::args|std::fs|std::io::Write'
    r'|libc|extern\s+"C"|no_mangle|\bexit\(|#!\[|global_asm|asm!|include!|include_str|include_bytes'
    r'|macro_rules!.*\bexit')


def _rust_sources_clean(work: Path) -> bool:
    """Fail closed: any non-test .rs file with a forbidden construct scores 0."""
    root = work.resolve()
    for path in root.rglob("*.rs"):
        rel = path.relative_to(root).parts
        if rel[0] in ("tests", "target"):
            continue
        try:
            if _RUST_FORBIDDEN.search(path.read_bytes().decode("utf-8", errors="replace")):
                return False
        except OSError:
            return False
    return True


def _grade_rust(g: _Grade, spec: dict) -> collections.Counter | None:
    """libtest has no in-process hook, so the runner is driven from the grader.

    ``cargo test --no-run`` locates the integration-test binaries (only targets under
    tests/ are trusted; unit tests in agent-editable sources are not run). Each is run
    listed with ``--list`` and then run one test per process (``--exact``): the grader
    requires exit 0, libtest's "1 passed" summary on grader-held stdout, and exactly one
    ``ok`` line on libtest's ``--logfile`` at a random high descriptor. Agent code in that
    process can reach the descriptor by scanning fds (no nonce is possible in libtest).
    """
    if spec["verify_cmd"] != "cargo test --offline --quiet":
        raise ValueError("unexpected verify command")
    if not _rust_sources_clean(g.work):
        return None
    with tempfile.TemporaryFile() as built:
        if g.run("cargo test --offline --no-run --message-format=json", stdout=built) != 0:
            return None
        built.seek(0)
        listing = built.read(OUTPUT_LIMIT).decode("utf-8", errors="replace")
    suites = []
    for line in listing.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if (isinstance(event, dict) and event.get("reason") == "compiler-artifact"
                and event.get("profile", {}).get("test") and event.get("executable")
                and "test" in event["target"]["kind"]):
            source = Path(event["target"]["src_path"]).resolve()
            try:
                suites.append((source.relative_to(g.work.resolve()).as_posix(), event["executable"]))
            except ValueError:
                return None
    if not suites:
        return None
    names = collections.Counter()
    manifest = f"CARGO_MANIFEST_DIR={_q(g.work)} "
    for suite, executable in suites:
        with tempfile.TemporaryFile() as listing_out:
            if g.run(manifest + f"exec {_q(executable)} --list", stdout=listing_out) != 0:
                return None
            listing_out.seek(0)
            listed = listing_out.read(OUTPUT_LIMIT).decode("utf-8", errors="replace")
        tests = [line[:-6] for line in listed.splitlines() if line.endswith(": test")]
        if not tests:
            return None
        for name in tests:
            g.path.write_bytes(b"")
            with tempfile.TemporaryFile() as summary:
                code = g.run(manifest + f"exec {_q(executable)} --exact {_q(name)} --test-threads=1 "
                             f"--logfile /dev/fd/{g.cfd}", stdout=summary)
                summary.seek(0)
                shown = summary.read(OUTPUT_LIMIT).decode("utf-8", errors="replace")
            # Exit 0 from the grader-side wait, libtest's own summary on the grader-held
            # stdout, and exactly one "ok" line on the hidden logfile descriptor.
            if code != 0 or g.raw().splitlines() != [f"ok {name}"]:
                return None
            if not re.search(r"^test result: ok\. 1 passed; 0 failed;", shown, re.M):
                return None
            names[f"{suite}::{name}"] += 1
    return names


def _grade_go(g: _Grade, spec: dict) -> collections.Counter | None:
    """Build per-package test binaries with a grader-owned first-initialised guard package.

    The guard (injected through ``go test -overlay``; nothing is written into the workspace)
    reads the nonce before any package-level code of the package under test and a generated
    TestMain reports ``m.Run()``'s exit code through the nonce channel. Test names come from
    ``go tool test2json`` over the binary's ``-test.v=test2json`` stream; a forged stream can
    add events but cannot make a failing run report code 0 or survive a hard exit.
    """
    if spec["verify_cmd"] != "go test -count=1 ./...":
        raise ValueError("unexpected verify command")
    with tempfile.TemporaryFile() as listed:
        template = "{{.ImportPath}}\t{{.Dir}}\t{{.Name}}\t{{len .TestGoFiles}}\t{{len .XTestGoFiles}}"
        if g.run("go list -m -f 'M\t{{.Path}}\t{{.Dir}}'; go list -f '" + template + "' ./...", stdout=listed) != 0:
            return None
        listed.seek(0)
        lines = listed.read(OUTPUT_LIMIT).decode("utf-8", errors="replace").splitlines()
    module = next((l.split("\t") for l in lines if l.startswith("M\t")), None)
    if not module or len(module) != 3:
        return None
    packages = []
    for line in lines:
        parts = line.split("\t")
        if len(parts) == 5 and parts[0] != "M" and int(parts[3]) + int(parts[4]) > 0:
            packages.append(parts)
    if not packages:
        return None
    gen = g.tools / "gen"
    gen.mkdir(exist_ok=True)
    modpath, moddir = module[1], module[2]
    guard_import = f"{modpath}/strimguard"
    guard_file = gen / "guard.go"
    guard_file.write_text((GRADERS / "go_guard.go.tmpl").read_text()
                          .replace("@NFD@", str(g.nfd)).replace("@CFD@", str(g.cfd)))
    replace = {f"{moddir}/strimguard/guard.go": str(guard_file)}
    main_template = (GRADERS / "go_main_test.go.tmpl").read_text()
    for index, (importpath, directory, name, _a, _b) in enumerate(packages):
        main_file = gen / f"main_{index}_test.go"
        main_file.write_text(main_template.replace("@PKGNAME@", name).replace("@GUARD@", guard_import)
                             .replace("@PKGPATH@", importpath))
        replace[f"{directory}/zz_strim_main_test.go"] = str(main_file)
    overlay = gen / "overlay.json"
    overlay.write_text(json.dumps({"Replace": replace}))
    binaries = g.scratch / "gobin"
    binaries.mkdir(exist_ok=True)
    build = " && ".join(
        f"go test -c -vet=off -overlay {_q(overlay)} -o {_q(binaries / f'{i}.test')} {shlex.quote(p[0])}"
        for i, p in enumerate(packages))
    if g.run(build) != 0:
        return None
    names = collections.Counter()
    for index, (importpath, directory, _name, _a, _b) in enumerate(packages):
        events = []
        with tempfile.TemporaryFile() as stream:
            code = g.run(f"cd {_q(directory)} && {_q(binaries / f'{index}.test')} -test.v=test2json "
                         f"-test.count=1 -test.timeout=50s 2>&1 | go tool test2json -p {shlex.quote(importpath)}",
                         stdout=stream)
            if code != 0:
                return None
            stream.seek(0)
            text = stream.read(OUTPUT_LIMIT).decode("utf-8", errors="replace")
        for line in text.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                return None
            if not isinstance(event, dict) or event.get("Package") != importpath:
                return None
            events.append(event)
        records = g.records()
        trailers = [r for r in (records or []) if r.get("pkg") == importpath]
        if (records is None or len(trailers) != 1 or trailers[0].get("k") != "end"
                or trailers[0].get("code") != 0 or records[-1] is not trailers[0]):
            return None
        g.path.write_bytes(b"")
        if any(e.get("Action") == "fail" for e in events):
            return None
        if not any(e.get("Action") == "pass" and not e.get("Test") for e in events):
            return None
        for event in events:
            if event.get("Action") == "pass" and event.get("Test"):
                names[f"{importpath}.{event['Test']}"] += 1
    return names


GRADERS_BY_LANGUAGE = {"javascript": _grade_node, "typescript": _grade_node, "react": _grade_bun,
                       "go": _grade_go, "ruby": _grade_ruby, "python": _grade_python,
                       "rust": _grade_rust, "java": _grade_java}


def _stage_tools(tools: Path, language: str) -> None:
    tools.mkdir()
    for item in GRADERS.iterdir():
        if item.is_file():
            shutil.copy2(item, tools / item.name)
    if language == "java":
        classes = tools / "java"
        classes.mkdir()
        subprocess.run(["javac", "-encoding", "UTF-8", "-Xlint:none", "-d", str(classes),
                        str(tools / "StrimRun.java")], check=True, capture_output=True,
                       env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")})


def run_checked(task_id: str, spec: dict, work: Path, scratch: Path, timeout: float,
                *, record: list[str] | None = None) -> bool:
    """Run the oracle; pass only on a valid trusted report AND every expected test passed.

    With ``record`` given (reference generation only) the observed passing names are
    appended to it and no expectation is consulted. ``scratch`` holds ``work`` and is the
    only sandbox-writable tree; trusted tools and the result channel live beside it.
    """
    home = scratch / "home"
    home.mkdir(exist_ok=True)
    tools = scratch.parent / "tools"
    _stage_tools(tools, spec["language"])
    tool_bins = sorted(Path.home().glob(".rustup/toolchains/stable-*/bin")) + sorted(Path.home().glob(".rbenv/versions/3.*/bin"), reverse=True)
    search_path = os.pathsep.join([*(str(p) for p in tool_bins), os.environ.get("PATH", "/usr/bin:/bin")])
    env = {"PATH": search_path, "HOME": str(home),
           "TMPDIR": str(scratch), "GOCACHE": str(scratch / "gocache"), "GOPROXY": "off",
           "GOSUMDB": "off", "GOTOOLCHAIN": "local", "GOFLAGS": "-buildvcs=false", "CGO_ENABLED": "0",
           "CARGO_HOME": str(scratch / "cargo"), "CI": "1", "LANG": "C.UTF-8"}
    grade = _Grade(work, scratch, tools, env, time.monotonic() + timeout)
    try:
        names = GRADERS_BY_LANGUAGE[spec["language"]](grade, spec)
    finally:
        grade.close()
    if names is None or not names:
        return False
    if record is not None:
        record.extend(sorted(names.elements()))
        return True
    return names == expected_tests(task_id)


def verify(task_id: str, workspace: Path, timeout: float = 60) -> float:
    """Return 1 only for an untampered workspace passing its offline oracle.

    Verifies a fresh copy, injecting protected paths only after the episode. Fails closed
    on missing sandbox, corrupt snapshot, timeout, or execution error. Exit status alone
    is never enough: a grader-owned wrapper must report, over a nonce-authenticated
    channel, every expected test (recorded from a reference run, never from the submitted
    workspace) as passing exactly once, and finish with a valid trailer.

    Grading needs only the final workspace tree, so a harness may run it in a separate
    container from the agent episode (see README).
    """
    spec = task(task_id)
    try:
        with tempfile.TemporaryDirectory(prefix="strim-env-") as temp:
            root = Path(temp).resolve()
            # Only ``sbx`` is ever sandbox-writable; the trusted base, wrappers and result
            # channel sit beside it and stay unreadable (base) or read-only (tools).
            scratch = root / "sbx"
            scratch.mkdir()
            base, work = root / "base", scratch / "work"
            _materialize(task_id, base, grading=True)
            protected = spec["test_paths"]
            expected = hashes(base, protected)
            if any(expected.get(k) != v for k, v in spec["test_sha256"].items()):
                return 0.0
            # The baseline agent view has no protected files. The same tamper
            # rule applies: any change under a protected path fails grading.
            workspace = Path(workspace)
            if not workspace.is_dir() or workspace.is_symlink():
                return 0.0
            if any((workspace / p).exists() or (workspace / p).is_symlink() for p in protected):
                return 0.0
            if not _only_plain(workspace):
                return 0.0
            # A stray process may still mutate the workspace: copy links as links
            # (never follow them), then re-scan the private copy.
            shutil.copytree(workspace, work, symlinks=True, copy_function=_copy_regular)
            if not _only_plain(work):
                return 0.0
            for name in protected:
                source, target = base / name, work / name
                if target.is_symlink() or target.is_file():
                    target.unlink()
                elif target.exists():
                    shutil.rmtree(target)
                if source.is_dir():
                    shutil.copytree(source, target)
                elif source.is_file():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
            if hashes(work, protected) != expected:
                return 0.0
            _sync_to_base(base, work, edit_policy(task_id), spec["language"])
            return float(run_checked(task_id, spec, work, scratch, timeout))
    except (OSError, ValueError, RuntimeError, tarfile.TarError, KeyError, subprocess.SubprocessError):
        return 0.0
