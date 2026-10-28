#!/bin/bash
# usage (repo root): ab_replay.sh OUTDIR BIN_A BIN_B  -> order A B A B; each run holds the GPU lock for its whole server lifetime.
# Waits (without holding the lock) until no other `strim serve` host is running.
OUT=$1; A=$2; B=$3; i=0
for BIN in $A $B $A $B; do
  i=$((i+1)); N=$( [ $BIN = $A ] && echo A || echo B )
  while true; do
    while [ -n "$(lsof -t $HOME/.strim/host.lock 2>/dev/null)" ]; do sleep 15; done
    lockf -t 30 -k /tmp/strim-bench.lock bench/results/cache-footprint-20261027/one_run.sh $OUT/run$i-$N $BIN 8214 bench/results/cache-footprint-20261027/cmds_replay.sh; [ $? -ne 75 ] && break; sleep 5
  done
done
