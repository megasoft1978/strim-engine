#!/bin/bash
# usage: summarize.sh  (from this dir) -> per-run replay ttft sum/cached, per-cell peak footprint, end-of-cell MLX/trie memory
for d in ab/run*; do
  echo "== $d"
  for r in replay1 replay2; do
    awk -v r=$r '/ttft=/ {split($0,a,"ttft="); split(a[2],b,"s"); t+=b[1]; split($0,c,"cached="); split(c[2],e," "); k=k" "e[1]} END{printf "%s ttft_sum=%.1fs cached:%s\n", r, t, k}' $d/$r.log
  done
  awk -F, 'NR>1 && $2!="idle" && $4>m[$2] {m[$2]=$4} END{for(k in m) printf "peak_fp %s=%d MB\n", k, m[k]}' $d/footprint.csv | sort | tr '\n' ';'; echo
  for f in $d/metrics_*.json; do printf "%s " $(basename $f .json); tr ',' '\n' < $f | grep -E 'trie_bytes|mlx_active|mlx_cache|mlx_peak|trie_nodes|trie_evict' | sed 's/"//g' | awk -F: '{if($1~/bytes|peak/) printf "%s=%dMB ", $1, $2/1048576; else printf "%s=%s ", $1,$2}'; echo; done
done
