#!/bin/bash
# usage: ttft.sh raw.jsonl... -> per variant: n, p50, p95 (nearest rank over sorted ttft), mean decode tok/s (jq only)
for f in "$@"; do
  jq -rs '[.[] | select(.kind=="request")] | group_by(.variant)[] |
    (map(.ttft_s) | sort) as $t | (length) as $n |
    "\(.[0].variant) n=\($n) p50=\($t[(($n*0.5)|ceil)-1]|.*1000|round/1000) p95=\($t[(($n*0.95)|ceil)-1]|.*1000|round/1000) decode_tps_mean=\((map(.decode_tps)|add)/$n|.*10|round/10)"' "$f" | sed "s#^#$(basename $(dirname $(dirname $(dirname $f))))/$(basename $(dirname $(dirname $f))) #"
done
