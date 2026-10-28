#!/bin/bash
# usage: trace.sh OUTDIR CONC  (foreground, run under lockf)
set -u
R=/Users/user/Desktop/Freelance/strim-engine
BIN=/tmp/strim-build-l1/release/strim
OUT=$1; C=$2; mkdir -p "$OUT"; cd "$R" || exit 2
PORT=8203; URL=http://127.0.0.1:$PORT; MODEL=qwen38-4bit
echo idle > "$OUT/cell"
STRIM_ENGINE_TRACE=1 "$BIN" serve models/qwen38-4bit models/qwen38-mtp-4bit --port $PORT --no-auth \
  > "$OUT/server.stdout" 2> >(perl -MTime::HiRes=time -ne 'printf("%.4f %s", time(), $_)' > "$OUT/server.trace") &
PID=$!
"$R/bench/h2h/watchdog.sh" "$PID" "$OUT/cell" "$OUT/watch.csv" & WD=$!
for i in $(seq 1 240); do curl -s -m 2 "$URL/v1/models" >/dev/null && break; kill -0 "$PID" 2>/dev/null || break; sleep 1; done
echo "ready after ${i}s"
SB=("$BIN" bench http scoreboard --arm "strim=$URL,$MODEL" --reps 1 --timeout 900 --bench-dir "$R/bench")
echo warm > "$OUT/cell"; "${SB[@]}" --workloads W3 --w3-sizes 4096 --w3-gen 8 --out-dir "$OUT/warmup" >/dev/null 2>&1
echo "w4c$C" > "$OUT/cell"; echo "MARK $(perl -MTime::HiRes=time -e 'printf "%.4f", time()')" >> "$OUT/marks.txt"
"${SB[@]}" --workloads W4 --conc "$C" --w4-size 512 --w4-gen 128 --out-dir "$OUT/w4c$C" > "$OUT/w4c$C.stdout" 2>&1; echo "rc=$?"
echo "MARKEND $(perl -MTime::HiRes=time -e 'printf "%.4f", time()')" >> "$OUT/marks.txt"
echo idle > "$OUT/cell"
for p in $(pgrep -P "$PID") "$PID"; do kill -TERM "$p" 2>/dev/null; done; sleep 4; kill "$WD" 2>/dev/null; wait 2>/dev/null
echo done
