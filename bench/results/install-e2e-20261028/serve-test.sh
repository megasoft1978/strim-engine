#!/bin/bash
# Phase A: authenticated server, API checks. Phase B: --no-auth server, 3 x W3 4K decode. Run under: lockf -t 3600 -k /tmp/strim-bench.lock this
cd /Users/user/Desktop/Freelance/strim-engine || exit 2
R=$PWD/bench/results/install-e2e-20261028; M=$PWD/models; O=$R/serve; mkdir -p $O
log() { echo "[$(date +%T)] $*" | tee -a $O/steps.txt; }
log "lock acquired load=$(sysctl -n vm.loadavg)"
start() { # name args...
  local n=$1; shift; local t0=$(date +%s)
  strim serve $M/qwen38-4bit $M/qwen38-mtp-4bit --port 8203 "$@" > $O/server-$n.log 2>&1 & SP=$!
  echo idle > $O/cell-$n; $PWD/bench/h2h/watchdog.sh $SP $O/cell-$n $O/watch-$n.csv & WD=$!
  for i in $(seq 1 300); do curl -s -m 1 http://127.0.0.1:8203/health >/dev/null && break; kill -0 $SP 2>/dev/null || { log "server died"; return 1; }; sleep 1; done
  log "$n: server pid $SP ready after ~$(( $(date +%s)-t0 ))s"
}
stop() { kill -TERM $SP; for i in $(seq 1 30); do kill -0 $SP 2>/dev/null || break; sleep 1; done; kill -0 $SP 2>/dev/null && { log "server did not exit in 30s, KILL"; kill -9 $SP; }; log "stopped after ${i}s"; kill $WD 2>/dev/null; }
start auth || exit 1
ls -la ~/.strim/token | tee -a $O/steps.txt; stat -f '%Lp' ~/.strim/token | tee -a $O/steps.txt
T=$(cat ~/.strim/token)
H=http://127.0.0.1:8203
echo "== health" ; curl -s -i $H/health | head -12
echo "== models noauth"; curl -s -i $H/v1/models | head -8
echo "== chat noauth"; curl -s -i $H/v1/chat/completions -H 'content-type: application/json' -d '{"model":"qwen38-4bit","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' | head -12
echo "== chat auth"; curl -s -w '\ntime %{time_total}s\n' $H/v1/chat/completions -H "Authorization: Bearer $T" -H 'content-type: application/json' -d '{"model":"qwen38-4bit","messages":[{"role":"user","content":"Say hi in 5 words."}],"max_tokens":32,"temperature":0}'
echo "== chat auth stream"; curl -sN -w '\ntime %{time_total}s\n' $H/v1/chat/completions -H "Authorization: Bearer $T" -H 'content-type: application/json' -d '{"model":"qwen38-4bit","messages":[{"role":"user","content":"Say hi in 5 words."}],"max_tokens":32,"stream":true,"stream_options":{"include_usage":true}}' | tail -8
echo "== anthropic noauth"; curl -s -i $H/v1/messages -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d '{"model":"qwen38-4bit","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' | head -10
echo "== anthropic x-api-key"; curl -s -w '\ntime %{time_total}s\n' $H/v1/messages -H "x-api-key: $T" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-5","max_tokens":32,"system":"You are terse.","messages":[{"role":"user","content":[{"type":"text","text":"Say hi in 5 words."}]}]}'
echo "== anthropic bearer stream"; curl -sN -w '\ntime %{time_total}s\n' $H/v1/messages -H "Authorization: Bearer $T" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-5","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"Say hi in 5 words."}]}' | head -40
echo "== count_tokens"; curl -s $H/v1/messages/count_tokens -H "x-api-key: $T" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"Say hi in 5 words."}]}'
echo "== wrong token"; curl -s -i $H/v1/chat/completions -H "Authorization: Bearer nope" -H 'content-type: application/json' -d '{"model":"qwen38-4bit","messages":[{"role":"user","content":"hi"}],"max_tokens":8}' | head -8
echo "== mem (footprint MB)"; footprint $SP 2>/dev/null | grep -i "phys_footprint" | head -2
stop
start noauth --no-auth || exit 1
for n in 1 2 3; do
  echo "w3$n" > $O/cell-noauth; log "w3 run $n load=$(sysctl -n vm.loadavg)"
  strim bench http scoreboard --arm strim=$H,qwen38-4bit --reps 1 --timeout 900 --bench-dir $PWD/bench --workloads W3 --w3-sizes 4096 --w3-gen 256 --out-dir $O/w3-$n > $O/w3-$n.stdout.txt 2>&1
  echo idle > $O/cell-noauth
done
stop
pgrep -fl "strim serve" || log "no strim serve left"
log done
