# fingerprint: tensorfold

- checkpoint: same
- features claimed: parallel 4 slots, drafts on by default (--no-drafts off), prompt cache 16 GiB default
- engine version: tensorfold-native 1.0.12
- checkpoint quantization (config.json): {"group_size": 64, "bits": 4, "mode": "affine"}
- vendor source: vendor/TensorFold; keyword-hit files: 29
- launch [default]: `tensorfold serve models/qwen38-4bit --port 8651 --parallel 4 --no-update-check`
  - time-to-ready: 4.0 s; RSS idle 21553312 kB, peak 21586064 kB; model id: qwen38-4bit
  - startup log hits: info: prompt cache: 13.0 GiB from 13.0 GiB free under the 70% cap (23.8 GiB in use once loaded and 6.0 GiB its streams take on first use, 64 GiB of RAM, 2 GiB kept for pr
  - startup log hits: [tensorfold] serving qwen38-4bit at http://127.0.0.1:8651/v1 (sampling: temperature 1.0, top_k 20, top_p 0.95; drafts: on; context: 32768; loaded in 3.8s)
  - startup log hits: info: prompt cache: 75 tokens, resumed at 0, kept 0; 0 states, 0 MiB and 0 MiB spare of 13267 MiB (hits 0, misses 1, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-50f8b346f3643977c1023ab5c8c6adc8 prompt=75 cached=0 thinking=False effort=none tokens=16 sha=6a98a6487fd1 finish=length rounds=15 accepted=0/0
  - startup log hits: info: prompt cache: 104 tokens, resumed at 0, kept 0; 2 states, 305 MiB and 0 MiB spare of 13267 MiB (hits 1, misses 2, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-3c5242fc22fdd740e6e9d7a6c923f18f prompt=104 cached=0 thinking=False effort=none tokens=64 sha=2f84a7a4c1b5 finish=length rounds=63 accepted=0/0
  - startup log hits: info: prompt cache: 71 tokens, resumed at 0, kept 0; 4 states, 619 MiB and 0 MiB spare of 13267 MiB (hits 2, misses 3, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-22f70e3ba831e8797049485e7113b06f prompt=71 cached=0 thinking=False effort=none tokens=64 sha=4c61495c9a7b finish=length rounds=63 accepted=0/0
  - startup log hits: info: prompt cache: 42 tokens, resumed at 0, kept 0; 6 states, 930 MiB and 0 MiB spare of 13267 MiB (hits 3, misses 4, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-0931e6ed40b44594d2fbe95c8bc30076 prompt=42 cached=0 thinking=False effort=none tokens=64 sha=873982fb9ac5 finish=length rounds=63 accepted=0/0
  - startup log hits: info: prompt cache: 42 tokens, resumed at 0, kept 0; 8 states, 1237 MiB and 0 MiB spare of 13267 MiB (hits 4, misses 5, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-7b9add3435fd89904259d1d2e0c10356 prompt=42 cached=0 thinking=False effort=none tokens=64 sha=873982fb9ac5 finish=length rounds=63 accepted=0/0
  - startup log hits: info: prompt cache: 111 tokens, resumed at 107, kept 0; 8 states, 1237 MiB and 0 MiB spare of 13267 MiB (hits 5, misses 5, evicted 0, refused 0, failed 0)
  - startup log hits: info: prompt cache: 71 tokens, resumed at 0, kept 0; 9 states, 1390 MiB and 0 MiB spare of 13267 MiB (hits 5, misses 6, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-4d302c314f0937fb9fe89038a11adafb prompt=71 cached=0 thinking=False effort=none tokens=64 sha=4c61495c9a7b finish=length rounds=63 accepted=0/0
  - startup log hits: info: prompt cache: 140 tokens, resumed at 136, kept 0; 9 states, 1390 MiB and 0 MiB spare of 13267 MiB (hits 6, misses 6, evicted 0, refused 0, failed 0)
  - startup log hits: info: prompt cache: 104 tokens, resumed at 0, kept 0; 10 states, 1546 MiB and 0 MiB spare of 13267 MiB (hits 6, misses 7, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-00c6cdd926bde53f4c696b5df29052e9 prompt=104 cached=0 thinking=False effort=none tokens=64 sha=2f84a7a4c1b5 finish=length rounds=63 accepted=0/0
  - startup log hits: info: prompt cache: 173 tokens, resumed at 169, kept 0; 10 states, 1546 MiB and 0 MiB spare of 13267 MiB (hits 7, misses 7, evicted 0, refused 0, failed 0)
  - startup log hits: info: prompt cache: 4107 tokens, resumed at 0, kept 2; 13 states, 2254 MiB and 0 MiB spare of 13267 MiB (hits 7, misses 8, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-71e08228caff546617810fcbb6d324ee prompt=4107 cached=0 thinking=False effort=none tokens=16 sha=552775e6fafa finish=length rounds=15 accepted=0/
  - startup log hits: info: prompt cache: 4107 tokens, resumed at 3, kept 1; 16 states, 3466 MiB and 0 MiB spare of 13267 MiB (hits 9, misses 8, evicted 0, refused 0, failed 0)
  - startup log hits: [tensorfold] done chatcmpl-ec069a26e7cdacb1884adce8ed6a3070 prompt=4107 cached=3 thinking=False effort=none tokens=16 sha=552775e6fafa finish=length rounds=15 accepted=0/
  - startup log hits: info: prompt cache: 1035 tokens, resumed at 3, kept 1; 19 states, 4485 MiB and 0 MiB spare of 13267 MiB (hits 11, misses 8, evicted 0, refused 0, failed 0)
  - startup log hits: info: prompt cache: 1035 tokens, resumed at 3, kept 1; 20 states, 4696 MiB and 0 MiB spare of 13267 MiB (hits 12, misses 8, evicted 0, refused 0, failed 0)

## --help keyword lines (speculative/MTP/cache/batching/quant)
- usage: tensorfold serve [-h] [--host HOST] [--port PORT] [--name NAME] [--chat-template FILE] [--alias ALIAS] [--api-key API_KEY] [--api-key-file API_KEY_FILE] [--metrics

## notes
- [default] stopped: port free after = True
- ANE/NAX use: unknown unless listed in log hits or help lines above.
- batching/prefix-cache behavior: see help lines and cache columns in summary.md.
