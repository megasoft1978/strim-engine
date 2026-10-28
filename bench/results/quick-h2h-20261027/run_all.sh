#!/bin/bash
# NOTE: the helper scripts used for this run (Python watchdog/agreement/aggregator) were removed from the repo; see summary.md for the method; rewrite with shell/Swift before rerunning
# ABAB-style: pass1 strim,rapid-mlx,mlx-vlm ; pass2 reversed. One engine at a time, GPU lock released between engines.
cd "$(dirname "$0")/../../.."
for ep in "strim 1" "rapid-mlx 1" "mlx-vlm 1" "mlx-vlm 2" "rapid-mlx 2" "strim 2"; do
  set -- $ep
  lockf -t 1800 -k /tmp/strim-bench.lock bench/results/quick-h2h-20261027/run_pass.sh $1 $2
  echo "== $1 pass$2 rc=$?"
  sleep 5
done
echo ALLDONE
