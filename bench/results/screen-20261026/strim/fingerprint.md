# fingerprint: strim

- checkpoint: same
- features claimed: MTP spec decode (depth 2); batched scheduler benchserve (4 slots); in-process CLI, no HTTP
- engine version: git bfb1e2d
- checkpoint quantization (config.json): {"group_size": 64, "bits": 4, "mode": "affine"}
- vendor source: Sources/; keyword-hit files: None

## --help keyword lines (speculative/MTP/cache/batching/quant)
- CLI: benchspec, benchprefill, benchserve (no HTTP server)

## notes
- in-process CLI rows; method labeled per row
- ANE/NAX use: unknown unless listed in log hits or help lines above.
- batching/prefix-cache behavior: see help lines and cache columns in summary.md.
