# Long-session cells (sourced by one_run.sh): warmup, cold 4K/16K x2, replay, c4, W5 x2, replay again.
cell() { local n=$1; shift; echo $n > $D/cell; "$@" > $D/$n.log 2>&1; echo idle > $D/cell
  curl -s -m 2 $URL/metrics | tr -d ' \n' > $D/metrics_$n.json; echo >> $D/metrics_$n.json; sleep 4; }
SB="$BIN bench http scoreboard --arm strim=$URL,$MODEL --reps 2 --timeout 600"
RP="$BIN bench http replay --fixture bench/results/final-20261026/synthetic-8turn.json --arm strim=$URL,$MODEL,cache=on --server-log strim=$D/server.log --reps 1 --max-tokens 48"
cell warmup $BIN bench http scoreboard --arm strim=$URL,$MODEL --workloads W3 --w3-sizes 4096 --w3-gen 8 --reps 1 --out-dir $D/warmup
cell replay1 $RP --out-dir $D/replay1
cell w3 $SB --workloads W3 --w3-sizes 4096,16384 --w3-gen 64 --out-dir $D/w3
cell w4c4 $SB --workloads W4 --conc 4 --w4-size 4096 --w4-gen 64 --out-dir $D/w4c4
cell w5 $SB --workloads W5 --out-dir $D/w5
cell replay2 $RP --out-dir $D/replay2
