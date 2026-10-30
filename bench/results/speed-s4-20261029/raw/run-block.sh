#!/bin/zsh
set -eu
part=$1
arm=$2
block=$3
out=/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-20261029/raw
model=$HOME/.strim/models/qwen38-4bit
mkdir -p "$out/$part/$block"
{
  date -u +%FT%TZ
  uptime
  sysctl -n vm.swapusage
} > "$out/$part/$block/system.txt"
if [[ $part == cap ]]; then
  binary=/tmp/s4/bin/$arm/strim
  for c in 1 4 8; do
    "$binary" s4 decode "$model" "$c" 3 64 > "$out/$part/$block/c$c.jsonl" 2> "$out/$part/$block/c$c.stderr"
  done
  "$binary" s4 verify "$model" 3 12 > "$out/$part/$block/verify.jsonl" 2> "$out/$part/$block/verify.stderr"
else
  binary=/tmp/s4/bin/base/strim
  for n in 4096 16384; do
    STRIM_S4_FUSE=$arm "$binary" s4 prefill "$model" "$n" 3 > "$out/$part/$block/n$n.jsonl" 2> "$out/$part/$block/n$n.stderr"
  done
fi
{
  date -u +%FT%TZ
  uptime
  sysctl -n vm.swapusage
} >> "$out/$part/$block/system.txt"
echo "completed $part $arm $block"
