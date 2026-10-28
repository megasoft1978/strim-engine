#!/bin/bash
# B5: quant ladder, run from repo root under the GPU lock. ref = qwen38-8bit; candidates 4bit, oq4e-mtp, 6bit.
B=/tmp/strim-build-ps/release/strim; O=bench/results/prescreen-20261028/raw/b5
$B quanteval ref models/qwen38-8bit $O/ref8.bin 2048 code=$O/code.ids prose=$O/prose.ids > $O/ref8.txt 2>&1
for m in qwen38-4bit qwen38-oq4e-mtp qwen38-6bit; do
  echo "=== cmp $m"; $B quanteval cmp models/$m $O/ref8.bin 2>&1
done > $O/cmp.txt
P4=$(cat $O/p4k.ids)
for m in qwen38-8bit:qwen38-mtp-8bit qwen38-4bit:qwen38-mtp-4bit qwen38-oq4e-mtp:qwen38-oq4e-mtp qwen38-6bit:qwen38-mtp-4bit; do
  M=${m%%:*}; H=${m##*:}
  { echo "=== speed $M head $H"; $B benchprefill models/$M 1024 3 2>&1 | tail -2
    $B benchspec models/$M models/$H 64 0 "$P4" 2 2>&1 | /usr/bin/grep -E "^rep|parity" | cut -c1-200
    $B benchspec models/$M models/$H 64 2 "$P4" 2 2>&1 | /usr/bin/grep -E "^rep|parity" | cut -c1-200; } >> $O/speed.txt
done
