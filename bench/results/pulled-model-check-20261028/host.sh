#!/bin/bash
# Holds the GPU lock, runs one strim server (pulled model, brew binary) until $W/stop appears (max 55 min).
R=/Users/user/Desktop/Freelance/strim-engine; W=/tmp/strim-live-work; mkdir -p $W; rm -f $W/stop $W/ready
PORT=${PORT:-8203}; P=~/.strim/models
echo live > $W/cell
strim serve $P/qwen38-4bit $P/qwen38-mtp-4bit --port $PORT > $W/serve.log 2>&1 &
pid=$!; echo $pid > $W/pid
bash $R/bench/h2h/watchdog.sh $pid $W/cell $W/mem.csv &
wd=$!
for i in $(seq 1 300); do curl -sf -m 2 http://127.0.0.1:$PORT/health >/dev/null && break; sleep 0.2; done
touch $W/ready
for i in $(seq 1 660); do [ -f $W/stop ] && break; kill -0 $pid 2>/dev/null || break; sleep 5; done
kill -TERM $pid; for i in $(seq 1 100); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
kill -0 $pid 2>/dev/null && kill -9 $pid
kill $wd 2>/dev/null; touch $W/stopped
