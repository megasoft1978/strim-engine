#!/bin/bash
# usage: gen_ids.sh OUT.ids [CHARS=6000]  -- the 8 agree.sh prompts as chat-template token ids (no-think framing), one per line
OUT=$1; CHARS=${2:-6000}; STRIM=${STRIM_BIN:-/tmp/strim-build-conc/release/strim}
FILES=($(ls Sources/StrimCore/*.swift Sources/StrimEngine/*.swift Sources/StrimServer/*.swift | sort)); N=${#FILES[@]}
printf '</think>\n\n' > /tmp/strim-nothink.txt
TAIL=$($STRIM tokenize --text /tmp/strim-nothink.txt)
: > "$OUT"
for i in 0 1 2 3 4 5 6 7; do
  F=${FILES[$(( (i*3 + 1) % N ))]}
  P="File $F:
$(head -c "$CHARS" "$F")

Question: explain what this code does and point out one edge case."
  jq -n --arg p "$P" '[{role:"user",content:$p}]' > /tmp/strim-parity-msg.json
  echo "$($STRIM tokenize --chat /tmp/strim-parity-msg.json),$TAIL" >> "$OUT"
done
