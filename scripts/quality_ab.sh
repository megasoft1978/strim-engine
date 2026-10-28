#!/usr/bin/env bash
# Same-token quality A/B between two Qwen3.8-27B checkpoints.
#   scripts/quality_ab.sh [modelA] [modelB]
# Teacher-forced NLL/PPL on a held-out code and prose slice, plus the external gen-16 check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
A="${1:-$ROOT/models/qwen38-4bit}"
B="${2:-$ROOT/models/qwen38-oq4e-mtp}"
BIN="$ROOT/.build/release/strim"

# First 512 tokens of each slice, with checkpoint A's tokenizer (strim tokenize).
"$BIN" tokenize --model "$A" --text "$ROOT/Sources/StrimCore/GDN.swift" --max 512 > /tmp/qab_code.txt
"$BIN" tokenize --model "$A" --text "$ROOT/docs/DEEPSEEK-V1-2026-10-26.md" --max 512 > /tmp/qab_prose.txt

for label in A B; do
  model=$A; [ "$label" = B ] && model=$B
  echo "== $label  $model"
  for p in code prose; do
    "$BIN" benchppl "$model" "/tmp/qab_${p}.txt" 512
  done
  "$BIN" gen "$model" 16 2>&1 | tail -2
done
