"""Trusted unittest runner (grader-owned, read-only to the sandbox).

argv: <nonce-fd> <result-fd> <start-dir> <top-level-dir>. Runs with ``python -I``
so neither cwd, script directory, user site nor PYTHON* variables can inject code.
The per-run nonce is read and its descriptor closed BEFORE any agent code is
imported. Results are written only after being produced by a custom TestResult.
"""
import json
import os
import sys
import unittest


def main():
    nonce_fd, chan, start, top = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
    with os.fdopen(nonce_fd, "rb") as handle:  # closes the descriptor
        nonce = handle.read().decode("ascii").strip()
    os.set_inheritable(chan, False)
    write, dumps = os.write, json.dumps

    def emit(**record):
        write(chan, (nonce + " " + dumps(record) + "\n").encode())

    guarded = [unittest.case.TestCase, unittest.TestSuite, unittest.TestResult, unittest.TextTestResult]
    before = [dict(vars(cls)) for cls in guarded]

    class Result(unittest.TestResult):
        def addSuccess(self, test):
            super().addSuccess(test)
            emit(k="pass", n=test.id())

        def _bad(self, test, what):
            emit(k="fail", n=test.id(), why=what)

        def addFailure(self, test, err):
            super().addFailure(test, err)
            self._bad(test, "failure")

        def addError(self, test, err):
            super().addError(test, err)
            self._bad(test, "error")

        def addSkip(self, test, reason):
            super().addSkip(test, reason)
            self._bad(test, "skip")

        def addExpectedFailure(self, test, err):
            super().addExpectedFailure(test, err)
            self._bad(test, "xfail")

        def addUnexpectedSuccess(self, test):
            super().addUnexpectedSuccess(test)
            self._bad(test, "xpass")

        def addSubTest(self, test, subtest, err):
            super().addSubTest(test, subtest, err)
            if err is not None:
                self._bad(subtest, "subtest")

    suite = unittest.TestLoader().discover(start, top_level_dir=top)
    result = Result()
    suite.run(result)
    tampered = any(dict(vars(cls)).keys() != old.keys() or any(vars(cls)[k] is not v for k, v in old.items())
                   for cls, old in zip(guarded, before))
    ok = result.wasSuccessful() and not tampered
    if tampered:
        emit(k="fail", n="<unittest tampered>", why="tamper")
    emit(k="end", total=result.testsRun, ok=ok)
    os._exit(0 if ok else 1)


main()
