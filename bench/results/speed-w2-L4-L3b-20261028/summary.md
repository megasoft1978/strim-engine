# Speed wave 2, L4 (decode host syncs) and L3b (windowed MTP head), 2026-10-28

Verdict: **L4 killed** (0.1-1.2 ms/pass saved, gate 2 ms, kill < 1.5). **L3b killed** (prefill gain 0.0% at 16K/32K, gate >= 1%).
Both are implemented, exact, tested and committed **default OFF** behind env flags (documented in `docs/CONTROL-API.md`); no default behavior changes except two bug fixes listed in section 4.
Machine M5 Max 64 GB, `models/qwen38-4bit` + `qwen38-mtp-4bit`, load average 3-6 from other workers. Every GPU run under `/tmp/strim-bench.lock` with the 5 s memory watchdog (`bench/h2h/watchdog.sh`); no run aborted by memory in the reported cells (peak 24.3 GB for 4K benchspec, 21.4-21.8 GB for the server cells; peak did not change between arms). One earlier 16K one-shot benchspec attempt was aborted by the watchdog (38 GB footprint, swap growth 2.3 GB while a build ran): one-shot 16K+ benchspec is not usable, the greedy reference computes full-prompt logits; long contexts were therefore measured through the server (W3 cell).

## 1. L4: what was built
`SpecStream` (greedy rounds, index chain): the draft token ids stay on the GPU (`concatenated` int32 of `[b, d1..dk]`), `QwenModel.forwardAll(indices:)` feeds `embedding(indices:)` for the verify pass, and one host read after the verify pass is queued returns drafts + target predictions (syncs/round 2 -> 1). Same embedding rows and arithmetic, so identical ids. `STRIM_SPEC_DEVICEFEED=1` enables it (default off after the result below). `STRIM_TIMING` now also prints `host_wait` (ms/pass blocked in a device read).

## 2. L4 measurement (benchspec, ABABAB, same binary, A = old host feed, B = device feed, fixed depth, 2 reps per process, decode-only)
Method note: `generateSpec` set `prefillSeconds` before the lazy prefill was evaluated, so benchspec's `decode_tok_s` included prefill; fixed (prefill + head seed forced before the timer). ms/pass = mtp_draft + verify + reseed from `STRIM_TIMING` (wall, includes blocking reads). Raw: `raw/l4-*`, table `l4-table.txt`, script `ab.sh`, `table.sh`.
| cell | A ms/pass | B ms/pass | saved | A tok/s | B tok/s | host_wait A/B | ids A==B |
|---|---:|---:|---:|---:|---:|---:|---|
| 4K depth 2 | 45.93 | 45.10 | 0.83 | 45.53 | 46.16 (+1.4%) | 39.9 / 40.3 | identical |
| 4K depth 4 | 54.77 | 54.70 | 0.07 | 46.19 | 46.31 (+0.3%) | 46.9 / 49.5 | identical |
| 8K depth 2 | 47.83 | 47.10 | 0.73 | 53.07 | 54.84 (+3.3%, noisy) | 41.8 / 42.3 | identical |
| 8K depth 4 | 58.87 | 57.63 | 1.24 | 52.06 | 49.56 (-4.8%, noisy) | 50.2 / 52.4 | identical |
Gap breakdown: the pass is GPU-bound. The host is blocked ~40 of ~45 ms/pass (waiting for the GPU); graph build + the removed sync together are worth < 1.3 ms/pass at every depth/context. tok/s differences are within the +-3-5% run-to-run noise at 8K; the ms/pass sums are the stable signal. 16K/32K were not run in benchspec (see memory note above); the saving is a host-side constant, so no larger gain is expected there.
Kill rule (< 1.5 ms/pass) applies at all four cells. Hash gates for the code as committed (new binary, defaults): `gen 16` ids identical to HEAD (`parity/gen16-*.log`), depth-0 `benchspec` EXACT old and new, `checkprefix 4096` ALL PASS, `checkprefix 8192 +MTP` ALL PASS (includes hot-continue), `checkprefixcuts` ALL PASS, `checkbatchparity 1024 4 8` PASS. (benchspec at depth 2 reports spec-vs-greedy MISMATCH at token 4186 in BOTH arms identically: pre-existing near-tie between one-shot verify and single-token numerics; not caused by this change.)

### Masked-kL SDPA / array RoPE offsets: estimate only, NOT implemented, NOT adopted
What it would buy: it would let the accepted-count rollback and the next draft/verify graph be built on the device, so the second host read (predictions) and the next pass's graph build could overlap the GPU. The measured ceiling for removing host involvement is what we just measured: host-side cost per pass is 0.1-1.2 ms for one sync removed, so a second sync is another ~1 ms, i.e. an upper bound of roughly 1.5-2.5 ms/pass = 3-5% (not the plan's 8-12%), because the pass is 85+% GPU time. It also changes SDPA arithmetic (masked key length) and resets the exactness reference. Recommendation: not worth the exactness reset on this evidence.

## 3. L3b: windowed MTP head in cold prefill
Built: `MTPState.base` (logical position/trim, so `SpecStream.reseed` and hot-session paths stay aligned: the old `headStale` case), `MTPBlock.start`, `PrefixStore.restoreMTPWindow` (longest contiguous run of head blocks, trimmed to the window, empty head positioned at the node end when the node has no block), contiguity check in whole-chain `lookup(requireMTP:)`, `insert(windowedHead:)`, and `PrefillJob.windowStart` + head skipping/trimming in `coldChunk` (`STRIM_MTP_WINDOW=N`, default 0 = whole prompt; unset behaves as before, verified by the parity gates above). Unit tests (all pass, `swift test` filtered): `mtpStateBaseKeepsLogicalPositionsAligned`, `windowedMTPBlocksSkipEarlyNodesAndRestoreFromTheWindow`, `nonContiguousMTPBlocksNeverJoin`, `HeadWindowTests` (4); they fail on the old code (no `base`, `start`, `restoreMTPWindow`, `windowStart`).
Activation verified (STRIM_TIMING log line `coldjob ... head_skipped 9 head_ran 3` for a 16395-token prompt at W=2048).

A/B through the server (`w3.sh`, `l3ball.sh`; W3 single-stream cold prompt, gen 128, trie off, ABC x3: A = full head, B = W 4096, C = W 2048):
| metric | A (full) | B (W=4096) | C (W=2048) |
|---|---:|---:|---:|
| TTFT 4K s | 4.098 | 4.110 | 4.139 |
| TTFT 16K s | 16.947 | 16.960 | 16.953 |
| TTFT 32K s | 36.62 | 36.64 | 36.65 |
| draft acceptance 4K / 16K / 32K | .729 / .640 / .691 | .718 / .655 / .709 | .717 / .657 / .761 |
| decode tok/s 4K / 16K / 32K | 65.2 / 48.5 / 47.0 | 64.0 / 50.4 / 50.4 | 64.7 / 50.1 / 56.1 |
Acceptance does not drop (differences are within the per-request noise, n=3 requests of 128 tokens); decode tok/s is noisy (cv ~5-10% across passes) with no regression beyond noise. **Prefill gain is 0.0% at 16K and 32K** (gate >= 1%), and an extra cross-check (W=1, almost no head work) is also not faster than the full head (17.06 vs 16.99 s TTFT at 16K, 2 passes each, `raw/skipchk`). In the served path the head prefill therefore costs ~0% of TTFT (L0's 2.8% was a fenced/isolated attribution; in the real pipeline it overlaps). Kill per rule. This also means the earlier L3a "-2.2%" skip result is not reproduced by W3 here (different prompt/sampling path); L3a is unchanged and still default.

## 4. Side fixes included (behavior, default on)
- `adoptCachedPrefix(requireMTP:)` now uses `j.mtp != nil` (was `head != nil`): a job that skipped the head (L3a) no longer restores head state from a trie hit and silently runs the head.
- `generateSpec` prefill timing (benchmark only).
- `STRIM_TIMING` prints per-request `mtp_accept` / `coldjob` lines in the engine.

## 5. Not done / open
- Hot-session turn-2 with a windowed head: covered by the `checkprefix 8192 +MTP` hot-continue gate at window 0 and by unit tests of `MTPState.base`/restore; not exercised end-to-end with `STRIM_MTP_WINDOW` > 0 because the lane was killed on the prefill gate.
- 16K/32K benchspec timing breakdown (memory, see top).
Raw: `raw/`, `parity/`, scripts `ab.sh l4all.sh l3ball.sh w3.sh cli.sh wd_run.sh table.sh`. Paths scrubbed to /Users/user; no tokens.
