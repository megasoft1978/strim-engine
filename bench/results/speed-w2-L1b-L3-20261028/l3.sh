#!/bin/bash
# usage (repo root, under the GPU lock): l3.sh BIN OUTDIR  -> sampled (temperature 0.7) cold prefill of 4K/16K prompts with
# STRIM_SAMPLED_DEPTH0=1 (no speculation => new build skips the MTP head; old build always runs it). Trie off, max_tokens 1.
BIN=$1; D=$2; mkdir -p "$D"; PORT=8261
STRIM_SAMPLED_DEPTH0=1 STRIM_PREFIX_CACHE=0 "$BIN" serve models/qwen38-4bit models/qwen38-mtp-4bit --port $PORT --no-auth >> "$D/server.txt" 2>&1 &
PID=$!; echo idle > "$D/cell"
bench/h2h/watchdog.sh $PID "$D/cell" "$D/watch.csv" & WD=$!
for i in $(seq 1 120); do curl -s -m 2 http://127.0.0.1:$PORT/v1/models >/dev/null && break; sleep 1; done
echo warm > "$D/cell"; curl -s -m 300 http://127.0.0.1:$PORT/v1/chat/completions -H 'content-type: application/json' -d '{"model":"x","messages":[{"role":"user","content":"hi"}],"max_tokens":2,"temperature":0.7}' >/dev/null
for size in 800 3200; do for rep in 1 2 3 4; do
  echo "s$size" > "$D/cell"
  body=$(awk -v n=$size -v s=$rep 'BEGIN{srand(s); printf "Summarize: "; for(i=0;i<n;i++) printf "w%d ", int(rand()*9000)}')
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  out=$(curl -s -m 900 http://127.0.0.1:$PORT/v1/chat/completions -H 'content-type: application/json' \
    -d "{\"model\":\"qwen38-4bit\",\"messages\":[{\"role\":\"user\",\"content\":\"$body\"}],\"max_tokens\":1,\"temperature\":0.7}")
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  echo "$size $rep $(echo "$out" | jq -r '.usage.prompt_tokens') $(echo "$t1 - $t0" | bc)" >> "$D/ttft.txt"
done; done
kill $WD 2>/dev/null; kill -TERM $PID; sleep 6; kill -KILL $PID 2>/dev/null
