# Homebrew

The cask lives in a separate tap repository so users can install with:

```bash
brew tap romejiang/tap
brew trust romejiang/tap
brew install --cask romejiang/tap/paseo-tray
```

## First-time tap setup

The tap already exists at <https://github.com/romejiang/homebrew-tap>.

## Each release

After the GitHub Release is published:

```bash
./scripts/package-release.sh 0.1.0
scripts/publish-homebrew.sh 0.1.0
```

`publish-homebrew.sh` updates the cask `version`/`sha256`, clones the tap,
commits, and pushes. The cask `sha256` must match the published DMG; never
publish a cask with a placeholder checksum.

## Notes

- The cask installs to `/Applications` via `app "PaseoTray.app"`.
- `depends_on macos: :ventura` matches the app's macOS 13 minimum.
- `uninstall quit:` uses the bundle identifier `sh.paseo.tray`.
- `zap` removes the shared tray config directory and preferences.
