#!/bin/bash
# Check repository files, including untracked non-ignored files, without traversing
# ignored build products, caches, vendor checkouts or benchmark run artifacts.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
bad=0
while IFS= read -r -d '' path; do
  case "$path" in
    envs/*.py) continue ;;
    bench/agenttasks*/tasks/*/*.py) continue ;;
    *.py) printf 'Python outside envs or task fixtures: %s\n' "$path" >&2; bad=1 ;;
  esac
done < <(git ls-files -co --exclude-standard -z)
exit "$bad"
