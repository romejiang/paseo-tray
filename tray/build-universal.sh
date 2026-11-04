#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

ROOT="$(pwd)"
BUILD="$ROOT/build-universal"
APP="$BUILD/PaseoTray.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling universal PaseoTray (arm64 + x86_64, macOS 13.0+)"
for arch in arm64 x86_64; do
  swiftc \
    -O \
    -target "${arch}-apple-macos13.0" \
    -framework AppKit \
    -framework ServiceManagement \
    -framework UserNotifications \
    Sources/*.swift \
    -o "$BUILD/PaseoTray-$arch"
done

lipo -create "$BUILD/PaseoTray-arm64" "$BUILD/PaseoTray-x86_64" \
  -output "$APP/Contents/MacOS/PaseoTray"
rm -f "$BUILD/PaseoTray-arm64" "$BUILD/PaseoTray-x86_64"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/trayTemplate.png "$APP/Contents/Resources/trayTemplate.png"
cp Resources/trayTemplate@2x.png "$APP/Contents/Resources/trayTemplate@2x.png"
cp Resources/PaseoIcon.icns "$APP/Contents/Resources/PaseoIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "${PASEOTRAY_SKIP_SIGN:-0}" != "1" ]]; then
  echo "==> Ad-hoc signing (release script re-signs with Developer ID when configured)"
  codesign --force --sign - --identifier sh.paseo.tray --timestamp=none "$APP"
fi

plutil -lint "$APP/Contents/Info.plist"
lipo -info "$APP/Contents/MacOS/PaseoTray"
echo "Built universal: $APP"
