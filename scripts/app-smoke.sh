#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
render=0
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && "$1" == --with-render ]]; then render=1; else echo 'usage: scripts/app-smoke.sh [--with-render]' >&2; exit 2; fi
fi
if [[ -z "${STRIM_SCRATCH:-}" || ! -d "$STRIM_SCRATCH/checkouts" || ! -f "$STRIM_SCRATCH/workspace-state.json" ]]; then
  echo 'FAIL: STRIM_SCRATCH must name an existing warm Swift scratch directory.' >&2; exit 2
fi
scratch=$(cd "$STRIM_SCRATCH" && pwd -P) || exit 2
start=$SECONDS
tmp=$(mktemp -d "${TMPDIR:-/tmp/}strim-app-smoke.XXXXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
if ! nice -n 19 swift build --product strim --scratch-path "$scratch" >"$tmp/build.log" 2>&1; then
  echo 'FAIL: strim build'; tail -30 "$tmp/build.log"; exit 1
fi
binary="$scratch/debug/strim"
if [[ ! -x "$binary" ]]; then echo "FAIL: built binary missing at $binary"; exit 1; fi
# Servers the tests launched from this scratch binary must never outlive the run, even when a scenario fails.
stop_test_servers() {
  local pids
  pids=$(pgrep -f "^$binary serve" || true)
  [[ -z "$pids" ]] && return
  kill -TERM $pids 2>/dev/null
  for _ in 1 2 3 4 5 6; do pgrep -f "^$binary serve" >/dev/null || return; sleep 0.5; done
  echo "WARN: leaked test server(s) $pids still alive; sending SIGKILL"
  kill -KILL $(pgrep -f "^$binary serve") 2>/dev/null
}
trap 'stop_test_servers; rm -rf "$tmp"' EXIT
result=0
STRIM_E2E=1 STRIM_BIN="$binary" nice -n 19 swift test --scratch-path "$scratch" --filter StrimAppE2ETests >"$tmp/tests.log" 2>&1 || result=$?
awk '/^[✔✘] Test / {print}' "$tmp/tests.log"
if [[ $result -ne 0 ]]; then
  echo 'FAIL: app E2E suite'
  grep -E 'recorded an issue|Expectation failed|error:|S[1-8]:' "$tmp/tests.log" | head -40 || true
fi
if [[ $render -eq 1 ]]; then
  echo 'this opens windows on your screen'
  if ! nice -n 19 swift build --product StrimApp --scratch-path "$scratch" >"$tmp/app-build.log" 2>&1; then
    echo 'FAIL: app build'; tail -20 "$tmp/app-build.log"; result=1
  else
    mkdir "$tmp/shots"
    if ! "$scratch/debug/StrimApp" --snapshots "$tmp/shots" --projects --sizes 640x460,800x560,1440x900 >"$tmp/render.log" 2>&1; then
      echo 'FAIL: snapshot render'; tail -20 "$tmp/render.log"; result=1
    else
      for size in 640x460 800x560 1440x900; do
        for theme in dark light; do
          for state in generating queued missing divider error scratch empty; do
            file="$tmp/shots/projects-$state-$size-$theme.png"
            if [[ ! -f "$file" || $(stat -f %z "$file") -le 5120 ]]; then echo "FAIL: missing or small $file"; result=1; continue; fi
            dims=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {print w "x" $2}')
            w=${size%x*}; h=${size#*x}
            if [[ "$dims" != "$((w*2))x$((h*2))" ]]; then echo "FAIL: $file is $dims"; result=1; fi
          done
        done
      done
      for file in "$tmp/shots"/*.png; do
        [[ -f "$file" && $(stat -f %z "$file") -gt 5120 ]] || { echo "FAIL: missing or small $file"; result=1; }
        case "$(basename "$file")" in
          projects-sidebar-open-640x460-*) expected=1280x920 ;;
          projects-settings-*) expected=1040x1040 ;;
          *) continue ;;
        esac
        dims=$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {print w "x" $2}')
        [[ "$dims" == "$expected" ]] || { echo "FAIL: $file is $dims, expected $expected"; result=1; }
      done
      for theme in dark light; do
        for file in "projects-sidebar-open-640x460-$theme.png" "projects-settings-chat-$theme.png" "projects-settings-about-$theme.png"; do
          [[ -f "$tmp/shots/$file" ]] || { echo "FAIL: missing $file"; result=1; }
        done
      done
      [[ $result -ne 0 ]] || echo 'PASS: snapshot renders'
    fi
  fi
fi
echo "Total: $((SECONDS-start))s"
exit "$result"
