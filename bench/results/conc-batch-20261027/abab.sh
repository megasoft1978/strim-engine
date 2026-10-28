#!/bin/bash
# ABAB: A = pre-change HEAD build, B = merged build (STRIM_BATCH_DECODE default on). Default policy, memory watchdog on.
R=bench/results/conc-batch-20261027
run() { STRIM_BIN=$3 lockf -t 3600 -k /tmp/strim-bench.lock $R/run_cell.sh "$1" "$2" $R/cells_abab.sh; }
OLD=/tmp/strim-build-conc3/release/strim; NEW=/tmp/strim-build-conc2/release/strim
run ab-old-p1 "" $OLD; run ab-new-p1 "" $NEW; run ab-old-p2 "" $OLD; run ab-new-p2 "" $NEW
echo ABABDONE
