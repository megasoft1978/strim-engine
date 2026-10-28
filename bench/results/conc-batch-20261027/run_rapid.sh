#!/bin/bash
# usage (repo root, under lockf): run_rapid.sh LABEL CELLSCRIPT   -- same cells against rapid-mlx 0.15.7 (--max-num-seqs 4, MTP)
set -u
LABEL=$1; CELLS=$2
R=bench/results/conc-batch-20261027; D=$R/$LABEL; mkdir -p "$D"
STRIM=${STRIM_BIN:-/tmp/strim-build-conc/release/strim}
PORT=8651; URL=http://127.0.0.1:$PORT; MODEL=models/qwen38-4bit
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "SKIP port busy"; exit 3; fi
echo "start $(date +%T) load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" > $D/steps.log
rapid-mlx --no-telemetry serve models/qwen38-4bit --port $PORT --max-num-seqs 4 --speculative-config '{"method":"mtp","model":"models/qwen38-mtp-4bit"}' > $D/server.log 2>&1 &
PID=$!
$R/watchdog.sh $PID $D/watch.csv &
WD=$!
for i in $(seq 1 240); do curl -s -m 2 $URL/v1/models >/dev/null && break; sleep 1; done
echo "ready after ${i}s" >> $D/steps.log
$STRIM bench http scoreboard --arm rapid=$URL,$MODEL --workloads W3 --w3-sizes 4096 --w3-gen 8 --reps 1 --out-dir $D/warmup >/dev/null 2>&1
export URL MODEL STRIM D R
source "$CELLS"
echo "end $(date +%T)" >> $D/steps.log
kill -TERM $PID 2>/dev/null; sleep 8; kill -KILL $PID 2>/dev/null; pkill -KILL -P $PID 2>/dev/null; kill $WD 2>/dev/null
awk -F, '!/^#/ && $2>m {m=$2} END{print "peak_footprint_mb=" m}' $D/watch.csv >> $D/steps.log
[ -f $D/watch.csv.abort ] && cat $D/watch.csv.abort >> $D/steps.log
exit 0
