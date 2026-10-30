cask "strim-app" do
  version "0.1.7"
  sha256 "4a4cb8bd854df506af4f0a715db00f4cbde3f730c79f2acf2e13b6bd2ee4d6d2"

  url "https://github.com/megasoft1978/strim-engine/releases/download/v#{version}/Strim-#{version}-arm64.dmg"
  name "Strim"
  desc "Menu-bar app for the Strim local inference engine"
  homepage "https://github.com/megasoft1978/strim-engine"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Strim.app"

  # Deliberately no zap stanza: ~/.strim holds the user's API tokens, models, jobs and logs and is never removed.

  caveats <<~EOS
    The app bundles the strim CLI; model weights are not included (about 16 GB).
    Strim keeps its state under ~/.strim (tokens, models, packs, jobs, logs, cache).
    `brew uninstall --cask strim-app` does not remove it.
    Download steps: https://github.com/megasoft1978/strim-engine/blob/main/docs/INSTALL.md
  EOS
end
