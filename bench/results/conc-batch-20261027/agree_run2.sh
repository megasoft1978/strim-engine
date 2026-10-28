#!/bin/bash
R=bench/results/conc-batch-20261027
run() { lockf -t 3600 -k /tmp/strim-bench.lock $R/run_cell.sh "$1" "$2" $R/cells_agree2.sh; }
run ag2-batch "STRIM_DECODE_POLICY=batch"
run ag2-batchdecode "STRIM_DECODE_POLICY=batch STRIM_BATCH_DECODE=1"
echo AGREEDONE
