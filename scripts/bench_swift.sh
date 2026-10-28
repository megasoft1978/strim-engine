#!/usr/bin/env bash
# Reproduce the Swift decode numbers in docs/SWIFT-PERF.md.
#
#   scripts/bench_swift.sh [model] [mtp-head]
#
# Prints a markdown table: pass time at S=1, component split, and speculative
# decode at depths 0-3 (tokens/pass, acceptance, tok/s) with greedy parity.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${1:-models/qwen38-4bit}"
HEAD="${2:-models/qwen38-mtp-4bit}"
BIN="$ROOT/.build/release/strim"

[ -x "$BIN" ] || { echo "build first: swift build -c release --disable-sandbox" >&2; exit 1; }

# A loaded product backend (A3B is ~19 GB) starves the GPU and inflates every number:
# a 38 ms pass measured 214 ms with strim-speed resident. Warn loudly.
LOADED=$(curl -s --max-time 2 http://127.0.0.1:8203/v1/strim/status 2>/dev/null \
  | tr '{' '\n' | grep '"loaded": *true' | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | paste -sd, - 2>/dev/null || true)
if [ -n "${LOADED:-}" ]; then
  echo "WARNING: strim serve has ${LOADED} loaded; numbers below will be inflated." >&2
  echo "         stop it first: lsof -tiTCP:8203 -sTCP:LISTEN | xargs kill" >&2
  echo
fi

PROMPT_TEXT="The key to fast local inference is reading each weight exactly once per token. A transformer decoder is memory bound at batch size one, so the design question is not how many floating point operations the GPU can issue, but how well the kernel streams quantized weights from memory while keeping every core busy."
PROMPT_IDS=$(printf '%s' "$PROMPT_TEXT" | "$BIN" tokenize --model "$ROOT/models/qwen38-4bit" --text -)

echo "## Pass"
"$BIN" benchpass "$MODEL" 20 | head -1
echo
echo "## Components (S=1)"
"$BIN" benchsplit "$MODEL" 10 | head -4
echo
echo "## Speculative decode (natural prompt, 48 new tokens)"
printf "| depth | tok/pass | accept | ms/pass | tok/s | parity |\n|---:|---:|---:|---:|---:|---|\n"
for d in 0 1 2 3; do
  out=$("$BIN" benchspec "$MODEL" "$HEAD" 48 "$d" "$PROMPT_IDS" 2>&1)
  stats=$(echo "$out" | grep '^spec:')
  parity=$(echo "$out" | grep '^parity:' | sed 's/parity: //')
  tp=$(echo "$stats" | sed -n 's/.*  \([0-9.]*\) tok\/pass.*/\1/p')
  acc=$(echo "$stats" | sed -n 's/.*accept \([0-9]*\)%.*/\1%/p')
  ms=$(echo "$stats" | sed -n 's/.* \([0-9.]*\) ms\/pass.*/\1/p')
  ts=$(echo "$stats" | sed -n 's/.* \([0-9.]*\) tok\/s.*/\1/p')
  printf "| %s | %s | %s | %s | %s | %s |\n" "$d" "$tp" "$acc" "$ms" "$ts" "$parity"
done
