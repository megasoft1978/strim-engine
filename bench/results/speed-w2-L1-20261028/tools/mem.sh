#!/bin/bash
# usage: mem.sh watch.csv... -> per file: peak footprint MB, swap grow MB (csv: epoch,cell,swap,rss,footprint)
for f in "$@"; do
  awk -F, -v f="$f" 'BEGIN{pk=0;sw0=-1;smax=0} /^#/ {next} NF>=5 { if(sw0<0) sw0=$3; if($5+0>pk) pk=$5+0; if($3-sw0>smax) smax=$3-sw0 } END{printf "%s peak_footprint_mb=%d swap_grow_mb=%d\n", f, pk, smax}' "$f"
done
