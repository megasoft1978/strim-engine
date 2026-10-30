#!/bin/sh
set -eu
OUT="${TMPDIR:-/tmp}/javatest-classes"
rm -rf "$OUT"
mkdir -p "$OUT"
javac -encoding UTF-8 -Xlint:none -d "$OUT" $(find src -name '*.java')
exec java -ea -cp "$OUT" tests.AllTests "$@"
