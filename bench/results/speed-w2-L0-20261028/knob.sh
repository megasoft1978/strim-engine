#!/bin/bash
# usage: knob.sh OUTDIR WORKLOAD(p4k|d1|d4) -- run under the bench lock. ABBA over knob settings, one process per setting
# (3 internal reps; prefill discards its first). Settings: d=default, oN=MLX_MAX_OPS_PER_BUFFER=N, mN=MLX_MAX_MB_PER_BUFFER=N.
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "$D/../../.." && pwd)
B=${BIN_B:-/tmp/strim-build-l0base/out/Products/Release/strim}   # unmodified HEAD build: knob test must not depend on OpTimer
OUT=$1; W=$2; mkdir -p "$OUT"
SEQ=${SEQ:-"d o50 o200 o500 m100 m400 m400 m100 o500 o200 o50 d"}
i=0
for s in $SEQ; do
  i=$((i+1)); envs=(); case $s in d) ;; o*) envs=(MLX_MAX_OPS_PER_BUFFER=${s#o});; m*) envs=(MLX_MAX_MB_PER_BUFFER=${s#m});; esac
  case $W in
    p4k) cmd=("$B" benchprefill "$R/models/qwen38-4bit" 4096 4 1024);;
    d1)  cmd=("$B" benchspec "$R/models/qwen38-4bit" "$R/models/qwen38-mtp-4bit" 96 2 9707,1234,5678 3);;
    d4)  cmd=("$B" benchbatch "$R/models/qwen38-4bit" 512 24 4);;
  esac
  echo "== $i $s load=$(uptime | sed 's/.*averages*: //')"
  env "${envs[@]}" "$D/wd_run.sh" "$OUT/${i}_$s.txt" "${cmd[@]}"
done
