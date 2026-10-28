#!/bin/bash
# L4 A/B driver (repo root). A = STRIM_SPEC_HOSTFEED=1, B = device feed; ABABAB per cell, fixed depth.
R=bench/results/speed-w2-L4-L3b-20261028
for cell in "4096 4" "8192 2" "8192 4"; do
  set -- $cell
  $R/ab.sh $R/raw/l4-$1-d$2 ABABAB "STRIM_TIMING=1 STRIM_MTP_FIXED=1" $1 $2 96 2
done
echo ALLDONE
