# cache-footprint-20261027 working notes

Status: code written, unit tests building; NO footprint-vs-time measurements taken yet (the other worker's server
holds ~/.strim/host.lock, so no second server could start; a before/after session is queued in run_session.sh / ab_replay.sh).

Measured so far (GPU gates on the tail-cut build, binary = HEAD + CutPolicy change only; logs in a-tail-cut/):
- checkprefixcuts ALL PASS: hit==miss logits, MTP head KV identical, reuse 3980 of 3983 tokens (turn-1 end now a cut).
- checkprefix 4096 ALL PASS (chunked cost -0.3% vs one-shot); checkprefix 8192 + MTP ALL PASS.
- cold throughput from checkprefixcuts: 5K 997 tok/s, 16K 953 tok/s (baseline comparison not yet run).
- From quick-h2h data: footprint = weights ~15 GB + trie (cap 12 GiB) + MLX cache (cap 4 GiB) + live KV/GDN + transient; peak 42 GB.
  Prior doc docs/MEMORY-2026-10-26.md already fixed conv-view retention and the parent retain cycle. Leak vs by-design:
  not yet separated; trie accounted vs real bytes comparison needs the session run.

Uncommitted files and what they do:
- Sources/StrimCore/PrefixCache.swift: CutPolicy gets an assistant-start cut (<|im_start|>assistant after >=256 tokens), so the
  end of a chat prompt is a trie node (exact: cut is a pure function of tokens); PrefixStore gets GDN-state thinning
  (interior single-child nodes off every 4th depth lose conv/ssm under budget pressure, lookup snaps to stateful ancestor),
  shrink(to:), stateless-stub pruning.
- Sources/StrimCLI/Cmd_PrefixCuts.swift: configures the assistant id, test gen prompt uses it.
- Sources/StrimEngine/Admission.swift: RAM-scaled MemoryModel.plan (budget 50% RAM floor weights+8 GiB, cache budget/32, trie remainder).
- Sources/StrimEngine/EngineCore.swift, EngineAPI.swift: use the plan, set assistant id, call relieveMemoryPressure per unit, new stats fields.
- Sources/StrimEngine/ProcessFootprint.swift, EngineCore+Memory.swift: phys_footprint backstop (clear MLX cache, trim trie, drop hot sessions).
- Tests: PrefixStoreTests (assistant cuts, thinning), AdmissionTests (new defaults).
Untested: thinning on real model (exactness of hits at snapped ancestors), pressure path, replay ABAB, W5/cold regression, defaults on real load.

## Update (gates)
- The 54 GB / swap incident was NOT the trie: the committed build's checkprefixcuts perf section (cold 4x16K, no store) peaks at 39.8 GB
  footprint because the CLI never sets Memory.cacheLimit (MLX buffer cache unbounded). Fix: Cmd_PrefixCache/Cmd_PrefixCuts set cacheLimit 2 GiB
  (peaks now 24 GB / 20 GB / 31 GB, swap +0). guard.sh (shell watchdog: kill at footprint or swap-growth limit) was used for all runs in b-thin/.
- Thinning bug found by checkprefix 4096: thinning followed by tip eviction pruned the whole chain. Thinning now runs only when it alone
  reaches the budget; otherwise the old leaf eviction applies.
- Gates on the committed set (b-thin/): checkprefixcuts ALL PASS (incl. new thinned hit==miss, spec hit==miss), checkprefix 4096 ALL PASS,
  checkprefix 8192+MTP ALL PASS.
- Unit tests: AdmissionTests and the CutPolicy tests pass; the MLX-array tests in PrefixStoreTests cannot run under `swift test` here
  (default.metallib not found), so thinning is covered by checkprefixcuts section (e) instead.
- NOT done: replay ABAB, W5/cold regression, footprint-vs-time before/after session. Servers launched from detached background shells
  failed with "Unable to create stream gpu"; and another worker's server held ~/.strim/host.lock. run_session.sh/ab_replay.sh/one_run.sh exist
  but must be run from a foreground shell when no other host is up. Kill criteria (replay gain < 3 s, cold loss > 2%) therefore unevaluated.

## Final A/B (ab/run1..run7; old = HEAD engine build, new = this work)
Replay 8-turn prefill sum (s), ABAB x2: old 52.1 52.8 52.0 52.2 (mean 52.3); tail-cut+thin+budget 50.1 49.7 49.5 49.7 (mean 49.75, gain 2.6 s < 3 s bar);
final default (tail-cut OFF) 52.1 52.3. Tail-cut ON cached tokens per turn: 4084 9339 14620 19877 25149 30371 35630 (old 3072 8741 14621 19229 25150 29758 35631).
Kill rule: gain < 3 s -> assistant cut disabled by default (STRIM_PREFIX_ASSISTANT_MIN=256 enables; gates pass either way).
W5 (4 clients, 16K shared): hit rows 6/8 at 15360 cached in old and final; first thinning version lost 3072 tokens on 3 rows (12288), fixed by evicting staler
leaves before thinning a live chain. Cold prefill TTFT 4K 4.17-4.20 s, 16K 17.2-17.3 s in old and new (no regression).
Peak footprint per cell (MB) old / final: replay1 31128/27163, replay2 36848/26983, w3 36386/28462, w4c4 37078/27986, w5 41894/32573.
Accumulation 37 -> 42 GB (old): by design, not a leak. Trie fills to its 12 GiB cap (7.3 GB after replay1, 12.1 GB from replay2 on, evictions keep it flat),
MLX buffer cache sits at its 4 GiB limit, mlx_active after the last cell stays 27-30 GB with the trie at the cap; new: trie capped 6.5 GB, cache 1 GiB.

## Decision update: assistant cut ON by default (STRIM_PREFIX_ASSISTANT_MIN=0 or off disables)
Goal is parity with rapid-mlx replay (50.1 s). Exact committed tree with the cut default on (ab/run8-default-on, c-default-on/):
replay 49.6 / 49.9 s (cached T2..T8 4084 9339 14620 19877 25149 30371 35630); W5 6/8 rows at 15360, TTFT 19.8-23.8 s (as old);
cold TTFT 4K 4.19/4.21 s, 16K 17.28/17.33 s (as old); c4 4K cell runs, peak 28.6 GB; peak footprint w5 32.7 GB (final column 32.6).
Gates on that tree: checkprefixcuts, checkprefix 4096, checkprefix 8192+MTP all PASS (peaks 23.9 / 20.5 / 31.2 GB, swap +0).
