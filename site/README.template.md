# Strim

**Run Qwen3.8-27B on your Mac like a server. One Swift binary, a local backend for Claude Code and Codex.**

![MIT](https://img.shields.io/badge/license-MIT-blue) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-macOS%2014%2B-lightgrey) ![Swift 6](https://img.shields.io/badge/Swift-6-orange)

![{{@hero_alt}}](site/assets/h2h-hero.svg)

*Own benchmark against rapid-mlx and mlx-vlm: Qwen3.8-27B 4-bit, 64 GB M5 Max (the only machine tested), medians of {{final.claim.passes|n}} passes ({{@runlink}}).*

```sh
brew install megasoft1978/strim/strim
strim pull        # Qwen3.8-27B 4-bit + MTP head, about 15 GB, resumable
strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
```

Then point Claude Code at `ANTHROPIC_BASE_URL=http://127.0.0.1:8203`; the bearer token is in `~/.strim/token`. Other install paths and Codex: [INSTALL](docs/INSTALL.md), [CLIENTS](docs/CLIENTS.md).

{{@proofs}}

{{@notfaster}}

> {{@validity}}

{{@glance}}

[Every cell and the method](site/benchmarks.html) · [Install](docs/INSTALL.md) · [Clients](docs/CLIENTS.md) · [Architecture](docs/ARCHITECTURE.md) · [Benchmarking](docs/BENCH.md) · [Security](SECURITY.md)

MIT, see [LICENSE](LICENSE). Third-party notices: [NOTICE](NOTICE).
