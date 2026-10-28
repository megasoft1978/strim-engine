#!/bin/bash
R=bench/results/conc-batch-20261027
run() { lockf -t 3600 -k /tmp/strim-bench.lock $R/run_cell.sh "$1" "$2" $R/cells_agree.sh; }
run ag-batch "STRIM_DECODE_POLICY=batch"
run ag-batchdecode "STRIM_DECODE_POLICY=batch STRIM_BATCH_DECODE=1"
run ag-batchmetal "STRIM_DECODE_POLICY=batch STRIM_GDN_BATCH_METAL=1"
echo AGREEDONE
