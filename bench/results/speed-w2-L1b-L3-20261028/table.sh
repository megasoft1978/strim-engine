#!/bin/bash
# usage: table.sh ABDIR -> TSV: arm pass cell variant metric value  (value = summary.md median; replay = per-turn ttft)
D=$1
for a in armA armB; do for p in 1 2 3; do
  P=$D/$a/strim/pass$p; [ -d "$P" ] || continue
  for c in w4s1 w4s w3 w5; do
    sm=$P/$c/summary.md; [ -f "$sm" ] || continue
    awk -F'|' -v a=$a -v p=p$p -v c=$c '/^\| W[0-9]/ {gsub(/ /,"",$3); gsub(/ /,"",$4); split($5,x," "); print a"\t"p"\t"c"\t"$3"\t"$4"\t"x[1]}' "$sm"
  done
  if [ -f $P/replay.stdout.txt ]; then
    sed -n 's/.*turn \([0-9]*\)\/8\] ttft=\([0-9.]*\)s.*/\1 \2/p' $P/replay.stdout.txt | awk -v a=$a -v p=p$p '{print a"\t"p"\treplay\tturn"$1"\tttft_s\t"$2; s+=$2} END{print a"\t"p"\treplay\tsum\tttft_s\t"s}'
  fi
  fp=$(awk -F, '/^[0-9]/ && $5+0>m{m=$5+0} END{print m+0}' $P/watch.csv)
  sw=$(awk -F, '/^[0-9]/ {if(!b)b=$3; g=$3-b; if(g>m)m=g} END{print m+0}' $P/watch.csv)
  echo -e "$a\tp$p\tMEM\tpeak_footprint_mb\tmb\t$fp"; echo -e "$a\tp$p\tMEM\tswap_grow_mb\tmb\t$sw"
done; done
