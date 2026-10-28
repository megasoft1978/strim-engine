#!/bin/bash
# B=4/B=8 decode step (BatchModel.forward, synthetic 4K caches), arm A = today, arm B = STRIM_PIPE_LAYERS=8 (snapshot-only prototype). Also one STRIM_TIMING round.
D=bench/results/speed-w2-L9-20261028
BIN=${BIN:-/tmp/strim-build-l9/out/Products/Release/strim}
i=0
for c in A B A B; do
  i=$((i+1)); arm=""; [ "$c" = B ] && arm="STRIM_PIPE_LAYERS=8"
  lockf -t 3600 -k /tmp/strim-bench.lock env $arm H2H_ROOT=$PWD DA_PARTS=top DA_CFG=b4,b8 DA_CTX=4096 "$D/wd_run.sh" "$D/raw/pipe-batch-${i}_$c.txt" "$BIN" benchdecodeanatomy $PWD/models/qwen38-4bit $PWD/models/qwen38-mtp-4bit 5
done
lockf -t 3600 -k /tmp/strim-bench.lock env H2H_ROOT=$PWD STRIM_TIMING=1 STRIM_MTP_FIXED=1 DA_PARTS=round DA_CTX=4096 "$D/wd_run.sh" "$D/raw/round-timing.txt" "$BIN" benchdecodeanatomy $PWD/models/qwen38-4bit $PWD/models/qwen38-mtp-4bit 5
