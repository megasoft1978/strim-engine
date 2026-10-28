# single-stream decode @4K (no-regression) and prefill-bound c=4/c=8 with distinct 4K prompts
$STRIM bench http scoreboard --arm strim=$URL,$MODEL --workloads W3 --w3-sizes 4096 --w3-gen 256 --reps 2 --out-dir $D/w3-4k > $D/w3-4k.stdout 2>&1
$STRIM bench http scoreboard --arm strim=$URL,$MODEL --workloads W4 --conc 4,8 --w4-size 4096 --w4-gen 64 --reps 2 --out-dir $D/w4-4k > $D/w4-4k.stdout 2>&1
