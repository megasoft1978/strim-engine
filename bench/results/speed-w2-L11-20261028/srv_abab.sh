#!/bin/bash
# usage (repo root): srv_abab.sh SEQ(e.g. ABABAB) CELLS   -- same binary; A = STRIM_WIRED_LIMIT_GB unset, B = STRIM_WIRED_LIMIT_GB=${WL:-40}.
D=bench/results/speed-w2-L11-20261028
BIN=${BIN:-/tmp/strim-build-l11/out/Products/Release/strim}
i=0
for c in $(echo "$1" | sed 's/./& /g'); do
  i=$((i+1)); echo "== $i $c $(date +%T)"
  if [ "$c" = B ]; then W="STRIM_WIRED_LIMIT_GB=${WL:-40}"; else W="STRIM_WIRED_LIMIT_GB="; fi
  lockf -t 3600 -k /tmp/strim-bench.lock env $W STRIM_BIN=$BIN H2H_ROOT=$PWD bench/h2h/pass.sh strim 1 "$2" "$D/raw/srv-$i-$c"
done
