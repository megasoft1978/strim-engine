# Vendor plan for the kept S4a patch

The S4 experiment ends at the patch and this plan. The real `Package.swift` and
`Package.resolved` stay unchanged. No GitHub fork, push or vendor directory was created.

1. In a separate integration change, materialize a local Swift package at
   `Vendor/mlx-swift`, using exact mlx-swift **0.32.3**
   (`19601207e9a0de51e03ee6ec0c3c5f3784275075`), including its MLX submodule at
   `1f8e74e3f12f31365464a6867c6579f0e9b29d85`. Include actual submodule source rather
   than a Git link or references to `/tmp` checkout object stores. Preserve the wrapper
   and MLX MIT licenses and copyright notices. Keep the existing resolved
   swift-numerics 1.1.1 pin; the scratch manifest's absolute numerics path is only a
   local experiment convenience and must not ship.
2. Retain `qmv-cap8.patch` and an origin manifest recording those revisions, patch
   checksum and benchmark report. From the vendored mlx-swift package root, apply
   `patch -p1 < .../qmv-cap8.patch`. Make the patch step reject an unexpected source
   context or an already applied patch. A normal `git archive` of the wrapper alone
   does not populate the nested MLX submodule.
3. Change the real root dependency to `.package(path: "Vendor/mlx-swift")`; keep
   product package identity `mlx-swift`. Do not copy either scratch Package.swift
   wholesale. Preserve upstream build/resource declarations so Metal libraries are
   included for release CLI and app builds. The patch changes only the qmv_wide
   tile cap on the generation >=17, non-'d' branch, matching the existing M5 Max
   dispatch path; it does not change `get_qmv_batch_limit` or any Metal arithmetic.
4. Re-run the pinned release build, relevant CPU tests, and existing exact-quality
   gates under `/tmp/strim-bench.lock`: `gen 16`, depth-0 `benchspec` EXACT,
   `checkprefix 4096/8192 +MTP`, concurrent-decode engine benchmark and
   `checkbatchparity`. Compare patched vs unpatched outputs within each identical
   batch/chunking policy; baseline B=1 vs B>1 differences are a separate existing
   numerical issue. Include c=6/7/8 and verify widths 3/5/8, checking logits and
   hashes against the unpatched dependency. S4 proved output identity for its
   measured cases, not every internal tensor or unmeasured hardware configuration.
5. Re-run two ABBA cycles of the S4 workloads on the installed release artifact,
   recording fresh controls and GPU-memory peaks. Require c=8 aggregate >=+2%,
   no c=1 regression beyond measured noise, and output identity. Treat any other
   device path or future architecture included by the >=17 predicate as unmeasured;
   restrict the production predicate or validate those devices before broad rollout.
   Check MTP width 3/5 stability; do not promise a normal-depth MTP speedup from this
   patch, since those widths retain the same tile.
6. Keep upstream version upgrades explicit: verify origin revisions and patch context,
   re-evaluate the cap against upstream changes and repeat gates. Rollback is the
   original exact 0.32.3 remote dependency (or cap 5 in the vendor source). No weight
   conversion or model/cache format change is involved.

S4b's GDN projection fusion is rejected and is not part of this plan.
