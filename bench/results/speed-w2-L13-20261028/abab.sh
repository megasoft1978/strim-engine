#!/bin/bash
# usage (repo root): abab.sh NAME CELLS REPS "BIN_A|ENV_A" "BIN_B|ENV_B"
# ABAB... x REPS; each session = pass13.sh (own engine, warm-up, CELLS) under the GPU lock. Own HOME not needed (host lock is per user).
R=bench/results/speed-w2-L13-20261028; N=$1; CELLS=$2; REPS=$3; A=$4; B=$5
for i in $(seq 1 $REPS); do for arm in A B; do
  spec=$A; [ $arm = B ] && spec=$B; bin=${spec%%|*}; envs=${spec#*|}
  d=$R/raw/$N/${i}_$arm; rm -rf $d; mkdir -p $d
  lockf -t 14400 -k /tmp/strim-bench.lock env STRIM_BIN=$bin $envs bash $R/pass13.sh strim 1 $CELLS $d > $d/driver.log 2>&1
  echo "$N $i $arm done"
done; done
echo ABABDONE
