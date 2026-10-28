#!/bin/bash
# usage (repo root): srv_abab.sh SEQ(e.g. ABABAB) CELLS   -- A = HEAD build (BIN_A), B = new build (BIN_B, pipelining default).
# One engine session per cell group under the GPU lock (bench/h2h/pass.sh: warm-up, 5 s memory watchdog), env knobs unset.
D=bench/results/speed-w2-L10-20261028
A=${BIN_A:-/tmp/strim-build-l9/out/Products/Release/strim}; B=${BIN_B:-/tmp/strim-build-l10/out/Products/Release/strim}
i=0
for c in $(echo "$1" | sed 's/./& /g'); do
  i=$((i+1)); bin=$A; [ "$c" = B ] && bin=$B
  echo "== $i $c"
  lockf -t 3600 -k /tmp/strim-bench.lock env STRIM_BIN=$bin H2H_ROOT=$PWD bench/h2h/pass.sh strim 1 "$2" "$D/raw/srv-$i-$c"
done
