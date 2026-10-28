# Disk-persisted prefix cache (opt-in), 2026-10-28

Closes the gap vs rapid-mlx / mlx-vlm in `COMPARISON-FEATURES-2026-10-28.md`: a server restart or a
memory-pressure eviction no longer loses agent warm-up (a 16K prefill costs ~17 s, 32K ~36 s).
Default OFF. With it off there is no extra code path: `PrefixStore.disk == nil`, no directory, no file, no thread.

## Enable

- `STRIM_PREFIX_DISK=1`, or `strim serve ... --prefix-disk`, or `--prefix-disk-dir DIR` (implies on).
- `STRIM_PREFIX_DISK_DIR` (default `~/.strim/cache`), `STRIM_PREFIX_DISK_GB` (byte budget, default 20),
  `STRIM_PREFIX_DISK_FLOOR_GB` (free space that must remain after a write, default 20).
- `strim cache stats|clear [--dir DIR]`: size, or delete every cache file (all model fingerprints).

## Design

- Unit: one file per trie node (its block's KV delta per attention layer, GDN conv/ssm, MTP block), tensors
  byte-identical to memory (bf16/f16/f32 raw), so a restored node is bitwise the node that was spilled.
- Layout `<dir>/<fingerprint32>/<key64>-<parent16>.spd`:
  `"STRIMPD1" | u32 header len | JSON header | tensor bytes | SHA-256(all preceding bytes)`.
- Key of block i = SHA-256(fingerprint | key of block i-1 | block tokens as int32 LE). Collision-safe without
  storing tokens; the in-memory trie still compares tokens against the live request.
- Fingerprint = SHA-256 of format version, `PrefixDisk.engineRev` (bump when prefill numerics or state layouts
  change), cut policy, `config.json` bytes and name/size/mtime of every `*.safetensors` of the model and MTP head.
  Another model, quantization, head or engine revision uses another directory; a file moved between directories
  is rejected by its header and deleted.
- Write-behind: `PrefixStore.insert` captures the node's evaluated tensors (zero-copy for contiguous arrays,
  arrays kept alive until written) and a serial utility queue writes `tmp` (O_EXCL, 0600) then `rename`. Pending
  bytes are capped at 384 MiB; if the writer is behind the engine thread waits (max 5 s) rather than leave a hole.
  A node whose parent has no file is skipped. MLX is only touched on the engine thread.
- Budget and floor: before each write, evict LRU leaves (a file no other file names as parent; mtime is the LRU
  clock, touched on hit) until `bytes + new <= budget` and `free - new >= floor`; if still not satisfiable the
  node stays memory-only. Orphaned children left by eviction are leaves and go next.
- Lookup: `PrefixStore.lookup` walks memory; at the first miss it computes the key chain for the following
  blocks, `stat`s the in-memory file index, verifies the run of files concurrently (map, SHA-256, header and
  bounds checks), then builds nodes one at a time and attaches them to the trie. They count against the existing
  `STRIM_PREFIX_CACHE_MB` budget (LRU reclaim as for an insert; loading stops if the budget cannot hold the next
  node), so no new memory plan exists. File pages are mapped, not copied; only the node being built is duplicated.
- Corrupt, truncated, wrong-version or wrong-fingerprint files are ignored, deleted, counted, and end the chain.
- Hooks: `PrefixCache.swift` (`disk`, `Node.diskKey`, `lookup`, `insert`) and one line at store creation in
  `EngineCore`. Implementation: `Sources/StrimCore/PrefixDisk.swift`.

## Privacy

Prompts are sensitive. Files contain tensors and a 256-bit hash chain only: no token ids, text, or request
metadata are written (`diskFilesArePrivateAndHoldNoTokens` greps every file for the token bytes). Directory 0700
(verified to be a real directory owned by the user, else the feature disables itself), files 0600. KV tensors are
still derived from the prompt and can leak content to anyone who can read them, so: same-user threat model as
`~/.strim/token`; clear with `strim cache clear`; keep off shared machines; FileVault covers data at rest.
A hash chain lets someone who already holds a candidate prompt confirm it was cached, nothing more.

## Verification

- Unit tests (`Tests/StrimCoreTests/PrefixDiskTests.swift`): bitwise round trip incl. MTP and bf16, permissions,
  no plaintext tokens, corruption and truncation, fingerprint mismatch, budget/LRU leaf-first, free-space floor,
  memory budget respected on load, disabled makes no files, clearAll.
- Real-model gate: `strim checkprefixdisk <model> <mtp head> 16384 --phase warm|restart` (two processes = a
  real restart): miss reference vs cold-with-disk vs restored-from-disk, hashing KV, GDN, MTP, seed hidden,
  logits and 64 speculative tokens.

Result, qwen38-4bit + qwen38-mtp-4bit, M-series, N=16384 (10 nodes, 2.61 GB), page cache warm (written seconds
earlier; not a cold-SSD read), bench/results/prefix-disk-20261028/:

| | |
|---|---|
| miss reference prefill | 16.83 s |
| cold run with disk on (10/10 nodes spilled, 0 stalls) | 17.30 s (+0.5 s, 2.8%, within run noise) |
| restart: load 2.61 GB | 1.9 s = 726 ms/GB (1.38 GB/s incl. SHA-256 verify and MLX copy) |
| restart TTFT (load + 1024-token tail) | 3.13 s vs 17.30 s |
| restored vs miss | cache, MTP, seed, logits, token, 64 spec tokens all identical |
| peak phys_footprint | 21.67 GB restart vs 22.04 GB cold run: no growth |

## Limits

- Spill happens at insert time; nodes dropped by the busy timeout or the floor stay memory-only.
- Windowed MTP heads and thinned (state-less) nodes are not specially persisted: a thinned node is spilled with
  its state at insert time, so disk hit points are denser than memory ones.
- `engineRev` is manual: bump it with any change to prefill arithmetic, KV/GDN/MTP layout or quantization code.
- The Bash sandbox deny list (`StrimHarness/Sandbox.swift`, `secretLiterals`) names `.strim/token` only; add
  `.strim/cache` there so the delegated model cannot read cached tensors (not done here: file not owned by this slice).
