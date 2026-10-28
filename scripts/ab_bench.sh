#!/usr/bin/env bash
# Reproducible A/B run for the Swift engine. Records the environment, then runs the
# matched instruments; raw output goes to bench/results/ab-<timestamp>/.
#
#   scripts/ab_bench.sh [model] [mtp-head]      # full run (~10-15 min)
#   QUICK=1 scripts/ab_bench.sh                 # skip corpus and service checks
#   HASH=0  scripts/ab_bench.sh                 # skip checkpoint SHA-256
#   REPS=3  scripts/ab_bench.sh                 # set speculative samples per prompt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-$ROOT/models/qwen38-4bit}"
HEAD="${2:-$ROOT/models/qwen38-mtp-4bit}"
BIN="$ROOT/.build/release/strim"
OUT="$ROOT/bench/results/ab-$(date +%Y%m%d-%H%M%S)"
REPS="${REPS:-5}"
mkdir -p "$OUT"

[ -x "$BIN" ] || { echo "build first: swift build -c release --disable-sandbox" >&2; exit 1; }

# One model resident; a loaded backend inflates every number (documented 3x).
LOADED=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E '127\.0\.0\.1:8203' || true)
if [ -n "$LOADED" ]; then
  echo "WARNING: a strim serve endpoint is listening on :8203; numbers will be inflated." >&2
  echo "$LOADED" >&2
fi

{
  echo "# environment"
  date -Iseconds
  sw_vers
  sysctl -n machdep.cpu.brand_string hw.memsize
  uptime
  pmset -g therm 2>/dev/null | head -5 || true
  echo "# git"; git -C "$ROOT" rev-parse HEAD; git -C "$ROOT" status --short
  echo "# swift"; swift --version 2>&1 | head -2
  echo "# mlx-swift"; grep -A3 '"mlx-swift"' "$ROOT/Package.resolved" | head -6
  echo "# rapid-mlx"; rapid-mlx --version 2>&1 | head -1
  echo "# listeners"; lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E ':(8200|8201|8202)' || true
  if [ "${HASH:-1}" != "0" ]; then
    echo "# model hashes"
    for path in "$MODEL/config.json" "$MODEL/model.safetensors.index.json" \
      "$MODEL/tokenizer.json" "$MODEL"/*.safetensors "$HEAD/config.json" \
      "$HEAD/model.safetensors.index.json" "$HEAD"/*.safetensors; do
      if [ -f "$path" ]; then shasum -a 256 "$path"; fi
    done
  fi
} > "$OUT/env.txt" 2>&1

# Prompt ids from bench/ab_prompts.json, tokenized with the model tokenizer (strim tokenize).
command -v jq >/dev/null || { echo "jq is required to read bench/ab_prompts.json" >&2; exit 1; }
: > "$OUT/prompts.txt"
for name in $(jq -r 'keys[]' "$ROOT/bench/ab_prompts.json"); do
  jq -j --arg n "$name" '.[$n]' "$ROOT/bench/ab_prompts.json" \
    | "$BIN" tokenize --model "$MODEL" --text - > "/tmp/ab_${name}_ids.txt"
  n=$(jq -j --arg n "$name" '.[$n]' "$ROOT/bench/ab_prompts.json" \
    | "$BIN" tokenize --model "$MODEL" --text - --count)
  echo "$name $n" >> "$OUT/prompts.txt"
done

run() { echo "=== $*" | tee -a "$OUT/raw.txt"; "$@" 2>&1 | tee -a "$OUT/raw.txt"; }
PARITY_FAIL=0
run_spec() {
  echo "=== $*" | tee -a "$OUT/raw.txt"
  local status=0
  if "$@" 2>&1 | tee -a "$OUT/raw.txt"; then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 2 ]; then
    PARITY_FAIL=1
    return 0
  fi
  return "$status"
}

run "$BIN" benchprefill "$MODEL" 1024 3
run "$BIN" benchprefill "$MODEL" 4096 3
NAT=$(cat /tmp/ab_natural_ids.txt)
run_spec "$BIN" benchspec "$MODEL" "$HEAD" 64 0 "$NAT" "$REPS"
run_spec "$BIN" benchspec "$MODEL" "$HEAD" 64 2 "$NAT" "$REPS"
run "$BIN" benchpathspec "$MODEL" "$HEAD" 48 2 "$NAT" 5

echo "=== independent gen16 reference" | tee -a "$OUT/raw.txt"
"$BIN" gen "$MODEL" 16 2>&1 | tee "$OUT/gen16-swift.txt" | tee -a "$OUT/raw.txt"
# independent Python MLX reference removed 2026-10-27; the serial (non-speculative) path is the in-repo reference.
echo "gen16 reference skipped (python reference removed)" | tee "$OUT/gen16-reference.txt" | tee -a "$OUT/raw.txt"
SWIFT_IDS=$(sed -n 's/^ids: //p' "$OUT/gen16-swift.txt" | tail -n 1)
REF_IDS=$(sed -n 's/^ids: //p' "$OUT/gen16-reference.txt" | tail -n 1)
if [ -z "$SWIFT_IDS" ] || [ -z "$REF_IDS" ] || [ "$SWIFT_IDS" != "$REF_IDS" ]; then
  echo "gen16 reference mismatch; see $OUT/gen16-swift.txt and gen16-reference.txt" \
    | tee -a "$OUT/raw.txt"
  exit 1
fi
echo "gen16 reference: EXACT" | tee -a "$OUT/raw.txt"

if [ "${QUICK:-0}" != "1" ]; then
  for p in code sql rust csvpy prose math json; do
    run_spec "$BIN" benchspec "$MODEL" "$HEAD" 64 2 "$(cat /tmp/ab_${p}_ids.txt)" "$REPS"
  done
  run "$BIN" benchpassS "$MODEL" 8
  run swift test --disable-sandbox
fi

echo "raw logs: $OUT" | tee -a "$OUT/raw.txt"
if [ "$PARITY_FAIL" -ne 0 ]; then
  echo "correctness gate failed; mismatches are recorded in $OUT/raw.txt" | tee -a "$OUT/raw.txt"
  exit 1
fi
