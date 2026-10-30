#!/bin/bash
# Run from a clean commit; artifacts are written only to an empty output directory.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
scratch=/tmp/strim-build-e2e
out="$root/dist"
identity= profile= skip_model=0
while (($#)); do
  case "$1" in
    --sign|--notarize|--scratch|--out)
      (($# >= 2)) && [[ -n "$2" ]] || { echo "missing value for $1" >&2; exit 2; }
      case "$1" in --sign) identity=$2;; --notarize) profile=$2;; --scratch) scratch=$2;; --out) out=$2;; esac
      shift 2;;
    --skip-model) skip_model=1; shift;;
    -h|--help) echo 'usage: release-gate.sh [--sign identity --notarize profile] [--skip-model] [--scratch warm-dir] [--out empty-dir]'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[[ -z "$profile" || -n "$identity" ]] || { echo '--notarize requires --sign' >&2; exit 2; }
start=$SECONDS
work=$(mktemp -d "${TMPDIR:-/tmp/}strim-release-gate.XXXXXXXX")
steps=() results=() durations=()
current= current_start=0 output_owned=0
cleanup() {
  local code=$? binary pid
  trap - EXIT INT TERM HUP
  if [[ -n "$current" ]]; then steps+=("$current"); results+=(FAIL); durations+=("$((SECONDS-current_start))"); fi
  # Only servers whose executable path belongs to this run can be terminated.
  for binary in "$work/test-build/debug/strim" "$work/release-build/out/Products/Release/strim" "$work/packaged-cli-placeholder"; do
    [[ "$binary" != "$work/packaged-cli-placeholder" ]] || { [[ $output_owned == 1 ]] || continue; binary="$out/Strim.app/Contents/Resources/strim"; }
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep .5; done
      if kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o command= | awk -v prefix="$binary serve" 'index($0, prefix " ") == 1 || $0 == prefix { found=1 } END { exit !found }'; then kill -KILL "$pid" 2>/dev/null || true; fi
    done < <(ps -axo pid=,command= | awk -v prefix="$binary serve" '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if (index($0, prefix " ") == 1 || $0 == prefix) print pid }')
  done
  rm -rf "$work"
  printf '\n%-25s %-6s %s\n' STEP RESULT SECONDS
  for ((i=0; i<${#steps[@]}; i++)); do printf '%-25s %-6s %s\n' "${steps[i]}" "${results[i]}" "${durations[i]}"; done
  printf 'Total: %ss\n' "$((SECONDS-start))"
  if ((code == 0)); then echo 'GATE PASS'; else echo 'GATE FAIL'; fi
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
step() {
  current=$1; shift; current_start=$SECONDS
  echo "==> $current"
  if "$@"; then
    steps+=("$current"); results+=(PASS); durations+=("$((SECONDS-current_start))"); current=
  else
    echo "FAIL: $current" >&2
    return 1
  fi
}
preflight() {
  cd "$root" || return
  "$root/packaging/release/check-python-paths.sh" || return
  git diff --quiet && git diff --cached --quiet || { echo 'tracked working tree is dirty' >&2; return 1; }
  [[ -d "$scratch/checkouts" && -f "$scratch/workspace-state.json" ]] || { echo "warm scratch missing: $scratch" >&2; return 1; }
  # The warm scratch seeds the release build: refuse one another user owns or can write (planted dependencies).
  [[ -O "$scratch" ]] || { echo "warm scratch not owned by you: $scratch" >&2; return 1; }
  if [[ -n "$(/usr/bin/find "$scratch" -maxdepth 2 \( -perm -0020 -o -perm -0002 \) -print -quit)" || -n "$(/usr/bin/find "$scratch" -maxdepth 2 ! -user "$(id -u)" -print -quit)" ]]; then
    echo "warm scratch has group/world-writable or foreign-owned entries: $scratch" >&2; return 1
  fi
  # Do not create output in the user's model or configuration directory.
  local parent base
  parent=$(dirname "$out"); base=$(basename "$out")
  [[ -d "$parent" ]] || { echo "output parent does not exist: $parent" >&2; return 1; }
  parent=$(cd "$parent" && pwd -P) || return
  out="$parent/$base"
  local protected
  protected="$(cd "$HOME" && pwd -P)/.strim"
  if [[ -d "$out" ]]; then out=$(cd "$out" && pwd -P) || return; fi
  case "$out" in "$protected"|"$protected/"*) echo 'output under ~/.strim is forbidden' >&2; return 1;; esac
  [[ ! -e "$out" || ( -d "$out" && -z "$(find "$out" -mindepth 1 -maxdepth 1 -print -quit)" ) ]] || { echo "output must be an empty directory: $out" >&2; return 1; }
  mkdir -p "$out" || return
  out=$(cd "$out" && pwd -P) || return
  version=$(tr -d '[:space:]' < VERSION)
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'invalid VERSION' >&2; return 1; }
  [[ $(sed -nE 's/^[[:space:]]*public static let current = "([^"]+)".*/\1/p' Sources/StrimAPI/Version.swift) == "$version" ]] || { echo 'Version.swift mismatch' >&2; return 1; }
  [[ $(grep -m 1 '^# ' RELEASE_NOTES.md) == "# Strim $version" ]] || { echo 'release notes mismatch' >&2; return 1; }
  for f in packaging/homebrew/strim.rb packaging/homebrew/Casks/strim-app.rb; do
    grep -Fq "version \"$version\"" "$f" || grep -Fq "/v$version/" "$f" || echo "WARN: $f version differs from $version"
  done
  [[ $skip_model == 1 || -d "$HOME/.strim/models/qwen38-4bit" ]] || { echo 'model missing; use --skip-model for a dry run' >&2; return 1; }
  command -v timeout >/dev/null || { echo 'timeout command required' >&2; return 1; }
}
snapshot() {
  mkdir "$work/test-tree" || return
  git -C "$root" archive HEAD | tar -x -C "$work/test-tree" || return
  cp -R "$scratch" "$work/test-build" || return
}
all_tests() {
  (cd "$work/test-tree" && nice -n 19 swift test --scratch-path "$work/test-build") 2>&1 | tee "$work/tests.log" || return
  grep -E 'Executed [0-9]+ tests|Test run with [0-9]+ tests? in [0-9]+ suites?' "$work/tests.log" | tail -3 || true
}
smoke() { (cd "$work/test-tree" && STRIM_SCRATCH="$work/test-build" scripts/app-smoke.sh); }
release_build() {
  (cd "$root" && packaging/release/publish-tree.sh "$work/release-tree") || return
  cp -R "$scratch" "$work/release-build" || return
  rm -rf "$work/release-build/out" "$work/release-build/manifest.pif" "$work/release-build/release" "$work/release-build/debug" || return
  find "$work/release-tree/Sources" -name '*.swift' -exec touch {} + || return
  (cd "$work/release-tree" && nice -n 19 swift build -c release --scratch-path "$work/release-build" --product StrimApp) || return
  (cd "$work/release-tree" && nice -n 19 swift build -c release --scratch-path "$work/release-build" --product strim) || return
}
package() {
  local build="$work/release-build/out/Products/Release"
  output_owned=1
  local sign=() notary=()
  [[ -z "$identity" ]] || sign=(--sign-identity "$identity")
  [[ -z "$profile" ]] || notary=(--notarize "$profile")
  "$work/release-tree/packaging/release/make-release.sh" --build-dir "$build" --out "$out" ${sign[@]+"${sign[@]}"} || return
  "$work/release-tree/packaging/app/make-app.sh" --build-dir "$build" --out "$out" ${sign[@]+"${sign[@]}"} ${notary[@]+"${notary[@]}"} || return
}
selftest() {
  local model=(--model "$HOME/.strim/models/qwen38-4bit")
  [[ $skip_model == 0 ]] || model=(--no-model)
  mkdir "$work/selftest" || return
  timeout 600 "$out/Strim.app/Contents/MacOS/Strim" --selftest "$work/selftest" "${model[@]}" || return
  /usr/bin/swift - "$work/selftest/selftest.json" "$version" "$skip_model" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
func fail(_ message: String) -> Never { fputs("selftest report: \(message)\n", stderr); exit(1) }
guard let data = try? Data(contentsOf: URL(fileURLWithPath: a[1])),
      let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      r["version"] as? String == a[2], r["windows"] as? Int == 0,
      let checks = r["checks"] as? [[String: Any]], !checks.isEmpty else { fail("invalid report, version, or windows") }
for c in checks { if c["skipped"] as? Bool != true && c["ok"] as? Bool != true { fail("failed check \(c["name"] ?? "unknown")") } }
for name in ["bundle-version", "cli-version", "blank-model-default", "no-windows"] + (a[3] == "0" ? ["health-version", "quit-owned-server"] : []) {
    guard let c = checks.first(where: { $0["name"] as? String == name }), c["ok"] as? Bool == true, c["skipped"] as? Bool == false else { fail("missing, failed, or skipped \(name)") }
}
SWIFT
}
dmg() {
  local sign=() notary=()
  [[ -z "$identity" ]] || sign=(--sign-identity "$identity")
  [[ -z "$profile" ]] || notary=(--notarize "$profile")
  "$work/release-tree/packaging/app/make-dmg.sh" --app "$out/Strim.app" --out "$out" --no-layout ${sign[@]+"${sign[@]}"} ${notary[@]+"${notary[@]}"}
}
checks() {
  local tarball="$out/strim-$version-arm64-macos.tar.gz" dmgfile="$out/Strim-$version-arm64.dmg"
  [[ $(find "$out" -name Strim.app -type d | wc -l | tr -d ' ') == 1 ]] || { echo 'expected exactly one Strim.app' >&2; return 1; }
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$out/Strim.app/Contents/Info.plist") == "$version" ]] || return 1
  [[ $("$out/Strim.app/Contents/Resources/strim" --version) == "strim $version" ]] || return 1
  mkdir "$work/tar" || return
  tar -xzf "$tarball" -C "$work/tar" || return
  if [[ -n "$(find "$work/tar" "$out/Strim.app" -type d -name envs -print -quit)" ]]; then
    echo 'envs directory found in release artifact' >&2; return 1
  fi
  [[ $("$work/tar/strim-$version/libexec/strim" --version) == "strim $version" ]] || return 1
  if [[ -n "$identity" ]]; then
    codesign --verify --deep --strict "$out/Strim.app" || return
    codesign --verify --strict "$dmgfile" || return
    spctl -a -vv "$out/Strim.app" || return
    spctl -a -vv -t open --context context:primary-signature "$dmgfile" || return
  fi
  shasum -a 256 "$tarball" "$dmgfile"
}
step Preflight preflight
step Snapshot snapshot
step 'All tests' all_tests
step 'Headless E2E' smoke
step 'Clean release build' release_build
step Packaging package
step 'Packaged self-test' selftest
step DMG dmg
step 'Artifact checks' checks
