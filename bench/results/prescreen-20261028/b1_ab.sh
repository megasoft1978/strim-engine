#!/bin/bash
# B1: ABAB, A = default scheduler (flag unset), B = STRIM_PREFILL_GAP_MS=100000 (unlimited burst). Run from repo root under the GPU lock.
export STRIM_BIN=/tmp/strim-build-ps/release/strim
O=bench/results/prescreen-20261028/raw/b1
mkdir -p $O
for r in 1 2; do
  unset STRIM_PREFILL_GAP_MS; bench/h2h/pass.sh strim $r w4s $O/armA_r$r
  STRIM_PREFILL_GAP_MS=100000 bench/h2h/pass.sh strim $r w4s $O/armB_r$r
done
for m in 523 530 523 530 523 530; do
  echo "benchprefill M=$m"; $STRIM_BIN benchprefill models/qwen38-4bit $m 5 2>&1 | tail -3
done > $O/benchprefill_rows.txt
