#!/bin/bash
# L3b A/B driver (repo root): A = STRIM_MTP_WINDOW=0 (full head), B = 4096, C = 2048; order ABCABCABC; W3 4K/16K/32K gen 128.
R=bench/results/speed-w2-L4-L3b-20261028
BIN=/tmp/strim-build-l3b/out/Products/Release/strim
i=0
for rep in 1 2 3; do for arm in A B C; do
  i=$((i+1)); w=0; [ $arm = B ] && w=4096; [ $arm = C ] && w=2048
  echo "== $i $arm window=$w"
  lockf -t 3600 -k /tmp/strim-bench.lock $R/w3.sh $BIN $R/raw/l3b/${i}_$arm 82$((70+i)) "STRIM_TIMING=1 STRIM_MTP_WINDOW=$w" 4096,16384,32768 128
done; done
echo ALLDONE
