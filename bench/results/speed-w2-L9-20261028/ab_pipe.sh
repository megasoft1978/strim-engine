#!/bin/bash
# usage (repo root): ab_pipe.sh SEQ(e.g. ABABAB)
# Same binary (snapshot build with a snapshot-only STRIM_PIPE_LAYERS prototype, NOT in the repo): arm A = STRIM_PIPE_LAYERS unset (today),
# arm B = STRIM_PIPE_LAYERS=8 (asyncEval(h) after every 8th layer of a decode/verify pass). Each cell under the GPU lock + 5 s watchdog.
D=bench/results/speed-w2-L9-20261028
BIN=${BIN:-/tmp/strim-build-l9/out/Products/Release/strim}
SEQ=$1; i=0
IDS=$(cat /tmp/l4-ids-4096.txt)
for c in $(echo "$SEQ" | sed 's/./& /g'); do
  i=$((i+1)); arm=""; [ "$c" = B ] && arm="STRIM_PIPE_LAYERS=8"
  echo "== $i $c"
  lockf -t 3600 -k /tmp/strim-bench.lock env $arm H2H_ROOT=$PWD STRIM_MTP_FIXED=1 DA_PARTS=round DA_CTX=4096,16384 "$D/wd_run.sh" "$D/raw/pipe-round-${i}_$c.txt" "$BIN" benchdecodeanatomy $PWD/models/qwen38-4bit $PWD/models/qwen38-mtp-4bit 5
  lockf -t 3600 -k /tmp/strim-bench.lock env $arm H2H_ROOT=$PWD STRIM_MTP_FIXED=1 "$D/wd_run.sh" "$D/raw/pipe-spec-${i}_$c.txt" "$BIN" benchspec models/qwen38-4bit models/qwen38-mtp-4bit 96 2 "$IDS" 2
done
