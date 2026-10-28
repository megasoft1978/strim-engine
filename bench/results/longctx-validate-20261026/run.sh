#!/bin/bash
# End-to-end long-context check of the blocked GDN prefill kernel on natural prompts.
# Usage: run.sh <ids_dir> <out_dir>. Every GPU run is serialized through the shared lock.
set -u
REPO=/Users/user/Desktop/Freelance/strim-engine
BIN=$REPO/.build/release/strim
IDS=$1
OUT=$2
cd "$REPO" || exit 1
mkdir -p "$OUT"
LOCK=/tmp/strim-bench.lock
PROMPTS="p4k_a p4k_b p4k_c p4k_d p4k_e p1k_a p1k_b p1k_c"
for P in $PROMPTS; do
  ID=$(cat "$IDS/$P.ids")
  # default = blocked kernel (S>=512), compiled elementwise
  lockf -k $LOCK $BIN logithash models/qwen38-4bit 16 "$ID" > "$OUT/$P.default1.log" 2>&1
  lockf -k $LOCK $BIN logithash models/qwen38-4bit 16 "$ID" > "$OUT/$P.default2.log" 2>&1
  # serial fused kernel (blocked disabled, S<=metalMaxS)
  STRIM_GDN_BLOCKED=0 lockf -k $LOCK $BIN logithash models/qwen38-4bit 16 "$ID" > "$OUT/$P.serial.log" 2>&1
  # tensor recurrence for prefill only (S>8 falls to MLX-op TF32 path; decode S<=8 keeps fused kernel)
  STRIM_GDN_METAL_MAX_S=8 lockf -k $LOCK $BIN logithash models/qwen38-4bit 16 "$ID" > "$OUT/$P.tensor.log" 2>&1
  echo "done $P"
done
for P in p4k_a p4k_c; do
  ID=$(cat "$IDS/$P.ids")
  lockf -k $LOCK $BIN benchspec models/qwen38-4bit models/qwen38-mtp-4bit 32 2 "$ID" 1 > "$OUT/$P.spec.log" 2>&1
  echo "spec $P exit=$?"
done
echo ALLDONE
