import shlex
import socket
import os
import sys
from pathlib import Path

import pytest

from strim_envs.core import CORPUS
from strim_envs.episode import Episode


@pytest.fixture
def episode():
    episode = Episode('js-01')
    try:
        yield episode
    finally:
        episode.close()


def test_file_actions(episode):
    assert 'lib/semver.js' in episode.act('list')['output']
    assert episode.act('read', path='lib/semver.js')['output']
    assert 'lib/semver.js:' in episode.act('grep', pattern='function')['output']
    assert episode.act('write', path='new/file.txt', content='one')['exit_code'] == 0
    assert episode.act('edit', path='new/file.txt', old_text='one', new_text='two')['exit_code'] == 0
    assert episode.act('read', path='new/file.txt')['output'] == 'two'
    assert episode.act('edit', path='new/file.txt', old_text='missing')['exit_code'] == 1


@pytest.mark.parametrize('path', ['../task.json', '/etc/passwd', '../../solution.patch'])
def test_traversal_is_denied(episode, path):
    assert episode.act('read', path=path)['exit_code'] == 1
    assert episode.act('write', path=path, content='bad')['exit_code'] == 1


def test_symlinks_are_denied(episode):
    (episode.workspace / 'link').symlink_to(CORPUS)
    assert episode.act('read', path='link/manifest.json')['exit_code'] == 1
    assert episode.act('write', path='link/manifest.json', content='bad')['exit_code'] == 1


def test_hardlinks_and_nonregular_files_are_denied(episode, tmp_path):
    source = tmp_path / 'outside'
    source.write_text('secret')
    os.link(source, episode.workspace / 'hardlink')
    os.mkfifo(episode.workspace / 'fifo')
    for name in ('hardlink', 'fifo'):
        assert episode.act('read', path=name)['exit_code'] == 1
        assert episode.act('write', path=name, content='bad')['exit_code'] == 1
    assert source.read_text() == 'secret'


def test_bash_cannot_read_grader_or_sibling_episode(episode):
    other = Episode('js-01')
    try:
        (other.workspace / 'secret').write_text('sibling secret')
        for path in [CORPUS / 'tasks/js-01/solution.patch',
                     CORPUS / 'tasks/js-01/snapshot.tar.gz', other.workspace / 'secret']:
            result = episode.act('bash', command='cat ' + shlex.quote(str(path)))
            assert result['exit_code'] != 0
            assert 'diff --git' not in result['output']
        reference = shlex.quote(str(CORPUS / 'tasks/js-01/solution.patch'))
        for flag, name in [('-s', 'symlink'), ('', 'hardlink')]:
            result = episode.act('bash', command=f'ln {flag} {reference} {name} && cat {name}')
            assert result['exit_code'] != 0
            assert 'diff --git' not in result['output']
        assert episode.act('bash', command='printf hello')['output'] == 'hello'
    finally:
        other.close()


def test_bash_timeout(episode):
    result = episode.act('bash', command='sleep 5', timeout=0.1)
    assert result['exit_code'] == 124
    assert 'timed out' in result['output']


def test_replacing_workspace_with_grader_symlink_cannot_expand_sandbox(episode):
    command = 'mv ../work ../saved && ln -s ' + shlex.quote(str(CORPUS)) + ' ../work'
    assert episode.act('bash', command=command)['exit_code'] == 0
    for operation, kwargs in [('list', {}), ('read', {'path': 'tasks/js-01/solution.patch'}),
                              ('bash', {'command': 'cat tasks/js-01/solution.patch'})]:
        result = episode.act(operation, **kwargs)
        assert result['exit_code'] != 0
        assert 'diff --git' not in result['output']
    assert episode.act('finish')['reward'] == 0.0


def test_no_network_even_loopback(episode):
    # A reachable owned listener distinguishes denial from an absent network service.
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(0.5)
        port = listener.getsockname()[1]
        result = episode.act('bash', command=f'node -e "const s=require(\'net\').connect({port},\'127.0.0.1\'); s.on(\'error\',()=>process.exit(7)); s.on(\'connect\',()=>process.exit(0));"')
        assert result['exit_code'] != 0
        with pytest.raises(socket.timeout):
            listener.accept()


def test_finish_is_terminal_and_limits_grade(episode):
    assert episode.act('finish')['reward'] == 0.0
    with pytest.raises(ValueError, match='finished'):
        episode.act('list')
    other = Episode('js-01', max_steps=1)
    try:
        assert other.act('list')['done']
    finally:
        other.close()


def _alive(marker):
    import subprocess
    if sys.platform.startswith('linux'):
        # Minimal images ship no procps; read the command lines from /proc instead.
        lines = []
        for entry in Path('/proc').iterdir():
            if entry.name.isdigit() and int(entry.name) != os.getpid():
                try:
                    lines.append((entry / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace'))
                except OSError:
                    pass
        return [line for line in lines if marker in line]
    out = subprocess.run(['ps', '-axo', 'command='], capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if marker in line and 'ps -axo' not in line]


ESCAPE = ("python3 -c \"import subprocess; subprocess.Popen(['sleep', '%s'], "
          "start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\"")


def test_setsid_child_is_killed_after_step(episode):
    marker = '47.3171'
    assert episode.act('bash', command=ESCAPE % marker)['exit_code'] == 0
    assert _alive(marker) == []


def test_setsid_child_is_killed_on_close():
    episode = Episode('js-01')
    marker = '47.3172'
    try:
        # Double fork: the intermediate parent exits at once, the sleeper outlives the shell.
        command = ("python3 -c \"import os, subprocess\nif os.fork() == 0:\n os.setsid()\n"
                   " subprocess.Popen(['sleep', '%s'])\n\"" % marker)
        assert episode.act('bash', command=command)['exit_code'] == 0
    finally:
        episode.close()
    assert _alive(marker) == []


def test_reap_leaves_unrelated_processes_alone(episode):
    import subprocess
    other = subprocess.Popen(['sleep', '47.3173'], start_new_session=True)
    try:
        episode.act('bash', command='true')
        episode.close()
        assert other.poll() is None
    finally:
        other.kill()
        other.wait()
