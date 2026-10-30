#!/bin/bash
set -euo pipefail
cd /Users/user/Desktop/Freelance/strim-engine
bin=/tmp/s5/build/release/strim
model=$HOME/.strim/models/qwen38-4bit
head=$HOME/.strim/models/qwen38-mtp-4bit
for arm in A B; do
  if [[ $arm == B ]]; then export STRIM_GDN_PRE_FUSE=1; else export STRIM_GDN_PRE_FUSE=0; fi
  mkdir -p /tmp/s5/quality/$arm
  { date -u '+%FT%TZ'; uptime; sysctl -n vm.swapusage; } > /tmp/s5/quality/$arm/start.txt
  lockf -k /tmp/strim-bench.lock "$bin" gen "$model" 16 > /tmp/s5/quality/$arm/gen16.txt 2> /tmp/s5/quality/$arm/gen16.stderr
  for ctx in 4096 8192; do
    lockf -k /tmp/strim-bench.lock "$bin" checkprefix "$model" "$ctx" 3 "$head" > /tmp/s5/quality/$arm/prefix$ctx.txt 2> /tmp/s5/quality/$arm/prefix$ctx.stderr
  done
  if [[ $arm == A ]]; then
    "$bin" benchsdpa s5quality "$model" /tmp/s5/quality/A/stress > /tmp/s5/quality/A/stress.jsonl 2> /tmp/s5/quality/A/stress.stderr
    "$bin" benchsdpa s5verify "$model" /tmp/s5/quality/A/verify > /tmp/s5/quality/A/verify.jsonl 2> /tmp/s5/quality/A/verify.stderr
  else
    "$bin" benchsdpa s5quality "$model" /tmp/s5/quality/B/stress /tmp/s5/quality/A/stress > /tmp/s5/quality/B/stress.jsonl 2> /tmp/s5/quality/B/stress.stderr
    "$bin" benchsdpa s5verify "$model" /tmp/s5/quality/B/verify /tmp/s5/quality/A/verify > /tmp/s5/quality/B/verify.jsonl 2> /tmp/s5/quality/B/verify.stderr
  fi
  { date -u '+%FT%TZ'; uptime; sysctl -n vm.swapusage; } > /tmp/s5/quality/$arm/end.txt
done
