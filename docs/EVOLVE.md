# strim evolve v0

Deterministic tuning of the harness pack. No LLM proposer: a hand-written candidate list, searched by coordinate
ascent, judged by the agent bench. Plan: `docs/PLAN-PRODUCT-2026-10-27.md` section C.

## What can change (and what cannot)

`PackCandidate` (Sources/StrimEvolve/Candidate.swift) is the only thing the search can express:

| field | options |
|---|---|
| system_prompt | baseline, verify_first, lean |
| tool_guidance | baseline, examples, strict |
| playbook_test_fix / playbook_repo_qa / playbook_mechanical_edit | off, concise, stepwise |
| result_cap | harness_default, tight (1500 chars), wide (8000) |
| compaction_threshold | harness_default, early (0.6), late (0.85) |
| compaction_summary | harness_default, structured, terse |
| thinking | off, first_planning_turn |
| temperature | greedy (0), warm (0.6) |

All 10 coordinates are searched by default. Every one is consumed by the harness: prompt text through
`STRIM_PACK_DIR`, the other knobs through `knobs.json` (`Coordinate.consumedByHarness` is true for all of them).

Variant texts live in `PackLibrary.swift` (`Variants`). The baseline renders exactly the shipped pack
(`PackLoader.shipped()`), so baseline = today's behaviour.

Not representable, by construction (there is no field, and `PackCandidate` decoding rejects unknown keys):
tool order, sandbox profile, HostPolicy, deny lists, redactor, limit ceilings, verify command, MCP surface.
`guardrails.md` is copied from the shipped pack unchanged. `SafetyBoundaryTests` hashes Sandbox, WorkspacePolicy,
Redactor, ProcessRunner (StrimHarness) and HostConfig (HostPolicy) before and after a full evolve run on fake data and
fails on any change.

### What reaches the model

Prompt text: a pack directory is picked up through `STRIM_PACK_DIR` (`PackLoader.builtin()`).
Knobs: `PackLoader.builtinKnobs()` reads `STRIM_PACK_DIR/knobs.json` at every job/session assemble
(`HarnessKnobs`, Sources/StrimHarness/HarnessKnobs.swift) and `HarnessRunner` hands it to `AgentLoop`.
Absent file = exactly the shipped behaviour (golden-tested: same engine traffic, same tool specs). An invalid file
(unknown key, wrong type, over 64 KB, symlink) is reported on stderr and ignored.

| knob | effect | safe range (clamped) |
|---|---|---|
| resultCapChars | head+tail cap on every tool result shown to the model (the loop cap; tools keep their own) | 200...8000 (8000 = today) |
| compactionThreshold | fraction of the 32768-token context at which the loop compacts (default 28000 = 0.855) | 0.4...0.9 |
| compactionSummaryPrompt | compaction is a deterministic log (no LLM summarizer), so the text is added to the continuation message as "Progress-note format"; control chars dropped, `<` escaped, 1000 chars max | |
| thinking | `off` or `first_planning_turn` (below) | |
| temperature | sampling temperature; above 0 also top_p 0.95, top_k 20 | 0...1 |
| seed | base seed (default 20261027); generation n of a drive samples with seed+n, so reruns are reproducible. Ignored when greedy | any |
| decoding | informational (`greedy` or `sampled`) | |

Limits (turns, seconds, tokens), sandbox, tool set and order are not knobs: any other key makes the file invalid, and
non-finite or out of range numbers are clamped. `HarnessKnobsTests` covers a hostile file (maxTurns 10^9, negative
values, huge values, symlinked file).

#### Thinking: `first_planning_turn`

Thinking is on for the first assistant turn of a job (and of the fresh session after a compaction), off for every
other turn; in a chat, for the first generation of the conversation only. The template renders thinking only in the
generation prompt (`<think>\n` vs `<think>\n\n</think>\n\n`) and, with the default effort, a reasoning instruction in
the system block. The thinking session therefore uses `reasoning_effort: medium` (no instruction), so system block,
tools block and user message are byte-identical to the thinking-off render and `ThinkingPrefixCacheTests` pins this.
Engine sessions have an immutable config, so after the thinking turn the harness opens a normal (today's) session, replays
the conversation without any reasoning content (history = system, user, assistant tool calls, tool results) and closes
the thinking one. Prefix cache: turns 2+ render exactly like today's prompt; the system and tools prefix is served by
the prefix trie, only the first assistant turn and its results are prefilled once more. The thinking turn gets a larger
output budget (8192 tokens, still inside the job's generated-token limit). Reasoning text only goes to the event stream.

## Method

1. Corpus split (`Split.swift`): bench/agenttasks, stratified by class, ordered by SHA-256 of the task id, 60/20/20
   train/val/test (18/6/6 for the 30-task corpus). Persisted in `<out>/split.json`; later runs reuse it and refuse a
   corpus that lost assigned tasks. The test split is frozen: `SplitGuard` rejects it unless `--release-eval`, and the
   search planner never schedules a test run.
   `--max-tasks N` (saved in `config.json`) keeps only the first N tasks of each class (sorted ids) in train and val, for
   a cheaper first run. It is applied in memory: `split.json` keeps the full assignment and the test split is never limited.
2. Fitness per run (`FitnessRow`): hidden verify pass (bench judge: `test_paths` restored from the snapshot and hashed,
   then `verify_cmd` or the answer oracle) = 1, minus 2 for a false-done (claimed done, verify failed; tampered tests
   never pass). Tie-break: local tokens (prompt + completion), then wall time, then fingerprint.
3. Coordinate ascent (`Search.swift`), per round, per coordinate in a fixed order:
   - evaluate the incumbent and the other options of that coordinate on train (1 rep);
   - the option with the best paired train gain over the incumbent (strictly positive, >= 80% row coverage) is the proposal;
   - the proposal and the incumbent are run on val, 2 reps;
   - adopt only if `Selection.confirm` says so: paired mean fitness gain >= 5 pp, no rep with a negative gain (noise
     guard), challenger false-done rate <= 5% or no worse than the incumbent's, >= 80% of paired rows present.
4. `SearchPlanner.replay` is a pure function from the results table (ledger rows) to the incumbent, the steps and the
   runs still missing. Resume = run again. Infrastructure failures are holes and are rerun. Selection rules are unit
   tested on recorded tables (ties, noise, regressions, missing rows).
5. Determinism: every row records the candidate fingerprint, the seed handed to the runner and the decoding mode
   (`greedy` or `sampled`). Fingerprint = first 16 hex of SHA-256 over the canonical JSON (sorted keys) of the
   candidate plus hashes of the rendered texts and knobs, so editing a variant text changes the fingerprint.
   Reps of a greedy candidate on one task may be identical; that is expected and cheap.
6. Packs are stored as `~/.strim/packs/<fingerprint>/` (dir 0700, files 0600): system.md, tool_guidance.md,
   guardrails.md, memory.md, knobs.json, candidate.json, FINGERPRINT, provenance.jsonl. `ACTIVE` names the adopted one.

## Kill rule

Stop if val gain is below 5 pp after 2 rounds: if no round adopted a val-confirmed challenger (a round with no
change counts as converged, since another round would repeat it), `run` exits 6, `report` prints `KILL RULE`, and
`adopt` refuses. Do not build the proposer (v2) in that case.

## Commands

```
strim evolve plan   [--out DIR] [--tasks-dir bench/agenttasks] [--coordinates a,b] [--max-tasks N] [--train-reps N]
strim evolve run    [--out DIR] --model DIR [--head DIR] [--budget-minutes N] [--background]
strim evolve run    --dry-run [--out DIR]                       # fake runner, no model, no GPU lock
strim evolve run    --split test --release-eval [--out DIR]    # frozen test split, after the search finished
strim evolve report [--out DIR]
strim evolve adopt  [--out DIR] [--store DIR] [--no-active]
```

- `--coordinates a,b`: restricts the search to these coordinates, in ascent order. Names are the raw values of the
  table above (`system_prompt`, `tool_guidance`, `playbook_test_fix`, `playbook_repo_qa`, `playbook_mechanical_edit`,
  `result_cap`, `compaction_threshold`, `compaction_summary`, `thinking`, `temperature`). Default: all 10.
  `--include-unplumbed` is deprecated and ignored (prints a note).
- `--max-tasks N`: search splits only (see Method 1). Default: all tasks.
- `--budget-minutes N`: checked between runs (a single run is bounded by `--timeout-s`, default 900). Exit 3 on stop; run again to resume.
- `--background`: lowers process priority (nice 15); the server child inherits it.
- GPU lock: same `FileLock` and `/tmp/strim-bench.lock` as `agentbench` (`--lock-path`, `--lock-wait-s`, `--lock-held`).
  Live runs spawn their own `strim serve` with `STRIM_PACK_DIR=<out>/live-pack`; candidates are swapped by rewriting
  that directory between runs (serial, one task at a time). Attaching to a running host is not supported because it
  would not see the pack directory.
- Exit codes: 0 finished, 3 budget, 4 infrastructure failure, 5 interrupted, 6 kill rule.
- Ledger: `<out>/ledger.jsonl` (`ledger.dry-run.jsonl` for `--dry-run`; fake data never mixes with real data, and
  `adopt --dry-run` needs an explicit `--store`). Config: `<out>/config.json`; flags that disagree with an existing
  config are refused, use a new `--out`.
- `adopt` refuses unless the search finished, the pack differs from baseline, no search row touched the test split,
  and the ledger has no dry-run rows. It prints the `STRIM_PACK_DIR=` line to use the pack.
- Release evaluation (`--split test --release-eval`) runs baseline and the chosen pack on test, 2 reps, phase `release`.
  `report` shows the paired difference and flags a regression; the lead decides what to do with it. Do it once.

## First live run

Recommended: two binary knobs (`thinking`, `temperature`), at most 2 tasks per class in train and val, 1 rep on train.
The test split is untouched.

```
swift build -c release          # lead only
.build/release/strim evolve plan --out bench/results/evolve-20261028 --coordinates thinking,temperature --max-tasks 2 --train-reps 1
.build/release/strim evolve run  --out bench/results/evolve-20261028 \
    --model <model dir> --head <mtp head dir> --budget-minutes 240 --background
.build/release/strim evolve report --out bench/results/evolve-20261028
```

`run` reads the saved `config.json`; repeating the flags is allowed only when they match it. Round 1 for this run is
12 train runs + 6 baseline train runs + 48 val runs (`plan` prints the exact bound). Round 1 over all 10 coordinates
(default, no `--max-tasks`) is 324 train + 240 val runs, about 29 h at 3 min/run: `plan` prints the bound for any flags.
