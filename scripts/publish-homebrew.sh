#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/publish-homebrew.sh <version> [sha256]}"
SHA="${2:-}"

if [[ -z "$SHA" ]]; then
  DMG="dist/PaseoTray-$VERSION.dmg"
  if [[ ! -f "$DMG" ]]; then
    echo "Missing $DMG; run scripts/package-release.sh $VERSION first." >&2
    exit 1
  fi
  SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
fi

./scripts/update-cask.sh "$VERSION" "$SHA"

TAP_DIR="$(mktemp -d)"
trap 'rm -rf "$TAP_DIR"' EXIT

git clone https://github.com/romejiang/homebrew-tap.git "$TAP_DIR"
cp packaging/homebrew/Casks/paseo-tray.rb "$TAP_DIR/Casks/paseo-tray.rb"
cd "$TAP_DIR"
git add Casks/paseo-tray.rb
if git diff --cached --quiet; then
  echo "Cask already up to date."
  exit 0
fi
git -c user.name="Paseo Tray" -c user.email="paseo-tray@local" commit -m "paseo-tray $VERSION"
git push
echo "Published Homebrew cask paseo-tray $VERSION"
