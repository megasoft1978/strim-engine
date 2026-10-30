"""Container-boundary fallback gate and server robustness."""
import sys
from pathlib import Path

import pytest

from strim_envs import core
from strim_envs.episode import MAX_OBS, clip
from strim_envs.openenv_server import StrimAction, StrimEnvironment


@pytest.fixture
def linux_without_bwrap(monkeypatch):
    monkeypatch.setattr(sys, 'platform', 'linux')
    monkeypatch.setattr(core, '_bwrap_usable', lambda: False)


def test_no_var_raises(linux_without_bwrap, monkeypatch, tmp_path):
    monkeypatch.delenv('STRIM_ENVS_CONTAINER_BOUNDARY', raising=False)
    with pytest.raises(RuntimeError, match='sandbox unavailable'):
        core._sandbox(tmp_path, tmp_path, 'true')


def test_var_must_be_exactly_one(linux_without_bwrap, monkeypatch, tmp_path):
    monkeypatch.setenv('STRIM_ENVS_CONTAINER_BOUNDARY', '0')
    with pytest.raises(RuntimeError):
        core._sandbox(tmp_path, tmp_path, 'true')


def test_var_set_falls_back_to_plain_shell(linux_without_bwrap, monkeypatch, tmp_path):
    monkeypatch.setenv('STRIM_ENVS_CONTAINER_BOUNDARY', '1')
    assert core._sandbox(tmp_path, tmp_path, 'echo hi') == ['/bin/sh', '-c', 'echo hi']


def test_fallback_runs_agent_bash(linux_without_bwrap, monkeypatch):
    monkeypatch.setenv('STRIM_ENVS_CONTAINER_BOUNDARY', '1')
    env = StrimEnvironment()
    try:
        env.reset(task_id='py-01')
        obs = env.step(StrimAction(operation='bash', command='echo $HOME; pwd; ulimit -f; env | wc -l'))
        assert obs.exit_code == 0, obs.output
        assert str(env.episode.scratch) in obs.output
    finally:
        env.close()


def test_clip_head_and_tail():
    text = 'a' * 20000 + 'END'
    out = clip(text)
    assert len(out) < MAX_OBS + 100 and out.startswith('aaa') and out.endswith('END') and 'omitted' in out
    assert clip('short') == 'short'


def test_errors_and_finish_are_observations():
    env = StrimEnvironment()
    try:
        obs = env.step(StrimAction(operation='finish'))
        assert obs.done and obs.reward == 0.0
        first = env.reset(task_id='py-01')
        assert len(first.prompt) < 7000 and len(first.files) <= 61
        bad = env.step(StrimAction(operation='read', path='../../etc/passwd'))
        assert not bad.done and bad.exit_code == 1 and bad.output
        big = env.step(StrimAction(operation='bash', command='yes x | head -c 200000'))
        assert len(big.output) < MAX_OBS + 100
        done = env.step(StrimAction(operation='finish'))
        assert done.done and 0.0 <= done.reward <= 1.0
        again = env.step(StrimAction(operation='read', path='x'))
        assert again.done and again.exit_code == 1
    finally:
        env.close()


def test_fallback_warns_once_and_failed_probe_not_cached(linux_without_bwrap, monkeypatch, tmp_path, capsys):
    monkeypatch.setenv('STRIM_ENVS_CONTAINER_BOUNDARY', '1')
    monkeypatch.setattr(core, '_WARNED', False)
    core._sandbox(tmp_path, tmp_path, 'true')
    core._sandbox(tmp_path, tmp_path, 'true')
    assert capsys.readouterr().err.count('STRIM-ENVS WARNING') == 1
    monkeypatch.undo()
    monkeypatch.setattr(core, '_BWRAP_OK', False)
    monkeypatch.setattr(core.shutil, 'which', lambda name: None)
    assert core._bwrap_usable() is False and core._BWRAP_OK is False
