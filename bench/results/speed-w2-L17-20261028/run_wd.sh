#!/bin/bash
# usage: run_wd.sh LABEL cmd...   (from repo root). GPU lock (<= 60 min) + 5 s memory watchdog
# (SIGTERM at > 42 GB footprint or swap growth > 2 GB). Output -> raw/LABEL.txt
L=$1; shift
D=$(cd "$(dirname "$0")" && pwd)
W=$D/../../h2h/watchdog.sh
exec lockf -t 3600 -k /tmp/strim-bench.lock bash -c '
D=$1; L=$2; W=$3; shift 3
echo "[$(date +%T)] start $L load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" > "$D/raw/$L.txt"
"$@" >> "$D/raw/$L.txt" 2>&1 &
P=$!
echo "$L" > "$D/raw/$L.cell"
bash "$W" "$P" "$D/raw/$L.cell" "$D/raw/$L.watch.csv" &
WP=$!
wait $P; rc=$?
kill $WP 2>/dev/null
echo "[$(date +%T)] end rc=$rc aborted=$(cat "$D/raw/$L.watch.csv.abort" 2>/dev/null | wc -l | tr -d " ")" >> "$D/raw/$L.txt"
' _ "$D" "$L" "$W" "$@"
