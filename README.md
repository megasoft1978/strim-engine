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
<p align="center"><sub>Live capture on Apple M5 Max, 64 GB, while 2 agent jobs were running. The benchmarks below run one request at a time.</sub></p>

## Install
```sh
brew install megasoft1978/strim/strim              # CLI
brew install --cask megasoft1978/strim/strim-app   # optional menu-bar app (includes the CLI)
strim pull                                         # downloads the model
```
Or the [DMG](https://github.com/megasoft1978/strim-engine/releases/latest) (not notarized yet: right-click, then Open). macOS 14+, Apple silicon.

## Use it with Claude Code or Codex
```sh
strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
export ANTHROPIC_BASE_URL=http://127.0.0.1:8203
export OPENAI_BASE_URL=http://127.0.0.1:8203/v1
```

## Benchmarks
<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="site/assets/readme/decode-dark.svg"><img src="site/assets/readme/decode-light.svg" width="720" alt="Decode tok/s at 4K: Strim 75.3, then rapid-mlx 50.1, then oMLX 33.5, then mlx-vlm 32.7, then mlx-lm 30.1"></picture></p>

| Workload | Strim | Best other engine | Ratio |
|---|---:|---:|---:|
| Decode, 4K context (tok/s) | 75.3 | 50.1 (rapid-mlx) | **1.50x** |
| 4 agents, shared 16K prefix (tok/s) | 9.77 | 3.47 (mlx-vlm) | **2.81x** |
| Peak memory, whole run (GB, lower is better) | 30.8 | 35.9-37.5 | **1.17x** |
| Cold 32K prompt, first token (s, lower is better) | 37.1 | 35.5 (mlx-vlm) | 0.96x, slower |
| 4 concurrent requests, aggregate (tok/s) | 69.2 | 71.7 (rapid-mlx) | 0.97x, slower |
| 8 concurrent requests, aggregate (tok/s) | 76.4 | 74.7 (mlx-vlm) | **1.02x** |

<sub>Apple M5 Max, 64 GB, macOS 27.0.1, Qwen3.8-27B 4-bit, one engine at a time, median of 2 passes, 2026-10-28, build ee9f9d8. Ratio above 1 means Strim is better. Not a fit if you want many models or a model browser: use Ollama or LM Studio. [Every cell and method](https://megasoft1978.github.io/strim-engine/benchmarks.html) · [raw data](bench/results/h2h-final3-20261028) · MIT · Not affiliated with Qwen, Alibaba or Apple.</sub>
