#!/bin/bash
# usage (repo root): p1_perf.sh ROUNDS   -- ABAB x ROUNDS of A (HEAD, core 0.32.3) vs B (mlx-swift branch mlx-0.32.4, core v0.32.4)
# A=/tmp/ps2-bins/A/strim  B=/tmp/ps2-bins/B/strim; every step under the GPU lock + 5 s memory watchdog.
D=$PWD/bench/results/prescreen2-20261028; M=$PWD/models/qwen38-4bit; H=$PWD/models/qwen38-mtp-4bit; IDS=$(cat $D/ids4096.txt)
run() { n=$1; shift; lockf -t 3600 -k /tmp/strim-bench.lock $D/wd_run.sh "$D/raw/$n.txt" "$@" >> $D/raw/p1_perf.log; }
for r in $(seq 1 $1); do
  for X in A B; do
    BIN=/tmp/ps2-bins/$X/strim
    run pf16k-$X-r$r $BIN benchprefill $M 16384 2 1024
    run pf32k-$X-r$r $BIN benchprefill $M 32768 2 1024
    run spec4k-$X-r$r $BIN benchspec $M $H 96 2 "$IDS" 2
    run bs4-$X-r$r $BIN benchbatchsplit $M 1024 4
    run bs8-$X-r$r $BIN benchbatchsplit $M 1024 8
  done
done
