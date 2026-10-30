#!/bin/zsh
set -eu
for cycle in 1 2; do
  index=0
  for arm in base cap8 cap8 base; do
    index=$((index + 1))
    echo "waiting for GPU lock: cap cycle $cycle block $index arm $arm"
    lockf -k /tmp/strim-bench.lock /tmp/s4/run-block.sh cap "$arm" "${cycle}-${index}-${arm}"
  done
done
