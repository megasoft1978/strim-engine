#!/bin/bash
# usage: sweep.sh OUT.txt NTOK CHUNK SWEEP_REPS NAMES(comma list or "")   (run under the bench lock)
# Fences one region name at a time (STRIM_OPTIME_SWEEP) with the MTP head emulation on.
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "$D/../../.." && pwd)
B=${BIN_B:-/tmp/strim-build-l0/out/Products/Release/strim}
STRIM_OPTIME=1 STRIM_OPTIME_MTP="$R/models/qwen38-mtp-4bit" STRIM_OPTIME_SWEEP=$4 STRIM_OPTIME_SWEEP_NAMES="$5" \
  "$D/wd_run.sh" "$1" "$B" benchprefill "$R/models/qwen38-4bit" "$2" 2 "$3"
