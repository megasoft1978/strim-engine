#!/bin/bash
# Greedy output sample. usage: agree.sh URL MODEL OUT.json [BENCH_DIR=bench]
# 8 fixed prompts (bench/ab_prompts.json), temperature 0, 64 tokens, thinking off, non-streamed -> {key: text}.
URL=$1; MODEL=$2; OUT=$3; B=${4:-bench}
res='{}'
for k in $(jq -r 'keys[]' "$B/ab_prompts.json"); do
  body=$(jq -n --arg m "$MODEL" --argjson p "$(jq --arg k "$k" '.[$k]' "$B/ab_prompts.json")" \
    '{model:$m,messages:[{role:"user",content:$p}],max_tokens:64,temperature:0,ignore_eos:true,stream:false,chat_template_kwargs:{enable_thinking:false}}')
  txt=$(curl -s -m 300 "$URL/v1/chat/completions" -H 'content-type: application/json' -d "$body" | jq -r '.choices[0].message.content // ""')
  res=$(jq --arg k "$k" --arg t "$txt" '. + {($k): $t}' <<<"$res")
done
echo "$res" > "$OUT"
