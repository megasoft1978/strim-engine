#!/bin/bash
# usage: table.sh ABDIR -> TSV rows: arm pass cell variant p50 p95 aggregate_tps decode_tps_mean footprint_peak swapgrow
D=$1
for a in armA armB; do for p in 1 2 3; do
  P=$D/$a/strim/pass$p
  for c in w4s w6 w4 w3; do
    raw=$P/$c/raw.jsonl; sm=$P/$c/summary.md
    [ -f "$raw" ] || continue
    jq -rs '[.[] | select(.kind=="request")] | group_by(.variant)[] |
      (map(.ttft_s)|sort) as $t | (length) as $n |
      [.[0].variant, ($t[(($n*0.5)|ceil)-1]), ($t[(($n*0.95)|ceil)-1]), ((map(.decode_tps)|add)/$n)] | @tsv' "$raw" |
    while IFS=$'\t' read -r v p50 p95 dtps; do
      agg=$(/usr/bin/grep "| $v | aggregate_tps" "$sm" | awk -F'|' '{print $5}' | awk '{print $1}')
      dec=$(/usr/bin/grep "| $v | decode_tps" "$sm" | awk -F'|' '{print $5}' | awk '{print $1}')
      echo -e "$a\tp$p\t$c\t$v\t$p50\t$p95\t$agg\t$dec"
    done
  done
  fp=$(awk -F, '/^[0-9]/ && $5+0>m{m=$5+0} END{print m+0}' $P/watch.csv)
  echo -e "$a\tp$p\tMEM\tpeak_footprint_mb\t$fp"
done; done
