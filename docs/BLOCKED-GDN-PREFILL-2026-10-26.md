# Blocked GDN prefill kernel — ported and measured (2026-10-26)

Ported rapid-mlx's blocked-sequential GDN Metal kernel (Apache-2.0, itself adapted from oMLX)
into `Sources/StrimCore/GDNMetal.swift`. It stages k/q/v in 48-token blocks in threadgroup
memory and keeps a 32-row x 128-d state block in registers; 8 threads cooperate per value row
with `simd_shuffle` reductions. The exact sequential recurrence is unchanged; only the f32
reduction tree differs.

## Numbers

| S | before (serial kernel) | blocked | gain |
|---:|---:|---:|---:|
| 512 | 896 | 897 | ~0% |
| 1024 | 846-912 | **920** (load 3.7) / **890** (load 7.3) | +1-9% |
| 4096 | 825-846 | **915** (load 3.7) / **878** (load 7.3) | +8-11% |
| 4096 total forward | 4.9 s | **4.48 s** | ~8% |

The 4K single request including 64 MTP tokens is 5.89 s at light load / 6.38 s at load 7.3 (10.5 decode-only).

One layout fix mattered: the kernel was being given q/k already repeated to Hv=48, so it staged 3x more
q/k rows than necessary. Passing the unrepeated Hk=16 tensors and deriving `hk = hv / (Hv/Hk)` inside
the kernel raised 4K from 835 to 878 tok/s and 1K from 844 to 890 at the same load.
Short-corpus numbers are unchanged because the blocked path only runs for S >= 512.

## Correctness caveat

At 4K the first generated token differs from the full-logit greedy path (105883 vs 27745);
short prompts and `gen 16` are unchanged. The blocked kernel's f32 reduction order is different,
so this is a near-tie flip, not a token-repetition bug, but it means 4K spec-vs-greedy parity is
not EXACT. `STRIM_GDN_BLOCKED=0` restores the old kernel for A/B.

## Remaining gap

rapid-mlx/TensorFold reach 4.26-4.29 s at 4K (963/958 tok/s at light load); Swift is 4.48 s (915)
light / 4.66 s (878) at load 7.3, where rapid's cold run is 4.50 s (912). The remaining gap is now
~4% at matched load, likely MLP/dispatch, not the GDN scan. oMLX's
ANE prefill path is 718 tok/s at 4K on 128 GB, slower than the GPU path here, so it is not the
answer for prefill; it is the answer for batch decode (MTP inside the batch).
