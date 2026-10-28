#!/bin/bash
# usage: gen_all.sh BIN MODEL OUT  (greedy, no MTP, 10 prompts)
for p in bench/results/speed-w2-L17-20261028/prompts/p*.json; do $1 bonsaispike gen $2 $p 300; done > $3 2>&1
