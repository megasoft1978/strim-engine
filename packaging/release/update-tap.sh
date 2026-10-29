#!/usr/bin/env bash
# Rewrite version + sha256 in the Homebrew formula and cask (files in a checkout of the tap, or in this repo).
#
#   packaging/release/update-tap.sh --tap-dir DIR --version 0.1.0 --tarball-sha HEX --dmg-sha HEX
#
# Edits DIR/Formula/strim.rb and DIR/Casks/strim-app.rb in place. The url lines are derived from `version`
# (cask: #{version} interpolation; formula: the version is substituted in the literal url).
set -euo pipefail
dir=""; version=""; tsha=""; dsha=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tap-dir) dir="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --tarball-sha) tsha="$2"; shift 2 ;;
    --dmg-sha) dsha="$2"; shift 2 ;;
    -h|--help) sed -n 2,7p "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
hex() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad --version '$version'" >&2; exit 2; }
hex "$tsha" || { echo "bad --tarball-sha" >&2; exit 2; }
hex "$dsha" || { echo "bad --dmg-sha" >&2; exit 2; }
f="$dir/Formula/strim.rb"; c="$dir/Casks/strim-app.rb"
[ -f "$f" ] && [ -f "$c" ] || { echo "need $f and $c" >&2; exit 1; }

# Formula: literal url with the version in it.
sed -E -i.bak \
  -e "s#(releases/download/v)[0-9]+\.[0-9]+\.[0-9]+(/strim-)[0-9]+\.[0-9]+\.[0-9]+(-arm64-macos\.tar\.gz)#\1${version}\2${version}\3#" \
  -e "s#^(  sha256 \")[0-9a-f]{64}(\")#\1${tsha}\2#" "$f"
# Cask: version line + sha256.
sed -E -i.bak \
  -e "s#^(  version \")[0-9]+\.[0-9]+\.[0-9]+(\")#\1${version}\2#" \
  -e "s#^(  sha256 \")[0-9a-f]{64}(\")#\1${dsha}\2#" "$c"
rm -f "$f.bak" "$c.bak"
grep -q "v${version}/strim-${version}-arm64-macos.tar.gz" "$f" && grep -q "sha256 \"$tsha\"" "$f" || { echo "formula not updated" >&2; exit 1; }
grep -q "version \"$version\"" "$c" && grep -q "sha256 \"$dsha\"" "$c" || { echo "cask not updated" >&2; exit 1; }
echo "updated $f and $c to $version"
