#!/bin/bash
# remaining gates after an environmental watchdog abort (swap growth caused by other workers)
D=$(cd "$(dirname "$0")" && pwd); R=$(cd "$D/../../.." && pwd); BIN=$1; O=$D/raw/gates-new
M=$R/models/qwen38-4bit; H=$R/models/qwen38-mtp-4bit
run() { n=$1; shift; lockf -t 3600 -k /tmp/strim-bench.lock "$D/wd_run.sh" "$O/$n.txt" "$BIN" "$@"; }
run checkprefix8192 checkprefix $M 8192 3 $H
run checkprefixcuts checkprefixcuts $M $H
run cbp-B4 checkbatchparity $M 512 4 32
run cbp-B8 checkbatchparity $M 512 8 32
