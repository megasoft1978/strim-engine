![Strim: Qwen3.8-27B on your Mac, like a server. 75.3 tok/s decode, fastest among 5 engines in the current run, run of 2026-10-28](site/assets/banner.svg)

# Strim
One Swift binary that runs Qwen3.8-27B on your Mac like a server: a local backend for Claude Code and Codex.

![Strim over its best rival in each measurement, 1.00x is the same speed, above is faster, first-token times inverted: Decode at 4K context 1.50x over rapid-mlx; Decode at 32K context 1.24x over rapid-mlx; 4 agents on a shared 16K prefix 2.81x over mlx-vlm; 8 agents at once: median first token 1.66x over rapid-mlx; Cold 32K prompt: first token 0.96x over mlx-vlm; 8 agents at once: total throughput 1.00x over mlx-vlm.](site/assets/h2h-ratio.svg)
Not faster: cold 4K/16K/32K prefill + TTFT (2/3/4% behind mlx-vlm); c=4 512-token aggregate (3% behind rapid-mlx); c=8 512-token p95 first token (6% behind mlx-vlm); 4K prompt aggregate: c=4 2%, c=8 4% behind mlx-vlm. All losses: [benchmarks](site/benchmarks.html).

![The Strim menu-bar app with a running server, captured from a live session on a 64 GB M5 Max](site/assets/app/app-hero-live.png)

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
