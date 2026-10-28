#!/bin/bash
# usage: sweep.sh   (repo root) runs the policy variants, each under the GPU lock
R=bench/results/conc-batch-20261027
run() { lockf -t 3600 -k /tmp/strim-bench.lock $R/run_cell.sh "$1" "$2" $R/cells_sweep.sh; }
run sw-auto  "STRIM_ENGINE_TRACE=1"
run sw-batch "STRIM_ENGINE_TRACE=1 STRIM_DECODE_POLICY=batch"
run sw-rr    "STRIM_ENGINE_TRACE=1 STRIM_DECODE_POLICY=roundrobin"
run sw-batchmetal "STRIM_ENGINE_TRACE=1 STRIM_DECODE_POLICY=batch STRIM_GDN_BATCH_METAL=1"
run sw-batchdecode "STRIM_ENGINE_TRACE=1 STRIM_DECODE_POLICY=batch STRIM_BATCH_DECODE=1"
echo SWEEPDONE
