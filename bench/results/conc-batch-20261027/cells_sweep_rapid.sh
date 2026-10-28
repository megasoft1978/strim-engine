# policy sweep cells: repeated-text and realistic flavors, c=1 (MTP acceptance), c=4, c=8; 512-token prompts, 128 out; 2 reps
for rep in 1 2; do
  $STRIM bench http scoreboard --arm rapid=$URL,$MODEL --workloads W4 --conc 1,4,8 --w4-size 512 --w4-gen 128 --reps 1 --out-dir $D/rep512-r$rep > $D/rep512-r$rep.stdout 2>&1
  echo "--- after rep512 r$rep: $(wc -l < $D/server.log) log lines" >> $D/steps.log
  for c in 1 4 8; do
    $R/real_conc.sh $URL $MODEL $c 1800 128 $D/real512-c$c-r$rep $((rep*10+c)) > $D/real512-c$c-r$rep.txt 2>&1
    echo "--- after real512 c$c r$rep: $(wc -l < $D/server.log) log lines" >> $D/steps.log
  done
done
