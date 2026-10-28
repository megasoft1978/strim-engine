# Qwen3.8-27B dense: is there a better version? (2026-10-26)

Short answer: **no drop-in "better 27B dense" from Qwen, and Ornith 1.5 is not a
Qwen3.8-27B variant.** Ornith 1.5 is a separate model family with its own architecture,
tokenizer and chat template. The same-base Qwen3.8-27B options are quantisations and
fine-tunes, not a new base model.

## What actually exists

| model | base / architecture | size / active | context | licence | MLX 4-bit | MTP / drafter | fits 64 GB? |
|---|---|---|---|---|---|---|---|
| **Qwen3.8-27B** (current) | Qwen3.8, dense GDN + gated attention, 64 layers | 27B dense | 262,144 native, 1M extensible | Apache-2.0 | yes (`mlx-community/Qwen3.8-27B-4bit`) | MTP head (separate) | 15 GB, yes |
| `Jundot/Qwen3.8-27B-oQ4e-mtp` | same base, mixed 4/5-bit | 27B, 4.887 bits/weight | same | Apache-2.0 | yes, but **5-bit tensors** | MTP included | 15.8 GiB, yes |
| `ukisai/Swift-1.5-Qwen3.8-27b` | same base, fine-tune (RL/OPD) | 27B dense | same | gated, Swift Open License 1.0 | no MLX 4-bit (GGUF/GSQ) | inherits base | weights yes, engine no |
| `incoai/Qwen3.8-27B-Splash` | Splash package (target + DFlash2) | 27B dense | same | Apache-2.0 | no, Splash-only | DFlash2 | 17.4 GB, Splash only |
| **Ornith-1.5-9B** | Ornith (Qwen3.5/Gemma4 lineage), dense | 9B dense | 262,144 | MIT | yes (`Ornith-1.5-9B-MLX-4bit`) | DFlash variants | ~5 GB, yes |
| **Ornith-1.5-35B-A3B** | Ornith, **MoE** | 35B total / ~3B active | 262,144 | MIT | yes (`Ornith-1.5-35B-A3B-MLX-4bit`) | DFlash variants | ~18–20 GB at 4-bit, yes at moderate context |
| Ornith-1.5-122B / 397B | Ornith, MoE | 122B / 397B | 262,144 | MIT | 122B yes, 397B yes | DFlash | 122B ~60 GB at 4-bit, tight; 397B no |

Ornith 1.5 is **not** a Qwen3.8 fine-tune. Its card says Ornith-1.0 was built on Qwen3.5
and Gemma4 with continued pretraining; 1.5 extends that self-improvement loop. The 122B
checkpoint is tagged `qwen3_5_moe`. Different tokenizer/template, reasoning `<think>` and
`<tool_call>` format, 262K context, MIT licence.

## Public numbers (not a matched comparison)

| benchmark | Qwen3.8-27B | Ornith-1.5-35B-A3B | Ornith-1.5-9B |
|---|---:|---:|---:|
| Terminal-Bench 2.1 (Terminus-2) | **73.0** | 67.8 | 46.2 |
| SWE-bench Pro | **61.7** | 59.6 | 47.5 |
| SWE-bench Verified | — (QwenSWEBench 79.0) | 79 | 70.6 |
| LiveCodeBench v6 | **90.3** | — | — |
| GPQA Diamond | 89.2 | 89.2 | 86.4 |
| MCP-Atlas | — | 70.2 | 54.2 |
| BenchLM public lane (overall) | **59.69** | 33.77 (estimated coding/agentic) | 31.67 (estimated) |

Caveats: Qwen's card and Ornith's card use different harnesses, context limits, sampling
and run counts (Ornith: 128K context, temperature 1.0, five runs; Qwen: its own Terminus
setup). BenchLM marks Ornith's coding/agentic rows as **estimated** and does not name a
winner from them. The honest read: **Qwen3.8-27B is at least competitive, and on the shared
Terminal-Bench / SWE-bench Pro rows it is ahead.** Ornith's 35B-A3B advantage is speed from
3B active parameters, not a demonstrated quality win over the 27B dense model.

## Same-base Qwen3.8-27B upgrades

- **oQ4e-mtp** (`Jundot/Qwen3.8-27B-oQ4e-mtp`) is the most concrete same-base upgrade:
  mixed 4/5-bit, 15.8 GiB, MTP head included, KL vs BF16 0.0117 on code and 0.0600 on
  novel text (lower is better). It is an **oMLX** checkpoint. The Swift engine's
  `WeightStore` currently supports only affine 4-bit group 64, so this will not load
  without 5-bit support; the product path would need oMLX or a compatible loader.
- **Swift 1.5** (`ukisai/Swift-1.5-Qwen3.8-27b`) is a same-base fine-tune claiming 58.5%
  fewer thinking tokens, +0.35% score and 1.95× task-level speed on some tasks. That is
  *token efficiency*, not engine tok/s. It is gated, carries a custom licence, and the
  published artefacts are GGUF/GSQ, not MLX 4-bit — not a drop-in for this engine.
- **Splash / DFlash2** are speed packages/drafters for their own engines (Splash,
  SGLang, vLLM), not MLX/Swift checkpoints.
- **FP8 / NVFP4** checkpoints are for vLLM/NVIDIA; M5/MLX does not give you the same
  path. Do not port them.

## What this means for the Swift engine

The engine is written for Qwen3.8-27B: GDN + gated attention, affine 4-bit group 64,
separate MTP head, Qwen tokenizer/template. That rules out:

- **Ornith 1.5 35B-A3B** — MoE architecture; needs a Qwen3.5-MoE implementation, a new
  tokenizer/template, and a different drafter. It is a separate engine path, not a
  checkpoint swap. It is the most interesting *speed/agentic* alternative if you are
  willing to build that path (or serve it through rapid-mlx/mlx-vlm if they support it).
- **Ornith 1.5 9B** — fits and is fast, but it is a smaller model; BenchLM's public lane
  puts it well below Qwen3.8-27B. A size/speed play, not a quality upgrade.
- **Ornith 122B/397B** — 4-bit 122B is ~60 GB before KV; 397B does not fit 64 GB.
- **oQ4e / Swift 1.5 / Splash** — same base, but incompatible format or loader today.

## Recommendation

1. **Keep Qwen3.8-27B dense as the engine base.** It is the current Qwen dense generation,
   the engine already matches its architecture, and the public coding/agentic rows do not
   show Ornith beating it.
2. If you want a same-base quality experiment, test **oQ4e-mtp** (needs 5-bit support or
   oMLX) and, if the licence is acceptable, a **Swift 1.5 MLX conversion** on a held-out
   coding set. Both are quality/token-efficiency changes, not decode-speed changes.
3. If you want a different model, **Ornith 1.5 35B-A3B** is the only one worth a scoped
   evaluation (3B active, 262K, strong agentic card). Treat it as a new engine target, not
   a replacement checkpoint.
4. Judge with your harness: same prompts, same tools, same context, task success and
   tokens — not model-card numbers. The card comparisons above are directional only.

## Sources

- [Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B)
- [Ornith-1.5-35B-A3B](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B),
  [Ornith-1.5-9B](https://huggingface.co/ornith-ai/Ornith-1.5-9B)
- [oQ4e-mtp](https://huggingface.co/Jundot/Qwen3.8-27B-oQ4e-mtp)
- [Swift 1.5](https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-27b)
- [Splash](https://huggingface.co/incoai/Qwen3.8-27B-Splash),
  [DFlash2](https://huggingface.co/incoai/Qwen3.8-27B-DFlash2)
- BenchLM: [9B vs 27B](https://benchlm.ai/compare/ornith-1-5-9b-vs-qwen3-8-27b),
  [35B-A3B vs 27B](https://benchlm.ai/compare/ornith-1-5-35b-a3b-vs-qwen3-8-27b)


## Quality experiment status (2026-10-26)

Selected checkpoint: **oQ4e-mtp** (Apache-2.0, same base, mixed 4/5-bit, MTP included).
Loader support landed: `WeightStore.quantBits` infers the bit depth per tensor from the
packed weight width and group count; `linear`/`embedding`/`qmm` use it; the fused MLP
inherits it from gate+up (both 4-bit in every layer of this checkpoint). `quantinfo` on
the current checkpoint reports 498 tensors, all 4-bit; on oQ it reports 505 tensors,
339 × 4-bit and 166 × 5-bit. The current 4-bit path is unchanged (gen 16 and depth-0 still
pass).

Quality instrument: `strim benchppl <model> <ids-file> [n]` (teacher-forced NLL/PPL on a
token slice) and `scripts/quality_ab.sh` (same code/prose tokens + gen-16 for two models).
Current baseline on the held-out slice:

| checkpoint | code PPL (512 tok) | prose PPL (512 tok) |
|---|---:|---:|
| Qwen3.8-27B MLX 4-bit (current) | 4.660 | 7.866 |

**Blocker:** the oQ4e download is incomplete. LFS SHA-256 checks show only shard 4 matches;
shards 1–3 are still missing bytes, so an early oQ PPL of 236k and repeated-token gen were
**corrupt-file artefacts**, not a loader result. Resume the download before running
`scripts/quality_ab.sh`; the 5-bit inference path itself has been exercised (`quantinfo`
reads all 505 tensors and the forward runs without error).

Next when the checkpoint is complete:
1. `strim benchppl models/qwen38-oq4e-mtp /tmp/qab_code.txt 512` and the prose slice;
   compare against 4.660 / 7.866.
2. `strim gen models/qwen38-oq4e-mtp 16` — token differences are expected; quality is the
   metric, not parity.
3. If PPL improves, test a few coding tasks and a depth-2 run with the standard MTP head;
   then decide whether oQ becomes an opt-in quality checkpoint.
4. Long-context instrument added: `strim benchctx <model> <ctx> <n>` measures prefill and
   decode as the KV cache grows; use it at 4K/8K/16K before choosing KV/prefix work.

## Measured quality scale: 4 vs 6 vs 8 bit (2026-10-26)

The per-tensor loader was exercised on the three local checkpoints; `quantinfo` reports
498 quantized tensors at 4, 6 and 8 bits respectively. Teacher-forced PPL on the same
512-token code and prose slices:

| checkpoint | code PPL | prose PPL | relative to 4-bit |
|---|---:|---:|---:|
| Qwen3.8-27B MLX **4-bit** | 4.660 | 7.866 | — |
| Qwen3.8-27B MLX **6-bit** | 4.624 | 7.744 | −0.8% / −1.6% |
| Qwen3.8-27B MLX **8-bit** | 4.588 | 7.744 | −1.6% / −1.6% |

The quality difference between 4-bit and 8-bit is ~1–2% PPL on this slice, while 8-bit
doubles the weight bytes and roughly halves decode speed. That supports keeping 4-bit as
the speed mode. It also means the oQ4e mixed 4/5-bit experiment needs a smaller-than-2%
PPL effect to be interesting; the current 4-bit baseline is not obviously leaving much on
the table. 6-bit is the closest compromise (small PPL gain, more bytes), matching the
earlier product observation that 4-bit + MTP is the speed mode.

The oQ4e comparison remains pending a complete checkpoint; the early 236k PPL was a
partial-file artefact.

## oQ4e-mtp A/B — complete checkpoint, 2026-10-26

The Apache-2.0 `Jundot/Qwen3.8-27B-oQ4e-mtp` shards were finally downloaded in full and
all four LFS SHA-256 hashes match:

| shard | LFS SHA-256 |
|---|---|
| 1 | `a52b4d90bdd3ac6faaa1b5e2dbd392476ff4a89f612d58f2cdf5da3e600505b6` |
| 2 | `da76b97546d3d6115539f7c3f56cb69a3eebd6b29d45f3f3e31223f993e5643a` |
| 3 | `22b410fbeb6bd93cd226fbf3d035744d70adf137ad4be9ba7ff4560fc38b3616` |
| 4 | `0e513a47300167766fe294ad9c9b8583853debc18dfb05ebadb018bffc97fa7a` |

`quantinfo`: 505 quantized tensors, 339 at 4-bit and 166 at 5-bit. The integrated MTP head
is under `language_model.mtp.` in the main shards; its `fc` projection is unquantized
(bf16), the rest of the head is quantized. The loader now handles both (key prefix +
dense fallback).

Same 512-token PPL slices as the 4/6/8-bit table:

| checkpoint | code PPL | prose PPL | code spec parity | gen 16 |
|---|---:|---:|---|---|
| MLX 4-bit | **4.660** | **7.866** | EXACT | baseline |
| oQ4e-mtp (mixed 4/5) | 4.697 | 7.866 | EXACT | repetitive |
| MLX 6-bit | 4.624 | 7.744 | — | — |
| MLX 8-bit | 4.588 | 7.744 | — | — |

Task/speed: 4-bit code spec **64.8 tok/s** (adaptive depth 4), oQ code **55.7 tok/s**;
natural/prose spec parity is MISMATCH for oQ (same prose mismatch as 4-bit, natural also
diverges). Verdict: **oQ4e is not better on this harness** — code PPL is 0.8% worse, prose
is equal, and it is ~14% slower because 166 tensors are 5-bit. Keep the standard 4-bit
checkpoint as the speed mode; do not switch to oQ.
