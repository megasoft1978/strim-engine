"""Official-client conformance against a real loopback uvicorn server."""
import os
import socket
import subprocess
import sys
import time
import urllib.request

import pytest

from strim_envs.core import CORPUS
from strim_envs.openenv_server import StrimAction, StrimClient, StrimEnvironment


@pytest.fixture(scope='module')
def server(tmp_path_factory):
    # Bind first and pass the owned socket to uvicorn, avoiding a port race.
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
    sock.listen()
    env = {**os.environ, 'ENABLE_WEB_INTERFACE': 'false'}
    with (tmp_path_factory.mktemp('server') / 'uvicorn.log').open('w+') as log:
        process = subprocess.Popen(
            [sys.executable, '-m', 'uvicorn', 'strim_envs.openenv_server:app',
             '--fd', str(sock.fileno()), '--log-level', 'warning'],
            pass_fds=(sock.fileno(),), env=env, stdout=log, stderr=log)
        url = f'http://127.0.0.1:{port}'
        try:
            for _ in range(200):
                if process.poll() is not None:
                    log.seek(0)
                    pytest.fail(log.read())
                try:
                    with urllib.request.urlopen(url + '/health', timeout=1) as response:
                        assert response.status == 200
                    break
                except OSError:
                    time.sleep(0.1)
            else:
                pytest.fail('server startup timed out')
            yield url
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            sock.close()


@pytest.mark.parametrize('solved', [False, True])
def test_official_client_episode(server, solved):
    with StrimClient(base_url=server).sync() as client:
        initial = client.reset(task_id='js-01', seed=1)
        assert initial.reward == 0.0 and not initial.done
        assert initial.observation.task_id == 'js-01'
        assert initial.observation.prompt
        assert 'lib/semver.js' in initial.observation.files
        assert all('test/' not in f and 'solution' not in f for f in initial.observation.files)
        assert client.state().step_count == 0
        read = client.step(StrimAction(operation='read', path='lib/semver.js'))
        assert read.observation.exit_code == 0
        assert read.observation.output
        if solved:
            # Read the fixture on the trusted test side; transmit only source edits.
            patch = (CORPUS / 'tasks/js-01/solution.patch').read_text()
            result = client.step(StrimAction(operation='bash', command="git apply - <<'PATCH'\n" + patch + '\nPATCH'))
            assert result.observation.exit_code == 0, result.observation.output
        final = client.step(StrimAction(operation='finish'))
        assert final.done and final.reward == float(solved)
        assert client.state().step_count == (3 if solved else 2)
        # The hidden paths remain absent even after verification.
        again = client.reset(task_id='js-01')
        assert not again.done
        assert client.step(StrimAction(operation='finish')).reward == 0.0


def test_reset_has_fresh_workspace_and_instances_are_independent():
    a, b = StrimEnvironment(), StrimEnvironment()
    try:
        a.reset(task_id='js-01')
        b.reset(task_id='js-01')
        assert a.episode.workspace != b.episode.workspace
        a.step(StrimAction(operation='write', path='only-a.txt', content='a'))
        assert 'only-a.txt' not in b.episode.files()
        a.reset(task_id='js-01')
        assert 'only-a.txt' not in a.episode.files()
    finally:
        a.close()
        b.close()
