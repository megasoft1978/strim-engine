# Perf profile 2026-10-27

Machine: Apple M5 Max (Mac17,14), 64 GB, Version 27.0.1 (Build 26A434), load avg 1.98 / 2.29 / 2.49, thermal NSProcessInfoThermalState(rawValue: 0), git d018dd1 (dirty). Reps per cell: 3 (first in-process rep discarded as warm-up). CV = sample stdev / mean.

Rows marked **ABLATION** disable real work through env flags: their outputs are not valid and their numbers must never be quoted as product speed.

## Prefill tok/s by chunk size (in-process `benchprefill`, valid outputs)

| tokens | variant | chunk | metric | n | median | mean | CV% | unit | note |
|---:|---|---:|---|---:|---:|---:|---:|---|---|
| 1024 | chunk | 512 | prefill tok/s | 3 | 992.00 | 991.33 | 0.4 | tok/s |  |
| 1024 | chunk | 1024 | prefill tok/s | 3 | 1034.00 | 1033.33 | 0.1 | tok/s |  |
| 4096 | chunk | 512 | prefill tok/s | 3 | 976.00 | 975.00 | 0.2 | tok/s |  |
| 4096 | chunk | 1024 | prefill tok/s | 3 | 1021.00 | 1021.00 | 0.1 | tok/s |  |
| 4096 | chunk | 2048 | prefill tok/s | 3 | 1019.00 | 1019.33 | 0.2 | tok/s |  |
| 4096 | chunk | 4096 | prefill tok/s | 3 | 1024.00 | 1024.33 | 0.1 | tok/s |  |
| 16384 | chunk | 512 | prefill tok/s | 3 | 574.00 | 651.33 | 31.9 | tok/s |  |
| 16384 | chunk | 1024 | prefill tok/s | 3 | 966.00 | 965.67 | 0.1 | tok/s |  |
| 16384 | chunk | 2048 | prefill tok/s | 3 | 964.00 | 963.33 | 0.2 | tok/s |  |
| 16384 | chunk | 4096 | prefill tok/s | 3 | 967.00 | 966.67 | 0.1 | tok/s |  |
| 32768 | chunk | 512 | prefill tok/s | 3 | 651.00 | 644.00 | 13.2 | tok/s |  |
| 32768 | chunk | 1024 | prefill tok/s | 3 | 386.00 | 370.33 | 9.0 | tok/s |  |
| 32768 | chunk | 2048 | prefill tok/s | 3 | 890.00 | 889.67 | 0.2 | tok/s |  |
| 32768 | chunk | 4096 | prefill tok/s | 3 | 886.00 | 870.00 | 3.4 | tok/s |  |

## GDN recurrence ablation (in-process, chunk 1024)

| tokens | variant | chunk | metric | n | median | mean | CV% | unit | note |
|---:|---|---:|---|---:|---:|---:|---:|---|---|
| 1024 | default | 1024 | prefill tok/s | 3 | 1006.00 | 1008.33 | 0.4 | tok/s |  |
| 1024 | skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 1015.00 | 1015.00 | 0.1 | tok/s | ABLATION: output invalid |
| 1024 | tensor | 1024 | prefill tok/s | 3 | 255.00 | 244.67 | 13.8 | tok/s |  |
| 1024 | tensor_skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 1067.00 | 1065.67 | 0.2 | tok/s | ABLATION: output invalid |
| 4096 | default | 1024 | prefill tok/s | 3 | 1007.00 | 1004.67 | 0.4 | tok/s |  |
| 4096 | skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 1008.00 | 1008.00 | 0.3 | tok/s | ABLATION: output invalid |
| 4096 | tensor | 1024 | prefill tok/s | 3 | 267.00 | 262.00 | 3.3 | tok/s |  |
| 4096 | tensor_skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 1057.00 | 1055.33 | 0.3 | tok/s | ABLATION: output invalid |
| 16384 | default | 1024 | prefill tok/s | 3 | 949.00 | 949.67 | 0.2 | tok/s |  |
| 16384 | skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 955.00 | 955.33 | 0.1 | tok/s | ABLATION: output invalid |
| 16384 | tensor | 1024 | prefill tok/s | 3 | 262.00 | 264.00 | 3.8 | tok/s |  |
| 16384 | tensor_skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 1004.00 | 1006.00 | 0.3 | tok/s | ABLATION: output invalid |
| 32768 | default | 1024 | prefill tok/s | 3 | 209.00 | 221.67 | 14.0 | tok/s |  |
| 32768 | skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 328.00 | 334.00 | 5.0 | tok/s | ABLATION: output invalid |
| 32768 | tensor | 1024 | prefill tok/s | 3 | 131.00 | 131.67 | 1.6 | tok/s |  |
| 32768 | tensor_skip_rec **ABLATION** | 1024 | prefill tok/s | 3 | 312.00 | 290.33 | 24.1 | tok/s | ABLATION: output invalid |

## MTP head prompt-seed cost (in-process `benchspec`, n=2)

| tokens | variant | chunk | metric | n | median | mean | CV% | unit | note |
|---:|---|---:|---|---:|---:|---:|---:|---|---|
| 1024 | depth0 | - | e2e seconds (n=2) | 3 | 1.07 | 1.07 | 0.0 | s |  |
| 1024 | depth2 | - | e2e seconds (n=2) | 3 | 1.09 | 1.09 | 0.5 | s |  |
| 4096 | depth0 | - | e2e seconds (n=2) | 3 | 4.08 | 4.08 | 0.0 | s |  |
| 4096 | depth2 | - | e2e seconds (n=2) | 3 | 4.15 | 4.15 | 0.2 | s |  |
| 16384 | depth0 | - | e2e seconds (n=2) | 3 | 17.03 | 20.00 | 25.8 | s |  |
| 16384 | depth2 | - | e2e seconds (n=2) | 3 | 22.90 | 21.24 | 15.4 | s |  |
| 32768 | depth0 | - | e2e seconds (n=2) | 3 | 220.14 | 222.80 | 10.8 | s |  |
| 32768 | depth2 | - | e2e seconds (n=2) | 0 | - | - | - | s |  |

## Decode with STRIM_TIMING=1 (in-process `benchspec`, depth 2)

| tokens | variant | chunk | metric | n | median | mean | CV% | unit | note |
|---:|---|---:|---|---:|---:|---:|---:|---|---|
| 4096 | depth2 | - | decode tok/s | 3 | 19.90 | 19.83 | 0.6 | tok/s |  |
| 4096 | depth2 | - | ms/pass | 3 | 134.10 | 134.47 | 0.5 | ms |  |
| 4096 | depth2 | - | tokens/pass | 3 | 2.67 | 2.67 | 0.0 | tok |  |
| 4096 | depth2 | - | accept | 3 | 70.00 | 70.00 | 0.0 | % |  |
| 4096 | depth2 | - | verify ms | 3 | 46.70 | 46.57 | 0.7 | ms |  |
| 4096 | depth2 | - | draft ms | 3 | 3.30 | 3.37 | 3.4 | ms |  |
| 4096 | depth2 | - | reseed ms | 3 | 1.40 | 1.43 | 4.0 | ms |  |
| 32768 | depth2 | - | decode tok/s | 0 | - | - | - | tok/s |  |
| 32768 | depth2 | - | ms/pass | 0 | - | - | - | ms |  |
| 32768 | depth2 | - | tokens/pass | 0 | - | - | - | tok |  |
| 32768 | depth2 | - | accept | 0 | - | - | - | % |  |
| 32768 | depth2 | - | verify ms | 1 | 56253.30 | 56253.30 | 0.0 | ms |  |
| 32768 | depth2 | - | draft ms | 1 | 467.50 | 467.50 | 0.0 | ms |  |
| 32768 | depth2 | - | reseed ms | 1 | 82.20 | 82.20 | 0.0 | ms |  |

## Derived

| tokens | metric | value | unit | note |
|---:|---|---:|---|---|
| 1024 | chunk 512 vs 1024 | -4.06 | % tok/s | valid outputs |
| 1024 | GDN recurrence share, blocked kernel path (STRIM_SKIP_REC) | 0.89 | % of prefill time | ablation; STRIM_SKIP_REC is only read on the tensor path, so ~0 here means the flag is a no-op on the blocked path |
| 1024 | GDN recurrence share, tensor path (MAX_S=8 + SKIP_REC) | 76.10 | % of tensor-path prefill time | ablation; tensor recurrence is ~2.7x slower than the blocked kernel, so this overstates the default-path share |
| 1024 | blocked kernel vs tensor recurrence | 294.51 | % tok/s | valid outputs (STRIM_GDN_METAL_MAX_S=8 is a supported A/B) |
| 1024 | MTP head prompt seed cost (depth2 - depth0, e2e) | 20.00 | ms | includes ~1 extra draft+verify round; share of prefill: 1.9% |
| 4096 | chunk 512 vs 1024 | -4.41 | % tok/s | valid outputs |
| 4096 | chunk 2048 vs 1024 | -0.20 | % tok/s | valid outputs |
| 4096 | chunk 4096 vs 1024 | 0.29 | % tok/s | valid outputs |
| 4096 | GDN recurrence share, blocked kernel path (STRIM_SKIP_REC) | 0.10 | % of prefill time | ablation; STRIM_SKIP_REC is only read on the tensor path, so ~0 here means the flag is a no-op on the blocked path |
| 4096 | GDN recurrence share, tensor path (MAX_S=8 + SKIP_REC) | 74.74 | % of tensor-path prefill time | ablation; tensor recurrence is ~2.7x slower than the blocked kernel, so this overstates the default-path share |
| 4096 | blocked kernel vs tensor recurrence | 277.15 | % tok/s | valid outputs (STRIM_GDN_METAL_MAX_S=8 is a supported A/B) |
| 4096 | MTP head prompt seed cost (depth2 - depth0, e2e) | 70.00 | ms | includes ~1 extra draft+verify round; share of prefill: 1.7% |
| 16384 | chunk 512 vs 1024 | -40.58 | % tok/s | valid outputs |
| 16384 | chunk 2048 vs 1024 | -0.21 | % tok/s | valid outputs |
| 16384 | chunk 4096 vs 1024 | 0.10 | % tok/s | valid outputs |
| 16384 | GDN recurrence share, blocked kernel path (STRIM_SKIP_REC) | 0.63 | % of prefill time | ablation; STRIM_SKIP_REC is only read on the tensor path, so ~0 here means the flag is a no-op on the blocked path |
| 16384 | GDN recurrence share, tensor path (MAX_S=8 + SKIP_REC) | 73.90 | % of tensor-path prefill time | ablation; tensor recurrence is ~2.7x slower than the blocked kernel, so this overstates the default-path share |
| 16384 | blocked kernel vs tensor recurrence | 262.21 | % tok/s | valid outputs (STRIM_GDN_METAL_MAX_S=8 is a supported A/B) |
| 16384 | MTP head prompt seed cost (depth2 - depth0, e2e) | 5870.00 | ms | includes ~1 extra draft+verify round; share of prefill: 34.5% |
| 32768 | chunk 512 vs 1024 | 68.65 | % tok/s | valid outputs |
| 32768 | chunk 2048 vs 1024 | 130.57 | % tok/s | valid outputs |
| 32768 | chunk 4096 vs 1024 | 129.53 | % tok/s | valid outputs |
| 32768 | GDN recurrence share, blocked kernel path (STRIM_SKIP_REC) | 36.28 | % of prefill time | ablation; STRIM_SKIP_REC is only read on the tensor path, so ~0 here means the flag is a no-op on the blocked path |
| 32768 | GDN recurrence share, tensor path (MAX_S=8 + SKIP_REC) | 58.01 | % of tensor-path prefill time | ablation; tensor recurrence is ~2.7x slower than the blocked kernel, so this overstates the default-path share |
| 32768 | blocked kernel vs tensor recurrence | 59.54 | % tok/s | valid outputs (STRIM_GDN_METAL_MAX_S=8 is a supported A/B) |

## Kill criteria

- P3 at 4096 tok: chunk 4096 vs 1024 = +0.3% -> KILL (below +2%)
- P3 at 16384 tok: chunk 4096 vs 1024 = +0.1% -> KILL (below +2%)
- P3 at 32768 tok: chunk 4096 vs 1024 = +129.5% -> kept
- P5 at 1024 tok (blocked path, STRIM_SKIP_REC): 0.9% -> INCONCLUSIVE (flag is a no-op on blocked path; needs engine hook)
- P5 at 4096 tok (blocked path, STRIM_SKIP_REC): 0.1% -> INCONCLUSIVE (flag is a no-op on blocked path; needs engine hook)
- P5 at 16384 tok (blocked path, STRIM_SKIP_REC): 0.6% -> INCONCLUSIVE (flag is a no-op on blocked path; needs engine hook)
- P5 at 32768 tok (blocked path, STRIM_SKIP_REC): 36.3% -> kept
- P5 at 1024 tok (tensor path upper bound): 76.1% of tensor-path time
- P5 at 4096 tok (tensor path upper bound): 74.7% of tensor-path time
- P5 at 16384 tok (tensor path upper bound): 73.9% of tensor-path time
- P5 at 32768 tok (tensor path upper bound): 58.0% of tensor-path time

## Not measured

- step failed or short: mtp-head/depth2/32768: exit 15
- step failed or short: mtp-head/depth2/32768: expected 3 reps, got 0
- step failed or short: decode/depth2/32768: exit 15
- step failed or short: decode/32768: expected 3 reps, got 0
- step failed or short: decode/32768: expected 3 STRIM_TIMING lines, got 1
- attention vs MLP vs MTP-head shares: no ablation flag exists in the engine (only STRIM_SKIP_REC for the GDN recurrence); needs an engine hook
- MTP head over last-N prompt tokens: no flag exists; only the full-prompt seed cost (depth2 - depth0) is reported
- served-path chunk sweep: chunk is the constant PrefixPrefill.chunk=1024 (StrimCore/PrefixCache.swift); served rows are cold TTFT at that chunk only

## Validity note (added after run)

- All L=32768 rows (chunk sweep, GDN ablation, mtp-head, decode) are swap-thrashed, INVALID: the machine was swapping (16-17 GB swap, ~53 GB RSS in `benchspec` depth2). Do not quote them.
- mtp-head depth2 L=32768 and decode depth2 L=32768 were SIGTERMed (exit 15) by the coordinator; not rerun.
- L=16384 depth0/depth2 rows have CV 15-26%: the 5.9 s MTP seed cost at 16K is also suspect (possible memory pressure).
- Peak RSS per case was not recorded by this harness.
