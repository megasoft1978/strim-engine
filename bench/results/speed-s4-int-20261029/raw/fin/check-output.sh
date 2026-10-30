#!/bin/bash
set -euo pipefail
path=$1
reference=$2
jq -s -e 'map(select(.kind != "meta")) | group_by([.kind, (.c // .width)]) | all(.[]; (map(.rep) | sort) == [-1,0,1,2])' "$path" > /dev/null
jq -s -S 'map(select(.kind != "meta") | {kind,c,width,rep,steps,hashes,hash})' "$path" > "$path.oracle.json"
if [[ $path != "$reference" ]]; then
  cmp "$reference.oracle.json" "$path.oracle.json"
fi
