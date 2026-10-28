#!/bin/bash
# usage (repo root): run16.sh BIN CELLS "name|ENV=.. ENV=.." ...   one engine session per (round, arm), arms rotated each round.
# Output: raw/<name>/<round>/ ; every session under the GPU lock with pass16.sh (warm-up, 5 s memory watchdog).
R=bench/results/speed-w2-L16-20261028; BIN=$1; CELLS=$2; shift 2
ROUNDS=${ROUNDS:-3}; arms=("$@"); n=${#arms[@]}
for r in $(seq 1 $ROUNDS); do for k in $(seq 0 $((n-1))); do
  spec=${arms[$(( (k + r - 1) % n ))]}; name=${spec%%|*}; envs=${spec#*|}
  d=$R/raw/$name/r$r; rm -rf $d; mkdir -p $d
  lockf -t 14400 -k /tmp/strim-bench.lock env STRIM_BIN=$BIN $envs STRIM_TIMING=trace H2H_ROOT=$PWD bash $R/pass16.sh strim $r $CELLS $d > $d/driver.log 2>&1
  echo "$name r$r done $(date +%T)"
done; done; echo RUNDONE
