#!/bin/sh
# Offline Java test runner: compiles every .java under src/ with the JDK and runs tests.AllTests.
# No Maven or Gradle, no downloads. Class files go to $TMPDIR (writable scratch), never into the worktree.
set -e
OUT="${TMPDIR:-/tmp}/javatest-classes"
rm -rf "$OUT"
mkdir -p "$OUT"
javac -encoding UTF-8 -Xlint:none -d "$OUT" $(find src -name '*.java')
exec java -ea -cp "$OUT" tests.AllTests "$@"
