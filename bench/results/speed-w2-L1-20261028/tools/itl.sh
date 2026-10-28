#!/bin/bash
# usage: itl.sh OUTDIR  (env passed to the engine; foreground, under lockf)
# Two long streams decode; a 512-token then a ~4K-token streamed request arrive. Timestamps every SSE data line.
set -u
R=/Users/user/Desktop/Freelance/strim-engine
BIN=${STRIM_BIN:-/tmp/strim-build-l1/release/strim}
OUT=$1; mkdir -p "$OUT"; cd "$R" || exit 2
PORT=8203; URL=http://127.0.0.1:$PORT; MODEL=qwen38-4bit
echo idle > "$OUT/cell"
"$BIN" serve models/qwen38-4bit models/qwen38-mtp-4bit --port $PORT --no-auth > "$OUT/server.txt" 2>&1 &
PID=$!
"$R/bench/h2h/watchdog.sh" "$PID" "$OUT/cell" "$OUT/watch.csv" & WD=$!
for i in $(seq 1 240); do curl -s -m 2 "$URL/v1/models" >/dev/null && break; kill -0 "$PID" 2>/dev/null || break; sleep 1; done
SB=("$BIN" bench http scoreboard --arm "strim=$URL,$MODEL" --reps 1 --timeout 900 --bench-dir "$R/bench")
"${SB[@]}" --workloads W3 --w3-sizes 4096 --w3-gen 8 --out-dir "$OUT/warmup" >/dev/null 2>&1
body() { jq -nc --arg p "$1" --argjson m "$2" '{model:"qwen38-4bit",messages:[{role:"user",content:$p}],max_tokens:$m,stream:true,chat_template_kwargs:{enable_thinking:false}}'; }
stream() { # name prompt max
  local now; now=$(perl -MTime::HiRes=time -e 'printf "%.4f", time()')
  echo "$1 $now" >> "$OUT/marks.txt"
  curl -s -N "$URL/v1/chat/completions" -H 'content-type: application/json' -d "$(body "$2" "$3")" \
    | perl -MTime::HiRes=time -ne 'print sprintf("%.4f", time), "\n" if /^data: \{/' > "$OUT/$1.ts" &
  LAST=$!
}
: > "$OUT/marks.txt"
echo itl > "$OUT/cell"
P_LONG="Tell a long story about a lighthouse keeper named Ada and the storms she survived, in detail."
REP512=$(perl -e 'print "The archive index lists one entry per file, each with a checksum and a date. " x 30')
REP4K=$(perl -e 'print "The archive index lists one entry per file, each with a checksum and a date. " x 240')
stream s1 "$P_LONG" 700; P1=$LAST
stream s2 "$P_LONG two" 700; P2=$LAST
for i in $(seq 1 120); do n=$(wc -l < "$OUT/s1.ts" 2>/dev/null || echo 0); [ "$n" -ge 40 ] && break; sleep 1; done
stream a512 "$REP512 Summarize in one line." 16; PA=$LAST
for i in $(seq 1 120); do [ -s "$OUT/a512.ts" ] && break; sleep 1; done; sleep 2
for i in $(seq 1 120); do n=$(wc -l < "$OUT/s1.ts" 2>/dev/null || echo 0); [ "$n" -ge 150 ] && break; sleep 1; done
stream a4k "$REP4K Summarize in one line." 16; PB=$LAST
wait $PA $PB $P1 $P2
echo "done $(date +%T)" >> "$OUT/marks.txt"
echo idle > "$OUT/cell"
for p in $(pgrep -P "$PID") "$PID"; do kill -TERM "$p" 2>/dev/null; done; sleep 4; kill "$WD" 2>/dev/null; wait 2>/dev/null
echo "lines s1=$(wc -l < $OUT/s1.ts) s2=$(wc -l < $OUT/s2.ts) a512=$(wc -l < $OUT/a512.ts) a4k=$(wc -l < $OUT/a4k.ts)"
