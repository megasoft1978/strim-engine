#!/bin/bash
# Warm-up: real requests through the OpenAI endpoint (thinking off), incl. repeated shared-prefix prompts. Output: warm.log
PORT=${PORT:-8203}; TOK=$(cat ~/.strim/token); OUT=${1:-/tmp/strim-live-work/warm.log}; : > $OUT
SYS="You are a concise senior engineer. Answer precisely and show code when asked. Follow the project conventions: small functions, clear names, explicit error handling, no needless abstraction."
ask() { jq -n --arg s "$SYS" --arg p "$1" '{messages:[{role:"system",content:$s},{role:"user",content:$p}],max_tokens:200,temperature:0.2,chat_template_kwargs:{enable_thinking:false}}' \
  | curl -s -m 300 http://127.0.0.1:$PORT/v1/chat/completions -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d @- | jq -c '{c:(.choices[0].message.content|.[0:60]),u:.usage}' >> $OUT; }
for p in "Write a Go function that reverses a slice of ints in place." "Explain what a mutex is in two sentences." "Write a Go function that returns the median of a float64 slice." "Write a Swift function that checks whether a string is a palindrome." "Give a one-paragraph summary of how a B-tree stays balanced." "Write a Go table-driven test for a function Abs(int) int." "Explain the difference between a process and a thread." "Write a Swift extension on Array that returns the sum of its elements."; do ask "$p"; done
