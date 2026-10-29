<p align="center"><picture>
<source media="(prefers-color-scheme: dark)" srcset="site/assets/readme/wordmark-dark.svg">
<img src="site/assets/readme/wordmark-light.svg" alt="strim" height="56"></picture></p>
<p align="center"><b>The local model server built for coding agents.</b><br>Qwen3.8-27B on Apple silicon. One Swift binary, a menu-bar app, nothing leaves your Mac.</p>
<p align="center">
<a href="https://github.com/megasoft1978/strim-engine/releases/latest"><img src="https://img.shields.io/github/v/release/megasoft1978/strim-engine?label=release&color=7C7CF5&labelColor=1B1C22" alt="Latest release"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-7C7CF5?labelColor=1B1C22" alt="MIT license"></a>
<img src="https://img.shields.io/badge/macOS-14%2B%20Apple%20silicon-7C7CF5?labelColor=1B1C22" alt="macOS 14 or newer, Apple silicon">
</p>
<p align="center"><a href="https://megasoft1978.github.io/strim-engine/">Website</a> · <a href="https://megasoft1978.github.io/strim-engine/benchmarks.html">Benchmarks</a> · <a href="docs/INSTALL.md">Install guide</a> · <a href="https://github.com/megasoft1978/strim-engine/releases">Releases</a></p>

<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/app/readme-hero-dark.png">
<img src="site/assets/app/readme-hero-light.png" width="880" alt="Strim status window: live decode speed, memory by component and engine counters, with the menu-bar popover"></picture></p>
<p align="center"><sub>{{@live_caption}}</sub></p>

## Install
```sh
brew install megasoft1978/strim/strim              # CLI
brew install --cask megasoft1978/strim/strim-app   # optional menu-bar app (includes the CLI)
strim pull                                         # downloads the model
```
Or the [DMG](https://github.com/megasoft1978/strim-engine/releases/latest) (signed and notarized). macOS 14+, Apple silicon.

## Use it with Claude Code or Codex
```sh
strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
export ANTHROPIC_BASE_URL=http://127.0.0.1:8203
export OPENAI_BASE_URL=http://127.0.0.1:8203/v1
```

## Benchmarks
<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/readme/decode-dark.svg"><img src="site/assets/readme/decode-light.svg" width="720" alt="{{@decode_alt}}"></picture></p>

{{@table}}

{{@caption}}
