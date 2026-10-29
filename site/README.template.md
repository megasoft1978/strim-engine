![{{@banner_alt}}](site/assets/banner.svg)

# Strim
One Swift binary that runs Qwen3.8-27B on your Mac like a server: a local backend for Claude Code and Codex.

![{{@ratio_alt}}](site/assets/h2h-ratio.svg)
{{@lossline}}

{{@app_figure}}

**Homebrew**
```sh
brew install megasoft1978/strim/strim
brew install --cask megasoft1978/strim/strim-app   # optional menu-bar app
```
**curl**
```sh
curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash
```
Then, either way:
```sh
strim pull
strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
```
[Site](https://megasoft1978.github.io/strim-engine/) · [Benchmarks](site/benchmarks.html) · [Install](docs/INSTALL.md) · [DMG](https://github.com/megasoft1978/strim-engine/releases/latest) (not notarized yet) · MIT, see [LICENSE](LICENSE).
