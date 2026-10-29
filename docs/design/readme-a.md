<!-- README layout A: ember editorial. Banner and logo are static SVG files. -->
<p align="center"><img src="docs/design/banner-a.svg" alt="Strim: fast enough to feel like a server" width="100%"></p>

<p align="center"><b>One Swift binary that runs Qwen3.8-27B on your Mac like a server.</b><br>A local backend for Claude Code and Codex.</p>

```sh
brew install megasoft1978/strim/strim   # or the curl script, see docs/INSTALL.md
strim pull && strim serve
```

**68.3 tok/s** decode, the fastest of 8 engines on an M5 Max (2026-10-26 run; the later build does 70.7 tok/s at 4K).

| Today, vs | rapid-mlx | mlx-vlm |
|---|---|---|
| Decode at 4K / 32K | 1.48x / 1.50x | 2.30x / 2.10x |
| 4 agents, shared prefix | 2.92x | 2.77x |
| Median first token, 8 agents | 1.71x | 1.73x |
| Cold 32K prefill | 0.96x | 0.95x |

Not faster: cold 32K prefill and 8-agent throughput (0.94x of mlx-vlm).

[Site](site/index.html) · [Benchmarks](site/benchmarks.html) · [Install](docs/INSTALL.md) · MIT
