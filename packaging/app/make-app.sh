#!/usr/bin/env bash
# Assemble Strim.app (menu-bar SwiftUI app + bundled CLI) from an existing SwiftPM release build.
#
#   packaging/app/make-app.sh [--build] [--scratch-path DIR] [--build-dir DIR] [--out DIR]
#                             [--sign-identity NAME] [--notarize KEYCHAIN_PROFILE]
#
# --build           run `nice swift build -c release --product StrimApp --product strim` first
# --scratch-path    SwiftPM scratch dir for --build (default .build; on a machine where fresh submodule clones
#                   hang, copy an existing checkout dir and point this at the copy)
# --build-dir       dir holding StrimApp, strim and the resource bundles (default <scratch-path>/release)
# --out             output dir (default dist/); result: <out>/Strim.app
# --sign-identity   OWNER-GATED. Developer ID Application identity to sign with (hardened runtime + timestamp).
#                   Default: ad-hoc signature (`codesign --sign -`). Never auto-picks a keychain identity.
# --notarize        OWNER-GATED. notarytool keychain profile; needs --sign-identity. Submits a zip, waits,
#                   staples the ticket to the app.
#
# Layout (CLI part is shared with the release tarball, see packaging/release/layout.sh):
#   Strim.app/Contents/MacOS/Strim                          StrimApp executable (LSUIElement menu-bar app)
#   Strim.app/Contents/Resources/strim                      real CLI binary
#   Strim.app/Contents/Resources/mlx-swift_Cmlx.bundle      metallib, next to the real binary
#   Strim.app/Contents/Resources/Strim_StrimHarness.bundle  harness prompt pack
#   Strim.app/Contents/Resources/AppIcon.icns               from packaging/app/icon/icon-1024.png
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
here="$root/packaging/app"
scratch="$root/.build"
build=""
out="$root/dist"
identity=""
profile=""
do_build=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) do_build=1; shift ;;
    --scratch-path) scratch="$2"; shift 2 ;;
    --build-dir) build="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --sign-identity) identity="$2"; shift 2 ;;
    --notarize) profile="$2"; shift 2 ;;
    -h|--help) sed -n 2,23p "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -z "$profile" ] || [ -n "$identity" ] || { echo "--notarize needs --sign-identity" >&2; exit 2; }

# shellcheck source=../release/layout.sh
. "$root/packaging/release/layout.sh"

if [ "$do_build" = 1 ]; then
  (cd "$root" && nice -n 19 swift build -c release --disable-sandbox --scratch-path "$scratch" --product StrimApp --product strim)
fi
[ -n "$build" ] || build="$scratch/release"
build="$(cd "$build" && pwd)"
strim_check_build "$build" || exit 1
[ -x "$build/StrimApp" ] || { echo "no executable $build/StrimApp (use --build)" >&2; exit 1; }
version="$(cat "$root/VERSION")" || exit 1
version="${version//[[:space:]]/}"
[ -n "$version" ] || { echo "VERSION is empty" >&2; exit 1; }

app="$out/Strim.app"
mkdir -p "$out"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build/StrimApp" "$app/Contents/MacOS/Strim"
chmod 0755 "$app/Contents/MacOS/Strim"
strim_stage_cli "$build" "$app/Contents/Resources"

# Icon: one source file, packaging/app/icon/icon-1024.png (swap it to re-skin).
icon="$here/icon/icon-1024.png"
[ -f "$icon" ] || { echo "missing $icon" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
iset="$tmp/AppIcon.iconset"; mkdir "$iset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$icon" --out "$iset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$icon" --out "$iset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Strim</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.strim.Strim</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Strim</string>
  <key>CFBundleDisplayName</key><string>Strim</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Gabriele Ferreri. MIT License.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null
cp "$root/LICENSE" "$root/NOTICE" "$app/Contents/Resources/"

# Signing. Inside-out: nested bundles and the CLI first, then the app. Default is ad-hoc.
if [ -n "$identity" ]; then
  sign=(codesign --force --options runtime --timestamp --sign "$identity")
else
  sign=(codesign --force --sign -)
fi
for b in "${STRIM_RESOURCE_BUNDLES[@]}"; do "${sign[@]}" "$app/Contents/Resources/$b"; done
"${sign[@]}" "$app/Contents/Resources/strim"
"${sign[@]}" "$app/Contents/MacOS/Strim"
"${sign[@]}" "$app"
codesign --verify --deep --strict "$app"
codesign -dv "$app" 2>&1 | grep -E "Identifier=|Signature=|flags=|TeamIdentifier=" | sed 's/^/codesign: /'
[ -n "$identity" ] || echo "note: ad-hoc signed only (not notarized; Gatekeeper blocks quarantined copies). Owner-gated: see packaging/RELEASING.md" >&2

if [ -n "$profile" ]; then
  zip="$tmp/Strim-notarize.zip"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi

echo "wrote $app (version $version)"
