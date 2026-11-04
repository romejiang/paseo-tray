#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

DEST_DIR="$HOME/Applications"
DEST_APP="$DEST_DIR/PaseoTray.app"
SOURCE_APP="$(pwd)/build/PaseoTray.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "==> build/PaseoTray.app not found, building first"
  ./build.sh
fi

mkdir -p "$DEST_DIR"

echo "==> Stopping existing PaseoTray"
pkill -x PaseoTray 2>/dev/null || true
sleep 0.3

echo "==> Installing to $DEST_APP"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"

echo "==> Launching"
open "$DEST_APP"

echo "Installed: $DEST_APP"
echo "Uninstall: pkill -x PaseoTray; rm -rf \"$DEST_APP\""
