#!/bin/zsh
set -eu
for cycle in 1 2; do
  index=0
  for arm in 0 1 1 0; do
    index=$((index + 1))
    echo "waiting for GPU lock: fuse cycle $cycle block $index arm $arm"
    lockf -k /tmp/strim-bench.lock /tmp/s4/run-block.sh fuse "$arm" "${cycle}-${index}-${arm}"
  done
done
