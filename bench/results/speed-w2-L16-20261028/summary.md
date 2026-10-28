# L16: draft-depth policy (2026-10-28) -- ADOPTED (cost-per-token policy, ceiling 3, start at 3)

Method: `STRIM_TIMING=trace` (new, no extra syncs) logs `TRACE ctx= d= acc= ms=` per round to the server stderr. `run16.sh` runs one served engine session per (round, arm) under the GPU lock + 5 s watchdog (`pass16.sh` = bench/h2h/pass.sh cells): W3 prefix-cached 4K/16K (gen 256), 32K (gen 256), W6 single-stream agent prompts (4 real repo-source prompts from `agent-prompts.sh`, gen 256), W4 512-tok c=4/8. Arms rotated each round, 3 rounds each. `STRIM_MTP_FIXED=1 STRIM_MTP_DEPTH=n` = fixed depth. Machine was shared (load 5-11), so differences < 2% are noise; 32K cv ~10%. Full tables: `tables.md` (current raw/), per-run raw in `raw/`, `run5/`, `*-runN/`. Tool: `summarize16.pl`.

## Fixed depth vs old adaptive (run 1, decode tok/s, median of 3)
| arm | 4K | 16K | 32K | agent |
|---|---|---|---|---|
| adaptive (old) | 69.9 | 56.9 | 55.5 | 57.2 |
| d2 | 61.5 | 55.9 | 45.1 | 58.2 |
| d3 | 70.5 | 63.0 | 53.4 | 61.7 |
| d4 | 75.5 | 61.9 | 54.6 | 54.4 |
Fixed d3 vs old adaptive over all 5 ABAB runs (mean of 4K/16K/32K): +2.5, +7.4, +1.0, +6.3, +3.8% (always positive); agent prompts +8, +10, +13, +5, +6%.

## Acceptance by position and replay (from fixed-d4 traces; P(prefix>=i), pass ms at d2/d3/d4)
| ctx | P1..P4 | pass ms d2/d3/d4 | Qd (d2/d3/d4) | emitted per ms x1000 (d2/d3/d4) | replay-optimal |
|---|---|---|---|---|---|
| 4K | .91 .78 .63 .51 | 43.9/45.9/50.9 | 2.69/3.32/3.82 | 61/72/75 | d4 (d3 within 4%) |
| 16K | .84 .73 .60 .43 | 46.3/51.3/57.9 | 2.57/3.17/3.60 | 55/62/62 | d3 = d4 |
| 32K | .88 .77 .62 .46 | 54.2/58.9/67.5 | 2.65/3.27/3.73 | 49/56/55 | d3 = d4 |
| agent | .76 .52 .33 .22 | 44.3/46.1/51.3 | 2.27/2.60/2.81 | 51/56/55 | d3 |
Old adaptive wasted time sitting at d2 (16K: 50% of rounds, agent: 68%) and at d4 on low-acceptance agent text; its own trace rate is 3-7% below replay-optimal at 4K/16K/32K.

## Policy (SpecStream.swift, `DepthPolicy`)
Start at depth 3. EWMA (alpha 0.1) of P(prefix>=i) per position; cost model ms(d,ctx)=42.5+0.35*ctxK+(3.3+3.3*ctxK/32)*(d-2) (fit to the table above); choose argmax (1+sum P_i)/ms(d); move only after 8 rounds at a depth and only for a > 5% rate gain; ceiling 3 (depth 4 lost on low-acceptance prompts; lift with STRIM_MTP_MAX_DEPTH). Timing-free, deterministic from acceptance history + ctx. `STRIM_MTP_POLICY=legacy` restores the old controller. Memory: rollback state for depth 3 only (below the old depth-4 ceiling), no growth.
Intermediate versions (v1 ewma hold 2 ceiling 4; v2 sticky margin 5% ceiling 4) tracked legacy +-1% (v2 had a bug letting the legacy branch fire; fixed); they are kept in raw/ewmav1, raw/sticky-v2, raw/cap3-hybridbug for the record.

## Final ABAB (policy "cap3" vs legacy, decode tok/s, median of 3; run 5 + run 6)
| run | 4K | 16K | 32K | mean | agent |
|---|---|---|---|---|---|
| 5 policy / legacy | 73.8 / 72.2 | 65.3 / 60.6 | 51.0 / 54.7 | 63.4 / 62.5 (+1.4%) | 58.5 / 59.3 |
| 6 policy / legacy | 75.0 / 73.1 | 65.0 / 63.1 | 52.1 / 47.8 | 64.0 / 61.3 (+4.4%) | 62.5 / 54.2 |
Pooled +2.9% on 4K/16K/32K, agent +5%; the policy sits at depth 3 almost always, so it tracks fixed d3 (+4.2% mean over 5 runs). Gate: adopt >= 1.5% -> met (kill < 1% not hit).

## Concurrency (W4 512 tok, aggregate tok/s c=4/c=8, 3 sessions)
policy 67.5-68.7 / 74.9-75.9; legacy 62.7-68.9 / 75.1-75.7; d3 67.8-68.5 / 75.2-75.7. No regression (batched path has its own depth rules).

## Exact tier (new == legacy)
gen16 ids identical; depth-0 benchspec EXACT (both); checkprefix 4096 and 8192 +MTP ALL PASS; checkprefixcuts ALL PASS; checkbatchparity B=4 1 mismatch (margin 0.125), B=8 4 mismatches (margin <= 0.125), identical to legacy; benchbatch B=4 tokens match; d1 benchspec rc=2 (pre-existing 4K parity line) in both. Peak footprint: new 31.2 GB vs legacy 31.1 GB (checkprefix8192), 27.6 both (cbp-B8). Unit tests: `Tests/StrimCoreTests/DepthPolicyTests.swift` (6, pass).

Caveats: greedy continuations differ run to run between depths (verify numerics), so acceptance on the same prompt varies +-5 points; 32K cells are noisy. Cost model is context-keyed, fitted on the 4K/16K/32K points only.
