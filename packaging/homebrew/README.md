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

Build and publish the DMG once, then update the cask from that same artifact.
Do not rebuild between uploading the Release asset and updating the cask:
Developer ID signing (with `--timestamp`) and notarization change the bytes, so
a rebuilt DMG has a different sha256.

After the GitHub Release is published with `dist/PaseoTray-0.1.0.dmg` as the
asset:

```bash
# When dist/PaseoTray-0.1.0.dmg is still the published asset:
scripts/publish-homebrew.sh 0.1.0

# Or pass the sha256 of the published asset explicitly:
scripts/publish-homebrew.sh 0.1.0 <release-dmg-sha256>
```

`publish-homebrew.sh` updates the cask `version`/`sha256`, clones the tap,
commits, and pushes. The cask `sha256` must match the published DMG; never
publish a cask with a placeholder checksum.

## Notes

- The cask installs to `/Applications` via `app "PaseoTray.app"`.
- `depends_on macos: :ventura` matches the app's macOS 13 minimum.
- `uninstall quit:` uses the bundle identifier `sh.paseo.tray`.
- `zap` removes the shared tray config directory and preferences.
