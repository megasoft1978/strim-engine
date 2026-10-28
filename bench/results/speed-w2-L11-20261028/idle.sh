#!/bin/bash
# usage (repo root): idle.sh SEQ(e.g. ABABAB) [IDLE_S=120]   -- first-token latency after idle. A = knob unset, B = STRIM_WIRED_LIMIT_GB=${WL:-40}.
# One engine session per letter (under the GPU lock + 5 s watchdog): warm 3 requests, then IDLE_S s of idle, then 3 timed 1-token requests (first = post-idle).
D=bench/results/speed-w2-L11-20261028; mkdir -p $D/raw
BIN=${BIN:-/tmp/strim-build-l11/out/Products/Release/strim}; IDLE=${2:-120}
i=0
for c in $(echo "$1" | sed 's/./& /g'); do
  i=$((i+1)); O=$D/raw/idle-$i-$c; mkdir -p $O
  if [ "$c" = B ]; then W="STRIM_WIRED_LIMIT_GB=${WL:-40}"; else W="STRIM_WIRED_LIMIT_GB="; fi
  lockf -t 3600 -k /tmp/strim-bench.lock bash -c '
    env '"$W"' '"$BIN"' serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8204 --no-auth > '"$O"'/server.txt 2>&1 &
    P=$!; echo idle > '"$O"'/cell; bash bench/h2h/watchdog.sh $P '"$O"'/cell '"$O"'/mem.csv & WD=$!
    for k in $(seq 1 120); do curl -s -m 2 http://127.0.0.1:8204/v1/models >/dev/null && break; sleep 1; done
    req() { curl -s -m 120 -o /dev/null -w "%{time_total}\n" http://127.0.0.1:8204/v1/chat/completions -H "content-type: application/json" \
      -d "{\"model\":\"qwen38-4bit\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi. $RANDOM\"}],\"max_tokens\":1,\"temperature\":0}"; }
    for k in 1 2 3; do req > /dev/null; done
    echo "warm: $(req) $(req)" > '"$O"'/lat.txt
    sleep '"$IDLE"'
    echo "post-idle then 2 more: $(req) $(req) $(req)" >> '"$O"'/lat.txt
    kill -TERM $P; kill $WD 2>/dev/null; sleep 5; kill -KILL $P 2>/dev/null; wait 2>/dev/null'
  echo "$i $c: $(cat $O/lat.txt | tr '\n' ' ')"
done
