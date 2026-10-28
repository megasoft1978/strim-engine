# Homebrew tap: owner steps

Nothing here is published yet. Run these in order (needs `gh` logged in as megasoft1978).

1. Build the release binary and tarball (arm64 Mac, not while benchmarking):
   ```sh
   swift build -c release --disable-sandbox
   packaging/release/make-release.sh        # writes dist/strim-<ver>-arm64-macos.tar.gz + .sha256
   ```
   Optional Developer ID signing/notarization: `--sign-identity "Developer ID Application: NAME (TEAMID)"`, then notarize (see comments in make-release.sh).
2. Publish the GitHub release (tag must be `v<version>`, matching `strim --version`):
   ```sh
   gh release create v0.1.0 dist/strim-0.1.0-arm64-macos.tar.gz dist/strim-0.1.0-arm64-macos.tar.gz.sha256 \
     --repo megasoft1978/strim-engine --title "Strim 0.1.0" --notes "See README"
   ```
   The repo must be public for brew and the curl installer to download the asset.
3. Fill the formula: set `url` version and `sha256` in `packaging/homebrew/strim.rb` (digest printed by make-release.sh, also in the `.sha256` file).
4. Create the tap repo (the name must start with `homebrew-`):
   ```sh
   gh repo create megasoft1978/homebrew-strim --public --description "Homebrew tap for Strim"
   git clone https://github.com/megasoft1978/homebrew-strim && cd homebrew-strim
   mkdir Formula && cp ../strim-engine/packaging/homebrew/strim.rb Formula/strim.rb
   git add Formula/strim.rb && git commit -m "strim 0.1.0" && git push origin HEAD
   ```
5. Verify on a clean arm64 Mac:
   ```sh
   brew install megasoft1978/strim/strim
   strim --version && brew test megasoft1978/strim/strim && brew audit --strict --online megasoft1978/strim/strim
   ```
6. Upgrades: repeat 1-4 with the new version (new `url` and `sha256`).

Notes
- The formula installs the real binary and its resource bundles into `libexec` and exposes `bin/strim` as an exec wrapper. A plain symlink does not work: the MLX metallib is looked up next to the unresolved binary path.
- Without Developer ID signing the binary is ad-hoc signed. Homebrew and curl downloads are not quarantined, so it runs; a browser-downloaded tarball may be blocked by Gatekeeper.
- `brew audit --strict` passed in a throwaway local tap (placeholder sha256). Re-run with `--online` after publishing.
