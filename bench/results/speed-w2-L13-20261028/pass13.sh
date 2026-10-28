#!/bin/bash
# L13 copy of bench/h2h/pass.sh: adds cell c148 (W4 512-token prompts, conc 1,4,8). STRIM_BIN, env knobs inherited.
# One engine session. usage (repo root, under the GPU lock): pass.sh ENGINE PASS CELLS OUTDIR
#   ENGINE strim|rapid-mlx|mlx-vlm   CELLS comma list of: agree w3 w3_32k w4 w4s w6 w5 replay  (warm-up always runs first)
# Needs a foreground shell (Metal cannot create a GPU stream from a detached process). Writes OUTDIR/ENGINE/passN/.
set -u
E=$1; P=$2; CELLS=$3; OUT=$4
H=${H2H_DIR:-$(cd "$(dirname "$0")/../../h2h" && pwd)}
ROOT=${H2H_ROOT:-$(git -C "$H" rev-parse --show-toplevel)}; cd "$ROOT" || exit 2
STRIM=${STRIM_BIN:-/tmp/strim-build-final/release/strim}
D=$OUT/$E/pass$P; mkdir -p "$D"
TMO=$(command -v timeout || command -v gtimeout || true)
case $E in
 strim) PORT=8203; MODEL=qwen38-4bit
   CMD=("$STRIM" serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth);;
 rapid-mlx) PORT=8651; MODEL=models/qwen38-4bit
   CMD=(rapid-mlx --no-telemetry serve models/qwen38-4bit --port 8651 --max-num-seqs 4 --speculative-config '{"method":"mtp","model":"models/qwen38-mtp-4bit"}');;
 mlx-vlm) PORT=8651; MODEL=$ROOT/models/qwen38-4bit
   CMD=("${MLXVLM_BIN:-$ROOT/.venv-sprint/bin/mlx_vlm.server}" --model "$ROOT/models/qwen38-4bit" --port 8651);;
 *) echo "unknown engine $E"; exit 2;;
esac
URL=http://127.0.0.1:$PORT
for i in $(seq 1 30); do lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 1; done
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "SKIP port $PORT busy"; exit 3; fi
PID=""; WD=""
echo "session $(date +%T) cells=$CELLS load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" >> "$D/steps.txt"
tree() { local p; echo "$1"; for p in $(pgrep -P "$1" 2>/dev/null); do tree "$p"; done; }
stop_engine() {
  [ -n "$WD" ] && kill "$WD" 2>/dev/null
  [ -n "$PID" ] || return
  local ps; ps=$(tree "$PID"); for p in $ps; do kill -TERM "$p" 2>/dev/null; done; sleep 6
  for p in $ps; do kill -KILL "$p" 2>/dev/null; done; PID=""
}
trap stop_engine EXIT
start_engine() {
  "${CMD[@]}" >> "$D/server.txt" 2>&1 &
  PID=$!; echo "$PID" >> "$D/pids"; echo idle > "$D/cell"
  "$H/watchdog.sh" "$PID" "$D/cell" "$D/watch.csv" & WD=$!
  local i; for i in $(seq 1 240); do curl -s -m 2 "$URL/v1/models" >/dev/null && break; kill -0 "$PID" 2>/dev/null || break; sleep 1; done
  echo "[$(date +%T)] engine pid $PID ready after ${i}s" >> "$D/steps.txt"
}
SB=("$STRIM" bench http scoreboard --arm "$E=$URL,$MODEL" --reps 1 --timeout 900 --bench-dir "$ROOT/bench")
ensure() { # restart the engine (and re-warm) if the watchdog or a crash killed it
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "[$(date +%T)] engine dead, restarting" >> "$D/steps.txt"; kill "$WD" 2>/dev/null
    start_engine; "${SB[@]}" --workloads W3 --w3-sizes 4096 --w3-gen 8 --out-dir "$D/rewarm" >/dev/null 2>&1
  fi
}
cell() { # name cmd...
  local n=$1; shift; ensure
  echo "$n" > "$D/cell"; local t0=$(date +%s)
  echo "[$(date +%T)] CELL $n load=$(sysctl -n vm.loadavg)" >> "$D/steps.txt"
  ${TMO:+$TMO ${CELL_TIMEOUT:-900}} "$@" > "$D/$n.stdout.txt" 2>&1; local rc=$?
  local ab=no; grep -qx "$n" "$D/watch.csv.abort" 2>/dev/null && ab=yes
  echo "[$(date +%T)] CELL $n rc=$rc $(( $(date +%s)-t0 ))s memory_aborted=$ab" >> "$D/steps.txt"
  echo idle > "$D/cell"; [ $ab = yes ] && sleep 8
}
want() { case ",$CELLS," in *",$1,"*) return 0;; esac; return 1; }
start_engine
cell warmup "${SB[@]}" --workloads W3 --w3-sizes 4096 --w3-gen 8 --out-dir "$D/warmup"
want agree  && cell agree  "$H/agree.sh" "$URL" "$MODEL" "$D/agree.json" "$ROOT/bench"
want w3     && cell w3     "${SB[@]}" --workloads W3 --w3-sizes 4096,16384 --w3-gen 256 --out-dir "$D/w3"
want w3_32k && cell w3_32k "${SB[@]}" --workloads W3 --w3-sizes 32768 --w3-gen 128 --out-dir "$D/w3_32k"
want c148   && cell c148   "${SB[@]}" --workloads W4 --conc 1,4,8 --w4-size 512 --w4-gen 128 --out-dir "$D/c148"
want w4     && cell w4     "${SB[@]}" --workloads W4 --conc 4,8 --w4-size 4096 --w4-gen 64 --out-dir "$D/w4"
want w4s    && cell w4s    "${SB[@]}" --workloads W4 --conc 4,8 --w4-size 512 --w4-gen 128 --out-dir "$D/w4s"
if want w6; then
  "$H/agent-prompts.sh" HEAD > "$D/agent-prompts.json"
  cell w6 "${SB[@]}" --workloads W6 --conc 4,8 --w6-prompts "$D/agent-prompts.json" --w6-gen 128 --out-dir "$D/w6"
fi
want w5     && cell w5     "${SB[@]}" --workloads W5 --w5-gen 64 --out-dir "$D/w5"
want replay && cell replay "$STRIM" bench http replay --fixture "${H2H_FIXTURE:-bench/results/final-20261026/synthetic-8turn.json}" \
    --arm "$E=$URL,$MODEL,cache=on" --server-log "$E=$D/server.txt" --reps 1 --max-tokens 48 --out-dir "$D/replay"
echo "end $(date +%T) load=$(sysctl -n vm.loadavg) swap=$(sysctl -n vm.swapusage)" >> "$D/steps.txt"
exit 0
