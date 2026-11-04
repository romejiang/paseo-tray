#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/update-cask.sh <version> [sha256]}"
CASK="packaging/homebrew/Casks/paseo-tray.rb"
SHA="${2:-}"

if [[ -z "$SHA" ]]; then
  DMG="dist/PaseoTray-$VERSION.dmg"
  if [[ ! -f "$DMG" ]]; then
    echo "Missing $DMG; run scripts/package-release.sh $VERSION first." >&2
    exit 1
  fi
  SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi

python3 - "$CASK" "$VERSION" "$SHA" <<'PY'
from pathlib import Path
import re
import sys

cask = Path(sys.argv[1])
version = sys.argv[2]
sha = sys.argv[3]
text = cask.read_text()
text = re.sub(r'^  version ".*"$', f'  version "{version}"', text, flags=re.M)
text = re.sub(r'^  sha256 ".*"$', f'  sha256 "{sha}"', text, flags=re.M)
cask.write_text(text)
PY

echo "Updated $CASK"
echo "  version: $VERSION"
echo "  sha256:  $SHA"
