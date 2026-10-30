#!/bin/bash
set -euo pipefail
repo=/Users/user/Desktop/Freelance/strim-engine
out="$repo/bench/results/speed-s4-int-20261029/divergence/raw"
model="$HOME/.strim/models/qwen38-4bit"
head="$HOME/.strim/models/qwen38-mtp-4bit"
for arm in upstream fork; do
  if [[ "$arm" = upstream ]]; then binary=/tmp/s4/build-base-int/release/S4IntegrationBench; else binary=/tmp/s4/build-int/release/S4IntegrationBench; fi
  for rep in 1 2; do
    mkdir -p "/tmp/s4/divergence/state/$arm-$rep"
    printf '%s waiting lock %s %s\n' "$(date -u +%FT%TZ)" "$arm" "$rep"
    lockf -k /tmp/strim-bench.lock /usr/bin/env STRIM_CD_MODE=sampled STRIM_CD_MIX=mixed STRIM_CD_B=3 STRIM_CD_POLICIES=auto STRIM_CD_ROUNDS=1 STRIM_CD_TOKENS=160 "$binary" enginebench "$model" "$head" --only=concurrent-decode > "$out/$arm-$rep.txt" 2> "$out/$arm-$rep.stderr"
    printf '%s completed %s %s\n' "$(date -u +%FT%TZ)" "$arm" "$rep"
  done
done
