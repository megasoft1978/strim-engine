cell() { local n=$1; shift; echo $n > $D/cell; "$@" > $D/$n.log 2>&1; echo idle > $D/cell; }
cell warmup $BIN bench http scoreboard --arm strim=$URL,$MODEL --workloads W3 --w3-sizes 4096 --w3-gen 8 --reps 1 --out-dir $D/warmup
cell replay $BIN bench http replay --fixture bench/results/final-20261026/synthetic-8turn.json --arm strim=$URL,$MODEL,cache=on --server-log strim=$D/server.log --reps 1 --max-tokens 48 --out-dir $D/replay
