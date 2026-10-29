cask "strim-app" do
  version "0.1.1"
  sha256 "f69ebcb01eba75f1a1a1635fdf753cf3638c9a09e9c2c180de0b35cc040cc8f6"

  url "https://github.com/megasoft1978/strim-engine/releases/download/v#{version}/Strim-#{version}-arm64.dmg"
  name "Strim"
  desc "Menu-bar app for the Strim local inference engine"
  homepage "https://github.com/megasoft1978/strim-engine"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Strim.app"

  # Deliberately no zap stanza: ~/.strim holds the user's API tokens, models, jobs and logs and is never removed.

  caveats <<~EOS
    Strim.app is not notarized yet. If macOS blocks the first launch, either
    open System Settings > Privacy & Security and choose "Open Anyway", or run:
      xattr -dr com.apple.quarantine /Applications/Strim.app

    The app bundles the strim CLI; model weights are not included (about 16 GB).
    Strim keeps its state under ~/.strim (tokens, models, packs, jobs, logs, cache).
    `brew uninstall --cask strim-app` does not remove it.
    Download steps: https://github.com/megasoft1978/strim-engine/blob/main/docs/INSTALL.md
  EOS
end
