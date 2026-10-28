# one rep: repeated-text scoreboard c=1,4,8 and realistic c=1,4,8 (512-token prompts, 128 out)
$STRIM bench http scoreboard --arm strim=$URL,$MODEL --workloads W4 --conc 1,4,8 --w4-size 512 --w4-gen 128 --reps 1 --out-dir $D/rep512-r1 > $D/rep512-r1.stdout 2>&1
for c in 1 4 8; do
  $R/real_conc.sh $URL $MODEL $c 1800 128 $D/real512-c$c-r1 $((RANDOM % 90 + 100 + c)) > $D/real512-c$c-r1.txt 2>&1
done
