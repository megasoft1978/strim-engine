#!/bin/bash
# usage: abba.sh OUTDIR NTOK REPS CHUNK SEQ(e.g. ABBA) -- A=baseline HEAD build, B=instrumented build, STRIM_OPTIME unset.
# Run under: lockf -t 500 -k /tmp/strim-bench.lock bash abba.sh ...
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "$D/../../.." && pwd)
OUT=$1; N=$2; REPS=$3; CH=$4; SEQ=$5
A=${BIN_A:-/tmp/strim-build-l5base/out/Products/Release/strim}; B=${BIN_B:-/tmp/strim-build-l5new/out/Products/Release/strim}
mkdir -p "$OUT"; i=0
for c in $(echo "$SEQ" | sed 's/./& /g'); do
  i=$((i+1)); bin=$A; [ "$c" = B ] && bin=$B
  echo "== $i $c" 
  env -u STRIM_OPTIME "$D/wd_run.sh" "$OUT/${i}_$c.txt" "$bin" benchprefill "$R/models/qwen38-4bit" "$N" "$REPS" "$CH"
done
