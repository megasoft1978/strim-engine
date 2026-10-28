# Release hygiene review, 2026-10-28

Scope: working tree of tracked files + non-ignored untracked files, before single-commit squash. History not scanned. Read-only review; findings appended below.

## Inventory
- Tracked files: 1608. Untracked non-ignored: 113 (all under bench/h2h/, bench/results/{agentbench-20261028-pyfix,h2h-final-20261028,head2head-20261026}/, docs/SECURITY-REVIEW-*). Also modified: Package.swift, Sources/StrimCLI/Commands.swift.
- File types: no Mach-O, no weights, no __pycache__, no .app/dist in tracked or untracked set. 17 `.tar.gz` are bench/agenttasks/tasks/*/snapshot.tar.gz (small task snapshots).

## 1. Secrets
- BLOCKER bench/results/agentbench-20261028-pyfix/control-token:1 and server.token:1: 64-hex bearer tokens (untracked, NOT gitignored; `*.log` ignore does not cover them). Neither value occurs in any other file; neither equals the live ~/.strim/{token,control-token}. Action: delete both files (`rm` the two paths) and add `bench/results/**/*token` and `*.token` to .gitignore.
- No private keys, ghp_/gho_/github_pat_/AKIA/xox/hf_/AIza strings in any real form. Hits are test/redactor fixtures only (benign): Sources/StrimHarness/Redactor.swift:29, RunProfile.swift:173, Tests/StrimHarnessTests/{ChatSessionTests.swift:176,RedactorTests.swift:12,121,166}, Tests/StrimMCPTests/{ResultRenderTests.swift:98,100,ToolsTests.swift:24}, Tests/StrimBenchHTTPTests/NeedleTests.swift:195 (fake "Bearer secret-token"). Keep.
- No tracked .env, .pem, id_rsa. .gitignore covers .env, .env.*.
- bench/results/h2h-final-20261028/strim/pass1/server.txt:5,12,19 mention the control-token PATH only (not the value); fine after the path scrub below.

## 2. Personal data
- Intended identity (keep): LICENSE:3 and NOTICE:2 the author name in LICENSE. No GitHub login or personal email string found anywhere in the tree.
- NOTE: no tracked file contains RFC1918 LAN addresses, 10.x LAN IPs, IOPlatformUUID, serial numbers, ssh alias "mini", colpal/CSC/EarlyBytes/a.team/Jira/Slack/Figma.
- <home> hits (88 lines, 8 files). 887 other lines use the already-scrubbed placeholder /Users/user (fine).
  - UNTRACKED bench/results/head2head-20261026/env.txt (58+21 lines): full `ps` top-CPU list incl. <home>/.local/bin/claude, lazygit, Netskope Enterprise Browser (lines 25-27, 31), vendor/llama.cpp gguf listing with home path (42-52), git HEAD. Action: DELETE file (not needed by site); employer-tooling name Netskope leaks.
  - UNTRACKED bench/results/head2head-20261026/raw/rapid-mlx-quality/warmup/summary.md:4 and raw.jsonl:1 (tokenizer path <home>/Desktop/Freelance/strim-engine/models/...). Action: sed `<home>` -> `/Users/user`.
  - UNTRACKED bench/results/h2h-final-20261028/strim/pass1/server.txt:5,12,19 (<home>/.strim/control-token). Action: sed -> `/Users/user`.
  - TRACKED Tests/StrimMCPClientsTests/Fixtures/{claude_a_ask.stream.jsonl:1, claude_b_fix_delegated.stream.jsonl:1,4,6, codex_b_fix.stream.jsonl:7-11, codex_b_fix.row.json (2)}: <home>/.claude-work/projects/..., <home>/.strim/jobs/j_*/patch.diff, and per-user temp dir /private/var/folders/<per-user hash>/T. Also reveal the private "claude-work" profile path and local session_id/uuids (not account IDs). Action: sed -> /Users/user and rename .claude-work path to .claude; verify tests (StrimMCPClientsTests) still pass, as they parse these fixtures; no GPU needed.
- bench/results/perf-profile-20261027/results.json:14 (tracked): "hostname": "<original hostname>". Action: replace with "mac-studio" (or drop key).
- scripts/agents.sh:48,73 "model_providers.local" is a config name, not a hostname. Fine.
- docs/EXPLORATION-2026-10-25.md:346, docs/m5-max-research.md:24, docs/model-selection-2026-10.md:3: "Mac Studio" product mentions only. Fine.

## 3. Size and binaries
- Tracked+untracked text/data total ~19 MB (bench/results 7.5 MB, bench/fixtures 4.4 MB, Sources 2.4 MB, Tests 1.5 MB, site 0.65 MB, agenttasks 0.6 MB). No Mach-O, no weights, no .bundle, no dist/Strim.app, no __pycache__, no .DS_Store in the file set.
- >1 MB (all KEEP, tests read them): bench/fixtures/template_parity.json (1.98 MB), tokenizer_parity.json (1.39 MB), prompt_parity.json (1.08 MB). Largest others: bench/draft_vocab_64k.json 394 KB, site/index.html 382 KB, site/data/results.json 248 KB, build/AppIcon.icns 230 KB, soak run1-invalid-codex-path/tasks.jsonl 165 KB.
- Candidate to drop (optional, no secrets): bench/results/soak-20261027/run1-invalid-codex-path/ (a run labelled invalid; drop unless a doc cites it).
- Large raw jsonl under bench/results are KEEP (site/data/results.json cites raw data; CONTRIBUTING requires it).
- Ignored by .gitignore and therefore not in the commit: *.log, vendor/, models/, .build/, dist/, runs/, logs/, wheelhouse/, .env*.

## 4. License / notices
- Package.resolved is tracked and matches docs/THIRD-PARTY.md: mlx-swift 0.32.3 (rev 19601207), swift-numerics 1.1.1. OK.
- GDN Metal kernel: attribution present in NOTICE (Rapid-MLX + oMLX, Apache-2.0), THIRD-PARTY.md, and Sources/StrimCore/GDNMetal.swift:197-198 comment. Gaps (low): (a) no copy of the Apache-2.0 license text in the repo (Apache s.4a asks for a copy to recipients of derivative works): add LICENSES/Apache-2.0.txt and link it from NOTICE; (b) no file-level header in GDNMetal.swift naming the original copyright holder: add a 3-line header.
- NOTICE:15-18 and docs/THIRD-PARTY.md list more-itertools, python-semver, jmespath.py, parse, cachetools, xmltodict, but bench/agenttasks/manifest.json only contains google/uuid, spf13/pflag, dustin/go-humanize plus 8 original tasks (tf-11..tf-18, MIT, no upstream LICENSE needed). Over-claiming, harmless but inaccurate: trim NOTICE and THIRD-PARTY to what the manifest has. Snapshots me-06..tf-05 do carry upstream LICENSE files (spot-checked 3, and 9 of 9 non-original have one).
- LICENSE is plain MIT, "Copyright line", consistent with NOTICE. OK.
- Qwen weights not redistributed; draft_vocab_*.json are own ids only per THIRD-PARTY. Not independently verified (no token strings seen in head of file).

## 5. SECURITY.md / CONTRIBUTING.md
- SECURITY.md: reporting channel is GitHub private vulnerability reporting; ACTION for owner: enable it in repo settings before publishing (cannot be verified here). Supported versions: "only main", fine. Token claims verified: TokenStore.swift:29 uses SecRandomCopyBytes; token files are 64 hex chars + newline (32 bytes); ControlPlane.swift:327 writes 0600.
- CONTRIBUTING.md and README.md:16 reference `bench/download.py`, which does not exist anywhere in the tree (tracked, untracked or ignored). Dangling instruction: ship the script (with sha256 checks, see 6) or reword.
- CONTRIBUTING.md says oracle scripts were "removed 2026-10-27, in history bundle". After the squash that history is gone: reword to "frozen data, generator not published".
- CONTRIBUTING says "Do not commit logs", yet bench/results holds many raw .jsonl/.stdout files; wording should say "run logs (*.log)".
- docs/HANDOFF.md:8 references untracked `bench/results/head2head-20261026/` and a stale HEAD sha; internal handoff notes (22 KB) are public-facing noise: consider dropping HANDOFF.md or at least line 8. Also CONTRIBUTING:20 and README point at HANDOFF.md, so edit rather than delete blindly.

## 6. Supply chain
- Package.swift:13 pins mlx-swift with `exact: "0.32.3"`; the only other dependency (swift-numerics) is transitive and pinned in the tracked Package.resolved. OK. Package.swift diff pending is whitespace only (StrimCLI dependency list).
- No curl|sh, no sudo, no install scripts needing root, no tracked script that downloads weights or binaries. curl uses are all local 127.0.0.1 health/chat calls (scripts/agents.sh:27,34, scripts/bench_swift.sh:18, integrations/harness2/run_local_codex.sh:13, bench/**/*.sh). No hf download / pip install / brew in scripts. The only absent downloader is bench/download.py (above).
- scripts/make_app.sh: builds .app from local binary, ad-hoc codesign (`-s -`), no install step. README should state the app is ad-hoc signed/unnotarized.
- LaunchAgent (Sources/StrimControl/LaunchAgent.swift): writes ~/Library/LaunchAgents plist 0644, dir 0755, atomic tmp+rename, refuses non-regular existing file, symlink-resolves binary, rejects tmp dirs and group/world-writable binaries/dirs, never runs launchctl (prints command). Good. Log dir mode follows line 137 (not read in full).
- StrimApp login item uses SMAppService.mainApp (Services.swift:251-253), user-level only.
- sandbox-exec profile referenced in SECURITY.md exists in StrimMCPClients/StrimSoak; not audited here (see the -exec/-server reviews).

## 7. Squash risks (untracked-but-required)
- REQUIRED, must be added before the squash: Sources/StrimHarness/SensitiveDirs.swift (untracked, new). Modified tracked files GitWorktree.swift, HarnessRunner.swift, HostConfig.swift, Tools.swift, Commands.swift, Package.swift are uncommitted work from other workers; squashing `git ls-files` alone ships HEAD or fails to build depending on whether the working tree is used. Commit them first.
- bench/h2h/{agent-prompts,agree,pass,run,watchdog}.sh: untracked, no personal data; KEEP (they produce the h2h-final results). Add to the commit.
- bench/results/h2h-final-20261028/ (188 KB): KEEP after server.txt path scrub. bench/results/head2head-20261026/ (868 KB): keep raw/ only after path scrub; delete env.txt. bench/results/agentbench-20261028-pyfix/: keep ledger.jsonl and runs/ only if site/data/results.json cites them (no tracked file references the name; grep found none), otherwise drop the whole dir; delete the two token files in any case.
- No tracked file references the three new untracked result dirs by name except docs/HANDOFF.md:8, so site/data/results.json integrity (`strim site check`) is unaffected by dropping them. If the site claims need them, they must be added.
- Dangling doc reference: bench/download.py (see 5).

## Scrub list (exact actions)
DELETE: bench/results/agentbench-20261028-pyfix/control-token; bench/results/agentbench-20261028-pyfix/server.token; bench/results/head2head-20261026/env.txt
IGNORE (.gitignore): `*.token`, `control-token`, `bench/results/**/env.txt`
SED <home> -> /Users/user: bench/results/h2h-final-20261028/strim/pass1/server.txt; bench/results/head2head-20261026/raw/rapid-mlx-quality/warmup/{summary.md,raw.jsonl}; Tests/StrimMCPClientsTests/Fixtures/{claude_a_ask.stream.jsonl,claude_b_fix_delegated.stream.jsonl,codex_b_fix.stream.jsonl,codex_b_fix.row.json} (also `.claude-work` -> `.claude`; rerun StrimMCPClientsTests)
EDIT: bench/results/perf-profile-20261027/results.json:14 hostname; NOTICE/docs/THIRD-PARTY.md (drop unused python projects, add Apache-2.0 text); CONTRIBUTING.md, README.md:16 (bench/download.py); docs/HANDOFF.md:8
ADD to commit: Sources/StrimHarness/SensitiveDirs.swift, bench/h2h/*.sh, other workers' modified files
INTENDED (keep): LICENSE:3, NOTICE:2 author name.

## Blockers
1. Two untracked, non-ignored bearer-token files (above): delete before squash.
2. Home path + employer tooling leak in untracked head2head env.txt: delete.
3. Uncommitted required source (SensitiveDirs.swift and edits) must be committed first.
4. Owner: enable GitHub private vulnerability reporting; fix dangling bench/download.py reference.
Non-blocking: path scrub in fixtures/results, hostname, NOTICE accuracy, Apache-2.0 text.
