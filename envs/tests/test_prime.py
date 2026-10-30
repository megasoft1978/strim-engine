import json
import os
from pathlib import Path
import subprocess
import sys

import pytest


def _verifiers_available() -> bool:
    try:
        import verifiers  # noqa: F401
    except ImportError:
        return False
    return True


@pytest.mark.skipif(not os.environ.get('STRIM_PRIME_PYTHON') and not _verifiers_available(),
                    reason='verifiers is not installed in this interpreter; set STRIM_PRIME_PYTHON '
                           '(e.g. /tmp/env1/prime-venv/bin/python) to run the Prime test')
def test_official_prime_loader_and_reward():
    # Separate extras: OpenEnv 0.11 requires MCP<2; verifiers 0.4 pins MCP==2.
    interpreter = os.environ.get('STRIM_PRIME_PYTHON', sys.executable)
    result = subprocess.run([interpreter, str(Path(__file__).with_name('prime_smoke.py'))],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    scores = json.loads(result.stdout.strip().splitlines()[-1])
    assert scores == {'tasks': 16, 'reference': 1.0, 'broken': 0.0,
                      'invalid': 0.0, 'tampered': 0.0}
