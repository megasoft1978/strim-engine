# fingerprint: mlx-lm

- checkpoint: same
- features claimed: continuous batching (decode/prompt concurrency 4), prompt cache; no MTP in this launch
- engine version: 0.31.2
- checkpoint quantization (config.json): {"group_size": 64, "bits": 4, "mode": "affine"}
- vendor source: vendor/mlx-lm/mlx_lm; keyword-hit files: 15
- launch [default]: `mlx_lm.server --model models/qwen38-4bit --port 8651 --decode-concurrency 4 --prompt-concurrency 4`
  - time-to-ready: 5.1 s; RSS idle 15582464 kB, peak 15775648 kB; model id: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit
  - startup log hits: 2026-10-26 16:55:20,762 - INFO - Prompt Cache: 0 sequences, 0.00 GB
  - startup log hits: 2026-10-26 16:55:21,679 - INFO - Prompt Cache: 3 sequences, 0.48 GB
  - startup log hits: 2026-10-26 16:55:23,972 - INFO - Prompt Cache: 6 sequences, 0.96 GB
  - startup log hits: 2026-10-26 16:55:26,270 - INFO - Prompt Cache: 9 sequences, 1.44 GB
  - startup log hits: 2026-10-26 16:55:28,514 - INFO - Prompt Cache: 10 sequences, 1.60 GB
  - startup log hits: 2026-10-26 16:55:30,601 - INFO - Prompt Cache: 10 sequences, 1.60 GB
  - startup log hits: 2026-10-26 16:55:32,694 - INFO - Prompt Cache: 10 sequences, 1.60 GB
  - startup log hits: 2026-10-26 16:55:34,784 - INFO - Prompt Cache: 10 sequences, 1.60 GB
  - startup log hits: 2026-10-26 16:55:39,798 - INFO - Prompt Cache: 10 sequences, 2.39 GB
  - startup log hits: 2026-10-26 16:55:44,807 - INFO - Prompt Cache: 10 sequences, 3.18 GB
  - startup log hits: 2026-10-26 16:55:44,913 - INFO - Prompt Cache: 10 sequences, 3.18 GB
  - startup log hits: 2026-10-26 16:55:45,018 - INFO - Prompt Cache: 10 sequences, 3.18 GB
  - startup log hits: 2026-10-26 16:55:45,124 - INFO - Prompt Cache: 10 sequences, 3.18 GB

## --help keyword lines (speculative/MTP/cache/batching/quant)
- [--draft-model DRAFT_MODEL]
- [--num-draft-tokens NUM_DRAFT_TOKENS]
- [--decode-concurrency DECODE_CONCURRENCY]
- [--prompt-concurrency PROMPT_CONCURRENCY]
- [--prompt-cache-size PROMPT_CACHE_SIZE]
- [--prompt-cache-bytes PROMPT_CACHE_BYTES] [--pipeline]
- --draft-model DRAFT_MODEL
- A model to be used for speculative decoding.
- --num-draft-tokens NUM_DRAFT_TOKENS
- Number of tokens to draft when using speculative
- --decode-concurrency DECODE_CONCURRENCY
- When a request is batchable then decode that many
- requests in parallel
- --prompt-concurrency PROMPT_CONCURRENCY
- When a request is batchable then process that many
- prompts in parallel
- --prompt-cache-size PROMPT_CACHE_SIZE
- Maximum number of distinct KV caches to hold in the
- prompt cache
- --prompt-cache-bytes PROMPT_CACHE_BYTES
- Maximum size in bytes of the KV caches
- --pipeline            Use pipelining instead of tensor parallelism

## notes
- [default] stopped: port free after = True
- ANE/NAX use: unknown unless listed in log hits or help lines above.
- batching/prefix-cache behavior: see help lines and cache columns in summary.md.
