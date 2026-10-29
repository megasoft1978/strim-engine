#!/bin/bash
# samples every 30 s: epoch time, bytes on-disk of ~/.strim/models, pull cpu/rss, load
D=$HOME/.strim/models
while true; do
  b=$(du -sk "$D" 2>/dev/null | awk '{print $1*1024}')
  p=$(cat /Users/user/Desktop/Freelance/strim-engine/bench/results/install-e2e-20261028/pull.pid)
  ps_=$( [ -n "$p" ] && ps -o %cpu=,rss= -p $p | awk '{print $1","$2}')
  echo "$(date +%T),$b,${p:-none},${ps_:-},$(sysctl -n vm.loadavg | awk '{print $2}')"
  sleep 30
done
