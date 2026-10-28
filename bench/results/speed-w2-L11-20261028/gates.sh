#!/bin/bash
# usage: gates.sh BIN TAG   (each step under the GPU lock + memory watchdog; repo root = 3 dirs up)
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "$D/../../.." && pwd); BIN=$1; T=$2; O=$D/raw/gates-$T; mkdir -p "$O"
M=$R/models/qwen38-4bit; H=$R/models/qwen38-mtp-4bit; IDS=$(cat "$D/nat-ids.txt")
run() { n=$1; shift; lockf -t 3600 -k /tmp/strim-bench.lock "$D/wd_run.sh" "$O/$n.txt" "$BIN" "$@"; }
run gen16 gen $M 16
run benchspec0 benchspec $M $H 64 0 "$IDS"
run checkprefix4096 checkprefix $M 4096 3 $H
run checkprefix8192 checkprefix $M 8192 3 $H
run checkprefixcuts checkprefixcuts $M $H
run cbp-B4 checkbatchparity $M 512 4 32
run cbp-B8 checkbatchparity $M 512 8 32
run d1 benchspec $M $H 96 2 9707,1234,5678 3
run d4 benchbatch $M 512 24 4
