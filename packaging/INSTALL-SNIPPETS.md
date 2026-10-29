# README / site install tabs (text for the design worker)

Three tabs in this order: Homebrew | curl | DMG. Apple Silicon, macOS 14+ line sits under the tabs.

## Homebrew (default tab)
```sh
brew install megasoft1978/strim/strim          # CLI
brew install --cask megasoft1978/strim/strim-app   # optional menu-bar app
strim pull
```
Caption: "Installs the `strim` command. The app is optional; it already contains the CLI."

## curl
```sh
curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash
```
Caption: "No sudo. Installs to ~/.local/strim and links ~/.local/bin/strim. Checks the SHA-256 before installing."

## DMG
Button: "Download Strim-<version>-arm64.dmg" -> `https://github.com/megasoft1978/strim-engine/releases/latest` (asset `Strim-<version>-arm64.dmg`).
Steps (3 short lines): "Open the DMG. Drag Strim to Applications. Launch Strim from the menu bar."
Honest note (small text, below the button, keep it while the app is not notarized):
> Not notarized yet, so macOS will warn on first launch. Open System Settings > Privacy & Security and click "Open Anyway",
> or run `xattr -dr com.apple.quarantine /Applications/Strim.app`. Installing with Homebrew avoids the warning.
Once the owner adds signing secrets and the release is notarized, delete the note.

## Shared footer under all tabs
"Model weights (about 16 GB) are downloaded separately: `strim pull`. State lives in ~/.strim and is never removed on uninstall.
Apple Silicon, macOS 14 or newer, tested on a 64 GB M5 Max."
