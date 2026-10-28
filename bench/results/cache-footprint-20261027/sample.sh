#!/bin/bash
# usage: sample.sh PID PORT CELLFILE OUT.csv   (every 3 s until PID exits)
# cols: t,cell,swap_mb,footprint_mb,trie_mb,trie_nodes,mlx_active_mb,mlx_cache_mb,mlx_peak_mb
PID=$1; PORT=$2; CELL=$3; OUT=$4; T0=$(date +%s)
echo "t,cell,swap_mb,footprint_mb,trie_mb,trie_nodes,mlx_active_mb,mlx_cache_mb,mlx_peak_mb" > $OUT
while kill -0 $PID 2>/dev/null; do
  FP=$(footprint -p $PID -f bytes 2>/dev/null | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p' | head -1)
  SW=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  M=$(curl -s -m 2 http://127.0.0.1:$PORT/metrics | tr -d ' \n')
  g() { echo "$M" | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }
  mb() { echo $(( ${1:-0} / 1048576 )); }
  echo "$(( $(date +%s) - T0 )),$(cat $CELL 2>/dev/null),${SW%.*},$(mb ${FP:-0}),$(mb $(g trie_bytes)),$(g trie_nodes),$(mb $(g mlx_active_bytes)),$(mb $(g mlx_cache_bytes)),$(mb $(g mlx_peak_bytes))" >> $OUT
  sleep 3
done
