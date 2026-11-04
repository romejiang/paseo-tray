# GitHub release workflow

This workflow builds a universal macOS app, signs it with a Developer ID
Application certificate, notarizes the DMG, and creates a GitHub Release.

The GitHub CLI token used during development did not have the `workflow` scope,
so this file lives outside `.github/workflows/` and is not pushed automatically.
After refreshing the token:

```bash
gh auth refresh -s workflow
mkdir -p .github/workflows
cp packaging/github/release.yml .github/workflows/release.yml
git add .github/workflows/release.yml
git commit -m "ci: add release workflow"
git push
```

Or add the file through the GitHub web UI.

## Required repository secrets

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of the exported Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `MACOS_SIGN_IDENTITY` | Full identity, e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_APP_PASSWORD` | App-specific password for notarization |

## Creating the certificate

1. Apple Developer → Certificates, Identifiers & Profiles → Certificates → **+**.
2. Choose **Developer ID Application** (not Apple Development / Apple Distribution).
3. Create a CSR, upload it, download the `.cer`, double-click to install it in
   the login keychain.
4. In Keychain Access, export the certificate **with its private key** as `.p12`.
5. Base64 it:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```
6. Add the secrets above in GitHub → Settings → Secrets and variables → Actions.

## Release

```bash
git tag v0.1.0
git push origin v0.1.0
```

A tag release fails fast if `MACOS_SIGN_IDENTITY` is missing, so an unsigned
build cannot be published accidentally. Manual `workflow_dispatch` runs default
to a draft release.
