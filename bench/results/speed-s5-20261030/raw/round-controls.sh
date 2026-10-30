#!/bin/bash
set -euo pipefail
for depth in 2 4 7; do
  { date -u '+%FT%TZ'; uptime; sysctl -n vm.swapusage; } > /tmp/s5/round-depth$depth.start
  DA_CTX=16384 DA_PARTS=round DA_DEPTH=$depth nice -n 19 /tmp/s4/build-int/release/strim benchdecodeanatomy "$HOME/.strim/models/qwen38-4bit" "$HOME/.strim/models/qwen38-mtp-4bit" 15 > /tmp/s5/round-depth$depth.txt 2> /tmp/s5/round-depth$depth.stderr
  { date -u '+%FT%TZ'; uptime; sysctl -n vm.swapusage; } > /tmp/s5/round-depth$depth.end
done
