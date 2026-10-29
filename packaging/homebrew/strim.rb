class Strim < Formula
  desc "Swift-only local inference engine for Qwen3.8-27B on Apple Silicon"
  homepage "https://github.com/megasoft1978/strim-engine"
  url "https://github.com/megasoft1978/strim-engine/releases/download/v0.1.5/strim-0.1.5-arm64-macos.tar.gz"
  sha256 "d9763c50979b3759eca5aa7a2f2786b9553900de7c81f34c404e40e0136f1734"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    # The binary finds mlx-swift_Cmlx.bundle (default.metallib) and Strim_StrimHarness.bundle next to its own
    # path, so a bare symlink into bin does not work. Keep everything in libexec and exec it from a wrapper.
    libexec.install Dir["libexec/*"]
    bin.write_exec_script libexec/"strim"
  end

  def caveats
    <<~EOS
      Model weights are not included (about 15 GB for the 4-bit checkpoint plus a 0.25 GB MTP head).
      Download steps: https://github.com/megasoft1978/strim-engine/blob/main/docs/INSTALL.md

      Start the server once the models are in place:
        strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203

      Strim keeps its state under ~/.strim (API token, control token, packs, jobs, worktrees,
      logs, cache). `brew uninstall strim` does not remove it.
    EOS
  end

  test do
    assert_match "strim #{version}", shell_output("#{bin}/strim --version")
  end
end
