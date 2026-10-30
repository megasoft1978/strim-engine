"""Agent-side operations. Trusted grader assets never enter this directory."""
from __future__ import annotations

import os
from contextlib import contextmanager
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import time

from .core import SKIP, _sandbox, materialize, safe_relative, task, verify

MAX_TEXT = 65_536
MAX_FILES = 2_000
# Observation budget: a turn must fit a small model context (default 8192 tokens).
MAX_OBS = 6_000
MAX_OBS_FILES = 60


def clip(text: str, limit: int = MAX_OBS) -> str:
    """Keep the head and tail of long text, with an explicit marker in between."""
    if len(text) <= limit:
        return text
    head = limit * 2 // 3
    tail = limit - head
    return (text[:head] + f'\n...[{len(text) - limit} chars omitted]...\n' + text[-tail:])


def task_prompt(task_id: str) -> str:
    spec = task(task_id)
    return (spec['prompt'] + '\n\nEnvironment: protected tests, dependencies/configuration listed below, '
            'and reference solutions are withheld from this workspace. Local test commands may '
            'therefore be unavailable. Implement the requested behavior in the source; use finish '
            'to end the episode and run the hidden grader. Creating or changing a protected path '
            'fails grading. Protected paths: ' + ', '.join(spec['test_paths']) + '.')


def _ps() -> list[tuple[int, int, int, str]]:
    """(pid, ppid, pgid, start time) for every process, via plain ps."""
    out = subprocess.run(['ps', '-axo', 'pid=,ppid=,pgid=,lstart='], capture_output=True,
                         text=True, timeout=10).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and all(x.isdigit() for x in parts[:3]):
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3].strip()))
    return rows


def _in_dir(directory: Path) -> set[int]:
    """Same-user processes whose working directory is inside `directory`.

    Environment variables are not visible through ps on every platform, but the
    working directory is inherited from the sandboxed shell (the episode's
    unique temporary tree) and survives setsid/double forks.
    """
    prefix = str(directory)
    found: set[int] = set()
    if Path('/proc/self/cwd').exists():
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    cwd = os.readlink(entry / 'cwd')
                except OSError:
                    continue
                if cwd == prefix or cwd.startswith(prefix + os.sep):
                    found.add(int(entry.name))
        return found
    out = subprocess.run(['lsof', '-a', '-u', str(os.getuid()), '-d', 'cwd', '-Fpn'],
                         capture_output=True, text=True, timeout=20).stdout
    pid = None
    for line in out.splitlines():
        if line.startswith('p') and line[1:].isdigit():
            pid = int(line[1:])
        elif line.startswith('n') and pid is not None:
            if line[1:] == prefix or line[1:].startswith(prefix + os.sep):
                found.add(pid)
    return found


class Episode:
    def __init__(self, task_id: str, *, max_steps: int = 100, max_seconds: float = 600):
        self.task_id = task_id
        self._temp = tempfile.TemporaryDirectory(prefix='strim-agent-')
        self.scratch = Path(self._temp.name).resolve()
        self.workspace = self.scratch / 'work'
        materialize(task_id, self.workspace)
        self.steps = 0
        self.max_steps = max_steps
        self.deadline = time.monotonic() + max_seconds
        self.done = False
        self.reward = 0.0
        # Descendants (pid -> start time) seen while a command runs.
        self._spawned: dict[int, str] = {}
        # Session leaders (one per bash command); every process in these sessions is ours.
        self._sessions: set[int] = set()

    def _track(self, roots: set[int]) -> None:
        rows = _ps()
        children: dict[int, list[tuple[int, str]]] = {}
        for pid, ppid, _, start in rows:
            children.setdefault(ppid, []).append((pid, start))
        queue = list(roots)
        starts = {pid: start for pid, _, _, start in rows}
        while queue:
            for pid, start in children.get(queue.pop(), ()):
                if pid not in self._spawned:
                    self._spawned[pid] = start
                    queue.append(pid)
        for pid in roots:
            if pid in starts:
                self._spawned.setdefault(pid, starts[pid])

    def _in_sessions(self) -> set[int]:
        """Linux: pids whose session id or process group is one of this episode's command sessions."""
        found: set[int] = set()
        if not self._sessions or not Path('/proc/self/stat').exists():
            return found
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit():
                try:
                    fields = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
                    pgrp, sid = int(fields[2]), int(fields[3])
                except (OSError, ValueError, IndexError):
                    continue
                if pgrp in self._sessions or sid in self._sessions:
                    found.add(int(entry.name))
        return found

    def _reap(self) -> None:
        """SIGKILL only processes this episode spawned (tracked lineage or working directory inside its own temp tree)."""
        me = os.getpid()
        for _ in range(4):
            try:
                rows = _ps()
                live = {pid: (ppid, start) for pid, ppid, _, start in rows}
                victims = {pid for pid, start in self._spawned.items()
                           if pid in live and live[pid][1] == start}
                victims |= _in_dir(self.scratch) & live.keys()
                # Descendants of victims are also this episode's.
                grew = True
                while grew:
                    grew = False
                    for pid, (ppid, _) in live.items():
                        if ppid in victims and pid not in victims:
                            victims.add(pid)
                            grew = True
            except (OSError, subprocess.SubprocessError):
                return
            victims |= self._in_sessions() & live.keys()
            victims -= {me, os.getppid(), 0, 1}
            if not victims:
                return
            for pid in victims:
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            time.sleep(0.05)

    def close(self):
        self._reap()
        self._temp.cleanup()

    def path(self, name: str = '.') -> Path:
        if self.workspace.is_symlink() or not self.workspace.is_dir():
            raise ValueError('workspace must remain a real directory')
        if name == '.':
            return self.workspace
        rel = safe_relative(name)
        path = self.workspace / rel
        if any(p.is_symlink() for p in (path, *path.parents)):
            raise ValueError('symlinks are not allowed')
        path.resolve().relative_to(self.workspace)
        return path

    def files(self, name: str = '.') -> list[str]:
        root = self.path(name)
        if root.is_file():
            return [root.relative_to(self.workspace).as_posix()]
        result = []
        for directory, dirs, names in os.walk(root, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in SKIP and not (Path(directory) / d).is_symlink())
            for n in sorted(names):
                p = Path(directory) / n
                if not p.is_symlink() and p.is_file():
                    result.append(p.relative_to(self.workspace).as_posix())
                    if len(result) >= MAX_FILES:
                        return result
        return result

    @contextmanager
    def _file(self, name: str, *, writing: bool = False):
        # Resolve each component by directory fd, never following symlinks. This
        # also prevents a background process racing the host's path validation.
        rel = safe_relative(name)
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        directory = os.open(self.workspace, flags)
        try:
            for part in rel.parts[:-1]:
                if writing:
                    try:
                        os.mkdir(part, dir_fd=directory)
                    except FileExistsError:
                        pass
                child = os.open(part, flags, dir_fd=directory)
                os.close(directory)
                directory = child
            mode = (os.O_WRONLY | os.O_CREAT) if writing else os.O_RDONLY
            fd = os.open(rel.name, mode | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644, dir_fd=directory)
            with os.fdopen(fd, 'wb' if writing else 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError('only regular files with one link are supported')
                if writing:
                    stream.truncate(0)
                yield stream
        finally:
            os.close(directory)

    def read(self, name: str, limit: int = MAX_TEXT) -> bytes:
        with self._file(name) as stream:
            return stream.read(limit)

    def finish(self) -> dict:
        # Set done before calling the grader: no further agent action is accepted.
        self.done = True
        self._reap()  # no agent process may outlive the episode into grading
        try:
            self.reward = float(verify(self.task_id, self.workspace))
        except Exception:  # fail closed: any grader fault scores zero
            self.reward = 0.0
        if not 0.0 <= self.reward <= 1.0:
            self.reward = 0.0
        return dict(output='Grading complete.', exit_code=0, done=True, reward=self.reward)

    def act(self, operation: str, *, path: str = '.', content: str = '',
            old_text: str = '', new_text: str = '', pattern: str = '',
            command: str = '', timeout: float = 10) -> dict:
        if self.done:
            raise ValueError('episode is finished; reset first')
        self.steps += 1
        if operation == 'finish' or self.steps >= self.max_steps or time.monotonic() >= self.deadline:
            return self.finish()
        try:
            self.path('.')
            if operation == 'bash':
                output, code = self.bash(command, min(timeout, 10, max(0.01, self.deadline - time.monotonic())))
            elif operation == 'list':
                output, code = '\n'.join(self.files(path)), 0
            elif operation == 'read':
                output = self.read(path).decode('utf-8', errors='replace')
                code = 0
            elif operation in ('write', 'edit'):
                if operation == 'edit':
                    raw = self.read(path, MAX_TEXT + 1)
                    if len(raw) > MAX_TEXT:
                        raise ValueError('file too large for edit; use bash')
                    text = raw.decode('utf-8')
                    if not old_text or text.count(old_text) != 1:
                        raise ValueError('old_text must match exactly once')
                    content = text.replace(old_text, new_text, 1)
                if len(content.encode()) > MAX_TEXT:
                    raise ValueError('content too large')
                with self._file(path, writing=True) as stream:
                    stream.write(content.encode('utf-8'))
                output, code = 'Written.', 0
            elif operation == 'grep':
                if not pattern:
                    raise ValueError('pattern must not be empty (literal substring search)')
                matches, budget = [], MAX_TEXT * 16
                for name in self.files(path):
                    raw = self.read(name, min(budget, MAX_TEXT))
                    budget -= len(raw)
                    for number, line in enumerate(raw.decode('utf-8', errors='replace').splitlines(), 1):
                        if pattern in line:
                            matches.append(f'{name}:{number}:{line}')
                    if budget <= 0 or sum(map(len, matches)) >= MAX_TEXT:
                        break
                output, code = '\n'.join(matches), 0
            else:
                raise ValueError('unknown operation')
            return dict(output=clip(output), exit_code=code, done=False, reward=0.0)
        except Exception as exc:  # report every action error as an observation
            return dict(output=clip(f'{type(exc).__name__}: {exc}'), exit_code=1, done=False, reward=0.0)

    def bash(self, command: str, timeout: float) -> tuple[str, int]:
        if not 0 < timeout <= 10:
            raise ValueError('timeout must be between 0 and 10 seconds')
        home = self.scratch / 'home'
        home.mkdir(exist_ok=True)
        tool_bins = sorted(Path.home().glob('.rustup/toolchains/stable-*/bin')) + sorted(
            Path.home().glob('.rbenv/versions/3.*/bin'), reverse=True)
        env = {'PATH': os.pathsep.join([*(str(p) for p in tool_bins), os.environ.get('PATH', '/usr/bin:/bin')]),
               'HOME': str(home), 'TMPDIR': str(self.scratch), 'CI': '1', 'LANG': 'C.UTF-8',
               'GOCACHE': str(self.scratch / 'gocache'), 'GOPROXY': 'off',
               'GOSUMDB': 'off', 'CARGO_HOME': str(self.scratch / 'cargo')}
        # Set both soft and hard file-size limits before running agent code.
        argv = _sandbox(self.workspace, self.scratch, 'ulimit -f 32768; ' + command)
        # Anonymous, host-held output descriptor; the agent cannot replace it.
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(argv, cwd=self.workspace, env=env, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=output, start_new_session=True)
            self._sessions.add(process.pid)
            end = time.monotonic() + timeout
            code = None
            try:
                while code is None:
                    # Watch the tree while it runs: a setsid'd child is reparented
                    # the moment its parent exits, so it must be seen beforehand.
                    try:
                        self._track({process.pid})
                    except (OSError, subprocess.SubprocessError):
                        pass
                    remaining = end - time.monotonic()
                    if remaining <= 0:
                        code = 124
                        break
                    try:
                        code = process.wait(timeout=min(0.05, remaining))
                    except subprocess.TimeoutExpired:
                        pass
            finally:
                # Reap descendants even if the shell exited before its children.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                self._reap()
            output.seek(0)
            text = output.read(MAX_TEXT).decode('utf-8', errors='replace')
        if code == 124:
            text += '\nCommand timed out.'
        return text, code
