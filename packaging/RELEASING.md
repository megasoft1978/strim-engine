# Releasing Strim

One tag drives everything: tag `v<version>` -> CI builds -> release assets -> Homebrew tap update.

## Flow

1. Bump the version in the CLI (`strim --version` must print `strim <version>`; the CI checks that it equals the tag).
2. Optional: write `RELEASE_NOTES.md` in the repo root (used as the release body; otherwise GitHub generates notes).
3. Commit, then tag and push the tag (the owner pushes; nothing here pushes for you):
   ```sh
   git tag v0.1.0 && git push origin v0.1.0
   ```
4. `.github/workflows/release.yml` then runs:
   - `build` (macos-26, arm64): select newest Xcode, ensure the Metal toolchain, cached `swift build -c release`,
     version/tag check, `swift test --filter 'StrimSiteTests|StrimPullTests|DepthPolicyTests'`,
     `packaging/release/make-release.sh` (tarball), `packaging/app/make-app.sh` (Strim.app), `packaging/app/make-dmg.sh`
     (DMG), DMG smoke check, upload as workflow artifact `strim-release`.
   - `release` (only job with `contents: write`): `gh release create v<version>` with
     `strim-<v>-arm64-macos.tar.gz`, `Strim-<v>-arm64.dmg` and their `.sha256` files.
   - `tap`: updates `Formula/strim.rb` and `Casks/strim-app.rb` in `megasoft1978/homebrew-strim` (url + sha256)
     via `packaging/release/update-tap.sh`. Skipped with a log line unless `TAP_GITHUB_TOKEN` exists.
5. Verify on a clean arm64 Mac: `brew install megasoft1978/strim/strim`, `brew install --cask megasoft1978/strim/strim-app`,
   the curl installer, and mounting the DMG.

## Dry run (no release, no tap)

Actions tab -> release -> Run workflow (branch of your choice, `dry_run` true). Or `gh workflow run release.yml -f dry_run=true`.
It builds, tests, packages and uploads the `strim-release` artifact (14 days). The `release` and `tap` jobs only run on tag pushes.
Local equivalent:
```sh
swift build -c release --disable-sandbox --product strim --product StrimApp
packaging/release/make-release.sh && packaging/app/make-app.sh && packaging/app/make-dmg.sh   # outputs in dist/
```
(On a machine where fresh submodule clones hang: copy an existing build dir and pass `--scratch-path` to `make-app.sh --build`.)

## Owner steps (not done by anyone else)

### Tap repo and token
1. Create `megasoft1978/homebrew-strim` (public) if it does not exist yet (see `packaging/homebrew/README.md`).
2. GitHub -> Settings -> Developer settings -> Fine-grained tokens -> new token: resource owner `megasoft1978`,
   repository access: only `homebrew-strim`, permission Repository -> Contents: Read and write. Expiry: your choice.
3. In `megasoft1978/strim-engine` -> Settings -> Secrets and variables -> Actions -> new repository secret `TAP_GITHUB_TOKEN`.

### Signing and notarization (removes the Gatekeeper warning)
Needs a paid Apple Developer Program membership under your own name. Do not use anyone else's certificate.
1. Developer portal -> Certificates -> "Developer ID Application". Install it, export it from Keychain Access as `.p12` with a password.
2. Repository secrets (Actions):
   - `MACOS_CERT_P12_BASE64`: `base64 -i cert.p12 | pbcopy`
   - `MACOS_CERT_PASSWORD`: the p12 password
   - Notarization, either:
     - `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (app-specific password from appleid.apple.com), or
     - `APPLE_API_KEY_P8_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` (App Store Connect API key, `base64 -i AuthKey_XXXX.p8`)
3. Next tag build signs the CLI, the app and the DMG (hardened runtime + timestamp), notarizes and staples the app and the DMG.
   With only the certificate and no notarization credentials it signs but does not notarize (log line says so).
   With no secrets everything is ad-hoc signed (current state).

Local signing, same scripts (use your own identity and a keychain profile you created with `xcrun notarytool store-credentials`):
```sh
packaging/app/make-app.sh --sign-identity "Developer ID Application: NAME (TEAMID)" --notarize my-profile
packaging/app/make-dmg.sh --sign-identity "Developer ID Application: NAME (TEAMID)" --notarize my-profile
```
Both flags are off unless passed.

## The app and the CLI

`Strim.app` carries the CLI at `Contents/Resources/strim` with `mlx-swift_Cmlx.bundle` and `Strim_StrimHarness.bundle`
beside it, the same arrangement as the tarball's `libexec/` (one definition: `packaging/release/layout.sh`). The app
finds that CLI via `HostCommand.defaultBinaries()`; apply `packaging/app/bundled-cli.patch` (one function) if it is not in the tree yet.
The app on launch only polls the local control API; it starts `strim serve` only when the user clicks Start.

## Icon

The only icon source is `packaging/app/icon/icon-1024.png` (placeholder). Replace it with a 1024x1024 PNG and rebuild;
`make-app.sh` generates the `.icns`, `make-dmg.sh` uses it as the volume icon. `packaging/app/dmg-background.png` (660x400)
is optional; remove it for a plain window. Both placeholders come from `packaging/app/tools/gen-images.swift`.
