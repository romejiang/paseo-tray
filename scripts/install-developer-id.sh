#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CERT="${1:?usage: scripts/install-developer-id.sh <DeveloperIDApplication.cer>}"
SIGN_DIR="${PASEOTRAY_SIGN_DIR:-$HOME/.paseo-tray-signing}"
KEY="$SIGN_DIR/developerID.key"
PEM="$SIGN_DIR/developerID.pem"
P12="$SIGN_DIR/developerID.p12"
KEYCHAIN="$SIGN_DIR/PaseoTray.keychain-db"
P12_PASSWORD="${PASEOTRAY_P12_PASSWORD:-paseo-tray-local}"
KEYCHAIN_PASSWORD="${PASEOTRAY_KEYCHAIN_PASSWORD:-paseo-tray-keychain}"

if [[ ! -f "$KEY" ]]; then
  echo "Missing private key: $KEY" >&2
  echo "Generate it first with scripts/create-developer-id-csr.sh." >&2
  exit 1
fi

if openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
  cp "$CERT" "$PEM"
else
  openssl x509 -inform DER -in "$CERT" -out "$PEM"
fi

openssl pkcs12 -export \
  -inkey "$KEY" \
  -in "$PEM" \
  -out "$P12" \
  -passout "pass:$P12_PASSWORD" \
  -name "Paseo Tray Developer ID"

chmod 600 "$P12" "$PEM"

security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN" >/dev/null

EXISTING="$(security list-keychains -d user | tr -d '"')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $EXISTING

echo ""
echo "Installed Developer ID certificate."
echo "Keychain: $KEYCHAIN"
echo "P12:      $P12"
echo "P12 password: $P12_PASSWORD"
echo ""
echo "Available identity:"
security find-identity -v -p codesigning "$KEYCHAIN"
echo ""
echo "Next:"
echo "  export PASEOTRAY_SIGN_IDENTITY=\"<identity from above>\""
echo "  export PASEOTRAY_SIGN_KEYCHAIN=\"$KEYCHAIN\""
echo "  ./scripts/package-release.sh 0.1.0"
echo ""
echo "For GitHub Actions, base64 the p12:"
echo "  base64 -i \"$P12\" | pbcopy"
