#!/bin/bash
# Memory watchdog. usage: watchdog.sh ENGINE_PID CELL_FILE CSV
# Every 5 s samples the engine process tree: phys_footprint (footprint(1); includes Metal buffers), RSS and system swap used.
# Appends: epoch,cell,swap_used_mb,rss_mb,footprint_mb. SIGTERMs the tree and appends the cell name to CSV.abort when
# footprint > H2H_MAX_FOOTPRINT_MB (default 43008 = 42 GB) or swap grew > H2H_MAX_SWAP_GROW_MB (default 2048) over the swap at start.
PID=$1; CELLF=$2; CSV=$3
MAXF=${H2H_MAX_FOOTPRINT_MB:-43008}; MAXS=${H2H_MAX_SWAP_GROW_MB:-2048}; EVERY=${H2H_WATCH_EVERY:-5}
swap_mb() { sysctl -n vm.swapusage | awk '{for(i=1;i<=NF;i++) if($i=="used"){v=$(i+2); sub(/M$/,"",v); print int(v)}}'; }
tree() { local p; echo "$1"; for p in $(pgrep -P "$1" 2>/dev/null); do tree "$p"; done; }
BASE=$(swap_mb)
echo "# base_swap_mb=$BASE start=$(date +%s)" >> "$CSV"
while kill -0 "$PID" 2>/dev/null; do
  PIDS=$(tree "$PID" | tr '\n' ' ')
  args=(); for p in $PIDS; do args+=("$p"); done
  FP=$(footprint -f bytes "${args[@]}" 2>/dev/null | awk '/\[[0-9]+\]: .*Footprint: [0-9]+ B/ {for(i=1;i<=NF;i++) if($i=="Footprint:"){s+=$(i+1)}} END{printf "%d", s/1048576}')
  RSS=$(ps -o rss= -p "$(echo $PIDS | tr ' ' ',')" 2>/dev/null | awk '{s+=$1} END{printf "%d", s/1024}')
  SW=$(swap_mb); CELL=$(cat "$CELLF" 2>/dev/null || echo idle)
  echo "$(date +%s),$CELL,$SW,${RSS:-0},${FP:-0}" >> "$CSV"
  if [ "${FP:-0}" -gt "$MAXF" ] || [ $((SW - BASE)) -gt "$MAXS" ]; then
    echo "$CELL" >> "$CSV.abort"
    echo "# ABORT cell=$CELL footprint_mb=$FP swap_grow_mb=$((SW - BASE)) $(date +%s)" >> "$CSV"
    for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
    exit 0
  fi
  sleep "$EVERY"
done
