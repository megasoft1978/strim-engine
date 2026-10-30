#!/bin/zsh
set -eu
out=/Users/user/Desktop/Freelance/strim-engine/bench/results/speed-s4-20261029/raw
model=$HOME/.strim/models/qwen38-4bit
mkdir -p "$out/quality"
echo 'waiting for GPU lock: reference quality'
lockf -k /tmp/strim-bench.lock /tmp/s4/bin/base/strim s4 quality "$model" /tmp/s4/quality/base > "$out/quality/base.jsonl" 2> "$out/quality/base.stderr"
echo 'reference quality completed; waiting for GPU lock: cap8 quality'
lockf -k /tmp/strim-bench.lock /tmp/s4/bin/cap8/strim s4 quality "$model" /tmp/s4/quality/cap8 /tmp/s4/quality/base > "$out/quality/cap8.jsonl" 2> "$out/quality/cap8.stderr"
echo 'cap8 quality completed; waiting for GPU lock: fusion quality'
STRIM_S4_FUSE=1 lockf -k /tmp/strim-bench.lock /tmp/s4/bin/base/strim s4 quality "$model" /tmp/s4/quality/fuse /tmp/s4/quality/base > "$out/quality/fuse.jsonl" 2> "$out/quality/fuse.stderr"
echo 'quality completed'
