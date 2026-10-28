#!/bin/bash
# usage (repo root, under the GPU lock, FOREGROUND/harness shell): one_run.sh DIR BIN PORT CMDFILE [ENV=VAL ...]
# Starts a server, samples footprint every 3 s, sources CMDFILE (vars: D BIN URL MODEL PID), stops the server.
D=$1; BIN=$2; PORT=$3; CMDS=$4; shift 4
mkdir -p $D; URL=http://127.0.0.1:$PORT; MODEL=qwen38-4bit
env "$@" $BIN serve models/qwen38-4bit models/qwen38-mtp-4bit --port $PORT --no-auth > $D/server.log 2>&1 &
PID=$!
for s in $(seq 1 150); do curl -s -m 2 $URL/v1/models >/dev/null && break; kill -0 $PID 2>/dev/null || { echo "server died: $(tail -2 $D/server.log)"; exit 1; }; sleep 1; done
echo idle > $D/cell
bench/results/cache-footprint-20261027/sample.sh $PID $PORT $D/cell $D/footprint.csv &
SP=$!
source $CMDS
kill -TERM $PID; wait $PID 2>/dev/null; sleep 3; kill $SP 2>/dev/null
