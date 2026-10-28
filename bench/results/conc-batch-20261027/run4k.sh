#!/bin/bash
R=bench/results/conc-batch-20261027
run() { lockf -t 3600 -k /tmp/strim-bench.lock $R/run_cell.sh "$1" "$2" $R/cells_4k.sh; }
run k4-batch "STRIM_DECODE_POLICY=batch"
run k4-batchdecode "STRIM_DECODE_POLICY=batch STRIM_BATCH_DECODE=1"
run k4-auto ""
echo K4DONE
