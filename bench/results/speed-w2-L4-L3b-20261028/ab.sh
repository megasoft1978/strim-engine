#!/bin/bash
# usage (repo root): ab.sh OUTDIR SEQ(e.g. ABABAB) "ENV=.. ENV=.." CTX DEPTH N REPS
# Same binary BIN, arm A = STRIM_SPEC_HOSTFEED=1 (old: host read of drafts between draft chain and verify),
# arm B = default (device feed). Extra env (e.g. STRIM_TIMING=1 STRIM_MTP_FIXED=1) in the third arg.
# Each cell: benchspec model head N DEPTH ids REPS under the GPU lock + 5 s memory watchdog.
D=bench/results/speed-w2-L4-L3b-20261028
OUT=$1; SEQ=$2; ENVS=$3; CTX=$4; DEPTH=$5; N=$6; REPS=$7
BIN=${BIN:-/tmp/strim-build-l4/out/Products/Release/strim}
IDS=$(cat /tmp/l4-ids-$CTX.txt)
mkdir -p "$OUT"; i=0
for c in $(echo "$SEQ" | sed 's/./& /g'); do
  i=$((i+1)); arm=""; [ "$c" = A ] && arm="STRIM_SPEC_HOSTFEED=1"
  echo "== $i $c"
  lockf -t 3600 -k /tmp/strim-bench.lock env $arm $ENVS "$D/wd_run.sh" "$OUT/${i}_$c.txt" "$BIN" benchspec models/qwen38-4bit models/qwen38-mtp-4bit "$N" "$DEPTH" "$IDS" "$REPS"
done
