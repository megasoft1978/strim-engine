#!/bin/bash
# usage: sumsweep.sh DIR...   -> one markdown row per (variant, flavor, c): aggregate tok/s (2 reps), median TTFT, mean per-request decode
echo "| variant | flavor | c | agg tok/s r1 | r2 | p50 TTFT s | per-req tok/s |"
echo "|---|---|---|---|---|---|---|"
for d in "$@"; do
  v=$(basename $d)
  for c in 1 4 8; do
    # repeated-text flavor: scoreboard summary tables
    a=(); t=(); p=()
    for r in 1 2; do
      f=$d/rep512-r$r/summary.md
      a+=($(awk -F'|' -v c="distinct-c$c" '$3 ~ c && $4 ~ /aggregate_tps/ {split($5,x," "); print x[1]}' $f))
      t+=($(awk -F'|' -v c="distinct-c$c" '$3 ~ c && $4 ~ /ttft_s/ {split($5,x," "); print x[1]}' $f))
      p+=($(awk -F'|' -v c="distinct-c$c" '$3 ~ c && $4 ~ /decode_tps/ {split($5,x," "); print x[1]}' $f))
    done
    echo "| $v | repeated | $c | ${a[0]:-?} | ${a[1]:-?} | ${t[0]:-?}/${t[1]:-?} | ${p[0]:-?}/${p[1]:-?} |"
    # realistic flavor
    ag=(); tt=(); pp=()
    for r in 1 2; do
      f=$d/real512-c$c-r$r.txt
      ag+=($(awk '/^AGG/ {sub("agg_tps=","",$NF); print $NF}' $f))
      tt+=($(awk '/^client/ {for(i=1;i<=NF;i++) if($i ~ /^ttft=/){sub("ttft=","",$i); print $i}}' $f | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'))
      pp+=($(awk '/^client/ {for(i=1;i<=NF;i++) if($i ~ /^decode_tps=/){sub("decode_tps=","",$i); s+=$i; n++}} END{if(n) printf "%.1f", s/n}' $f))
    done
    echo "| $v | realistic | $c | ${ag[0]:-?} | ${ag[1]:-?} | ${tt[0]:-?}/${tt[1]:-?} | ${pp[0]:-?}/${pp[1]:-?} |"
  done
done
