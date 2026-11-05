#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_DIR="${PASEOTRAY_SIGN_DIR:-$HOME/.paseo-tray-signing}"
CSR="$SIGN_DIR/developerID.csr"
KEY="$SIGN_DIR/developerID.key"

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

if [[ ! -f "$KEY" ]]; then
  openssl genrsa -out "$KEY" 2048
fi
chmod 600 "$KEY"

openssl req \
  -new \
  -key "$KEY" \
  -out "$CSR" \
  -subj "/CN=Paseo Tray Developer ID/C=US"
chmod 600 "$CSR"

echo "CSR: $CSR"
echo "Private key: $KEY (keep this local; never upload or commit it)"
echo ""
echo "Send the CSR to the Apple Developer Account Holder."
echo "They upload it at developer.apple.com -> Certificates -> + -> Developer ID Application."
