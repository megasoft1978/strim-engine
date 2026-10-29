#!/usr/bin/env bash
# Build the release tarball from an existing SwiftPM release build. Does not build, upload or publish.
#
#   packaging/release/make-release.sh [--build-dir DIR] [--out DIR] [--sign-identity "Developer ID Application: ..."]
#
# --build-dir  directory holding `strim` and the SwiftPM resource bundles (default: .build/release)
# --out        output directory (default: dist/)
#
# Output: strim-<version>-arm64-macos.tar.gz and .sha256 (the .sha256 holds only the hex digest).
# Tarball layout (top dir strim-<version>/):
#   libexec/strim                          real binary
#   libexec/mlx-swift_Cmlx.bundle/         holds default.metallib; MLX finds it next to the REAL binary
#   libexec/Strim_StrimHarness.bundle/     harness prompt pack (Bundle.module)
#   LICENSE NOTICE
# The binary resolves resources relative to its own (unresolved) path, so a plain symlink into bin/ does NOT
# work (metallib not found). bin/strim must be an exec wrapper script (Homebrew: bin.write_exec_script).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
build="$root/.build/release"
out="$root/dist"
identity=""
while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir) build="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --sign-identity) identity="$2"; shift 2 ;;
    -h|--help) sed -n 2,16p "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

build="$(cd "$build" && pwd)"
# shellcheck source=layout.sh
. "$root/packaging/release/layout.sh"
strim_check_build "$build" || exit 1

# Version = second word of the first line of `strim --version` ("strim 0.1.0").
version="$(strim_version "$build")" || exit 1
name="strim-$version-arm64-macos"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/strim-$version"
mkdir -p "$out"
strim_stage_cli "$build" "$stage/libexec"
cp "$root/LICENSE" "$root/NOTICE" "$stage/"

# Signing. Default: keep the linker's ad-hoc signature (enough to run on Apple Silicon locally).
# OWNER-GATED: Developer ID signing + notarization slot in HERE, before the tarball is made:
#   codesign --force --options runtime --timestamp --sign "Developer ID Application: NAME (TEAMID)" libexec/strim
#   zip the binary, `xcrun notarytool submit --wait`, (bare Mach-O cannot be stapled; Gatekeeper checks online).
# Without it, files downloaded by a browser carry quarantine and Gatekeeper may block them; curl/brew downloads
# do not set quarantine, which is why the install paths are Homebrew and curl, not "download in Safari".
if [ -n "$identity" ]; then
  codesign --force --options runtime --timestamp --sign "$identity" "$stage/libexec/strim"
fi
sig="$(codesign -dv "$stage/libexec/strim" 2>&1)" || { echo "codesign -dv failed: binary is unsigned" >&2; exit 1; }
echo "$sig" | grep -E "Signature=|flags=|TeamIdentifier=" | sed 's/^/codesign: /'
if ! echo "$sig" | grep -q "TeamIdentifier=[A-Z0-9]\{10\}"; then
  echo "note: ad-hoc signed only (no Developer ID / notarization; owner-gated)" >&2
fi
codesign --verify --strict "$stage/libexec/strim" 2>&1 | sed 's/^/codesign verify: /' || true

# Deterministic archive: fixed mtime, sorted names, numeric owner 0:0, no xattrs/AppleDouble, gzip -n.
find "$work" -exec touch -h -t 202001010000 {} +
(
  cd "$work"
  find "strim-$version" -print | LC_ALL=C sort > "$work/list"
  COPYFILE_DISABLE=1 tar --format ustar --no-xattrs --uid 0 --gid 0 --uname root --gname wheel \
      -cf - -T "$work/list" --no-recursion | gzip -n -9 > "$out/$name.tar.gz"
)
digest="$(shasum -a 256 "$out/$name.tar.gz" | awk '{print $1}')"
echo "$digest" > "$out/$name.tar.gz.sha256"

echo "wrote $out/$name.tar.gz"
echo "sha256 $digest"
echo "formula: set  version \"$version\"  and  sha256 \"$digest\"  in packaging/homebrew/strim.rb"
