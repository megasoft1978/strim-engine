#!/bin/bash
set -euo pipefail
cd /Users/user/Desktop/Freelance/strim-engine
export STRIM_DECODE_POLICY=roundrobin
unset STRIM_PREFIX_DISK STRIM_PARITY_IDS STRIM_GDN_TENSOR STRIM_CONV_TENSOR STRIM_MTP_DEPTH STRIM_MTP_FIXED STRIM_SPEC_DEVICEFEED STRIM_MTP_WINDOW
index=0
for arm in A B B A A B B A; do
  index=$((index+1))
  export STRIM_GDN_PRE_FUSE=$([[ $arm == B ]] && echo 1 || echo 0)
  out=/tmp/s5/abba/$index-$arm
  mkdir -p "$out"
  for ctx in 4096 16384 32768; do
    for c in 1 4; do
      { date -u '+%FT%TZ'; uptime; sysctl -n vm.swapusage; } > "$out/ctx$ctx-c$c.start"
      /tmp/s5/build/release/strim benchsdpa s5decode "$HOME/.strim/models/qwen38-4bit" "$HOME/.strim/models/qwen38-mtp-4bit" "$ctx" "$c" 3 64 > "$out/ctx$ctx-c$c.jsonl" 2> "$out/ctx$ctx-c$c.stderr"
      { date -u '+%FT%TZ'; uptime; sysctl -n vm.swapusage; } > "$out/ctx$ctx-c$c.end"
    done
  done
done
