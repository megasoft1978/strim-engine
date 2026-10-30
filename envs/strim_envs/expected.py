"""Regenerate the trusted expected-test and edit-policy records from the reference solutions.

Run on a trusted host: ``python -m strim_envs.expected``. Both records are read from this
package at grade time; they are never derived from an agent workspace, and the grader
image needs neither the reference patches nor the hidden fixtures to use them.
"""
import json
from pathlib import Path
import re
import subprocess
import tempfile

from .core import CORPUS, EXPECTED, POLICY, TASK_IDS, _materialize, run_checked, task


def patched_files(patch: str) -> list[str]:
    paths = set(re.findall(r"^\+\+\+ b/(.+)$", patch, re.M)) | set(re.findall(r"^--- a/(.+)$", patch, re.M))
    return sorted(paths)


def generate() -> tuple[dict, dict]:
    result, policy = {}, {}
    for task_id in TASK_IDS:
        spec = task(task_id)
        patch_path = CORPUS / "tasks" / task_id / "solution.patch"
        files = patched_files(patch_path.read_text())
        if not files:
            raise SystemExit(f"{task_id}: reference patch touches no files")
        policy[task_id] = {"files": files,
                           "dirs": sorted({str(Path(f).parent) if str(Path(f).parent) != "." else "." for f in files})}
        with tempfile.TemporaryDirectory(prefix="strim-expected-") as temp:
            scratch = Path(temp).resolve() / "sbx"
            scratch.mkdir()
            work = scratch / "work"
            _materialize(task_id, work, grading=True)
            subprocess.run(["git", "apply", str(patch_path)], cwd=work, check=True)
            names: list[str] = []
            if not run_checked(task_id, spec, work, scratch, 300, record=names) or not names:
                raise SystemExit(f"{task_id}: reference run failed or reported no tests")
            result[task_id] = names
    return result, policy


if __name__ == "__main__":
    names, policy = generate()
    EXPECTED.write_text(json.dumps(names, indent=1, sort_keys=True) + "\n")
    POLICY.write_text(json.dumps(policy, indent=1, sort_keys=True) + "\n")
