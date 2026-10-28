# Third-party material

Strim is MIT-licensed (`LICENSE`). This file lists third-party software, models and data that Strim
depends on, copies or adapts, and what it only references or measures. Licenses were read from the
upstream LICENSE files (the `vendor/` checkouts used for study and benchmarking are not part of this
repository and are git-ignored).

## Linked dependencies (SwiftPM, not copied)

| Project | License | Use |
|---|---|---|
| mlx-swift 0.32.3 (ml-explore/mlx-swift, Apple) | MIT | Array/Metal runtime, linked via SwiftPM. It bundles MLX (ml-explore/mlx, MIT). |
| swift-numerics 1.1.1 (apple/swift-numerics) | Apache-2.0 | Transitive dependency of mlx-swift. |

## Adapted code (attribution kept in `NOTICE`)

| Where | Source | License | Note |
|---|---|---|---|
| `Sources/StrimCore/GDNMetal.swift`, `blockedKernel` | Rapid-MLX `rapid_mlx/gdn_prefill.py`, itself adapted from oMLX | Apache-2.0 | Metal kernel for blocked Gated DeltaNet prefill, ported to a Swift `MLXFast.metalKernel`. Compatible with MIT; Apache-2.0 text in `LICENSES/Apache-2.0.txt`, credit in the file header of `GDNMetal.swift` and in `NOTICE`. |
| `bench/agenttasks/tasks/*` (snapshots, `setup.patch`, `solution.patch`) | more-itertools (MIT), python-semver (BSD-3-Clause), jmespath.py (MIT), parse (MIT), google/uuid (BSD-3-Clause), spf13/pflag (BSD-3-Clause), dustin/go-humanize (MIT), cachetools (MIT), xmltodict (MIT) | as listed | Small test-fix / refactor / QA task corpus. URLs, commits and licenses are in `bench/agenttasks/manifest.json`; each snapshot archive carries the upstream LICENSE file. These files stay under their upstream licenses, not under Strim's MIT license. |

Behaviours re-implemented from reading (no code copied) and credited for the idea: the Qwen
tool-call and reasoning-toggle policy follows Rapid-MLX (Apache-2.0), and the chat template is a
Swift re-implementation of the Qwen template.

## Models and data

| Item | License | Note |
|---|---|---|
| Qwen3.8-27B / Qwen3.6-35B-A3B weights and tokenizer | Apache-2.0 (per the model cards) | Not redistributed. `models/` is git-ignored; users download weights themselves. |
| `bench/fixtures/tokenizer_parity.json` | derived | 33 special-token ids plus encode/decode/stream test cases (short text and the Qwen token ids it maps to). It contains no vocabulary or merge table, so it is not a copy of the tokenizer. |
| `bench/fixtures/template_parity.json`, `prompt_parity.json`, `prompt_adversarial.json` | derived | Rendered chat-template output for test conversations. This includes fixed strings from the Qwen chat template (Apache-2.0); attribution above applies. |
| `bench/draft_vocab_*.json` | own | Lists of token ids ranked by frequency in this repository's text; the tokenizer hash identifies the tokenizer used. No token strings. |

## Benchmarked against (not included)

Nothing from these projects is copied, linked or shipped. They are named only as benchmark targets in `bench/results/` and `site/`.

| Project | License | Use |
|---|---|---|
| mlx-lm (Apple) | MIT | Baseline engine and reference outputs. |
| mlx-vlm (Prince Canuma) | MIT | Baseline engine. |
| llama.cpp (ggml authors) | MIT | Baseline engine (`llama-server`). |
| Rapid-MLX | Apache-2.0 | Baseline engine and design reference (its kernel is adapted above). |
| oMLX (jundot) | Apache-2.0 | Baseline engine. |
| TensorFold | Apache-2.0 | Baseline engine. |
| Ollama | external binary | Baseline engine, installed separately. |

## Studied or used with the repo, not included

| Project | License | Use |
|---|---|---|
| mlx-engine (LM Studio) | MIT | Studied for design comparison (docs only). |
| ax-engine, exo | Apache-2.0 | Studied for design comparison (docs only). |
| Harness2 (google-research) | Apache-2.0 | Agent harness that the scripts in `integrations/harness2/` drive; installed separately. |

Third-party engines named in benchmark results are trademarks of their owners and are used only to
identify them.
