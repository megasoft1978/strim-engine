#!/bin/bash
# Head-to-head driver. usage (repo root, FOREGROUND shell): run.sh OUTDIR [PASS=1,2] [ENGINES=strim,rapid-mlx,mlx-vlm,mlx-lm,omlx] [GROUPS=g1,g2,g3]
# Pass 1 runs the engines in the given order, pass 2 in reverse (ABBA). One engine at a time under the GPU lock
# (lockf /tmp/strim-bench.lock). Cell groups keep every engine session short: g1=agree,w3,w3_32k g2=w4,w4s,w6 g3=w5,replay.
# Quiet gate samples: H2H_GATE_N_FIRST (4 x 30 s) before the first group of an engine session, H2H_GATE_N_LATER (2) before the others (H2H_GATE_N overrides both).
# H2H_COOLDOWN s (60) idle between two engine sessions (not between the groups of one engine, H2H_GROUP_GAP 5 s there).
# H2H_DRYRUN=1: stub servers instead of engines, private lock, no cooldown (see RUNBOOK.md).
OUT=${1:?outdir}; PASSES=${2:-1,2}; ENGS=${3:-strim,rapid-mlx,mlx-vlm,mlx-lm,omlx}; GRPS=${4:-g1,g2,g3}
H=$(cd "$(dirname "$0")" && pwd); LOCK=${STRIM_BENCH_LOCK:-/tmp/strim-bench.lock}
COOL=${H2H_COOLDOWN:-60}; GAP=${H2H_GROUP_GAP:-5}
if [ "${H2H_DRYRUN:-0}" = 1 ]; then COOL=${H2H_COOLDOWN:-0}; GAP=${H2H_GROUP_GAP:-0}; LOCK=${STRIM_BENCH_LOCK:-${H2H_SCRATCH:-/private/tmp/h2h-scratch}/dryrun.lock}; mkdir -p "$(dirname "$LOCK")"; fi
group_cells() { case $1 in g1) echo agree,w3,w3_32k;; g2) echo w4,w4s,w6;; g3) echo w5,replay;; *) echo "$1";; esac; }
mkdir -p "$OUT"; echo "order: passes=$PASSES engines=$ENGS groups=$GRPS cooldown=${COOL}s dryrun=${H2H_DRYRUN:-0} start=$(date +%FT%T)" >> "$OUT/run-order.txt"
first=1
for P in ${PASSES//,/ }; do
  list=${ENGS//,/ }; [ $((P % 2)) = 0 ] && list=$(echo $list | tr ' ' '\n' | sed '1!G;h;$!d' | tr '\n' ' ')
  echo "pass $P order: $list" | tee -a "$OUT/run-order.txt"
  for E in $list; do
    [ $first = 0 ] && [ "$COOL" -gt 0 ] && { echo "== cooldown ${COOL}s"; sleep "$COOL"; }; first=0
    gi=0
    for G in ${GRPS//,/ }; do
      gi=$((gi+1)); if [ $gi = 1 ]; then GN=${H2H_GATE_N:-${H2H_GATE_N_FIRST:-4}}; else GN=${H2H_GATE_N:-${H2H_GATE_N_LATER:-2}}; fi
      H2H_GATE_N=$GN lockf -t 3600 -k "$LOCK" "$H/pass.sh" "$E" "$P" "$(group_cells "$G")" "$OUT"; echo "== $E pass$P $G rc=$?"; sleep "$GAP"
    done
  done
done
echo "done $(date +%FT%T)" >> "$OUT/run-order.txt"
