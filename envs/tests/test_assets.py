import json

from strim_envs.assets import export
from strim_envs.core import TASK_IDS


def test_grader_export_has_selected_snapshots_and_no_solutions(tmp_path):
    destination = tmp_path / 'grader'
    export(destination)
    spec = json.loads((destination / 'manifest.json').read_text())
    assert {row['id'] for row in spec['tasks']} == set(TASK_IDS)
    assert len(list(destination.rglob('snapshot.tar.gz'))) == 16
    assert len(list(destination.rglob('task.json'))) == 16
    assert not list(destination.rglob('solution.patch'))
    assert len(list(destination.rglob('*'))) == 50  # task dir + 16 task dirs + 33 files
