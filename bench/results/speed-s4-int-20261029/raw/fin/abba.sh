#!/bin/bash
set -euo pipefail
out=/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029/raw/fin/abba
if [[ ${1:-} != block ]]; then
  for cycle in 1 2; do
    index=0
    for arm in base fork fork base; do
      index=$((index+1))
      echo "$(date -u +%FT%TZ) waiting GPU lock $cycle-$index-$arm"
      lockf -k /tmp/strim-bench.lock bash "$0" block "$cycle-$index-$arm" "$arm"
    done
  done
  exit
fi
block=$2
arm=$3
mkdir -p "$out/$block"
if [[ $arm == base ]]; then build=/tmp/s4/build-base-int; else build=/tmp/s4/build-int; fi
model=$HOME/.strim/models/qwen38-4bit
unset STRIM_PARITY_IDS STRIM_DECODE_POLICY STRIM_PREFIX_DISK STRIM_S4_FUSE
{ date -u +%FT%TZ; uptime; sysctl -n vm.swapusage; } > "$out/$block/start.txt"
for c in 1 4 8; do
  echo "$(date -u +%FT%TZ) $block decode c=$c"
  "$build/release/S4IntegrationBench" decode "$model" "$c" 3 64 > "$out/$block/c$c.jsonl" 2> "$out/$block/c$c.stderr"
  bash /tmp/s4/fin/check-output.sh "$out/$block/c$c.jsonl" "$out/1-1-base/c$c.jsonl"
done
echo "$(date -u +%FT%TZ) $block verify widths=3,5,8"
"$build/release/S4IntegrationBench" verify "$model" 3 12 > "$out/$block/verify.jsonl" 2> "$out/$block/verify.stderr"
bash /tmp/s4/fin/check-output.sh "$out/$block/verify.jsonl" "$out/1-1-base/verify.jsonl"
{ date -u +%FT%TZ; uptime; sysctl -n vm.swapusage; } > "$out/$block/end.txt"
echo "completed $block"
