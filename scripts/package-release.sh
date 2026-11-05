#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' tray/Info.plist)}"
APP="$ROOT/tray/build-universal/PaseoTray.app"
DIST="$ROOT/dist"
DMG="$DIST/PaseoTray-$VERSION.dmg"

SIGN_IDENTITY="${PASEOTRAY_SIGN_IDENTITY:-}"
SIGN_KEYCHAIN="${PASEOTRAY_SIGN_KEYCHAIN:-}"
NOTARY_PROFILE="${PASEOTRAY_NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_APP_PASSWORD="${APPLE_APP_PASSWORD:-}"

echo "==> Building Paseo Tray $VERSION"
./tray/build-universal.sh

if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  echo "==> Signing with Developer ID: $SIGN_IDENTITY"
  CODESIGN_ARGS=(
    --force
    --options runtime
    --timestamp
    --sign "$SIGN_IDENTITY"
    --identifier sh.paseo.tray
  )
  if [[ -n "$SIGN_KEYCHAIN" ]]; then
    CODESIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
  fi
  codesign "${CODESIGN_ARGS[@]}" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "WARNING: PASEOTRAY_SIGN_IDENTITY is not set; this is an ad-hoc build."
  echo "         It is for local testing only and is not suitable for public download."
  codesign --force --sign - --identifier sh.paseo.tray --timestamp=none "$APP"
fi

rm -rf "$DIST"
mkdir -p "$DIST/stage"
ditto "$APP" "$DIST/stage/PaseoTray.app"
ln -s /Applications "$DIST/stage/Applications"

echo "==> Creating DMG"
hdiutil create \
  -volname "Paseo Tray $VERSION" \
  -srcfolder "$DIST/stage" \
  -ov \
  -format UDZO \
  "$DMG"
rm -rf "$DIST/stage"

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "==> Notarizing with keychain profile: $NOTARY_PROFILE"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
elif [[ -n "$APPLE_ID" && -n "$APPLE_TEAM_ID" && -n "$APPLE_APP_PASSWORD" ]]; then
  echo "==> Notarizing with Apple ID"
  xcrun notarytool submit \
    "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$DMG"
else
  echo "WARNING: notarization skipped."
  echo "         Set PASEOTRAY_NOTARY_PROFILE or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD."
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo ""
echo "DMG:    $DMG"
echo "SHA256: $(cut -d' ' -f1 "$DMG.sha256")"
