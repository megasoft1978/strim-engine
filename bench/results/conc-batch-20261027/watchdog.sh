#!/bin/bash
# usage: watchdog.sh PID OUT.csv  -- samples phys_footprint (footprint(1)) + swap every 3 s.
# Kills PID and writes OUT.csv.abort if footprint > 42 GB or swap used grew > 2 GB over the start value.
PID=$1; OUT=$2
swap() { sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/'; }
S0=$(swap); echo "# t,footprint_mb,swap_mb (swap0=$S0)" > "$OUT"
while kill -0 "$PID" 2>/dev/null; do
  F=$(footprint "$PID" 2>/dev/null | awk '/Footprint:/ { for(i=1;i<=NF;i++) if($i=="Footprint:"){v=$(i+1);u=$(i+2)}
        if (u ~ /GB/) v*=1024; else if (u ~ /KB/) v/=1024; print int(v); exit }')
  S=$(swap)
  echo "$(date +%s),${F:-0},$S" >> "$OUT"
  if [ "${F:-0}" -gt 43008 ] || [ "$(echo "$S - $S0 > 2048" | bc)" = 1 ]; then
    echo "ABORT footprint=${F}MB swap=${S}MB (swap0=$S0)" > "$OUT.abort"; kill -TERM "$PID"; exit 2
  fi
  sleep 3
done
