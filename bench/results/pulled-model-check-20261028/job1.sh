#!/bin/bash
# JOB 1b/1c: run under: lockf -t 3600 -k /tmp/strim-bench.lock bash job1.sh
R=/Users/user/Desktop/Freelance/strim-engine
OUT=$R/bench/results/pulled-model-check-20261028/serve; mkdir -p $OUT
TOK=$(cat ~/.strim/token); PORT=8231
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
PROMPTS=("Explain in two sentences why the sky is blue." "Write a Swift function that returns the n-th Fibonacci number iteratively. Code only." "List the planets of the solar system in order from the sun, comma separated.")
run_server() { # name dir...
  local name=$1; shift
  echo "$name" > $OUT/cell; : > $OUT/$name.serve.log
  echo "load_avg_start: $(sysctl -n vm.loadavg)" > $OUT/$name.timing
  curl -sf -m 1 http://127.0.0.1:$PORT/health >/dev/null && { echo "PORT BUSY" >> $OUT/$name.timing; return; }
  local t0; t0=$(now)
  strim serve "$@" --port $PORT >> $OUT/$name.serve.log 2>&1 &
  local pid=$!
  bash $R/bench/h2h/watchdog.sh $pid $OUT/cell $OUT/$name.mem.csv &
  local wd=$!
  for i in $(seq 1 600); do curl -sf -m 2 http://127.0.0.1:$PORT/health >/dev/null && break; sleep 0.1; done
  local th; th=$(now)
  # first token: streamed request, stamp first content delta
  local first
  first=$(curl -sN -m 120 http://127.0.0.1:$PORT/v1/chat/completions -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Say hello."}],"max_tokens":16,"temperature":0,"stream":true,"chat_template_kwargs":{"enable_thinking":false}}' \
    | perl -MTime::HiRes=time -ne 'if(/"content":\s*"[^"]/ && !$d){printf "%.3f",time;$d=1}')
  echo "serve_to_health_s: $(echo "$th - $t0" | bc)" >> $OUT/$name.timing
  echo "serve_to_first_token_s: $(echo "$first - $t0" | bc)" >> $OUT/$name.timing
  echo "first_request_after_health_s: $(echo "$first - $th" | bc)" >> $OUT/$name.timing
  if [ -z "$NOPROMPTS" ]; then
  local n=0
  for p in "${PROMPTS[@]}"; do n=$((n+1))
    jq -n --arg p "$p" '{messages:[{role:"user",content:$p}],max_tokens:64,temperature:0,stream:false,chat_template_kwargs:{enable_thinking:false}}' \
      | curl -s -m 300 http://127.0.0.1:$PORT/v1/chat/completions -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d @- > $OUT/$name.p$n.json
    jq -j '.choices[0].message.content' $OUT/$name.p$n.json > $OUT/$name.p$n.txt
  done
  fi
  echo "load_avg_end: $(sysctl -n vm.loadavg)" >> $OUT/$name.timing
  kill -TERM $pid; for i in $(seq 1 100); do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
  kill -0 $pid 2>/dev/null && { echo "server still alive" >> $OUT/$name.timing; kill -9 $pid; }
  kill $wd 2>/dev/null; sleep 2
}
P=~/.strim/models
NOPROMPTS= run_server pulled-cold $P/qwen38-4bit $P/qwen38-mtp-4bit
run_server pulled-warm $P/qwen38-4bit $P/qwen38-mtp-4bit
run_server repo $R/models/qwen38-4bit $R/models/qwen38-mtp-4bit
echo finished > $OUT/done
