#!/bin/bash
# Head-to-head driver. usage (repo root, FOREGROUND shell): run.sh OUTDIR [PASS=1,2] [ENGINES=strim,rapid-mlx,mlx-vlm] [GROUPS=g1,g2,g3]
# Pass 1 runs the engines in the given order, pass 2 in reverse (ABBA). One engine at a time under the GPU lock
# (lockf /tmp/strim-bench.lock). Cell groups keep every engine session short: g1=agree,w3,w3_32k g2=w4,w4s,w6 g3=w5,replay.
OUT=${1:?outdir}; PASSES=${2:-1,2}; ENGS=${3:-strim,rapid-mlx,mlx-vlm}; GRPS=${4:-g1,g2,g3}
H=$(cd "$(dirname "$0")" && pwd); LOCK=${STRIM_BENCH_LOCK:-/tmp/strim-bench.lock}
group_cells() { case $1 in g1) echo agree,w3,w3_32k;; g2) echo w4,w4s,w6;; g3) echo w5,replay;; *) echo "$1";; esac; }
for P in ${PASSES//,/ }; do
  list=${ENGS//,/ }; [ $((P % 2)) = 0 ] && list=$(echo $list | tr ' ' '\n' | sed '1!G;h;$!d' | tr '\n' ' ')
  for E in $list; do for G in ${GRPS//,/ }; do
    lockf -t 3600 -k "$LOCK" "$H/pass.sh" "$E" "$P" "$(group_cells "$G")" "$OUT"; echo "== $E pass$P $G rc=$?"; sleep 5
  done; done
done
