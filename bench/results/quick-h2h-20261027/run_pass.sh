#!/bin/bash
# NOTE: the helper scripts used for this run (Python watchdog/agreement/aggregator) were removed from the repo; see summary.md for the method; rewrite with shell/Swift before rerunning
# usage (from repo root, under lockf): run_pass.sh ENGINE PASS   -> bench/results/quick-h2h-20261027/ENGINE/passN
set -u
E=$1; P=$2
R=bench/results/quick-h2h-20261027; D=$R/$E/pass$P; mkdir -p $D
STRIM=${STRIM_BIN:-/tmp/strim-build-p3/release/strim}
PORT=8651; MODEL=models/qwen38-4bit
case $E in
 strim) PORT=8203; MODEL=qwen38-4bit; CMD=($STRIM serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth);;
 rapid-mlx) CMD=(rapid-mlx --no-telemetry serve models/qwen38-4bit --port 8651 --max-num-seqs 4 --speculative-config '{"method":"mtp","model":"models/qwen38-mtp-4bit"}');;
 mlx-vlm) MODEL=$PWD/models/qwen38-4bit; CMD=($PWD/.venv-sprint/bin/mlx_vlm.server --model $PWD/models/qwen38-4bit --port 8651);;
esac
URL=http://127.0.0.1:$PORT
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "SKIP port busy"; exit 3; fi
echo "start $(date +%T) load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" > $D/steps.log
"${CMD[@]}" > $D/server.log 2>&1 &
PID=$!
echo "$PID" > $D/pid; echo idle > $D/cell
python3 -I $R/watchdog.py $PID $D/cell $D/watch.csv &
WD=$!
for i in $(seq 1 180); do curl -s -m 2 $URL/v1/models >/dev/null && break; sleep 1; done
echo "ready after ${i}s" >> $D/steps.log
cell() { # name cmd...
  local n=$1; shift
  echo $n > $D/cell; local t0=$(date +%s)
  echo "[$(date +%T)] CELL $n load=$(sysctl -n vm.loadavg)" >> $D/steps.log
  if [ -s $D/watch.csv.abort ] && grep -qx "$n" $D/watch.csv.abort; then :; fi
  timeout ${CELL_TIMEOUT:-900} "$@" > $D/$n.stdout.log 2>&1; local rc=$?
  local ab=no; grep -qx "$n" $D/watch.csv.abort 2>/dev/null && ab=yes
  echo "[$(date +%T)] CELL $n rc=$rc $(( $(date +%s)-t0 ))s memory_aborted=$ab" >> $D/steps.log
  if [ $ab = yes ]; then sleep 8; fi
  echo idle > $D/cell
}
ensure() { # restart engine if killed by watchdog
  if ! kill -0 $PID 2>/dev/null; then
    echo "[$(date +%T)] engine dead, restarting" >> $D/steps.log
    kill $WD 2>/dev/null; "${CMD[@]}" >> $D/server.log 2>&1 &
    PID=$!; echo $PID >> $D/pid
    python3 -I $R/watchdog.py $PID $D/cell $D/watch.csv & WD=$!
    for i in $(seq 1 180); do curl -s -m 2 $URL/v1/models >/dev/null && break; sleep 1; done
    "$STRIM" bench http scoreboard --arm $E=$URL,$MODEL --workloads W3 --w3-sizes 4096 --w3-gen 8 --reps 1 --out-dir $D/rewarm >/dev/null 2>&1
  fi
}
SB="$STRIM bench http scoreboard --arm $E=$URL,$MODEL --reps 1 --timeout 600"
cell warmup $STRIM bench http scoreboard --arm $E=$URL,$MODEL --workloads W3 --w3-sizes 4096 --w3-gen 8 --reps 1 --out-dir $D/warmup
ensure; cell agree python3 -I $R/agree.py $URL $MODEL $D/agree.json
ensure; cell w3_4k_16k $SB --workloads W3 --w3-sizes 4096,16384 --w3-gen 256 --out-dir $D/w3_4k_16k
# 32K only if memory stayed < 35 GB so far
PK=$(awk -F, '!/^#/ {m=($4>$5?$4:$5); if(m>x)x=m} END{print int(x)}' $D/watch.csv)
echo "peak so far ${PK} MB" >> $D/steps.log
if [ "${PK:-99999}" -lt 35840 ]; then ensure; cell w3_32k $SB --workloads W3 --w3-sizes 32768 --w3-gen 128 --out-dir $D/w3_32k
else echo "32K skipped: peak ${PK} MB >= 35 GB" >> $D/steps.log; fi
ensure; cell w4_c4_c8 $SB --workloads W4 --conc 4,8 --w4-size 4096 --w4-gen 64 --out-dir $D/w4_c4_c8
ensure; cell w4s_c4_c8 $SB --workloads W4 --conc 4,8 --w4-size 512 --w4-gen 128 --out-dir $D/w4s_c4_c8
ensure; cell w5 $SB --workloads W5 --out-dir $D/w5
ensure; cell replay $STRIM bench http replay --fixture bench/results/final-20261026/synthetic-8turn.json --arm $E=$URL,$MODEL,cache=on --server-log $E=$D/server.log --reps 1 --max-tokens 48 --out-dir $D/replay
echo "end $(date +%T) load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" >> $D/steps.log
kill $WD 2>/dev/null
for p in $(cat $D/pid); do pkill -TERM -P $p 2>/dev/null; kill -TERM $p 2>/dev/null; done
sleep 8
for p in $(cat $D/pid); do pkill -KILL -P $p 2>/dev/null; kill -KILL $p 2>/dev/null; done
exit 0
