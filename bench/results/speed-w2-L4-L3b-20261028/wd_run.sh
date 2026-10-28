#!/bin/bash
# usage: wd_run.sh OUT_FILE CMD [ARGS...]   (run under: lockf -t 500 -k /tmp/strim-bench.lock ...)
# Runs CMD with stdout+stderr to OUT_FILE and the repo's memory watchdog (SIGTERM at footprint > 42 GB or
# swap growth > 2 GB). Prints load average, watchdog verdict and the exit status.
out=$1; shift
root=${H2H_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
cell=$(mktemp /tmp/l0-cell.XXXXXX); csv="${out%.txt}.mem.csv"; rm -f "$csv" "$csv.abort"
basename "$out" > "$cell"
echo "load: $(uptime | sed 's/.*load averages*: //')" > "${out%.txt}.load"
"$@" > "$out" 2>&1 &
pid=$!
bash "$root/bench/h2h/watchdog.sh" $pid "$cell" "$csv" &
wd=$!
wait $pid; rc=$?
kill $wd 2>/dev/null; wait $wd 2>/dev/null
echo "load end: $(uptime | sed 's/.*load averages*: //')" >> "${out%.txt}.load"
rm -f "$cell"
peak=$(awk -F, '!/^#/ {if ($5>m) m=$5} END{print m+0}' "$csv")
echo "rc=$rc peak_footprint_mb=$peak abort=$([ -f "$csv.abort" ] && echo YES || echo no)"
