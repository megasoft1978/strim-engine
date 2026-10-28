#!/bin/zsh
# interleaved A/B (start, new) pairs; usage: ab.sh <pairs> <grep-regex> <args...>
S=/private/tmp/claude-501/-Users-user-Desktop-Freelance-strim-engine/6df0dc83-1ce6-455e-8d6d-9354559af0eb/scratchpad
N=$1; RX=$2; shift 2
for i in $(seq $N); do
  for v in start new; do
    bin=$S/strim-p3c-start; [ $v = new ] && bin=.build/release/strim
    r=$(lockf -k /tmp/strim-bench.lock $bin "$@" 2>&1 | grep -E "$RX" | tr '\n' ' ')
    echo "pair $i $v | $(uptime | sed 's/.*load/load/') | $r"
  done
done
