#!/bin/bash
# Realistic agent prompts: 8 distinct repo source heads + a coding question -> JSON array of strings on stdout.
# usage: agent-prompts.sh [REV=HEAD] [LINES=220]. Deterministic for a given revision (files are picked by path order).
REV=${1:-HEAD}; N=${2:-220}
files=$(git ls-tree -r -l "$REV" -- Sources | awk '$5 ~ /\.swift$/ && $4 >= 9000 {print $5}' | sort | awk 'NR%11==1' | head -8)
for f in $files; do
  { printf 'You are a coding agent working in a Swift repository. The user opened %s. Its first %s lines are below.\n\n```swift\n' "$f" "$N"
    git show "$REV:$f" | head -n "$N"
    printf '\n```\n\nQuestion: what is the most likely correctness or performance risk in this file, and what minimal change would you make? Answer in a short list.\n'; } | jq -Rs .
done | jq -s .
