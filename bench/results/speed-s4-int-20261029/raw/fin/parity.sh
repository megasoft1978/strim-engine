#!/bin/bash
set -euo pipefail
out=/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-int-20261029/raw/fin/parity
model=$HOME/.strim/models/qwen38-4bit
unset STRIM_PARITY_IDS STRIM_DECODE_POLICY STRIM_PREFIX_DISK STRIM_S4_FUSE
for c in 6 7 8; do
  for arm in base fork; do
    if [[ $arm == base ]]; then build=/tmp/s4/build-base-int; else build=/tmp/s4/build-int; fi
    date -u +%FT%TZ
    echo "checkbatchparity c=$c $arm"
    "$build/release/strim" checkbatchparity "$model" 512 "$c" 16 > "$out/batch$c-$arm.txt" 2> "$out/batch$c-$arm.stderr"
  done
  if ! cmp -s "$out/batch$c-base.txt" "$out/batch$c-fork.txt"; then
    echo "difference c=$c; upstream/fork repeats"
    for arm in base fork; do
      if [[ $arm == base ]]; then build=/tmp/s4/build-base-int; else build=/tmp/s4/build-int; fi
      "$build/release/strim" checkbatchparity "$model" 512 "$c" 16 > "$out/batch$c-$arm-repeat.txt" 2> "$out/batch$c-$arm-repeat.stderr"
    done
  fi
done
for arm in base fork; do
  if [[ $arm == base ]]; then build=/tmp/s4/build-base-int; else build=/tmp/s4/build-int; fi
  echo "qualityverify widths=3,5,8 $arm"
  if [[ $arm == base ]]; then
    "$build/release/S4IntegrationBench" qualityverify "$model" /tmp/s4/fin/verify-base > "$out/verify-$arm.jsonl" 2> "$out/verify-$arm.stderr"
  else
    "$build/release/S4IntegrationBench" qualityverify "$model" /tmp/s4/fin/verify-fork /tmp/s4/fin/verify-base > "$out/verify-$arm.jsonl" 2> "$out/verify-$arm.stderr"
  fi
done
