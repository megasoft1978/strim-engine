#!/usr/bin/env bash
# Build dist/Strim.app (SwiftUI menu-bar client, links StrimAppCore + StrimAPI only, never MLX).
# Env: CONFIG=release|debug (default release), SCRATCH=<swiftpm scratch path> (default .build),
#      SMOKE=1 to launch the built binary headless for 2 s with STRIM_APP_TEST=1 and kill it by pid.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
version="$(cat "$ROOT/VERSION")"; version="${version//[[:space:]]/}"; [ -n "$version" ] || { echo "VERSION is empty" >&2; exit 1; }
CONFIG="${CONFIG:-release}"
SCRATCH="${SCRATCH:-.build}"
BUILD_DIR="${BUILD_DIR:-build}"
mkdir -p "$BUILD_DIR" dist

swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product StrimApp
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/StrimApp"

ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" -h "$s" assets/icon.svg -o "$ICONSET/icon_${s}x${s}.png"
  d=$((s*2))
  rsvg-convert -w "$d" -h "$d" assets/icon.svg -o "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

APP=dist/Strim.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Strim"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Strim</string>
  <key>CFBundleDisplayName</key><string>Strim</string>
  <key>CFBundleIdentifier</key><string>local.strim.app</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleExecutable</key><string>Strim</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
codesign -v --deep --strict "$APP"
echo "built $APP ($CONFIG), codesign ok"

if [ "${SMOKE:-0}" = "1" ]; then
  STRIM_APP_TEST=1 "$APP/Contents/MacOS/Strim" >"$BUILD_DIR/smoke.log" 2>&1 &
  PID=$!
  sleep 2
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"; wait "$PID" 2>/dev/null || true
    echo "smoke ok: pid $PID alive after 2s, killed"
  else
    echo "smoke FAILED: process exited early"; tail -20 "$BUILD_DIR/smoke.log"; exit 1
  fi
fi
