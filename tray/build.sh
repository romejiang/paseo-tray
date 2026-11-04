#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/PaseoTray.app"
ARCH="$(uname -m)"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling PaseoTray ($ARCH, macOS 13.0+)"
swiftc \
  -O \
  -target "${ARCH}-apple-macos13.0" \
  -framework AppKit \
  -framework ServiceManagement \
  -framework UserNotifications \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/PaseoTray"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/trayTemplate.png "$APP/Contents/Resources/trayTemplate.png"
cp Resources/trayTemplate@2x.png "$APP/Contents/Resources/trayTemplate@2x.png"
cp Resources/PaseoIcon.icns "$APP/Contents/Resources/PaseoIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier sh.paseo.tray --timestamp=none "$APP"

echo "==> Verifying"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
