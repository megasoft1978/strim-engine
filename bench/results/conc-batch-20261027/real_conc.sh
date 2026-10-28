#!/bin/bash
# usage: real_conc.sh URL MODEL C CHARS GEN OUTDIR [SEED]
# Realistic agent flavor: C concurrent greedy requests, each = distinct repo source file head (CHARS chars)
# + a coding question. Prints per-client ttft/decode and aggregate tok/s (total completion tokens / wall).
URL=$1; MODEL=$2; C=$3; CHARS=$4; GEN=$5; OUT=$6; SEED=${7:-0}
mkdir -p "$OUT"
FILES=($(ls Sources/StrimCore/*.swift Sources/StrimEngine/*.swift Sources/StrimServer/*.swift Sources/StrimHost/*.swift Sources/StrimHarness/*.swift 2>/dev/null | sort))
N=${#FILES[@]}
T0=$(date +%s.%N)
for i in $(seq 0 $((C-1))); do
  F=${FILES[$(( (SEED*7 + i*5 + 3) % N ))]}
  PROMPT="File $F (run tag $SEED-$i):
$(head -c "$CHARS" "$F")

Question: explain what this code does, point out one possible bug or edge case, and show a minimal fix."
  jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson n "$GEN" \
    '{model:$m,messages:[{role:"user",content:$p}],max_tokens:$n,temperature:0,stream:true,stream_options:{include_usage:true},ignore_eos:true,chat_template_kwargs:{enable_thinking:false}}' > "$OUT/req$i.json"
  (
    S=$(date +%s.%N); FIRST=""
    curl -sN -m 600 "$URL/v1/chat/completions" -H 'content-type: application/json' -d @"$OUT/req$i.json" | while IFS= read -r line; do
      case "$line" in
        'data: {'*) if [ -z "$FIRST" ] && echo "$line" | grep -q '"content": *"'; then FIRST=$(date +%s.%N); echo "first $FIRST" >> "$OUT/c$i.txt"; fi
                    echo "$line" | grep -q '"completion_tokens"' && echo "usage $line" >> "$OUT/c$i.txt";;
      esac
    done
    echo "start $S" >> "$OUT/c$i.txt"; echo "end $(date +%s.%N)" >> "$OUT/c$i.txt"
  ) &
done
wait
T1=$(date +%s.%N)
TOT=0
for i in $(seq 0 $((C-1))); do
  n=$(grep '^usage' "$OUT/c$i.txt" | sed -E 's/.*"completion_tokens": *([0-9]+).*/\1/' | tail -1)
  pt=$(grep '^usage' "$OUT/c$i.txt" | sed -E 's/.*"prompt_tokens": *([0-9]+).*/\1/' | tail -1)
  s=$(awk '/^start/{print $2}' "$OUT/c$i.txt"); f=$(awk '/^first/{print $2}' "$OUT/c$i.txt"); e=$(awk '/^end/{print $2}' "$OUT/c$i.txt")
  echo "client $i prompt_tokens=${pt:-?} completion=${n:-0} ttft=$(echo "${f:-0} - $s" | bc -l | cut -c1-6) decode_tps=$(echo "(${n:-1}-1)/($e - ${f:-$e} + 0.0001)" | bc -l | cut -c1-6)"
  TOT=$((TOT + ${n:-0}))
done
echo "AGG c=$C chars=$CHARS tokens=$TOT wall=$(echo "$T1 - $T0" | bc -l | cut -c1-6) agg_tps=$(echo "$TOT / ($T1 - $T0)" | bc -l | cut -c1-6)"
