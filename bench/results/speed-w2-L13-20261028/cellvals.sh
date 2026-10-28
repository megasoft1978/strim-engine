#!/bin/bash
# usage: cellvals.sh SESSION_DIR   (a pass13.sh output dir: has w3/ w3_32k/ c148/ raw.jsonl) -> "metric value" lines
D=${1:?dir}
JQDEF='def med: sort | if length==0 then null elif length%2==1 then .[(length/2)|floor] else (.[length/2-1]+.[length/2])/2 end;
 def pct($p): sort | if length==0 then null else ((length-1)*$p) as $i | (.[$i|floor]) as $a | (.[$i|ceil]) as $b | $a+($b-$a)*($i-($i|floor)) end;
 def req($w;$v): [.[] | select(.kind=="request" and .workload==$w and .variant==$v and .error==null)];
 def agg($w;$v): [.[] | select(.kind=="batch" and .workload==$w and .variant==$v) | .aggregate_tps | numbers] | med;
 def tt($w;$v): req($w;$v) | map(.ttft_s);'
v() { f="$D/$1/raw.jsonl"; [ -s "$f" ] || return; shift; printf '%s %s\n' "$1" "$(jq -s -r "$JQDEF $2 | numbers" "$f" 2>/dev/null | head -1)"; }
v w3 pf4k 'req("W3";"ctx-4096")|map(.prompt_tokens/.ttft_s)|med'
v w3 pf16k 'req("W3";"ctx-16384")|map(.prompt_tokens/.ttft_s)|med'
v w3_32k pf32k 'req("W3";"ctx-32768")|map(.prompt_tokens/.ttft_s)|med'
v w3 d16k 'req("W3";"ctx-16384")|map(.decode_tps)|med'
for c in 1 4 8; do
 v c148 p50_c$c "tt(\"W4\";\"distinct-c$c\")|pct(0.5)"
 v c148 p95_c$c "tt(\"W4\";\"distinct-c$c\")|pct(0.95)"
 v c148 agg_c$c "agg(\"W4\";\"distinct-c$c\")"
done
echo "peak_mb $(awk -F, '!/^#/ {if ($5>m) m=$5} END{print m+0}' "$D/watch.csv" 2>/dev/null)"
echo "mtp_acc $(grep -h '^\[serve\]' "$D/server.txt" 2>/dev/null | sed -n 's/.* mtp=\([0-9.]*\).*/\1/p' | awk '{s+=$1;n++} END{if(n) printf "%.4f", s/n}')"
