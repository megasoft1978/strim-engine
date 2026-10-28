#!/bin/bash
# usage (repo root, under the GPU lock): w3.sh BIN OUTDIR PORT "ENV=.." SIZES GEN
# One engine, warmup, then the W3 single-stream cold-prefill+decode cell for SIZES; memory watchdog every 5 s.
BIN=$1; D=$2; PORT=$3; ENVS=$4; SIZES=$5; GEN=$6; mkdir -p "$D"
env $ENVS STRIM_PREFIX_CACHE=0 "$BIN" serve models/qwen38-4bit models/qwen38-mtp-4bit --port $PORT --no-auth >> "$D/server.txt" 2>&1 &
PID=$!; echo idle > "$D/cell"
bench/h2h/watchdog.sh $PID "$D/cell" "$D/watch.csv" & WD=$!
for i in $(seq 1 240); do curl -s -m 2 http://127.0.0.1:$PORT/v1/models >/dev/null && break; sleep 1; done
SB=("$BIN" bench http scoreboard --arm "x=http://127.0.0.1:$PORT,qwen38-4bit" --reps 1 --timeout 900 --bench-dir "$PWD/bench")
echo warm > "$D/cell"; "${SB[@]}" --workloads W3 --w3-sizes 4096 --w3-gen 8 --out-dir "$D/warm" > /dev/null 2>&1
echo w3 > "$D/cell"; "${SB[@]}" --workloads W3 --w3-sizes "$SIZES" --w3-gen "$GEN" --out-dir "$D/w3" > "$D/w3.stdout.txt" 2>&1
kill $WD 2>/dev/null; kill -TERM $PID; sleep 6; kill -KILL $PID 2>/dev/null
