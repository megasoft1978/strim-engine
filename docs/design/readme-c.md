<!-- README layout C: aurora glass. Centered banner, mono details. -->
<p align="center"><img src="docs/design/banner-c.svg" alt="Strim: your Mac, now a local AI server" width="100%"></p>

<p align="center"><code>brew install megasoft1978/strim/strim</code></p>

<p align="center">
One Swift binary. Qwen3.8-27B on Apple silicon. A local backend for <b>Claude Code</b> and <b>Codex</b>.
</p>

```sh
strim pull     # pinned revision, resumable, verified
strim serve    # point Claude Code or Codex at the local port
```

<p align="center"><b>1.5x</b> decode &nbsp;·&nbsp; <b>2.8x</b> shared-prefix agents &nbsp;·&nbsp; <b>1.7x</b> faster first token</p>

All 8 engines, decode tok/s (M5 Max, 2026-10-26): **Strim 68.3**, rapid-mlx 50.6, oMLX 33.8, mlx-vlm 32.2, mlx-lm 30.1, tensorfold 30.1, llama.cpp 27.4, Ollama 24.0.

Where it is not faster: cold 32K prefill (0.95x) and 8-agent throughput (0.94x of mlx-vlm).

<p align="center"><a href="site/index.html">Site</a> · <a href="site/benchmarks.html">Benchmarks</a> · <a href="docs/INSTALL.md">Install</a> · MIT</p>
