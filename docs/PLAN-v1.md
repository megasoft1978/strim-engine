# Strim v1 — plan

> **Update 2026-10-25 (measured):** 6-bit + MTP is *slower* than 6-bit alone (21.2 vs 23.4 tok/s)
> because MLX's 6-bit small-batch verify path is slow. Revised: **4-bit + MTP is the speed mode**
> (31.6 → 51.1 tok/s, 19.5 GB), **8-bit + MTP is the quality mode** (17.2 → 33.3 tok/s, 30 GB).
> 6-bit stays only as a non-MTP compromise. 4-bit then passed 3/3 TypeScript/React tasks
> (`canonical-merged-ingredient-names`, `import-prep-note-text`, `linked-recipe-macros`), so it is the
> working default pending repetition. See [QUANTIZATION-2026-10-25.md](QUANTIZATION-2026-10-25.md)
> and [TASKS-2026-10-25.md](TASKS-2026-10-25.md).

**Decisions locked (2026-10-25):** product we use/sell daily · Qwen3.8-27B, 6-bit graded default /
8-bit quality mode · Swift + MLX Swift · 64 GB Mac Studio only for v1.

Companion: [exploration memo](EXPLORATION-2026-10-25.md) · [M5 Max research](m5-max-research.md) ·
[model selection](model-selection-2026-10.md)

---

## 1. What v1 is

A native macOS app + CLI + local OpenAI-compatible server that runs **one** model, Qwen3.8-27B,
fully resident on a 64 GB M5 Max, with:

- **MTP speculative decoding** — the model's own multi-token-prediction head, which `mlx-lm`
  currently discards. Target ~2× decode.
- **Prefix/radix cache** — repeated agent context re-prefills in ~1–2 s, not 35 s.
- **int8 KV** for the 16 full-attention layers; fp32 GDN state.
- **Memory governor** — hard wired ceiling, admission, pressure reaction, model switch.
- **Agent harness** — tools, context management, thinking preservation.

Everything above MLX is ours. MLX's kernels, tokenizer primitives and quantisation formats are not.

### Non-goals for v1

| Not doing | Why |
|---|---|
| Hand-written Metal kernels | 0.5–0.8× MLX track record; our own engine was 2.6× slower (§2 of the memo) |
| SSD expert streaming | ~5 tok/s on 16 GB; wrong product |
| Models other than Qwen3.8-27B | One model, deeply tuned, is the whole thesis |
| Macs below 64 GB | Model ladder comes after quality is proven |
| Python at runtime | Shipping constraint; Python only for benchmarks/quantisation |
| Vision / video input | Text-first; the vision tower stays unloaded |
| Concurrency beyond 1–2 sessions | Single-user product; batching later if measured |

---

## 2. Definition of done

### Functional

- Loads `mlx-community/Qwen3.8-27B-MTP-8bit` (and `-MTP-4bit`) from disk, verified digests.
- Chat + generate + tool calls; thinking mode on/off; 32 k and 64 k context modes.
- OpenAI-compatible `/v1/chat/completions` (stream + non-stream), `/v1/models`, cancel.
- CLI: `strim run`, `strim chat`, `strim serve`, `strim bench`, `strim models`.
- App: load/unload, chat, live tok/s and memory, context-mode switch.
- Clean unload, model switch, cancellation at any token, no orphan GPU memory.
- **Multi-session serving (added 2026-10-25):** 2–4 concurrent sessions with continuous batching,
  a shared prefix cache, and two priority classes (interactive / background) with token-boundary
  preemption. See [COMPETITORS-2026-10-25.md](COMPETITORS-2026-10-25.md) for the measured bar.

### Performance (this machine, quiet, median of 5)

| Metric | Gate | Reference |
|---|---:|---|
| Decode @16 k, 8-bit, MTP on | **≥ 40 tok/s** | 40.2 measured (oMLX, M5 Max) |
| Decode @64 k, 6-bit, MTP on | **≥ 30 tok/s** | 24.5 at 8-bit; 6-bit should exceed |
| Decode @1 k, 8-bit, MTP on | **≥ 50 tok/s** | 45.2 measured |
| Prefill @16 k | **≥ 700 tok/s** | 760–818 measured |
| 4 k TTFT (warm model) | **≤ 3 s** | rapid-mlx 2.6 s; ours 7.7 s today |
| 4 concurrent, distinct 4 k prompts, per-request decode | **≥ 80% of serial** | rapid-mlx 16.0 vs 17.4 |
| 4 concurrent aggregate (shared prefix) | **≥ 3× serial** | rapid-mlx 61 vs 17.8 identical prompts |
| Foreground TTFT under 3 background streams | **≤ 1.5× idle TTFT** | no competitor does this |
| TTFT, warm prefix @30 k | **≤ 2 s** | prefix cache |
| Cold start (load + first token) | **≤ 20 s** | 29 GB from SSD |
| Peak memory @64 k | **≤ 52 GB** | 60.1 GB working set |
| No swap growth, no pressure ≥ 2 | required | 64 GB hazard |

### Quality

- Token parity: greedy 128 tokens × 10 prompts, **exact** vs pinned `mlx-lm` reference on the same
  checkpoint.
- Task quality: 24 frozen coding tasks, pass rate **≥ mlx-lm 27B-8-bit baseline − 1 task**.
- Long context: 32 k needle + repo-QA check, no degradation vs reference.

### Reliability

- 8-hour soak with repeated 30 k-prefix turns: no panic, no leak > 1 GB, no swap growth.
- Cancellation mid-prefill and mid-decode leaves a usable engine.
- Killing the app never leaves the model wired.

---

## 3. Architecture

```
┌───────────────────────────────────────────────────────────────┐
│ StrimApp (SwiftUI)   StrimCLI   StrimServer (HTTP/SSE)        │
├───────────────────────────────────────────────────────────────┤
│ StrimAgent — tools, context manager, thinking, patch proposals │
├───────────────────────────────────────────────────────────────┤
│ StrimEngine — sessions, scheduler, MTP decoder, prefix cache,  │
│               KV/GDN state, sampler, memory governor           │
├───────────────────────────────────────────────────────────────┤
│ StrimCore — Qwen3.8 graph, safetensors/MLX-quant loader,       │
│             tokenizer + chat template, weight verification     │
├───────────────────────────────────────────────────────────────┤
│ MLX Swift 0.32.3 (Cmlx) — Metal 4, NAX, SDPA, quantised matmul │
│ + MLXFast.metalKernel for the GDN kernel (ported MSL)          │
└───────────────────────────────────────────────────────────────┘
```

### SwiftPM targets

| Target | Responsibility |
|---|---|
| `StrimCore` | `Qwen38Model`, `Weights` (safetensors + MLX quant), `Tokenizer`, `ChatTemplate`, `ModelID` |
| `StrimEngine` | `Engine` actor, `Session`, `KVCache`, `GDNState`, `PrefixCache`, `MTPDecoder`, `Governor`, `Sampler` |
| `StrimAgent` | tool registry, exec/file tools, context budget, history, patch proposals |
| `StrimServer` | Hummingbird routes, SSE, OpenAI schema, auth token, cancel |
| `StrimCLI` | ArgumentParser commands |
| `StrimApp` | SwiftUI shell over `Engine` |
| `StrimBench` | parity/speed/memory harness used by CI and the sprint |

Dependencies pinned: `mlx-swift 0.32.3`, `swift-transformers` (pinned commit), `hummingbird` (pinned
release), `swift-argument-parser`, `swift-crypto` (SHA-256), `swift-log`.

### Threading model

- One `Engine` actor owns the GPU. All MLX arrays are created/evaluated inside it.
- Tokenisation, HTTP, tools and UI run off-actor and hand work in as messages.
- Decode runs in **bursts of 32–64 steps per actor turn** (one `eval` per step, one hand-off per
  burst) — measured ~8% over per-token hand-off.
- Cancellation is a flag checked between steps and at prefill chunk boundaries; the actor always
  returns to a consistent cache state.

### Model graph (Qwen3.8-27B, `qwen3_5` text)

- 64 layers: 48 GatedDeltaNet (linear attention) + 16 gated full attention (`full_attention_interval = 4`).
- Hidden 5120, 24 Q heads / 4 KV heads, head_dim 256, partial RoPE 0.25 (mrope 11/11/10), θ = 1e7.
- MLP 17408, SwiGLU. Vocab 248 320 (tied? no — separate lm_head).
- **MTP:** `fc(concat(norm(embedding), norm(hidden))) → 1 MTPDecoderLayer → norm → lm_head`.
- Reference: `transformers 5.16.1` `models/qwen3_5/modeling_qwen3_5.py` for the backbone (MTP is
  stripped there), and **`mlx-lm` PR #990** (MIT, open, updated 2026-10-15) /
  `oMLX patches/mlx_lm_mtp/qwen35_model.py` (Apache-2.0) for the MTP head and rollback semantics.
  Port with attribution; keep their notices in `third_party/`.

### Caches and state

| State | Size @64 k | Format | Notes |
|---|---:|---|---|
| Full-attn KV (16 layers) | ~4.3 GB fp16 / ~2.2 GB int8 | `KVCache` per layer | quantise only the 16 full layers |
| GDN conv + recurrent state | ~0.15 GB | fp32 | snapshot for MTP rollback (ping-pong buffers) |
| Prefix cache | up to budget | radix over block hashes, COW snapshots | LRU eviction, per-session |
| Activations | ~1–2 GB | transient | chunked prefill |

MTP rollback: keep a copy of the 48-layer GDN state before drafting (≈0.3 ms at 500 GB/s), truncate KV
by `num_rejected`, restore state. Do not re-run the verified prefix.

### Memory governor

```
budget = min(installed * 0.80, recommendedWorkingSet)   // 51.2 GB on this machine
wired  = min(budget, 44 GB)                             // never the mlx-lm 75% default
admit  = weights + kv + state + activation_peak + 2 GB reserve <= budget
```

- Sample pressure/swap every 500 ms; degrade context mode before OOM.
- Reject a context request rather than silently quantise or drop tokens.
- Unload: drop arrays, clear cache, release wired limit, verify footprint.

### Server surface

`/v1/models`, `/v1/chat/completions` (SSE), `/health`, `/metrics` (tok/s, TTFT, peak memory),
`/v1/sessions/{id}/cancel`. OpenAI schema, one bearer token, localhost-only by default.

---

## 4. Phase 0 — 10-day measurement sprint (no product code)

Purpose: replace assumptions with numbers before committing three months.

### Setup (historical: Python env removed 2026-10-27)

```sh
# fresh env, do not disturb the system 0.31.1 install
uv venv .venv-sprint && source .venv-sprint/bin/activate
uv pip install mlx==0.32.4 mlx-lm==0.32.2
```

Downloads (measured 8.4 MB/s → run overnight, ~2.5 h total):

```sh
hf download mlx-community/Qwen3.8-27B-MTP-8bit      # ~29 GB
hf download mlx-community/Qwen3.8-27B-MTP-4bit      # ~15 GB
hf download lmstudio-community/Qwen3.8-27B-MLX-6bit # ~22 GB (no MTP; quant-quality reference)
```

### Experiments

| # | Experiment | Method | Gate |
|---|---|---|---|
| 0.1 | Stack delta | same prompt/model, 0.31.1 vs 0.32.4 + `--kv-bits 8` | ≥10% decode or prefill |
| 0.2 | Baseline matrix | 27B {4,6,8} bit @4k/16k/64k; decode, prefill, peak | within 10% of published |
| 0.3 | **MTP A/B** | 8-bit and 4-bit with/without MTP; 3 coding prompts × 3 seeds; acceptance, net tok/s | **≥1.8× net decode** |
| 0.4 | **Quality bake-off** | 24 frozen tasks × {8b, 6b, 4b}; checker pass + wall | 6-bit within 1 task of 8-bit |
| 0.5 | Prefix cache | 3-turn 30 k-repo session; TTFT turn 2+ | ≤2 s |
| 0.6 | 64 GB limit | 8-bit @64 k, wired 44 GB; pressure/swap/peak | peak ≤52 GB, no panic |
| 0.7 | Burst decode | 1 vs 32 vs 64 steps per eval | ≥5% from bursting |
| 0.8 | Router/step profile | per-op timing of one decode step (metal trace or `mx.metal` counters) | identify ≥15% hotspots |

MTP runner: `mlx-lm` `main` + PR #990 (or oMLX 0.7.x with `mtp_enabled`). Record acceptance rate,
draft depth, and tokens/step — not just tok/s.

### Go/no-go

- MTP < 1.5× on coding prompts → stop, re-plan (the speed thesis weakens; quality-only product).
- 6-bit degrades > 1 task → 8-bit is the only default, 64 k needs 6-bit only for long mode.
- Peak > 52 GB at 64 k → cap v1 at 32 k and revisit KV quant.
- Everything green → proceed to Phase 1 with 8-bit default.

Artifact: `docs/SPRINT-RESULTS.md` + raw JSON per run (engine, checkpoint hash, quant, context,
tokens, memory, quiet flag).

---

## 5. Roadmap after the sprint

### Phase 1 — Graph parity (3 weeks)

- SwiftPM skeleton, pinned deps, CI (`swift test`).
- safetensors reader (mmap) + MLX affine-quant weights (`weight`, `scales`, `biases` per layer).
- Tokenizer (swift-transformers) + Qwen3.8 chat template hard-coded in Swift, validated against the
  HF Jinja template on 50 cases (roles, tools, thinking, images-stripped).
- Graph: GDN (port `gated_delta` MSL into `MLXFast.metalKernel`), gated attention, RoPE/mRoPE,
  SwiGLU, final norm, lm_head.
- fp16 KV, greedy sampler, no MTP.

**Acceptance:** exact greedy parity (128 tok × 10 prompts) vs `mlx-lm`; decode ≥ 80% of mlx-lm
no-MTP reference.

### Phase 2 — Speed layer (3 weeks)

- MTP head + draft/verify/rollback (port PR #990 semantics; ping-pong GDN state).
- Prefix radix cache with block hashes, COW, LRU.
- int8 KV for the 16 full-attn layers; verify quality vs fp16 on 5 prompts.
- Memory governor, wired ceiling, admission, pressure degradation.
- Burst decode.

**Acceptance:** all performance gates in §2; MTP acceptance ≥ 2.0 tokens/step on code; TTFT gate.

### Phase 3 — Product (3 weeks)

- OpenAI-compatible server, SSE, cancel, metrics.
- CLI: run/chat/serve/bench/models.
- Agent harness: tool calling (exec, read/write/patch, grep, git), context budget, thinking
  preservation, subagent delegation.
- SwiftUI app: model status, chat, tok/s + memory HUD, context-mode switch.
- Model manager: verified download, digest check, quant selection, disk GC.
- Packaging: signed/notarised `.app`, universal? (arm64 only), first-run model setup.

**Acceptance:** 20/20 agent pilot tasks; 8 h soak; unload/switch clean.

### Phase 4 — Tuning (2 weeks)

- Profile the real step; fuse whatever is ≥10% (router, norm+quant, RoPE).
- ANE prefill experiment (oMLX recipe): target +10–20% prefill.
- 6-bit long-context mode if the bake-off allows.
- Only then decide whether a custom `mx::Primitive` kernel is worth 1.2–1.35×.

**Total: ~10 days + 11 weeks ≈ 3 months to beta.**

---

## 6. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| MTP is harder than the PR suggests | loses 2× | Phase 0 gate; fall back to classic draft (0.6B) + prompt-lookup |
| MLX Swift op gaps | blocks graph | drop to `Cmlx` (C API has quantized_matmul, SDPA, gather_qmm, compile) |
| GDN kernel port drifts numerically | parity fail | port MSL verbatim, compare layer outputs, tolerance + exact-token gate |
| 64 GB pressure / panic | product unsafe | wired ≤44 GB, admission, pressure monitor, 64 k test in Phase 0 |
| Tokenizer/chat-template drift | quality loss | golden outputs vs HF tokenizer; template tests |
| MLX 0.33 breaks API | maintenance | pin + vendor; upgrade deliberately |
| Download throughput 8.4 MB/s | sprint delay | overnight downloads; 4-bit first, 8-bit second |
| Model superseded in ~6 months | rework | graph layer isolated; new architecture = 2–3 week port |

---

## 7. Repo layout

```
strim-engine/
  Package.swift
  Sources/
    StrimCore/      Model, Weights, Tokenizer, ChatTemplate, Quantization
    StrimEngine/    Engine, Session, KVCache, GDNState, PrefixCache, MTP, Governor, Sampler
    StrimAgent/     Tools, Context, History, Patch
    StrimServer/    Routes, SSE, OpenAISchema
    StrimCLI/       Commands
    StrimApp/       SwiftUI
    StrimBench/     Parity, Speed, Memory
  Tests/
    StrimCoreTests/ StrimEngineTests/ ParityTests/
  bench/            Python sprint scripts, raw JSON
  docs/             this plan, exploration, sprint results, ADRs
  third_party/      notices (mlx-lm MIT, oMLX Apache-2.0, Qwen Apache-2.0)
```

---

## 8. Open items (decide during Phase 0/1)

1. **8-bit vs 6-bit default** — decided by the bake-off, not now.
2. **32 k vs 64 k default** — depends on 64 GB peak measurement.
3. **Classic draft fallback** — if MTP underperforms, test Qwen3.8-0.6B/1.7B draft (same tokenizer).
4. **App vs CLI first** — plan assumes CLI+server first, app in Phase 3; confirm.
5. **Tool protocol** — Qwen3.8 native tool template vs our own JSON; test with 20 pilot tasks.
6. **Vision** — defer; the vision tower is in the checkpoint and must be skipped at load, not run.

---

## Appendix — why these choices

- **Why MLX:** 83–98% of the measured bandwidth ceiling on dense decode; 140+ architectures; Metal 4
  + NAX; MIT; `mlx-c` exposes every op we need (`mlx_quantized_matmul`, `mlx_fast_scaled_dot_product_attention`,
  `mlx_gather_qmm`, `mlx_compile`); `MLXFast.metalKernel` lets us port the GDN kernel without C++.
- **Why Swift:** best iteration loop for a Mac product; Metal debugger/frame capture; Swift 6 actors;
  swift-transformers; native UI later. Rust buys safety, not speed.
- **Why this model:** newest Qwen generation, best published agentic coding scores, hybrid GDN keeps
  KV tiny at 262 k, MTP head included, Apache-2.0, and MLX/LM Studio support is first-class.
- **Why MTP is the bet:** 2.1–2.4× measured on M5 Max, and no shipping Swift engine uses it. It is
  the one large, defensible win left above the kernel layer.
