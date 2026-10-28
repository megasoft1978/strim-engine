#!/bin/bash
# usage (repo root): p1_gates.sh   -- exactness references + 8x64 agreement, A (core 0.32.3) vs B (core v0.32.4 + JIT dsplit fix)
D=$PWD/bench/results/prescreen2-20261028; M=$PWD/models/qwen38-4bit; H=$PWD/models/qwen38-mtp-4bit
IDS=$(cat $PWD/bench/results/speed-w2-L5-20261028/nat-ids.txt)
run() { n=$1; shift; lockf -t 3600 -k /tmp/strim-bench.lock $D/wd_run.sh "$D/raw/$n.txt" "$@" >> $D/raw/p1_gates.log; }
rm -rf /tmp/ps2-agree-A /tmp/ps2-agree-B
for X in A B; do
  BIN=/tmp/ps2-bins/$X/strim
  run gates-gen16-$X $BIN gen $M 16
  run gates-benchspec0-$X $BIN benchspec $M $H 64 0 "$IDS"
  run gates-checkprefix4096-$X $BIN checkprefix $M 4096 3 $H
done
run agree-A /tmp/ps2-bins/A/strim benchprescreen2 agree $M $D/ids12000.txt /tmp/ps2-agree-A
run agree-B /tmp/ps2-bins/B/strim benchprescreen2 agree $M $D/ids12000.txt /tmp/ps2-agree-B /tmp/ps2-agree-A
