#!/bin/bash
# usage (repo root): ab.sh OUTDIR BIN_A BIN_B CELLS [PASSES=3]  -> order A B A B A B, each session under the GPU lock.
OUT=$1; A=$2; B=$3; CELLS=$4; N=${5:-3}
R=$(cd "$(dirname "$0")" && pwd)
for p in $(seq 1 $N); do for arm in A B; do
  BIN=$([ $arm = A ] && echo "$A" || echo "$B")
  STRIM_BIN=$BIN lockf -t 7200 -k /tmp/strim-bench.lock "$R/pass.sh" strim $p "$CELLS" "$OUT/arm$arm"
done; done
