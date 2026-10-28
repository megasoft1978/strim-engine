#!/bin/bash
# usage (repo root): cli.sh LOG BIN args... ; runs under the GPU lock with the 5 s memory watchdog.
LOG=$1; shift
lockf -t 3600 -k /tmp/strim-bench.lock bash -c '
  LOG=$1; shift
  "$@" > "$LOG" 2>&1 & P=$!
  echo cli > "$LOG.cell"
  bench/h2h/watchdog.sh $P "$LOG.cell" "$LOG.watch.csv" & W=$!
  wait $P; rc=$?; kill $W 2>/dev/null; echo "exit $rc" >> "$LOG"
' _ "$LOG" "$@"
