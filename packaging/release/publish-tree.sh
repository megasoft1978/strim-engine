#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then echo "usage: $0 <out_dir>" >&2; exit 2; fi
out=$1
if [[ -e "$out" ]]; then
  [[ -d "$out" ]] || { echo "output exists and is not a directory: $out" >&2; exit 1; }
  [[ -z "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit)" ]] || { echo "output directory must be empty: $out" >&2; exit 1; }
else
  mkdir -p "$out"
fi
root=$(git rev-parse --show-toplevel)
cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Materialize archive outside destination so paths are always clean.
git archive HEAD | tar -x -C "$tmp"
# No policy in the release guide/docs says design work or app fixture images stay private.
# Drop large files and benchmark scratch explicitly.
find "$tmp" -type f -size +20M -print -delete > "$tmp.dropped-large"
find "$tmp/bench/results" -type f \( -path '*/raw/*.bin' -o -path '*/raw/*.cell' -o -path '*/raw/*.load' -o -path '*/raw/*.mem.csv' \) -print -delete 2>/dev/null > "$tmp.dropped-scratch" || true
# Models are never published.
rm -rf "$tmp/models"
replaced=0
while IFS= read -r -d '' f; do
  if grep -IqE '/Users/user|-Users-user' "$f"; then
    n=$(grep -oE '/Users/user|-Users-user' "$f" | wc -l | tr -d ' ')
    sed -i '' -e 's|/Users/user|/Users/user|g' -e 's|-Users-user|-Users-user|g' "$f"
    replaced=$((replaced + n))
  fi
done < <(find "$tmp" -type f -print0)
# Private LAN addresses (benchmark server logs list the host's aliases).
while IFS= read -r -d '' f; do
  if grep -IqE '192\.168\.[0-9]+\.[0-9]+' "$f"; then
    sed -i '' -E 's/192\.168\.[0-9]+\.[0-9]+/192.168.x.x/g' "$f"
  fi
done < <(find "$tmp" -type f -print0)
mkdir -p "$out"
cp -R "$tmp"/. "$out"/
files=$(find "$out" -type f | wc -l | tr -d ' ')
dropped=$(($(wc -l < "$tmp.dropped-large") + $(wc -l < "$tmp.dropped-scratch")))
printf 'files=%s replaced=%s dropped=%s\n' "$files" "$replaced" "$dropped"
rm -f "$tmp.dropped-large" "$tmp.dropped-scratch"
