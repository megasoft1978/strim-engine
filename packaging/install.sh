#!/usr/bin/env bash
# Strim installer (Apple Silicon, macOS 14+). No sudo. Installs under ~/.local/strim, wrapper in ~/.local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash
#   ... | bash -s -- --version 0.1.0 --prefix ~/.local
#
# Options:  --version X.Y.Z   (default: latest release)
#           --prefix DIR      (default: $HOME/.local; files go to DIR/strim, wrapper to DIR/bin/strim)
# Env:      STRIM_RELEASE_BASE  override the download base URL (tests use file://). Layout under it:
#           <base>/v<version>/strim-<version>-arm64-macos.tar.gz and .tar.gz.sha256
# Only the downloaded tarball is used, and only after its SHA-256 matches. Nothing downloaded is executed
# before verification, and no remote text is passed to eval.
set -euo pipefail

repo="megasoft1978/strim-engine"
base="${STRIM_RELEASE_BASE:-https://github.com/$repo/releases/download}"
version=""
prefix="$HOME/.local"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version="${2#v}"; shift 2 ;;
    --prefix)  [ $# -ge 2 ] || die "--prefix needs a value"; prefix="$2"; shift 2 ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done
prefix="${prefix/#\~/$HOME}"

[ "$(uname -s)" = Darwin ] || die "macOS only"
[ "$(uname -m)" = arm64 ] || die "Apple Silicon (arm64) only; this machine is $(uname -m)"
macos="$(sw_vers -productVersion)"
[ "${macos%%.*}" -ge 14 ] || die "macOS 14 or newer required (found $macos)"
command -v curl >/dev/null || die "curl not found"
command -v shasum >/dev/null || die "shasum not found"

if [ -z "$version" ]; then
  # Resolve the latest release tag from the redirect target; no JSON parsing.
  loc="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "https://github.com/$repo/releases/latest")" || die "cannot resolve latest release"
  version="${loc##*/v}"
  [ -n "$version" ] && [ "$version" != "$loc" ] || die "cannot resolve latest release; pass --version"
fi
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "bad version '$version'" ;;
esac

name="strim-$version-arm64-macos.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading strim $version"
curl -fsSL "$base/v$version/$name" -o "$tmp/$name" || die "download failed: $base/v$version/$name"
curl -fsSL "$base/v$version/$name.sha256" -o "$tmp/$name.sha256" || die "checksum download failed"
want="$(awk '{print $1}' "$tmp/$name.sha256" | head -n 1)"
got="$(shasum -a 256 "$tmp/$name" | awk '{print $1}')"
case "$want" in *[!0-9a-f]*|"") die "malformed checksum file" ;; esac
[ ${#want} -eq 64 ] || die "malformed checksum file"
[ "$want" = "$got" ] || die "checksum mismatch (expected $want, got $got)"
echo "Checksum OK"

mkdir "$tmp/x"
tar -xzf "$tmp/$name" -C "$tmp/x"
src="$tmp/x/strim-$version"
[ -x "$src/libexec/strim" ] || die "unexpected tarball layout"

dest="$prefix/strim"
mkdir -p "$prefix/bin" "$dest"
rm -rf "$dest/$version.new"
cp -R "$src/libexec" "$dest/$version.new"
rm -rf "$dest/$version"
mv "$dest/$version.new" "$dest/$version"
ln -sfn "$version" "$dest/current"

# A symlink to the binary does not work (resources are found next to the unresolved path), so use a wrapper.
wrapper="$prefix/bin/strim"
{
  printf '#!/bin/sh\n'
  printf 'exec "%s/strim/current/strim" "$@"\n' "$prefix"
} > "$wrapper.tmp"
chmod 0755 "$wrapper.tmp"
mv -f "$wrapper.tmp" "$wrapper"

"$wrapper" --version | head -n 1
echo
echo "Installed to $dest/$version, command: $wrapper"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Add to PATH:  echo 'export PATH=\"$prefix/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
cat <<NEXT

Next steps:
  1. Download the model (about 15 GB, not included): see docs/INSTALL.md
     https://github.com/$repo/blob/main/docs/INSTALL.md
  2. strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
Uninstall: rm -rf "$dest" "$wrapper"   (state in ~/.strim is kept)
NEXT
