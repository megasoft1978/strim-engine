<!-- README layout B: Swiss paper. The banner carries the one big number. -->
<img src="docs/design/banner-b.svg" alt="Strim: 68.3 tok/s decode, fastest of 8 engines" width="100%">

# Strim
Qwen3.8-27B on your Mac, like a server. One Swift binary, a local backend for Claude Code and Codex.

```sh
brew install megasoft1978/strim/strim
strim pull
strim serve
```

| | rapid-mlx | mlx-vlm |
|---|---|---|
| Decode, 4K context | **1.48x** | **2.30x** |
| Decode, 32K context | **1.50x** | **2.10x** |
| Shared 16K prefix, 4 agents | **2.92x** | **2.77x** |
| Median first token, 8 agents | **1.71x** | **1.73x** |
| Cold 32K prefill | 0.96x | 0.95x |
| 8-agent throughput | 1.07x | 0.94x |

Ratios are Strim over the rival, above 1.00x is faster. Apple M5 Max, 64 GB, 2026-10-28 build.
[Benchmarks](site/benchmarks.html) · [Install](docs/INSTALL.md) · [Docs](docs/ARCHITECTURE.md) · MIT
