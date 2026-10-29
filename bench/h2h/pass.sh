#!/bin/bash
# One engine session. usage (repo root, under the GPU lock): pass.sh ENGINE PASS CELLS OUTDIR
#   ENGINE strim|rapid-mlx|mlx-vlm|mlx-lm|omlx   CELLS comma list of: agree w3 w3_32k w4 w4s w6 w5 replay  (warm-up always runs first)
# Engine table (launch, port, capabilities, timeouts): engines.sh. Writes OUTDIR/ENGINE/passN/ (steps.txt, flags.csv, sessions.jsonl, ...).
# Needs a foreground shell (Metal cannot create a GPU stream from a detached process).
# H2H_DRYRUN=1 replaces the engine by stub/stub.swift (no GPU, no models served) and shortens the waits; everything else is the real code path.
set -u
E=$1; P=$2; CELLS=$3; OUT=$4
H=$(cd "$(dirname "$0")" && pwd)
ROOT=${H2H_ROOT:-$(git -C "$H" rev-parse --show-toplevel)}; cd "$ROOT" || exit 2
DRY=${H2H_DRYRUN:-0}
STRIM=${STRIM_BIN:-/tmp/strim-build-final/release/strim}
if [ "$DRY" = 1 ] && [ ! -x "$STRIM" ]; then
  for c in /tmp/strim-build-final3/release/strim /tmp/strim-build-final2/release/strim "$ROOT/.build/release/strim"; do [ -x "$c" ] && STRIM=$c && break; done
fi
H2H_SCRATCH=${H2H_SCRATCH:-/private/tmp/h2h-scratch}; mkdir -p "$H2H_SCRATCH"
. "$H/engines.sh"
engine_spec "$E" || { echo "unknown engine $E"; exit 2; }
if [ "$DRY" = 1 ]; then # tiny stub server, compiled once (outside SwiftPM, not part of the product)
  STUB_BIN=${H2H_STUB_BIN:-$H2H_SCRATCH/h2h-stub}
  if [ ! -x "$STUB_BIN" ] || [ "$H/stub/stub.swift" -nt "$STUB_BIN" ]; then swiftc -O "$H/stub/stub.swift" -o "$STUB_BIN" 2>"$H2H_SCRATCH/stub-build.txt" || { echo "stub build failed"; exit 2; }; fi
  : "${H2H_GATE:=0}"; : "${H2H_STOP_GRACE:=1}"; : "${H2H_SAMPLE_EVERY:=1}"; : "${H2H_WATCH_EVERY:=1}"; export H2H_WATCH_EVERY
fi
D=$OUT/$E/pass$P; mkdir -p "$D"
TMO=$(command -v timeout || command -v gtimeout || true)
URL=http://127.0.0.1:$PORT
SS=$(date +%s); SID=$SS-$$
PID=""; PGID=""; WD=""; LS=""; NEEDS_RESTART=0; GATE=OFF; ENDED_OK=0; STARTED_OK=0; STATUS_FORCE=""; CELLNOW=session
flag() { # flag NAME DETAIL -> flags.csv (epoch,session,cell,flag,detail) + steps.txt; never retried silently
  local d=${2//,/;}; echo "$(date +%s),$SID,$CELLNOW,$1,$d" >> "$D/flags.csv"; echo "[$(date +%T)] FLAG $CELLNOW $1 $d" >> "$D/steps.txt"
}
skip() { # skip FLAG DETAIL: session not run; recorded as INVALID so the summary shows a hole instead of silently missing data
  flag "$1" "$2"; jq -nc --arg e "$E" --argjson p "$P" --arg sid "$SID" --arg cells "$CELLS" --argjson s "$SS" --arg f "$1" --arg d "$2" '{engine:$e,pass:$p,session:$sid,cells:($cells|split(",")),start:$s,end:$s,gate:"OFF",status:"INVALID",polluted_cells:[],load_max:0,completed:false,flags:[{cell:"start",flag:$f,detail:$d}]}' >> "$D/sessions.jsonl"; exit 3
}
for i in $(seq 1 30); do lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 1; done
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "SKIP port $PORT busy"; skip port_busy "$PORT"; fi
if [ "$E" = omlx ] && [ "$DRY" != 1 ] && pgrep -f 'oMLX\.app/Contents/MacOS/oMLX$|omlx-cli' >/dev/null 2>&1 && [ "${H2H_OMLX_ALLOW_RUNNING:-0}" != 1 ]; then
  echo "SKIP an oMLX app/server is already running (quit oMLX.app first; H2H_OMLX_ALLOW_RUNNING=1 overrides)"; skip omlx_already_running "oMLX already running"
fi
BASEPIDS=$(mktemp "${TMPDIR:-/tmp}/h2h-base.XXXXXX"); pgrep -f "$PROC_PAT" 2>/dev/null | sort > "$BASEPIDS"
load1() { if [ -n "${H2H_FAKE_LOAD_FILE:-}" ] && [ -s "$H2H_FAKE_LOAD_FILE" ]; then cat "$H2H_FAKE_LOAD_FILE"; else sysctl -n vm.loadavg | awk '{print $2}'; fi; }
foreign() { # pid cpu command of non-benchmark processes above 60% CPU (H2H_NO_FOREIGN=1: dry-run test knob, reports none)
  [ "${H2H_NO_FOREIGN:-0}" = 1 ] && return
  ps -Ao pid=,%cpu=,command= | awk '$2>60 && $0 !~ /\/(ps|awk|footprint|curl|sysctl) / && $0 !~ / bench (http|scoreboard)/ && $0 !~ /qwen38|mlx_vlm|mlx_lm|rapid-mlx|omlx|oMLX|h2h-stub|pass\.sh/ {print}' | cut -c1-120
}
# Quiet gate (H2H_GATE=0 disables): wait until the 1-min load is < H2H_GATE_LOAD (4.5; relaxed from 3.0 because the Spotlight mds baseline holds the load at 3.5-4.2) for H2H_GATE_N (6) consecutive
# H2H_GATE_EVERY (30) s samples and no foreign process (not the engine tree, not a bench client) is above 60% CPU; at most H2H_GATE_MAX s (900). Logged to gate.txt.
if [ "${H2H_GATE:-1}" = 1 ]; then
  g0=$(date +%s); ok=0; echo "# gate for cells=$CELLS start $(date +%T) threshold=${H2H_GATE_LOAD:-4.5}" >> "$D/gate.txt"
  while :; do
    l=$(load1); f=$(foreign); now=$(( $(date +%s)-g0 ))
    if awk -v l="$l" -v t="${H2H_GATE_LOAD:-4.5}" 'BEGIN{exit !(l<t)}' && [ -z "$f" ]; then ok=$((ok+1)); else ok=0; fi
    echo "t=${now}s load=$l consec_ok=$ok foreign=[${f//$'\n'/ | }]" >> "$D/gate.txt"
    [ $ok -ge "${H2H_GATE_N:-6}" ] && { echo "GATE PASSED after ${now}s" >> "$D/gate.txt"; GATE=PASSED; break; }
    [ $now -ge "${H2H_GATE_MAX:-900}" ] && { echo "GATE TIMEOUT after ${now}s (proceeding, session flagged)" >> "$D/gate.txt"; GATE=TIMEOUT; flag gate_timeout "${now}s"; break; }
    sleep "${H2H_GATE_EVERY:-30}"
  done
fi
# Per-session sampler: every H2H_SAMPLE_EVERY s (30) the 1-min load and any foreign process above 60% CPU -> load.csv (epoch,cell,load1,foreign);
# one more sample at every cell start and end.
sample_now() { echo "$(date +%s),$(cat "$D/cell" 2>/dev/null),$(load1),\"$(foreign | tr '\n' ';')\"" >> "$D/load.csv"; }
( while :; do sample_now; sleep "${H2H_SAMPLE_EVERY:-30}"; done ) &
LS=$!; disown

echo "session $(date +%T) id=$SID engine=$E cells=$CELLS load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" >> "$D/steps.txt"
if [ "$DRY" = 1 ]; then echo "$E dry-run stub" >> "$D/versions.txt"; else engine_version "$E" >> "$D/versions.txt" 2>/dev/null; fi
tree() { local p; echo "$1"; for p in $(pgrep -P "$1" 2>/dev/null); do tree "$p"; done; }
seen_alive() { # pids recorded by the watchdog that are still the same process (start time matches)
  local line p ls; [ -s "$D/watch.csv.seen" ] || return
  while IFS='|' read -r p ls; do [ -n "$p" ] && [ "$(ps -o lstart= -p "$p" 2>/dev/null)" = "$ls" ] && echo "$p"; done < "$D/watch.csv.seen"
}
grp() { [ -n "$PGID" ] && ps -Ao pid=,pgid= | awk -v g="$PGID" '$2==g {print $1}'; }
stray() { # engine processes by name that were not running before this session, plus anything left in the engine process group (oMLX helpers that escaped the tree), minus ourselves
  { pgrep -f "$PROC_PAT" 2>/dev/null | sort | grep -vxF -f "$BASEPIDS"; grp; } | sort -u | grep -vx "$$"
}
suspects() { # orphans (ppid 1) younger than the engine and unknown before the session: reported (leftover_suspect), never killed; inspect with ps before the next session
  [ -n "${ESTART:-}" ] || return
  ps -Ao pid=,ppid=,user=,etime=,command= | awk -v u="$(id -un)" -v lim="$(( $(date +%s)-ESTART+3 ))" '$2==1 && $3==u { n=split($4,a,/[-:]/); s=a[n]+a[n-1]*60+(n>=3?a[n-2]*3600:0)+(n>=4?a[n-3]*86400:0); if (s<=lim) print $1 "|" substr($0, index($0,$5), 90) }' |
    grep -vE "^[0-9]+\|(/System/|/usr/libexec/|/Library/|/usr/sbin/|/sbin/|/opt/homebrew/opt/git/|git )" | while IFS="|" read -r p cmd; do grep -qx "$p" "$BASEPIDS" || flag leftover_suspect "pid $p $cmd"; done
}
stop_server() { # TERM -> grace -> KILL on the whole tree + every pid the watchdog ever saw; then verify nothing is left
  [ -n "$WD" ] && kill "$WD" 2>/dev/null; WD=""
  local v p left
  v="$( { [ -n "$PID" ] && tree "$PID"; seen_alive; stray; } 2>/dev/null | sort -u)"
  for p in $v; do kill -TERM "$p" 2>/dev/null; done; [ -n "$v" ] && sleep "${H2H_STOP_GRACE:-6}"
  for p in $v; do kill -KILL "$p" 2>/dev/null; done; sleep 1
  left="$( { for p in $v; do kill -0 "$p" 2>/dev/null && echo "$p"; done; stray; } | sort -u | tr '\n' ' ')"
  lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && left="$left port:$PORT"
  if [ -n "${left// /}" ]; then
    flag leftover_process "$left"
    for p in ${left//port:$PORT/}; do kill -KILL "$p" 2>/dev/null; done; sleep 2
    left="$( { stray; } | tr '\n' ' ')"; lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && left="$left port:$PORT"
    [ -n "${left// /}" ] && { flag leftover_unkillable "$left"; STATUS_FORCE=INVALID; }
  fi
  suspects
  PID=""; engine_cleanup
}
write_session() {
  local end st pol poll_max lp
  end=$(date +%s); st=CLEAN; lp=${H2H_POLLUTE_LOAD:-4.5}
  # POLLUTED = 2 consecutive samples with load > lp or a foreign process > 60% CPU; cell = the cell of the second sample
  pol=$(awk -F, -v s="$SS" -v t="$lp" '$1>=s && $2!="" && $2!="idle" { bad=($3+0>t) || ($4!="\"\"" && $4!=""); if (bad && prev) c[$2]=1; prev=bad } END{for(k in c) print k}' "$D/load.csv" 2>/dev/null | sort | tr '\n' ' ')
  poll_max=$(awk -F, -v s="$SS" '$1>=s && $3+0>m {m=$3+0} END{print m+0}' "$D/load.csv" 2>/dev/null)
  [ -n "${pol// /}" ] && st=POLLUTED
  [ "$GATE" = TIMEOUT ] && st=POLLUTED
  grep -q "^[0-9]*,$SID,[^,]*,\(start_failed\|leftover_unkillable\|port_busy\)," "$D/flags.csv" 2>/dev/null && st=INVALID
  [ "$STARTED_OK" = 1 ] || st=INVALID
  grep -q "^[0-9]*,$SID,warmup,\(cell_timeout\|cell_rc\|memory_abort_watchdog\|engine_guard_abort\|engine_oom\),"  "$D/flags.csv" 2>/dev/null && st=INVALID
  [ -n "$STATUS_FORCE" ] && st=$STATUS_FORCE
  jq -nc --arg e "$E" --argjson p "$P" --arg sid "$SID" --arg cells "$CELLS" --argjson s "$SS" --argjson en "$end" --arg gate "$GATE" --arg st "$st" \
     --arg pol "$pol" --argjson lmax "${poll_max:-0}" --argjson lp "$lp" --argjson dry "$DRY" --argjson done "$ENDED_OK" \
     --slurpfile fl <(awk -F, -v sid="$SID" '$2==sid {printf "{\"cell\":\"%s\",\"flag\":\"%s\",\"detail\":\"%s\"}\n",$3,$4,$5}' "$D/flags.csv" 2>/dev/null) \
     '{engine:$e,pass:$p,session:$sid,cells:($cells|split(",")),start:$s,end:$en,gate:$gate,status:$st,polluted_cells:($pol|split(" ")|map(select(length>0))),
       load_max:$lmax,pollute_load:$lp,dryrun:($dry==1),completed:($done==1),flags:$fl}' >> "$D/sessions.jsonl"
}
finish() {
  [ -n "$LS" ] && kill "$LS" 2>/dev/null; LS=""
  CELLNOW=shutdown; stop_server
  echo "end $(date +%T) load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" >> "$D/steps.txt"
  write_session; rm -f "$BASEPIDS"
}
trap finish EXIT
start_engine() {
  NEEDS_RESTART=0; engine_cmd
  { printf '[%s] launch:' "$(date +%T)"; printf ' %q' "${CMD[@]}"; echo; } >> "$D/launch.txt"
  ESTART=$(date +%s)
  set -m; "${CMD[@]}" >> "$D/server.txt" 2>&1 &
  PID=$!; PGID=$PID; disown; set +m; echo "$PID" >> "$D/pids"; echo idle > "$D/cell"
  "$H/watchdog.sh" "$PID" "$D/cell" "$D/watch.csv" & WD=$!; disown
  local i ready=0 t0=$(date +%s) why="not healthy after ${START_TMO}s"
  while [ $(( $(date +%s)-t0 )) -lt "$START_TMO" ]; do
    kill -0 "$PID" 2>/dev/null || { why="engine exited"; break; }
    if [ -n "$HEALTH_ID" ]; then curl -sf -m 2 "$URL/v1/models" 2>/dev/null | grep -q "$HEALTH_ID" && { ready=1; break; }
    else curl -sf -m 2 "$URL/v1/models" >/dev/null 2>&1 && { ready=1; break; }; fi
    sleep 1
  done
  if [ $ready = 1 ]; then echo "[$(date +%T)] engine pid $PID ready after $(( $(date +%s)-t0 ))s port $PORT tree=$(tree "$PID" | tr '\n' ' ')" >> "$D/steps.txt"; STARTED_OK=1; return 0; fi
  CELLNOW=start; flag start_failed "$why (see server.txt)"; return 1
}
SB=("$STRIM" bench http scoreboard --arm "$E=$URL,$MODEL" --reps 1 --timeout 900 --bench-dir "$ROOT/bench")
rewarm() { ${TMO:+$TMO $CELL_TMO} "${SB[@]}" --workloads W3 --w3-sizes 4096 --w3-gen 8 --out-dir "$D/rewarm" >/dev/null 2>&1 || flag rewarm_failed "rc=$?"; }
RESTARTS=0
ensure() { # restart (and re-warm) after a watchdog kill, a crash, a hang or an engine-side guard abort; the aborted cell is flagged, never retried
  local cur=$CELLNOW
  if [ "$NEEDS_RESTART" = 1 ] || ! kill -0 "$PID" 2>/dev/null; then
    local why=crash_or_watchdog; [ "$NEEDS_RESTART" = 1 ] && why=restart_after_flagged_cell
    echo "[$(date +%T)] engine restart ($why)" >> "$D/steps.txt"; CELLNOW=restart; flag engine_restart "$why"
    RESTARTS=$((RESTARTS+1))
    if [ $RESTARTS -gt "${H2H_MAX_RESTARTS:-3}" ]; then flag too_many_restarts "$RESTARTS"; STATUS_FORCE=INVALID; echo "too many restarts"; exit 4; fi
    stop_server; start_engine || { echo "restart failed"; exit 4; }; rewarm; CELLNOW=$cur
  fi
}
cache_note() { # cache-hit logging per cell: usage-reported cached tokens (rows with a null value = engine did not report)
  local f="$D/$1/raw.jsonl"; [ -s "$f" ] || return
  jq -sc --arg c "$1" --arg e "$E" --arg sid "$SID" '[.[]|select(.kind=="request")] | {engine:$e,session:$sid,cell:$c,rows:length,hit_rows:([.[]|select((.cached_tokens//0)>0)]|length),
     cached_tokens:([.[].cached_tokens|numbers]|add//0),unreported_rows:([.[]|select(.cached_tokens==null)]|length)}' "$f" 2>/dev/null >> "$D/cache.jsonl"
}
cell() { # name cmd...
  local n=$1; shift; CELLNOW=$n; ensure
  echo "$n" > "$D/cell"; local t0=$(date +%s) lo; lo=$(cat "$D/server.txt" 2>/dev/null | wc -c); local ab0; ab0=$(cat "$D/watch.csv.abort" 2>/dev/null | wc -l)
  sample_now; echo "[$(date +%T)] CELL $n load=$(sysctl -n vm.loadavg) timeout=${CELL_TMO}s" >> "$D/steps.txt"
  ${TMO:+$TMO $CELL_TMO} "$@" > "$D/$n.stdout.txt" 2>&1; local rc=$?
  sample_now
  local ab=no ab1; ab1=$(cat "$D/watch.csv.abort" 2>/dev/null | wc -l)
  if [ $((ab1)) -gt $((ab0)) ]; then ab=yes; flag memory_abort_watchdog "$(grep '^# ABORT' "$D/watch.csv" | tail -1)"; NEEDS_RESTART=1; fi
  [ $rc = 124 ] && { flag cell_timeout "${CELL_TMO}s"; NEEDS_RESTART=1; }
  [ $rc != 0 ] && [ $rc != 124 ] && [ $ab = no ] && flag cell_rc "$rc"
  local dl; dl=$(tail -c +"$((lo+1))" "$D/server.txt" 2>/dev/null)
  if [ -n "$dl" ]; then
    local g; g=$(echo "$dl" | grep -E -m1 "$GUARD_PAT")
    if [ -n "$g" ]; then
      case $g in *"Hard memory pressure"*|*"process memory limit"*|*"memory guard"*) flag engine_guard_abort "${g:0:200}";; *) flag engine_oom "${g:0:200}";; esac
      NEEDS_RESTART=1
    fi
    echo "[$(date +%T)] CACHELOG $n server_log_cache_lines=$(echo "$dl" | grep -ci cache)" >> "$D/steps.txt"
  fi
  cache_note "$n"
  echo "[$(date +%T)] CELL $n rc=$rc $(( $(date +%s)-t0 ))s memory_aborted=$ab" >> "$D/steps.txt"
  echo idle > "$D/cell"; [ $ab = yes ] && sleep "${H2H_ABORT_SETTLE:-8}"
  return 0
}
want() { case ",$CELLS," in *",$1,"*) return 0;; esac; return 1; }
start_engine || { echo "engine failed to start"; exit 4; }
cell warmup "${SB[@]}" --workloads W3 --w3-sizes 4096 --w3-gen 8 --out-dir "$D/warmup"
want agree  && cell agree  "$H/agree.sh" "$URL" "$MODEL" "$D/agree.json" "$ROOT/bench"
want w3     && cell w3     "${SB[@]}" --workloads W3 --w3-sizes 4096,16384 --w3-gen 256 --out-dir "$D/w3"
want w3_32k && cell w3_32k "${SB[@]}" --workloads W3 --w3-sizes 32768 --w3-gen 128 --out-dir "$D/w3_32k"
want w4     && cell w4     "${SB[@]}" --workloads W4 --conc 4,8 --w4-size 4096 --w4-gen 64 --out-dir "$D/w4"
want w4s    && cell w4s    "${SB[@]}" --workloads W4 --conc 4,8 --w4-size 512 --w4-gen 128 --out-dir "$D/w4s"
if want w6; then
  # W6 workload is pinned to the prompts generated from 2df65e7 (the revision of the original h2h-final run) so it stays the
  # same across runs although the source files change; override with H2H_PROMPTS_REV.
  "$H/agent-prompts.sh" "${H2H_PROMPTS_REV:-2df65e7}" > "$D/agent-prompts.json"
  cell w6 "${SB[@]}" --workloads W6 --conc 4,8 --w6-prompts "$D/agent-prompts.json" --w6-gen 128 --out-dir "$D/w6"
fi
want w5     && cell w5     "${SB[@]}" --workloads W5 --w5-gen 64 --out-dir "$D/w5"
want replay && cell replay "$STRIM" bench http replay --fixture "${H2H_FIXTURE:-bench/results/final-20261026/synthetic-8turn.json}" \
    --arm "$E=$URL,$MODEL,cache=on" --server-log "$E=$D/server.txt" --reps 1 --max-tokens 48 --out-dir "$D/replay"
CELLNOW=end
# the footprint watchdog must have seen the engine tree: a zero footprint with a non-zero RSS means footprint(1) could not read it
awk -F, -v s="$SS" '!/^#/ && $1>=s && $5+0==0 && $4+0>0 {n++} END{exit !(n>0)}' "$D/watch.csv" 2>/dev/null && flag footprint_blind "footprint(1) returned 0 for the engine tree while RSS was non-zero"
ENDED_OK=1
exit 0
