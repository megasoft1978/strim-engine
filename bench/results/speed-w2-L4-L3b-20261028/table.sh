#!/bin/bash
# usage: table.sh DIR...   one line per cell file: arm, decode tok/s (aggregate), ms/pass (draft+verify+reseed, rep lines only),
# host_wait ms/pass, syncs/round, accept, then per-dir mean of each arm. Ids equality A vs B (first mismatch listing).
for d in "$@"; do
  echo "# $d"
  for f in $(ls "$d"/*_?.txt | sort -V); do
    arm=$(basename "$f" .txt | sed 's/.*_//')
    awk -v arm="$arm" -v f="$(basename "$f")" '
      /^ms\/pass:/ { for(i=1;i<=NF;i++){ if($i=="mtp_draft")dr=$(i+1)+0; if($i=="verify")ve=$(i+1)+0; if($i=="reseed")rs=$(i+1)+0; if($i=="host_wait")hw=$(i+1)+0; if($i=="rounds")ro=$(i+1)+0; if($i=="syncs/round")sy=$(i+1)+0 }
        if (ro>4) { n++; ms+=dr+ve+rs; w+=hw; s=sy } }
      /^aggregate:/ { for(i=1;i<=NF;i++) if($i ~ /^decode_tok_s=/){split($i,a,"=");tps=a[2]} }
      /accept/ && /rep/ { match($0,/accept [0-9]+%/); acc=substr($0,RSTART,RLENGTH) }
      END { printf "%s arm=%s decode_tok_s=%s ms_pass=%.2f host_wait=%.2f syncs/round=%.2f %s\n", f, arm, tps, (n?ms/n:0), (n?w/n:0), s, acc }' "$f"
  done | tee /tmp/l4tab.$$
  awk '{split($2,a,"="); split($3,b,"="); split($4,c,"="); split($5,h,"="); n[a[2]]++; t[a[2]]+=b[2]; m[a[2]]+=c[2]; w[a[2]]+=h[2]} END{for(k in n) printf "MEAN arm=%s n=%d decode_tok_s=%.2f ms_pass=%.2f host_wait=%.2f\n", k, n[k], t[k]/n[k], m[k]/n[k], w[k]/n[k]}' /tmp/l4tab.$$ | sort
  rm -f /tmp/l4tab.$$
  # ids identical A vs B (benchspec prints the spec ids only on a parity mismatch)
  a=$(ls "$d"/*_A.txt | sort -V | head -1); b=$(ls "$d"/*_B.txt | sort -V | head -1)
  if [ -n "$a" ] && [ -n "$b" ]; then
    if cmp -s <(grep '^  spec  ' "$a") <(grep '^  spec  ' "$b"); then echo "ids A==B: identical ($(grep -c '^  spec  ' "$a") rep dumps compared)"; else echo "ids A!=B: DIFFER"; fi
  fi
done
