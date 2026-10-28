# Post-security-hardening serve-path sanity (2026-10-28)

OLD = 2df65e7-era build (/tmp/strim-build-final), NEW = HEAD 99ee472 clean build (hardening c76f18f, b793f4f, 58b3396). Model qwen38-4bit + MTP, `strim serve --no-auth`. Runner: bench/h2h/pass.sh (STRIM_BIN per binary; the bench client is the same binary as the server under test), one engine session per cell group under `lockf /tmp/strim-bench.lock`, ABBA order: pass1 old,new; pass2 new,old. Watchdog (42 GB footprint / 2 GB swap): no abort; peak footprint 32.5 GB.

## Per-cell, NEW vs OLD (positive = NEW better; TTFT and sums inverted)

| cell | old p1 | new p1 | old p2 | new p2 | d p1 | d p2 | verdict |
|---|---|---|---|---|---|---|---|
| cold 4K prefill | 984.2 | 983.5 | 989.9 | 977.9 | -0.1% | -1.2% | ok |
| cold 4K TTFT | 4.173 | 4.176 | 4.149 | 4.2 | -0.1% | -1.2% | ok |
| decode 256 tok @ 4K ctx | 68.89 | 66.58 | 67.85 | 65.88 | -3.4% | -2.9% | ok |
| cold 16K prefill | 951.1 | 951.8 | 950.8 | 952.9 | +0.1% | +0.2% | ok |
| cold 16K TTFT | 17.24 | 17.23 | 17.24 | 17.21 | +0.1% | +0.2% | ok |
| decode 256 tok @ 16K ctx | 54.79 | 58.1 | 58.56 | 57.66 | +6.0% | -1.5% | ok |
| c=4 512-tok prompts aggregate | 60.3 | 60.56 | 61.19 | 61.05 | +0.4% | -0.2% | ok |
| c=4 512-tok prompts p50 TTFT | 1.835 | 1.872 | 1.8 | 1.824 | -2.0% | -1.3% | ok |
| c=4 512-tok prompts p95 TTFT | 2.844 | 2.881 | 2.798 | 2.832 | -1.3% | -1.2% | ok |
| c=8 512-tok prompts aggregate | 65.66 | 67.36 | 65.78 | 68.56 | +2.6% | +4.2% | ok |
| c=8 512-tok prompts p50 TTFT | 3.284 | 3.293 | 3.287 | 3.269 | -0.3% | +0.6% | ok |
| c=8 512-tok prompts p95 TTFT | 5.652 | 5.682 | 5.637 | 5.722 | -0.5% | -1.5% | ok |
| W5 4 clients, 16K shared prefix aggregate | 9.475 | 9.456 | 9.496 | 9.413 | -0.2% | -0.9% | ok |
| W5 p50 TTFT | 20.79 | 20.67 | 20.74 | 20.74 | +0.6% | +0.0% | ok |
| W5 p95 TTFT | 23.49 | 23.34 | 23.45 | 23.42 | +0.6% | +0.1% | ok |
| agent replay prefill sum T1-T8 | 49.72 | 49.74 | 49.78 | 49.65 | -0.0% | +0.3% | ok |
| agent replay prefill sum T1-T6 | 35.11 | 35.15 | 35.23 | 35.1 | -0.1% | +0.4% | ok |
| agent replay T8 cached fraction | 0.8725 | 0.8725 | 0.8725 | 0.8725 | +0.0% | +0.0% | ok |

Cells map: single-stream decode 4K = "decode 256 tok @ 4K ctx"; cold prefill 4K/16K = prefill and TTFT rows; c=4 / c=8 on 512-token prompts; W5 shared 16K prefix, 4 clients; 8-turn replay (synthetic-8turn fixture).
Each pass is n=1 request per W3 cell, so single-stream decode is noisy (old-vs-old spread up to 6% at 16K).

## Follow-up on decode 4K (-3.4% / -2.9% in the main passes)
Re-ran decode 256 tok @ 4K ctx with 5 reps per session, ABBA (old, new, new, old), medians tok/s:
old 65.68, 65.51; new 67.11, 67.31 (new +2.4%). The earlier dip was noise; not a regression.
Raw: extra-decode4k/.

## Functional checks (NEW binary)
- Greedy agreement sample (8 prompts, temp 0): agree.json identical across old pass1/2 and new pass1/2 (same md5).
- 2000-token streamed generation, client sleeping 40 ms per SSE line (wall 97 s, finish=length, completion_tokens=2000): completed, not cut by the 120 s idle timeout. Note: kernel socket buffers absorbed the backpressure (max inter-line gap 0.1 s), so a >120 s true client stall was not exercised.
- 8 concurrent non-streamed clients: 8x HTTP 200.
- 16 MiB (16,777,216 byte) request body (small JSON padded with whitespace, exactly HTTPLimits.maxBodyBytes): HTTP 200.

## Verdict
No regression on any cell: no cell worse than -3% in both passes. Hardening commits show no measurable serve-path cost.
