#!/bin/bash
# usage (repo root, under lockf): run_cell.sh LABEL "ENV=.. ENV2=.." CELLSCRIPT
# Starts `strim serve` (snapshot binary) + watchdog, warms up, then `source CELLSCRIPT` with
# URL, MODEL, STRIM, D, R set (it runs the cells), then stops the server.
set -u
LABEL=$1; ENVS=$2; CELLS=$3
R=bench/results/conc-batch-20261027; D=$R/$LABEL; mkdir -p "$D"
STRIM=${STRIM_BIN:-/tmp/strim-build-conc/release/strim}
PORT=${PORT:-8231}; URL=http://127.0.0.1:$PORT; MODEL=qwen38-4bit
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "SKIP port busy"; exit 3; fi
echo "start $(date +%T) load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage) env=$ENVS" > $D/steps.log
env $ENVS $STRIM serve models/qwen38-4bit models/qwen38-mtp-4bit --port $PORT --no-auth > $D/server.log 2>&1 &
PID=$!
$R/watchdog.sh $PID $D/watch.csv &
WD=$!
for i in $(seq 1 180); do curl -s -m 2 $URL/v1/models >/dev/null && break; sleep 1; done
echo "ready after ${i}s" >> $D/steps.log
$STRIM bench http scoreboard --arm strim=$URL,$MODEL --workloads W3 --w3-sizes 4096 --w3-gen 8 --reps 1 --out-dir $D/warmup >/dev/null 2>&1
export URL MODEL STRIM D R
source "$CELLS"
echo "end $(date +%T)" >> $D/steps.log
kill -TERM $PID 2>/dev/null; sleep 5; kill -KILL $PID 2>/dev/null; kill $WD 2>/dev/null
awk -F, '!/^#/ && $2>m {m=$2} END{print "peak_footprint_mb=" m}' $D/watch.csv >> $D/steps.log
[ -f $D/watch.csv.abort ] && cat $D/watch.csv.abort >> $D/steps.log
exit 0
