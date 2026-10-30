import shutil
import subprocess
from pathlib import Path

import pytest

from strim_envs.core import CORPUS, TASK_IDS, materialize, task, verify


@pytest.mark.parametrize("task_id", TASK_IDS)
def test_reference_broken_and_tampered(task_id, tmp_path):
    spec = task(task_id)
    required = {"javascript": ["node"], "typescript": ["node", "tsc"], "react": ["bun"],
                "go": ["go"], "ruby": ["ruby"], "python": ["python3"],
                "rust": ["cargo"], "java": ["java", "javac"]}[spec["language"]]
    if any(shutil.which(name) is None for name in required):
        pytest.skip("missing toolchain")
    work = tmp_path / "work"
    materialize(task_id, work)
    assert verify(task_id, work) == 0.0
    patch = CORPUS / "tasks" / task_id / "solution.patch"
    subprocess.run(["git", "apply", str(patch)], cwd=work, check=True)
    assert verify(task_id, work) == 1.0
    target = work / next(iter(spec["test_sha256"]))
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"tampered\n")
    assert verify(task_id, work) == 0.0


@pytest.mark.parametrize("task_id", TASK_IDS)
def test_agent_view_has_no_grading_artifacts(task_id, tmp_path):
    work = tmp_path / "agent"
    materialize(task_id, work)
    assert all(not (work / name).exists() for name in task(task_id)["test_paths"])
    assert not any(p.name in {"solution.patch", "task.json", "snapshot.tar.gz"}
                   for p in work.rglob("*"))
    assert any(p.is_file() for p in work.rglob("*"))


def test_grading_does_not_inject_tests_into_agent_view(tmp_path):
    work = tmp_path / "agent"
    materialize("js-01", work)
    before = {p.relative_to(work): p.read_bytes() for p in work.rglob("*") if p.is_file()}
    verify("js-01", work)
    after = {p.relative_to(work): p.read_bytes() for p in work.rglob("*") if p.is_file()}
    assert before == after


@pytest.mark.parametrize("kind", ["file", "directory", "symlink"])
def test_injected_protected_paths_fail(tmp_path, kind):
    work = tmp_path / "agent"
    materialize("js-01", work)
    subprocess.run(["git", "apply", str(CORPUS / "tasks/js-01/solution.patch")],
                   cwd=work, check=True)
    target = work / "test"
    if kind == "file":
        target.write_text("tampered")
    elif kind == "directory":
        target.mkdir()
    else:
        target.symlink_to(tmp_path / "missing")
    assert verify("js-01", work) == 0.0
