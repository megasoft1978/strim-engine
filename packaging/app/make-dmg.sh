#!/usr/bin/env bash
# Build Strim-<version>-arm64.dmg (UDZO, drag-to-Applications layout) from a Strim.app made by make-app.sh.
#
#   packaging/app/make-dmg.sh [--app PATH] [--out DIR] [--no-layout]
#                             [--sign-identity NAME] [--notarize KEYCHAIN_PROFILE]
#
# --app           Strim.app to package (default dist/Strim.app)
# --out           output dir (default dist/); writes Strim-<v>-arm64.dmg and .dmg.sha256 (hex digest only)
# --no-layout     skip the Finder window layout step (background, icon positions). The DMG still has the
#                 Applications symlink; used automatically when Finder scripting is unavailable (headless).
# --sign-identity OWNER-GATED. Signs the DMG (default: unsigned DMG; the app inside keeps its own signature).
# --notarize      OWNER-GATED. notarytool keychain profile; needs --sign-identity. Submits the DMG and staples it.
#
# Background image: packaging/app/dmg-background.png (660x400; regenerate with tools/gen-images.swift).
# Volume icon: AppIcon.icns taken from the app. Determinism: payload mtimes are fixed and the image is built
# from a sorted staging folder; the Finder layout step writes a .DS_Store whose bytes vary run to run, so the
# DMG is byte-reproducible only with --no-layout. The released sha256 is whatever CI produced.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
here="$root/packaging/app"
app="$root/dist/Strim.app"
out="$root/dist"
identity=""
profile=""
layout=1
while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --no-layout) layout=0; shift ;;
    --sign-identity) identity="$2"; shift 2 ;;
    --notarize) profile="$2"; shift 2 ;;
    -h|--help) sed -n 2,17p "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -z "$profile" ] || [ -n "$identity" ] || { echo "--notarize needs --sign-identity" >&2; exit 2; }
[ -d "$app/Contents" ] || { echo "no app at $app (run make-app.sh)" >&2; exit 1; }
app="$(cd "$app" && pwd)"
[ "$(uname -m)" = arm64 ] || { echo "run on arm64" >&2; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
vol="Strim $version"
name="Strim-$version-arm64"
mkdir -p "$out"; out="$(cd "$out" && pwd)"
dmg="$out/$name.dmg"

work="$(mktemp -d)"
mnt=""
cleanup() {
  [ -z "$mnt" ] || hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

stage="$work/stage"
mkdir -p "$stage"
ditto --norsrc --noextattr --noqtn "$app" "$stage/Strim.app"
ln -s /Applications "$stage/Applications"
bg="$here/dmg-background.png"
if [ -f "$bg" ]; then
  mkdir "$stage/.background"; cp "$bg" "$stage/.background/background.png"
else
  echo "note: no $bg; DMG will have no background" >&2
  layout=0
fi
find "$stage" -exec touch -h -t 202001010000 {} +

rw="$work/rw.dmg"
hdiutil create -quiet -srcfolder "$stage" -volname "$vol" -fs HFS+ -format UDRW -ov "$rw"
[ ! -e "/Volumes/$vol" ] || { echo "/Volumes/$vol is already mounted; eject it first" >&2; exit 1; }
# Finder only scripts volumes mounted under /Volumes and not hidden with -nobrowse.
nb=(); [ "$layout" = 1 ] || nb=(-nobrowse)
mnt="/Volumes/$vol"
hdiutil attach -quiet "${nb[@]+"${nb[@]}"}" -noverify -noautoopen "$rw"

if [ "$layout" = 1 ]; then
  # Best effort, time-boxed: Finder scripting can be unavailable (headless, no Automation permission).
  osa="$work/layout.applescript"
  cat > "$osa" <<OSA
tell application "Finder"
  tell disk "$vol"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set background picture of opts to file ".background:background.png"
    set position of item "Strim.app" of container window to {170, 210}
    set position of item "Applications" of container window to {490, 210}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
  if perl -e 'alarm 45; exec @ARGV' osascript "$osa" >/dev/null 2>"$work/osa.err"; then
    sync; sleep 1
  else
    echo "note: Finder layout skipped ($(head -c 200 "$work/osa.err" | tr '\n' ' '))" >&2
  fi
fi
# Volume icon goes in last: the Finder layout step deletes .VolumeIcon.icns if it is already there.
cp "$app/Contents/Resources/AppIcon.icns" "$mnt/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$mnt" || true; else echo "note: SetFile missing; no volume icon" >&2; fi
sync
hdiutil detach -quiet "$mnt" || hdiutil detach -quiet -force "$mnt"
mnt=""

rm -f "$dmg"
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
if [ -n "$identity" ]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
fi
if [ -n "$profile" ]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
  xcrun stapler staple "$dmg"
fi
digest="$(shasum -a 256 "$dmg" | awk '{print $1}')"
echo "$digest" > "$dmg.sha256"
echo "wrote $dmg"
echo "sha256 $digest"
