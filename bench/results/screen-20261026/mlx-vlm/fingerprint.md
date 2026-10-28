# fingerprint: mlx-vlm

- checkpoint: same
- features claimed: MLX VLM server (text path used); no MTP claimed
- engine version: 0.4.4
- checkpoint quantization (config.json): {"group_size": 64, "bits": 4, "mode": "affine"}
- vendor source: vendor/mlx-vlm/mlx_vlm; keyword-hit files: 129
- launch [default]: `mlx_vlm.server --model /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit --port 8651`
  - time-to-ready: 5.1 s; RSS idle 16576864 kB, peak 16625952 kB; model id: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None
  - startup log hits: Stream finished, cleared cache.
  - startup log hits: Using cached model: /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit, Adapter: None

## --help keyword lines (speculative/MTP/cache/batching/quant)
- [--kv-quant-scheme {uniform,turboquant}]
- [--quantized-kv-start QUANTIZED_KV_START] [--reload]
- --kv-bits KV_BITS     Number of bits for KV cache quantization.
- --kv-quant-scheme {uniform,turboquant}
- KV cache quantization backend. Fractional --kv-bits
- values use TurboQuant automatically.
- Group size for uniform KV cache quantization.
- Maximum KV size for the prompt cache (tokens).
- --quantized-kv-start QUANTIZED_KV_START
- Start index (of token) for the quantized KV cache.

## notes
- [default] stopped: port free after = True
- ANE/NAX use: unknown unless listed in log hits or help lines above.
- batching/prefix-cache behavior: see help lines and cache columns in summary.md.
