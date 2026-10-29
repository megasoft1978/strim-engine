#!/bin/bash
# usage: summarize.sh RESULTS_DIR [ENGINES=strim,rapid-mlx,mlx-vlm,mlx-lm,omlx]  -> markdown tables on stdout (jq + awk only)
# H2H_JSON=file also writes results.json (schema in SCHEMA.md).
# cell value = median over passes of the per-pass value (per-pass: median over the cell's requests); ratio = strim / rival;
# verdict WIN/TIE/LOSS with TIE = within H2H_TIE_PCT percent (default 2); lower-is-better cells are inverted.
# A cell flagged memory_abort_watchdog / engine_guard_abort / engine_oom / cell_timeout in the LATEST session of that engine+pass is n/a
# (raw kept, never retried silently). H2H_ONLY_CLEAN=1 also drops every cell whose latest session is not CLEAN.
R=${1:?results dir}; ENGS=${2:-strim,rapid-mlx,mlx-vlm,mlx-lm,omlx}; TIE=${H2H_TIE_PCT:-2}
HERE=$(cd "$(dirname "$0")" && pwd); MEMO=$(mktemp); EXCL=$(mktemp)
cstate() { # engine pass cell -> "excluding-flag|session-status" of the latest session of that engine+pass that ran the cell ("|UNKNOWN" for runs without sessions.jsonl)
  local k="$1|$2|$3|" m; m=$(grep -F -m1 "$k" "$MEMO"); if [ -n "$m" ]; then echo "${m#$k}"; return; fi
  local f="$R/$1/pass$2/sessions.jsonl" r="|UNKNOWN"
  [ -s "$f" ] && r=$(jq -rs --arg c "$3" 'map(select(.cells|index($c))) | last | if . == null then "|UNKNOWN" else ((.flags|map(select(.cell==$c and (.flag|test("^(memory_abort_watchdog|engine_guard_abort|engine_oom|cell_timeout)$"))))|map(.flag)|first) // "") + "|" + .status end' "$f" 2>/dev/null || echo "|UNKNOWN")
  echo "$k$r" >> "$MEMO"; echo "$r"
}
skipcell() { local s; s=$(cstate "$1" "$2" "$3"); [ -n "${s%%|*}" ] && return 0; [ "${H2H_ONLY_CLEAN:-0}" = 1 ] && [ "${s##*|}" != CLEAN ] && return 0; return 1; }
JQDEF='def med: sort | if length==0 then null elif length%2==1 then .[(length/2)|floor] else (.[length/2-1]+.[length/2])/2 end;
 def pct($p): sort | if length==0 then null else ((length-1)*$p) as $i | (.[$i|floor]) as $a | (.[$i|ceil]) as $b | $a+($b-$a)*($i-($i|floor)) end;
 def req($w;$v): [.[] | select(.kind=="request" and .workload==$w and .variant==$v and .error==null)];
 def agg($w;$v): [.[] | select(.kind=="batch" and .workload==$w and .variant==$v) | .aggregate_tps | numbers] | med;
 def tt($w;$v): req($w;$v) | map(.ttft_s) ;
 def rp: [.[] | select(.kind=="request" and .error==null)] | sort_by(.turn);'
# id|label|unit|dir(h=higher better,l=lower)|cell dir|jq program (input: slurped raw.jsonl of that cell, one request set)
METRICS=$(cat <<'M'
c4k_pf|cold 4K prefill|tok/s|h|w3|req("W3";"ctx-4096")|map(.prompt_tokens/.ttft_s)|med
c4k_tt|cold 4K TTFT|s|l|w3|tt("W3";"ctx-4096")|med
d4k|decode 256 tok @ 4K ctx|tok/s|h|w3|req("W3";"ctx-4096")|map(.decode_tps)|med
c16k_pf|cold 16K prefill|tok/s|h|w3|req("W3";"ctx-16384")|map(.prompt_tokens/.ttft_s)|med
c16k_tt|cold 16K TTFT|s|l|w3|tt("W3";"ctx-16384")|med
d16k|decode 256 tok @ 16K ctx|tok/s|h|w3|req("W3";"ctx-16384")|map(.decode_tps)|med
c32k_pf|cold 32K prefill|tok/s|h|w3_32k|req("W3";"ctx-32768")|map(.prompt_tokens/.ttft_s)|med
c32k_tt|cold 32K TTFT|s|l|w3_32k|tt("W3";"ctx-32768")|med
d32k|decode 128 tok @ 32K ctx|tok/s|h|w3_32k|req("W3";"ctx-32768")|map(.decode_tps)|med
a512c4|c=4 512-tok prompts aggregate|tok/s|h|w4s|agg("W4";"distinct-c4")
p50_512c4|c=4 512-tok prompts p50 TTFT|s|l|w4s|tt("W4";"distinct-c4")|pct(0.5)
p95_512c4|c=4 512-tok prompts p95 TTFT|s|l|w4s|tt("W4";"distinct-c4")|pct(0.95)
a512c8|c=8 512-tok prompts aggregate|tok/s|h|w4s|agg("W4";"distinct-c8")
p50_512c8|c=8 512-tok prompts p50 TTFT|s|l|w4s|tt("W4";"distinct-c8")|pct(0.5)
p95_512c8|c=8 512-tok prompts p95 TTFT|s|l|w4s|tt("W4";"distinct-c8")|pct(0.95)
aagc4|c=4 agent prompts (~2.8K tok) aggregate|tok/s|h|w6|agg("W6";"agent-c4")
p50_agc4|c=4 agent prompts p50 TTFT|s|l|w6|tt("W6";"agent-c4")|pct(0.5)
p95_agc4|c=4 agent prompts p95 TTFT|s|l|w6|tt("W6";"agent-c4")|pct(0.95)
aagc8|c=8 agent prompts aggregate|tok/s|h|w6|agg("W6";"agent-c8")
p50_agc8|c=8 agent prompts p50 TTFT|s|l|w6|tt("W6";"agent-c8")|pct(0.5)
p95_agc8|c=8 agent prompts p95 TTFT|s|l|w6|tt("W6";"agent-c8")|pct(0.95)
a4kc4|c=4 4K prompts aggregate (prefill-bound)|tok/s|h|w4|agg("W4";"distinct-c4")
p50_4kc4|c=4 4K prompts p50 TTFT|s|l|w4|tt("W4";"distinct-c4")|pct(0.5)
p95_4kc4|c=4 4K prompts p95 TTFT|s|l|w4|tt("W4";"distinct-c4")|pct(0.95)
a4kc8|c=8 4K prompts aggregate (prefill-bound)|tok/s|h|w4|agg("W4";"distinct-c8")
p50_4kc8|c=8 4K prompts p50 TTFT|s|l|w4|tt("W4";"distinct-c8")|pct(0.5)
p95_4kc8|c=8 4K prompts p95 TTFT|s|l|w4|tt("W4";"distinct-c8")|pct(0.95)
aw5|W5 4 clients, 16K shared prefix aggregate|tok/s|h|w5|agg("W5";"shared16384-c4")
p50_w5|W5 p50 TTFT|s|l|w5|tt("W5";"shared16384-c4")|pct(0.5)
p95_w5|W5 p95 TTFT|s|l|w5|tt("W5";"shared16384-c4")|pct(0.95)
M
)
val() { # engine pass cell program -> number|""
  local f="$R/$1/pass$2/$3/raw.jsonl"; [ -s "$f" ] || return; skipcell "$1" "$2" "$3" && return
  jq -s -r "$JQDEF ${4} | numbers" "$f" 2>/dev/null
}
rval() { # replay metrics: engine pass kind
  local f="$R/$1/pass$2/replay/raw.jsonl"; [ -s "$f" ] || return; skipcell "$1" "$2" replay && return
  jq -s -r "$JQDEF rp | $3" "$f" 2>/dev/null
}
medpass() { awk 'NF{a[n++]=$1} END{if(!n){print "NA";exit} for(i=0;i<n;i++)for(j=i+1;j<n;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}; print (n%2)?a[int(n/2)]:(a[n/2-1]+a[n/2])/2}'; }
IFS=, read -ra E <<<"$ENGS"
ROWS=$(mktemp); PASSV=$(mktemp)
passes() { ls -d "$R/${E[0]}"/pass* 2>/dev/null | sed 's/.*pass//' | sort; }
xrec() { # id engine cell -> EXCL line: excluded passes and the session status per pass (for results.json)
  local P s ex="" st=""; for P in $(passes); do s=$(cstate "$2" "$P" "$3"); [ -n "${s%%|*}" ] && ex="$ex$P,"; st="$st${s##*|},"; done
  echo "$1|$2|$3|${ex%,}|${st%,}" >> "$EXCL"
}
while IFS='|' read -r id label unit dir cellname prog rest; do
  [ -z "$id" ] && continue
  p="$prog"; [ -n "$rest" ] && p="$prog | $rest"
  line="$id|$label|$unit|$dir"
  for e in "${E[@]}"; do
    pv=$(for P in $(passes); do val "$e" "$P" "$cellname" "$p"; done | tr "\n" ","); echo "$id|$e|${pv%,}" >> "$PASSV"; xrec "$id" "$e" "$cellname"; v=$(echo "$pv" | tr "," "\n" | medpass); line="$line|$v"
  done
  echo "$line" >> "$ROWS"
done <<<"$(echo "$METRICS" | awk -F'|' '{printf "%s|%s|%s|%s|%s|", $1,$2,$3,$4,$5; for(i=6;i<=NF;i++) printf "%s%s", $i, (i<NF?"|":""); print ""}')"
# replay: prefill sum over turns 1-8 and 1-6, cached fraction at T8
for spec in "rp8|agent replay prefill sum T1-T8|s|l|map(select(.turn<=8).ttft_s)|add" "rp6|agent replay prefill sum T1-T6|s|l|map(select(.turn<=6).ttft_s)|add" \
            "rpc8|agent replay T8 cached fraction|frac|h|map(select(.turn==8).cache_frac)|first"; do
  IFS='|' read -r id label unit dir a b <<<"$spec"; line="$id|$label|$unit|$dir"
  for e in "${E[@]}"; do pv=$(for P in $(passes); do rval "$e" "$P" "$a | $b | numbers"; done | tr "\n" ","); echo "$id|$e|${pv%,}" >> "$PASSV"; xrec "$id" "$e" replay; v=$(echo "$pv" | tr "," "\n" | medpass); line="$line|$v"; done
  echo "$line" >> "$ROWS"
done
echo "## Results (ratio = ${E[0]} / rival; lower-is-better cells (TTFT, time) win with ratio < 1; tie = within ${TIE}%)"; echo
printf '| cell | unit |'; for e in "${E[@]}"; do printf ' %s |' "$e"; done
for e in "${E[@]:1}"; do printf ' %s/%s |' "${E[0]}" "$e"; done
for e in "${E[@]:1}"; do printf ' vs %s |' "$e"; done; echo
n=${#E[@]}; printf '|---|---|'; for i in $(seq 1 $((n + 2 * (n - 1)))); do printf -- '---|'; done; echo
awk -F'|' -v n="$n" -v tie="$TIE" '{
  printf "| %s | %s |", $2, $3
  for (i = 1; i <= n; i++) { v = $(4 + i); printf " %s |", (v == "NA" ? "n/a" : sprintf("%.4g", v)) }
  s = $5
  for (i = 2; i <= n; i++) { v = $(4 + i); if (v == "NA" || s == "NA" || v + 0 == 0) { r[i] = "n/a"; printf " n/a |" } else { r[i] = s / v; printf " %.2fx |", r[i] } }
  for (i = 2; i <= n; i++) {
    if (r[i] == "n/a") { printf " n/a |"; continue }
    x = ($4 == "h") ? r[i] : 1 / r[i]
    printf " %s |", (x > 1 + tie / 100) ? "WIN" : (x < 1 - tie / 100) ? "LOSS" : "TIE"
  }
  print ""
}' "$ROWS"
echo; echo "## Peak memory per cell (MB; max over passes and sessions; footprint = phys_footprint of the engine process tree, includes Metal buffers)"; echo
printf '| cell |'; for e in "${E[@]}"; do printf ' %s footprint / RSS |' "$e"; done; echo; printf '|---|'; for e in "${E[@]}"; do printf -- '---|'; done; echo
for c in warmup agree w3 w3_32k w4 w4s w6 w5 replay; do
  printf '| %s |' "$c"
  for e in "${E[@]}"; do
    cat "$R/$e"/pass*/watch.csv 2>/dev/null | awk -F, -v c="$c" '!/^#/ && $2==c {if($5>f)f=$5; if($4>r)r=$4} END{ if (f=="") print " n/a |"; else printf " %d / %d |\n", f, r}' | tr -d '\n'
  done; echo
done
printf '| **whole run** |'
for e in "${E[@]}"; do cat "$R/$e"/pass*/watch.csv 2>/dev/null | awk -F, '!/^#/ {if($5>f)f=$5; if($4>r)r=$4} END{printf " **%d / %d** |", f, r}'; done; echo
echo; echo "## Engines: capabilities and exact launch (engines.sh is the single source; versions are those measured in this run)"; echo
H2H_ROOT=$HERE/../.. "$HERE/engines.sh" table "$ENGS" "$R"
echo; echo "## Session validity (latest session per engine, pass and cell group; CLEAN = no 2-sample pollution, gate passed; claims only from CLEAN)"; echo
printf '| engine | pass | cells | status | gate | polluted cells | flags |\n|---|---|---|---|---|---|---|\n'
for e in "${E[@]}"; do for P in $(passes); do
  [ -s "$R/$e/pass$P/sessions.jsonl" ] || { echo "| $e | $P | n/a | UNKNOWN (no sessions.jsonl) | n/a | n/a | n/a |"; continue; }
  jq -rs --arg e "$e" --argjson p "$P" 'group_by(.cells|join(","))|map(last)|.[]|"| \($e) | \($p) | \(.cells|join(",")) | \(.status) | \(.gate) | \(.polluted_cells|join(" ")) | \(.flags|map("\(.cell):\(.flag)")|join(" ")) |"' "$R/$e/pass$P/sessions.jsonl"
done; done
echo; echo "## Flagged cells (never retried silently; n/a in the tables above when an abort, guard, OOM or timeout flag)"; echo
FL=$(for e in "${E[@]}"; do for P in $(passes); do [ -s "$R/$e/pass$P/sessions.jsonl" ] && jq -rs --arg e "$e" --argjson p "$P" '.[]|.flags[]|"- \($e) pass\($p) \(.cell): \(.flag) \(.detail)"' "$R/$e/pass$P/sessions.jsonl"; done; done)
[ -n "$FL" ] && echo "$FL" || echo "- none"
echo; echo "## Cache-hit reporting (usage-reported cached tokens, per engine; rows without a value = engine did not report)"; echo
printf '| engine | cell | rows | rows with a hit | cached tokens | unreported rows |\n|---|---|---|---|---|---|\n'
for e in "${E[@]}"; do for c in w5 replay; do
  cat "$R/$e"/pass*/cache.jsonl 2>/dev/null | jq -rs --arg e "$e" --arg c "$c" '[.[]|select(.cell==$c)]|if length==0 then "| \($e) | \($c) | n/a | n/a | n/a | n/a |" else "| \($e) | \($c) | \(map(.rows)|add) | \(map(.hit_rows)|add) | \(map(.cached_tokens)|add) | \(map(.unreported_rows)|add) |" end'
done; done
echo; echo "## Run conditions"; echo
for e in "${E[@]}"; do for d in "$R/$e"/pass*; do
  s=$(awk '/^session/ {n++} END{print n}' "$d/steps.txt")
  echo "- $e $(basename "$d"): $s sessions; first load $(awk '/^session/ {sub(/.*load=/,""); sub(/ swap=.*/,""); print; exit}' "$d/steps.txt"); swap used at start $(awk '/^session/ {sub(/.*used = /,""); sub(/ .*/,""); print; exit}' "$d/steps.txt"); swap growth max $(awk -F, '/^# base_swap_mb/ {split($1,a,"="); b=a[2]} !/^#/ {g=$3-b; if(g>m)m=g} END{print m+0}' "$d/watch.csv") MB; watchdog aborts: $( [ -s "$d/watch.csv.abort" ] && tr '\n' ' ' < "$d/watch.csv.abort" || echo none )"
done; done
echo; echo "## Greedy agreement (sanity only; 8 fixed prompts, 64 tokens, near-ties diverge)"; echo
JQCMP='def cp($a;$b): ($a|explode) as $x | ($b|explode) as $y | ([($x|length),($y|length)]|min) as $n | (first(range(0;$n) | select($x[.]!=$y[.])) // $n) as $k | {same: ($a==$b), frac: (if ([$x|length,$y|length]|max)==0 then 1 else $k/([$x|length,$y|length]|max) end)};
 . as [$A,$B] | [$A | keys[] as $k | cp($A[$k];$B[$k])] | "\(map(select(.same))|length)/\(length) identical; mean common-prefix fraction \((map(.frac)|add/length*100|round)/100)"'
cmp() { jq -s -r "$JQCMP" "$1" "$2" 2>/dev/null || echo "n/a"; }
F=$R/${E[0]}
[ -s "$F/pass1/agree.json" ] && [ -s "$F/pass2/agree.json" ] && echo "- ${E[0]} pass1 vs pass2 (self): $(cmp "$F/pass1/agree.json" "$F/pass2/agree.json")"
for e in "${E[@]:1}"; do echo "- ${E[0]} vs $e (pass1): $(cmp "$F/pass1/agree.json" "$R/$e/pass1/agree.json"); (pass2): $(cmp "$F/pass2/agree.json" "$R/$e/pass2/agree.json")"; done
for ((i=1;i<${#E[@]};i++)); do for ((j=i+1;j<${#E[@]};j++)); do echo "- ${E[i]} vs ${E[j]} (pass1): $(cmp "$R/${E[i]}/pass1/agree.json" "$R/${E[j]}/pass1/agree.json")"; done; done
echo; echo "## Agent replay detail (8 turns; median over passes)"; echo
printf '| turn | prompt tok |'; for e in "${E[@]}"; do printf ' %s TTFT s | %s cached tok |' "$e" "$e"; done; echo; printf '|---|---|'; for e in "${E[@]}"; do printf -- '---|---|'; done; echo
for t in 1 2 3 4 5 6 7 8; do
  pt=$(for P in $(passes); do rval "${E[0]}" "$P" "map(select(.turn==$t).prompt_tokens)|first|numbers"; done | medpass)
  printf '| %s | %s |' "$t" "$pt"
  for e in "${E[@]}"; do
    a=$(for P in $(passes); do rval "$e" "$P" "map(select(.turn==$t).ttft_s)|first|numbers"; done | medpass)
    b=$(for P in $(passes); do rval "$e" "$P" "map(select(.turn==$t).cached_tokens)|first|numbers"; done | medpass)
    printf ' %s | %s |' "$(awk -v x="$a" 'BEGIN{ if (x=="NA") print "n/a"; else printf "%.2f", x }')" "${b//NA/n/a}"
  done; echo
done
echo; echo "## Pass-to-pass noise (|pass1-pass2| / mean, percent, over all cells above; TIE band is ${TIE}%)"; echo
printf '| engine | cells | median spread | p90 spread | max spread (cell) |\n|---|---|---|---|---|\n'
for e in "${E[@]}"; do
  awk -F'|' -v e="$e" -v lab="$(echo "$METRICS" | awk -F'|' '{print $1"="$2}' | tr '\n' ';')" 'BEGIN{n=split(lab,L,";"); for(i=1;i<=n;i++){split(L[i],kv,"="); name[kv[1]]=kv[2]}}
    $2==e { m=split($3,v,","); if (m<2 || (v[1]+v[2])==0) next; s=($1 ~ /^x/)?0:100*((v[1]>v[2]?v[1]-v[2]:v[2]-v[1])/((v[1]+v[2])/2)); a[++k]=s; id[k]=name[$1] }
    END{ if(!k){print "| " e " | 0 | n/a | n/a | n/a |"; exit}
      for(i=1;i<=k;i++)for(j=i+1;j<=k;j++)if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t;u=id[i];id[i]=id[j];id[j]=u}
      printf "| %s | %d | %.1f%% | %.1f%% | %.1f%% (%s) |\n", e, k, a[int((k+1)/2)], a[int(k*0.9)>0?int(k*0.9):1], a[k], id[k] }' "$PASSV"
done
if [ -n "${H2H_JSON:-}" ]; then
  awk -F'|' -v n="$n" -v tie="$TIE" -v engs="$ENGS" 'BEGIN{split(engs,E,",")}{
    printf "%s\t%s\t%s\t%s", $1,$2,$3,$4
    s=$5
    for(i=1;i<=n;i++) printf "\t%s", $(4+i)
    for(i=2;i<=n;i++){ v=$(4+i); if(v=="NA"||s=="NA"||v+0==0){printf "\tNA\tn/a"} else { r=s/v; x=($4=="h")?r:1/r; printf "\t%.4f\t%s", r, (x>1+tie/100)?"WIN":(x<1-tie/100)?"LOSS":"TIE" } }
    print "" }' "$ROWS" | jq -R -s --arg engs "$ENGS" --argjson tie "$TIE" --slurpfile pv <(jq -R -s 'split("\n")|map(select(length>0)|split("|")|{id:.[0],engine:.[1],passes:(.[2]//""|split(",")|map(tonumber? // null))})' "$PASSV") '
    ($engs|split(",")) as $E | ($E|length) as $n | [ split("\n")[] | select(length>0) | split("\t") | . as $f |
      ($f[4:4+$n] | map(tonumber? // null)) as $med | ($f[4+$n:] ) as $rv |
      {id:$f[0], cell:$f[1], unit:$f[2], better:(if $f[3]=="h" then "higher" else "lower" end),
       median:([range(0;$n)] | map({key:$E[.], value:$med[.]}) | from_entries),
       per_pass:([range(0;$n)] | map(. as $i | {key:$E[$i], value:([$pv[0][]|select(.id==$f[0] and .engine==$E[$i])|.passes][0] // [])}) | from_entries),
       vs_rivals:([range(1;$n)] | map(. as $i | {key:$E[$i], value:{ratio_strim_over_rival:($rv[($i-1)*2]|tonumber? // null), verdict:$rv[($i-1)*2+1]}}) | from_entries)} ]
    | {tie_pct:$tie, engines:$E, cells:.}' > "$H2H_JSON.tmp"
  # schema v2 additions (all additive; SCHEMA.md): per-cell group / excluded_passes / session_status / claim_eligible, engine_meta, sessions, flags, claim_policy
  jq --arg dir "$(basename "$R")" \
     --slurpfile ex <(jq -R -s 'split("\n")|map(select(length>0)|split("|")|{id:.[0],engine:.[1],group:.[2],excluded:(.[3]|split(",")|map(select(length>0)|tonumber)),status:(.[4]|split(",")|map(select(length>0)))})' "$EXCL") \
     --slurpfile meta <("$HERE/engines.sh" tsv "$ENGS" "$R" | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{key:.[0],value:{port:(.[1]|tonumber),mtp:.[2],prefix_cache:.[3],cache_hits_visible_via:.[4],own_memory_guard:.[5],flags:.[6],version:.[7],model:.[8]}})|from_entries') \
     --slurpfile sess <(cat "$R"/*/pass*/sessions.jsonl 2>/dev/null | jq -s '.') \
     --argjson only "$([ "${H2H_ONLY_CLEAN:-0}" = 1 ] && echo true || echo false)" '
    ($ex[0]) as $X | .engines as $E |
    .cells |= map(. as $c | ([$X[]|select(.id==$c.id)]) as $r |
      . + {group: ($r[0].group // null),
           excluded_passes: ([$E[] | . as $e | {key:$e, value:([$r[]|select(.engine==$e)|.excluded]|first // [])}] | from_entries),
           session_status: ([$E[] | . as $e | {key:$e, value:([$r[]|select(.engine==$e)|.status]|first // [])}] | from_entries),
           claim_eligible: ([$E[] | . as $e | {key:$e, value:(([$r[]|select(.engine==$e)][0]) as $q | if $q == null or ($q.status|length)==0 then null else (($q.excluded|length)==0 and ($q.status|all(. == "CLEAN")) and (($c.per_pass[$e]|length) == ($q.status|length))) end)}] | from_entries)})
    | . + {schema_version: 2, run_dir: $dir, only_clean: $only,
           claim_policy: {claims_only_from_clean_sessions: true, tie_pct: .tie_pct, rerun_polluted_once: true,
                          pollution_rule: "1-min load > pollute_load or a foreign process > 60% CPU in 2 consecutive samples = POLLUTED",
                          excluded_flags: ["memory_abort_watchdog","engine_guard_abort","engine_oom","cell_timeout"]},
           engine_meta: $meta[0],
           sessions: $sess[0],
           flags: [($sess[0] // [])[] | . as $s | .flags[] | {engine:$s.engine, pass:$s.pass, session:$s.session, cell:.cell, flag:.flag, detail:.detail}]}' "$H2H_JSON.tmp" > "$H2H_JSON" && rm -f "$H2H_JSON.tmp"
fi
rm -f "$ROWS" "$PASSV" "$MEMO" "$EXCL"
