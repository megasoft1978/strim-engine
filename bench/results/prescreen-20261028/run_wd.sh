#!/bin/bash
# usage: run_wd.sh LABEL cmd...   (run from repo root). GPU lock (wait <= 30 min, else SKIP) + 5 s memory watchdog
# (SIGTERM at > 42 GB footprint or swap growth > 2 GB, via bench/h2h/watchdog.sh). Output -> raw/LABEL.txt
L=$1; shift
D=$(cd "$(dirname "$0")" && pwd)
exec lockf -t 1800 -k /tmp/strim-bench.lock bash -c '
D=$1; L=$2; shift 2
echo "[$(date +%T)] start $L load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" > "$D/raw/$L.txt"
"$@" >> "$D/raw/$L.txt" 2>&1 &
P=$!
echo "$L" > "$D/raw/$L.cell"
bash "'"$D"'/../../h2h/watchdog.sh" "$P" "$D/raw/$L.cell" "$D/raw/$L.watch.csv" &
W=$!
wait $P; rc=$?
kill $W 2>/dev/null
echo "[$(date +%T)] end rc=$rc aborted=$(cat "$D/raw/$L.watch.csv.abort" 2>/dev/null | wc -l | tr -d " ")" >> "$D/raw/$L.txt"
' _ "$D" "$L" "$@"
