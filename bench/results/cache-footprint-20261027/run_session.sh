#!/bin/bash
# usage (repo root): run_session.sh LABEL BIN [ENV=VAL ...]  -> waits for the host lock to be free, then holds the GPU lock for the session
LABEL=$1; BIN=$2; shift 2
while true; do
  while [ -n "$(lsof -t $HOME/.strim/host.lock 2>/dev/null)" ]; do sleep 15; done
  lockf -t 30 -k /tmp/strim-bench.lock bench/results/cache-footprint-20261027/one_run.sh bench/results/cache-footprint-20261027/$LABEL $BIN 8215 bench/results/cache-footprint-20261027/cmds_session.sh "$@"
  [ $? -ne 75 ] && break; sleep 5
done
