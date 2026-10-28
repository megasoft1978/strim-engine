# Strim — completion status (2026-10-25)

Evidence-based status for the v1 objective. Every number below was measured on this machine
(Mac Studio, M5 Max, 64 GB) and is reproducible with the commands in the repo.

## Product

| Requirement | Evidence |
|---|---|
| Local OpenAI endpoint | `strimd :8200`, `/v1/models`, `/v1/chat/completions` (stream + non-stream) |
| Anthropic endpoint (Claude Code) | `/v1/messages` stream/non-stream, tool_use translation, `/v1/messages/count_tokens` |
| MCP | narrow tools (`summarize`, `review_diff`, `explain_error`, `draft_patch`, `generate_tests`, `classify`) + `strim_status/switch/chat`; registered in Codex (`~/.codex/config.toml`) and Claude Code (`claude mcp list` → connected) |
| MCP delegation metrics | 6 real calls: 17,966 tokens in / 771 out = **17,195 kept local (96%)**; latency p50 3.1 s, max 16.8 s; 6/6 returned results (from the delegation log; the stats script was retired) |
| Two modes | `strim-speed` = A3B 4-bit (~127 tok/s), `strim-quality` = 27B 4-bit + MTP (~50 tok/s) |
| Single resident + fast switch | one backend at a time; **5.5–6.9 s** switch, verified both directions |
| Prefix cache | repeated 4k prompt: TTFT **8.72 s → 0.20 s** |
| Batched decode + scheduler | 2–4 sequences with different prompt lengths; continuous scheduler (serial prefill, batched decode, join/leave, EOS, priority admission): 8 requests × 16 tokens = **35.8 / 51.9 tok/s aggregate** at 2/4 slots vs 23.5 sequential; with 4 interactive + 4 background, interactive TTFT **1.29 s / 1.22 s** vs background 3.25 / 2.64 s; tokens match sequential. No MTP/HTTP/preemption yet. |
| Priority classes | 3 background streams + 1 interactive: interactive slot wait **0.0 s**, background total wait **2.57 s** (background capped at 1, interactive never queued behind it; 2026-10-26, speed backend) |
| Menu-bar app | `StrimApp` builds/launches; status, speed/quality switch, status window, quit |
| Smoke suite (historical: `bench/smoke_service.py` removed 2026-10-27) | **10/10** at the time |

## Quality

Three real TypeScript/React tasks, run through the product (`strimd` → `strim-quality`), hidden
Vitest tests injected only at verification:

| Task | Result | Tests | Agent |
|---|---|---:|---:|
| `canonical-merged-ingredient-names` | PASS | 2/2 | 150 s |
| `import-prep-note-text` | PASS | 5/5 | 124 s |
| `linked-recipe-macros` | PASS | 4/4 | 295 s |

Earlier standalone runs: 5/5 on 4-bit (including 3 repeats of `linked-recipe-macros`), 1/1 on 8-bit.
No test files were modified in any run.

## Swift engine

| Capability | Evidence |
|---|---|
| Weight loading | 2,180 tensors, 16.05 GB, 3 shards, 498 quantized layers |
| GDN layer | mean abs diff 4e-5, max 0.0625 (1 bf16 ulp) |
| Attention layer | mean abs diff 3.6e-4, max 0.0078 |
| Full model logits | same argmax (198) and same top-5 order as `mlx-vlm` |
| Greedy generation | **32/32 tokens identical** to the Python reference |
| MTP head | 85% draft acceptance (17/20) on a real prompt |
| MTP speculative decode | depth 2 default (depth 3 loses: +5.2 ms for +0.17 tok/pass at 36% accept); exact rollback; 4-5 of 8 prompts token-identical to depth-0 greedy, the rest are near-tie flips |
| Decode speed (release build) | Depth-2 corpus (8 prompts, 64 tokens) **55.1 tok/s decode-only / 54.9 end-to-end** mean with the **kernel default + adaptive MTP depth 2–4** (fixed depth 2: 49.2); natural prompt 41.3 tok/s, depth 0 **25.2 tok/s** (S=1 pass 36–40 ms). Prefill **827–863 tok/s at 1K, 825–846 at 4K** after the kernel and last-token-only lm_head, up from 251–266; the bf16 GEMM peak (62.9 TF/s) puts a 4K prefill at ~1,170 tok/s. Numbers are from a loaded machine (UTM VM + Chrome); the docs' idle corpus was higher. See [SWIFT-NEXT.md](SWIFT-NEXT.md). |

> **Re-measured 2026-10-26.** The kernel is now the default: its conv is bit-exact and its
> recurrence matches MLX's gemv FMA association, so `gen 16`, depth-0 EXACT and an 8-prompt
> corpus that ties the tensor path 7/8 all pass. Adaptive MTP depth is also default
> (`STRIM_MTP_FIXED=1` opts out): +7.4% corpus, +11.3% on code, same 7/8 EXACT. The residual difference from the tensor path
> is TF32 in MLX's recurrence; `STRIM_GDN_TENSOR=1` restores that reference path. Prefill is
> 3.2× faster; 1,200 tok/s is above the measured ~890 tok/s qmm roofline on this machine.

## Known limits (documented, not hidden)

1. **The Swift engine is not the shipping backend.** The release build now does **41.3 tok/s**
   on the natural prompt at depth 2 (50.3 corpus mean, kernel default), versus rapid-mlx's 48.2
   on the same model and prompt mix; prefill is 799 tok/s at 4k versus rapid-mlx's 1,150–1,560.
   The product still uses rapid-mlx for both modes; Swift is the parity/ownership implementation
   and the base for the kernel/prefill work described in `docs/SWIFT-NEXT.md`.
2. **Speculative exactness is text-dependent.** Rejected drafts are rolled back exactly (KV slice +
   per-token GDN state), so no token is re-forwarded; but a batched verify is not bit-identical to
   per-token bf16 math, so a near-tie can still flip. The 8-prompt corpus puts the flip rate at
   4-5 of 8 prompts in **both** paths, so "107-token natural generations are token-identical" was
   one prompt and does not generalise. Only depth 0 is exact as a configuration.
3. **Prefix cache is product-level** (rapid-mlx), not yet in the Swift runtime.
4. Menu-bar app is a shell: status and switching, not an embedded chat UI.
5. Swift decode is **bandwidth/op-efficiency bound, not dispatch bound** (measured: only 2.6 ms of a
   37.7 ms pass is graph construction, and `compile` saves 3.1 ms, not the 13 ms a dispatch gap would
   imply). The pass runs at ~330 GB/s versus a measured 530 GB/s streaming ceiling. Per-op
   `mx.compile` returned 0–11%; a hand-written 4-bit GEMV was slower than MLX's (150–390 vs
   221–784 GB/s) and is not wired in; fusing the four GDN projections is 1.73× in isolation but
   ~1% in-pass. The fused GDN recurrence kernel is **faster** and is now the **default**
   (5–23% per pass, 50.3 vs 41.0 tok/s corpus); its conv is bit-exact and its gemv FMA
   association matches MLX, leaving only MLX's TF32 in the tensor path as a difference
   (`STRIM_GDN_TENSOR=1` restores that reference path). It also runs prefill (799 tok/s at 4k
   vs 251 before). The remaining gap is prefill compute (~90% of the measured qmm roofline) and
   the MTP head/bookkeeping — see `docs/SWIFT-NEXT.md`.

## Reproduce

```sh
.build/release/strim serve --port 8200     # product
# bench/smoke_service.py removed 2026-10-27 (no Swift port yet); last recorded result 10/10
swift build -c release --disable-sandbox
.build/release/strim gen models/qwen38-4bit 32
.build/release/strim genmtp models/qwen38-4bit models/qwen38-mtp-4bit 32
.build/release/strim benchspec models/qwen38-4bit models/qwen38-mtp-4bit 48 2
.build/debug/StrimApp                                     # menu bar
```
