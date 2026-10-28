# perf-validate 2026-10-27 (commits 0fe0b3a + boundary-id fix)
old = 0fe0b3a^ release build, new = working tree release build, same GPU, ABAB.
Gates (exact): checkprefix 4096 / 8192+MTP ALL PASS; gen16 ids identical old/new; benchspec depth-0 parity EXACT; checkprefixcuts (multi-message, plain + MTP) ALL PASS.
old-r*/new-r*: W5 (4 reps x 4 requests) + replay; the `new` binary there still had the wrong <|im_start|> id (151644; Qwen3.8 is 248045), so it shows lazy lookup only.
old2-r*/new2-r*: replay with the boundary-id fix (message cuts active).
cuts_fixed.log = STRIM_PREFIX_CUTS=fixed (== old chunking) cold prefill; cuts_new/cuts2_new = cut policy.

## cut-policy sweep (cut-sweep/)
Default chosen: STRIM_PREFIX_CUT_MIN=1024, STRIM_PREFIX_CUT_MAX=1536 (STRIM_PREFIX_CUTS=fixed restores 1024 blocks).
Cold prefill tok/s (5133 / 16723-token multi-message prompt), replay prefill sum (s), see cut-sweep/*.log and */replay/summary.md.
