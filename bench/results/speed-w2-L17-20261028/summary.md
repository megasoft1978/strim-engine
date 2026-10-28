# L17: Ternary-Bonsai-2-27B 2-bit spike (16 GB tier) - 2026-10-28

Decision: **KILL as a quality tier at current evidence (gate 4, KL).** Mechanics all work (gates 1-3 pass, output coherent, tool calls intact, footprint fits). Quality gate fails by 6.6x vs 4-bit.

## Gates
1. Spec (spec.md): PASS. Fully defined by hadamard.json + per-module `.signs` tensors + config. No vendor Python used.
2. Load: PASS. 402 quantized modules all `affine 2-bit g128` through the config-driven shape cross-check; 402 `.signs` tensors equal hadamard.json (0 mismatches); 401 declared weight_names all present, 0 undeclared quantized modules. File sha256 matches files.json. raw/load.txt.
3. Hadamard transform (Sources/StrimCore/Hadamard.swift, MLX `hadamardTransform` on [K/1024,1024] + f32 sign multiply): PASS. Bit-exact vs brute-force Sylvester matrix for n=8/64/1024 (`strim bonsaispike unit`, Tests/StrimCoreTests/HadamardTests.swift 2 tests pass; the swift-test metallib needs `mlx.metallib` copied next to the test binary, same for every MLX test in this snapshot build).
   Orientation found empirically: H(x*s) -> prose ppl 8.1, top-1 57%; s*H(x) -> ppl 603910, top-1 0% (raw/nll_prose_o*.txt). Embedding rows use the inverse s*H(row).
4. Layer-wise: PASS (raw/layers.txt): no NaN/Inf; bf16 hidden absmax 960 at layer 63. fp16 activations not used because the engine GDN Metal kernels are bf16-only (STRIM_BONSAI_ACT=f16 untested).
   Coherence (raw/gen_bonsai.out vs raw/gen_4bit.out, greedy, no MTP, 10 prompts): all coherent; code correct (fib, Python avg fix); both Qwen tool-call prompts emit well-formed `<tool_call><function=...><parameter=...>` and stop. Thinking-style preamble present as in the 4-bit outputs.
   **KL vs qwen38-8bit reference (quanteval cmp, same windows as the oQ ladder, raw/kl_bonsai.txt):**
   | set | meanKL bonsai | meanKL 4-bit | top1 bonsai | top1 4-bit | ppl ref -> bonsai | ppl 4-bit |
   |---|---|---|---|---|---|---|
   | code text | 0.229 | 0.0347 | 0.866 | 0.948 | 2.350 -> 2.817 (+20%) | 2.399 (+2%) |
   | prose text | 0.323 | 0.0504 | 0.773 | 0.886 | 5.130 -> 6.515 (+27%) | 5.308 (+3.5%) |
   | code gen64 | 0.136 | 0.0215 | 0.898 | 0.949 | | |
   | prose gen64 | 0.174 | 0.0257 | 0.840 | 0.891 | | |
   Caveat: Bonsai is a re-trained ternary model, so KL vs Qwen3.8-8bit mixes quantization error with intended distillation drift; ppl on identical text is the model-independent number and is also clearly worse (+20-27% vs +2-3.5%). The gate as specified ("KL far above the oQ ladder") fails. The vendor's 98.2% benchmark retention is not contradicted by this, only not confirmed; no agentic/long-run eval was done.

## Footprint (phys_footprint, indicative; watchdog csv in raw/*.watch.csv)
- Load, text only (vision_tower tensors dropped after load; the 0.86 GiB tower is in the same single shard, so a one-time 8.0 GiB read, then 7.10 GiB MLX active): footprint 8.64 GiB right after first forward incl. MLX buffer cache.
- Default MLX cache, 2048-token chunks: 8K ctx peak 11.17 GiB; 16K ctx peak 12.07 GiB (above 10.5 GiB: FAIL as configured).
- Lean (cache limit 256 MB, 512-token chunks): 8K 9.03 GiB; 16K **9.86 GiB** peak (watchdog 10.19 GiB) = under 10.5 GiB, bf16 KV, trie off, no other state. So the footprint gate passes only with the lean memory plan.
## Speed (loaded machine, other lanes on the GPU; indicative)
- Plain decode, no MTP: 46-50 tok/s at ~70-400 token prompts (4-bit plain same harness: 28-31 tok/s, i.e. 1.6x, matches bandwidth ratio); 43 tok/s at 16K, 45 at 8K (lean).
- Prefill: ~800-830 tok/s at 8K/16K (4-bit ~1000 per prescreen B5). Hadamard + F32->bf16 cast overhead not isolated.

## Productionize estimate (only if quality is re-opened, e.g. a better 2-bit rung or an agentbench pass)
- Loader: rotation metadata (done in spike), text-only shard repack or selective tensor load, index generation, config key mapping: 1-2 d.
- Activation transform in every linear: done via WeightStore.qmm keyed on K (valid because all modules of one width share the sign vector; verified). Needs a fused sign+Hadamard Metal kernel (currently ~4 extra dispatches x ~400 projections/token) and compile-graph/pipelining check: 2-3 d. Isolated cost not measured.
- MTP: none shipped; graft of the 4-bit head unmeasured, acceptance likely low: 2 d to measure.
- Tier picker, admission/memory plan for 16 GB (cache cap, chunk 512, KV q8 optional), prefix-disk fingerprint, per-quant goldens, tests: 4-6 d.
- Total ~2 weeks. Main risk is quality (+20-27% ppl vs the 8-bit base on our corpora, top-1 77-87%), not mechanics; unknown behavior in long agent runs. Recommendation: do not productionize now; revisit only with an agentbench run on this model (cheap now: the spike CLI and quanteval already work) if a 16 GB tier becomes a priority.

## Files
spec.md, run_wd.sh, gen_all.sh, prompts/p01-p10.json, raw/ (load, layers, nll_*, kl_bonsai, gen_*.out, ctx*, ctxlean*). Code: Sources/StrimCore/Hadamard.swift, 5 small hooks in Sources/StrimCore/Weights.swift, Sources/StrimCLI/Cmd_BonsaiSpike.swift (+1 dispatch line in Commands.swift), Tests/StrimCoreTests/HadamardTests.swift. Model: models/qwen38-bonsai2-2bit (untracked, 8.0 GiB + model.safetensors.index.json written from the header).
