#!/bin/bash
# usage (repo root): sweep.sh ROUNDS "DEPTHS" "NS"   -- interleaved sweep of STRIM_PIPE_LAYERS (ABAB generalised) on benchspec 4K prompt, STRIM_MTP_FIXED=1
D=bench/results/speed-w2-L10-20261028
BIN=${BIN:-/tmp/strim-build-l10/out/Products/Release/strim}
IDS=$(cat /tmp/l4-ids-4096.txt)
CTX=${CTX:-4096}
for r in $(seq 1 $1); do
 for d in $2; do
  for n in $3; do
   lockf -t 3600 -k /tmp/strim-bench.lock env STRIM_PIPE_LAYERS=$n H2H_ROOT=$PWD STRIM_MTP_FIXED=1 "$D/wd_run.sh" "$D/raw/sweep-d${d}-n${n}-r${r}.txt" "$BIN" benchspec models/qwen38-4bit models/qwen38-mtp-4bit 128 $d "$IDS" 2 >> $D/raw/sweep.log
  done
 done
done
