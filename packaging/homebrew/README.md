# Homebrew

The cask lives in a separate tap repository so users can install with:

```bash
brew install --cask romejiang/tap/paseo-tray
```

## First-time tap setup

```bash
gh repo create romejiang/homebrew-tap --public --description "Homebrew tap for romejiang"
```

Clone it, create `Casks/`, and copy the cask:

```bash
git clone https://github.com/romejiang/homebrew-tap.git
mkdir -p homebrew-tap/Casks
cp packaging/homebrew/Casks/paseo-tray.rb homebrew-tap/Casks/
```

After the first signed release, update the version and SHA:

```bash
scripts/update-cask.sh 0.1.0
cp packaging/homebrew/Casks/paseo-tray.rb homebrew-tap/Casks/
cd homebrew-tap
git add Casks/paseo-tray.rb
git commit -m "paseo-tray 0.1.0"
git push
```

## Each release

```bash
./scripts/package-release.sh 0.1.0
scripts/update-cask.sh 0.1.0
```

Then copy the cask to the tap and push. The cask `sha256` must match the
published DMG; never publish a cask with a placeholder checksum.

## Notes

- The cask installs to `/Applications` via `app "PaseoTray.app"`.
- `depends_on macos: ">= :ventura"` matches the app's macOS 13 minimum.
- `uninstall quit:` uses the bundle identifier `sh.paseo.tray`.
- `zap` removes the shared tray config directory and preferences.
