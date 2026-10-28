#!/bin/bash
# Runs all B x ctx combinations of benchbatchsplit serially under the shared GPU lock.
cd /Users/user/Desktop/Freelance/strim-p3a || exit 1
LOG=/Users/user/Desktop/Freelance/strim-p3a/bench/results/batchsplit-20261026/log
: > "$LOG"
for ctx in 1024 4096; do
  for B in 1 2 4; do
    echo "### ctx=$ctx B=$B" >> "$LOG"
    lockf -k /tmp/strim-bench.lock ./.build/release/strim benchbatchsplit /Users/user/Desktop/Freelance/strim-p3a/models/qwen38-4bit "$ctx" "$B" >> "$LOG" 2>&1
    echo "exit=$?" >> "$LOG"
  done
done
echo "ALL DONE" >> "$LOG"
