#!/bin/bash
# usage: guard.sh LOG CMD...   Runs CMD, polls phys_footprint every 2 s, SIGKILLs at > 30 GB or swap growth > 1 GB.
LOG=$1; shift
SW0=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9]*\).*/\1/p')
"$@" > $LOG 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
  FP=$(footprint -p $PID -f bytes 2>/dev/null | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p' | head -1)
  SW=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9]*\).*/\1/p')
  LIM=${GUARD_MB:-30000}
  if [ $(( ${FP:-0} / 1048576 )) -gt $LIM ] || [ $(( SW - SW0 )) -gt 1024 ]; then kill -9 $PID; echo "GUARD KILL" >> $LOG; break; fi
  echo "$(( ${FP:-0} / 1048576 )) MB swap+$(( SW - SW0 )) MB" >> $LOG.fp
  sleep 2
done
wait $PID 2>/dev/null; echo "exit $?" >> $LOG
