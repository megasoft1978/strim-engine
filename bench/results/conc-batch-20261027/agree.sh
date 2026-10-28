#!/bin/bash
# usage: agree.sh URL MODEL OUTDIR [GEN=96]
# 8 fixed realistic prompts (distinct repo source heads + question). Phase "solo": one request at a time
# (single-stream reference). Phase "conc": all 8 at once (batch of 8; also run 4+4). Greedy, 'ignore_eos'.
# Reports per prompt: identical text, else the first differing character index. Text is compared (no token ids on HTTP).
URL=$1; MODEL=$2; OUT=$3; GEN=${4:-96}
mkdir -p "$OUT"
FILES=($(ls Sources/StrimCore/*.swift Sources/StrimEngine/*.swift Sources/StrimServer/*.swift | sort))
N=${#FILES[@]}
req() { # idx phase
  local i=$1 F=${FILES[$(( (i*3 + 1) % N ))]}
  local P="File $F:
$(head -c "${CHARS:-1500}" "$F")

Question: explain what this code does and point out one edge case."
  jq -n --arg m "$MODEL" --arg p "$P" --argjson n "$GEN" \
    '{model:$m,messages:[{role:"user",content:$p}],max_tokens:$n,temperature:0,stream:false,ignore_eos:true,chat_template_kwargs:{enable_thinking:false}}' \
  | curl -s -m 300 "$URL/v1/chat/completions" -H 'content-type: application/json' -d @- | jq -r '.choices[0].message.content' > "$OUT/$2-$i.txt"
}
for i in 0 1 2 3 4 5 6 7; do req $i solo; done
for i in 0 1 2 3 4 5 6 7; do req $i conc8 & done; wait
for i in 0 1 2 3; do req $i conc4a & done; wait
for i in 4 5 6 7; do req $i conc4b & done; wait
cmpfirst() { # a b -> index of first differing char or SAME
  if cmp -s "$1" "$2"; then echo SAME; else cmp "$1" "$2" 2>&1 | sed -E 's/.*byte ([0-9]+).*/diff@byte \1/' | head -1; fi
}
same8=0; same4=0
for i in 0 1 2 3 4 5 6 7; do
  r8=$(cmpfirst "$OUT/solo-$i.txt" "$OUT/conc8-$i.txt")
  if [ $i -lt 4 ]; then r4=$(cmpfirst "$OUT/solo-$i.txt" "$OUT/conc4a-$i.txt"); else r4=$(cmpfirst "$OUT/solo-$i.txt" "$OUT/conc4b-$i.txt"); fi
  [ "$r8" = SAME ] && same8=$((same8+1)); [ "$r4" = SAME ] && same4=$((same4+1))
  echo "prompt $i bytes=$(wc -c < "$OUT/solo-$i.txt") batch8: $r8  batch4: $r4"
done
echo "MATCH batch8 $same8/8  batch4 $same4/8"
