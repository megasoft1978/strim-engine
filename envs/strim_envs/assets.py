"""Export only the selected trusted grader data, never reference solutions."""
import json
from pathlib import Path
import shutil
import sys

from .core import CORPUS, TASK_IDS, task


def export(destination: Path):
    destination.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((CORPUS / 'manifest.json').read_text())
    manifest['tasks'] = [row for row in manifest['tasks'] if row['id'] in TASK_IDS]
    (destination / 'manifest.json').write_text(json.dumps(manifest))
    for task_id in TASK_IDS:
        spec = task(task_id)
        target = destination / 'tasks' / task_id
        target.mkdir(parents=True)
        for name in ('task.json', spec['snapshot']):
            shutil.copy2(CORPUS / 'tasks' / task_id / name, target / name)


if __name__ == '__main__':
    export(Path(sys.argv[1]))
