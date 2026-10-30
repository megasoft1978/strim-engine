# strim evolve v0

Deterministic tuning of the harness pack. No LLM proposer: a hand-written candidate list, searched by coordinate
ascent, judged by the agent bench. Plan: `docs/PLAN-PRODUCT-2026-10-27.md` section C.

## What can change (and what cannot)

`PackCandidate` (Sources/StrimEvolve/Candidate.swift) is the only thing the search can express:

| field | options |
|---|---|
| system_prompt | baseline, verify_first, lean, ambitious |
| tool_guidance | baseline, examples, strict |
| playbook_test_fix | off, concise, stepwise, converge |
| playbook_repo_qa / playbook_mechanical_edit | off, concise, stepwise |
| stall_nudge | off (default), on |
| result_shape | head_tail (default), errors_first |
| progress_gate | off (default), on |
| test_status | plain (default), structured |
| result_cap | harness_default, tight (1500 chars), wide (8000) |
| compaction_threshold | harness_default, early (0.6), late (0.85) |
| compaction_summary | harness_default, structured, terse |
| thinking | off, first_planning_turn, all_turns_medium/high/xhigh, on_stall_medium/high/xhigh |
| temperature | greedy (0), warm (0.6); retained for existing candidates |
| context | standard (default), long, xlong (currently capped to long) |
| sampling | greedy (default; legacy temperature), qwen (turn-dependent preset) |
| preserve_thinking | off (default; legacy behavior), on |

All 17 coordinates are searched by default. Every one is consumed by the harness: prompt text through
`STRIM_PACK_DIR`, the other knobs through `knobs.json` (`Coordinate.consumedByHarness` is true for all of them).

`--coordinates` accepts `system_prompt,tool_guidance,playbook_test_fix,playbook_repo_qa,playbook_mechanical_edit,result_cap,compaction_threshold,compaction_summary,thinking,temperature,stall_nudge,result_shape,progress_gate,test_status,context,sampling,preserve_thinking`.

The new values are opt-in: `converge` adds a stop-and-diagnose rule after two edits leave the same assertion failing;
`stall_nudge=on` appends advisory feedback after the second recurrence of a normalized bash failure following edits
(third occurrence), at most once per signature per three turns. Successful `edit_file` / `write_file` calls count as edits.
Failure signatures retain assertion context and normalize durations, timestamps, hex addresses and temporary paths.
The reminder never changes command output, exit codes or loop limits.
`result_shape=errors_first` preserves an exit-code line, the first three diagnostic blocks (two context lines on
each side when the budget permits), and the tail summary for oversized bash results, with line-elision markers
inside the existing character cap. Other tools and short results keep their existing formatting.
Default fields are omitted from candidate and pack-knob JSON so all existing candidate fingerprints stay unchanged.

`progress_gate=on` tracks successful file-tool edits and, for git workspaces with at most 2,000 tracked
files, bounded metadata snapshots before/after non-test shell commands (size, modification time, inode, deletion).
A failed test gets an assertion → source file/symbol → intended change instruction. A second failure with the
same normalized test names/assertions and no intervening edit gets one firm source-target reminder. The third
ends the job as `failed` with a `blocked:` summary, never DONE/claimed_done, so it does not create a false_done
penalty. Runs are executed before comparison, including identical commands; the gate does not hide a rerun.
Edits, success, or changed failure evidence reset the streak. If a source path is unknown, the reminder asks the
agent to locate the source symbol rather than inventing a path. Shell snapshots are best effort (no content reads,
no symlinks outside the workspace); unavailable git, large repos, and newly untracked files rely on file-tool edits.

`test_status=structured` enables Bash pipefail for detected test/verify commands and prepends at most 1,500 bytes
of exit status, parseable pass/fail counts, failing test names, expected/actual evidence, and file:line references.
The rest retains the existing result cap and shape. The command record keeps the original command with the
pipefail exit code (including failures from output filters). Pipefail applies to pipelines in the invoked shell;
commands that explicitly swallow errors or nested scripts manage their own status. Recognition uses the task's
verify command and common Go, Node, Bun, Cargo, Swift, pytest/unittest, Ruby/rake, Java script and tsc runners,
including shell pipelines. Tool grammar, tools, sandbox and deny lists are unchanged.

`on_stall_medium` renders `thinking: on_stall`, `reasoningEffort: medium`. Thinking is normally off. Two
unchanged failing test runs without an edit, or an emitted `stall_nudge` reminder, enable exactly the next assistant
generation with `thinkingTurnTokens` (8,192, bounded by the job token limit); subsequent turns revert to normal.
This trigger works with `progress_gate=off` too. Compaction does not independently enable recovery thinking.
An on-stall recovery turn costs up to two extra prefills, bounded by the 8,192-token thinking turn cap.

Example paired evaluation (dry-run, no model):

```sh
strim evolve run --dry-run --out /tmp/pg1/dry-run --tasks-dir bench/agenttasks --max-tasks 2 \
  --candidate '{"progress_gate":"on","test_status":"structured","thinking":"on_stall_medium"}' --against baseline
```

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
| stall_nudge | `off` (default), `on`: advisory repeated-failure note, only after edits | |
| result_shape | `head_tail` (default), `errors_first`: bash-only diagnostic shaping for oversized output | |
| progress_gate | `off` (default), `on`: unchanged-test recovery and blocked termination | |
| test_status | `plain` (default), `structured`: pipefail and compact test digest | |
| resultCapChars | head+tail cap on every tool result shown to the model (the loop cap; tools keep their own) | 200...8000 (8000 = today) |
| compactionThreshold | fraction of the effective context at which the loop compacts (standard default 28000 = 0.855) | 0.4...0.9 |
| compactionSummaryPrompt | compaction is a deterministic log (no LLM summarizer), so the text is added to the continuation message as "Progress-note format"; control chars dropped, `<` escaped, 1000 chars max | |
| thinking | harness policy `off`, `first_planning_turn`, `all_turns`, `on_stall`; evolve variants select effort separately | |
| temperature | sampling temperature; above 0 also top_p 0.95, top_k 20 | 0...1 |
| seed | base seed (default 20261027); generation n of a drive samples with seed+n, so reruns are reproducible. Ignored when greedy | any |
| decoding | informational (`greedy` or `sampled`) | |
| context | `standard`: 32768 accounting / 28000 compaction / 4096 normal, 8192 thinking output; `long`: 65536 / 56000 / 8192, 16384; `xlong`: requested 131072 / 112000, currently clamped to the long values | max effective context 65536 |
| sampling | absent: existing temperature behavior; explicit `greedy`: 0/1/0; `qwen`: thinking 1.0/0.95/20, non-thinking 0.7/0.8/20 (temperature/top_p/top_k), overrides temperature | |
| preserve_thinking | `off`: leave historical template behavior unchanged; `on`: explicitly retain reasoning across user turns and thinking-session replays; compaction drops old reasoning before rebuilding progress | |

Limits (turns, seconds, tokens), sandbox, tool set and order are not knobs: any other key makes the file invalid, and
non-finite or out of range numbers are clamped. `HarnessKnobsTests` covers a hostile file (maxTurns 10^9, negative
values, huge values, symlinked file).

#### Thinking: `first_planning_turn`

Thinking is on for the first assistant turn of a job (and of the fresh session after a compaction), off for every
other turn; in a chat, for the first generation of the conversation only. The template renders thinking only in the
generation prompt (`<think>\n` vs `<think>\n\n</think>\n\n`) and, with the default effort, a reasoning instruction in
the system block. The thinking session therefore uses `reasoning_effort: medium` (no instruction), so system block,
tools block and user message are byte-identical to the thinking-off render and `ThinkingPrefixCacheTests` pins this.
Engine sessions have an immutable config, so after the thinking turn the harness opens a normal session,
replays the conversation (including generated reasoning and tool results), and closes the thinking one.
The template already defaults to preserving reasoning; `preserve_thinking=off` leaves this legacy behavior
unchanged, rather than forcing a template setting that would change old runs. `on` explicitly sets
`SessionConfig.preserveThinking=true` and retains the replay transcript even after leaving first-turn thinking,
including subsequent user turns. This is deliberately partly redundant with existing all-turn thinking.
Compaction drops **all** earlier reasoning first, then replaces history with the bounded progress log and recent
tool exchanges. Reasoning-only assistant messages are never carried into a compacted session; the summary carries
progress. When usage is unavailable, opted-in preserved reasoning contributes to estimated context accounting.

`all_turns_medium` and `on_stall_medium` retain their exact old rendered knobs and fingerprints. New
`all_turns_high`, `all_turns_xhigh`, `on_stall_high`, `on_stall_xhigh` variants use the same policies with
`reasoningEffort=xhigh`. **High is an alias of xhigh**, because the installed template and
[`ChatTemplate.renderSegments`](../Sources/StrimTemplate/ChatTemplate.swift) support only low/medium/xhigh;
passing literal high to a thinking template throws. Xhigh adds an instruction to the system block and therefore
changes its prefix cache key, intentionally, only for these new candidates.

#### Context limits and memory evidence (2026-10-30, source-only)

The [Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B) and installed
`~/.strim/models/qwen38-4bit/config.json` (`text_config.max_position_embeddings`) / `tokenizer_config.json`
(`model_max_length`) give a native limit of 262144. No YaRN extension is configured here. The current engine has
**no fixed prompt-length truncation or rejection at 32K/64K**: [`EngineCore.startGenerate` and `admit`](../Sources/StrimEngine/EngineCore.swift)
admit the prompt plus requested output against available memory, or throw `insufficientMemory`.
[`AttentionCache.append`](../Sources/StrimCore/Cache.swift) grows KV buffers in 256-position increments;
it does not use a sliding context window. [`Attention.forward`](../Sources/StrimCore/Attention.swift) uses RoPE offsets.
The harness ceiling below is conservative, not a new server context limit.

[`MemoryModel`](../Sources/StrimEngine/Admission.swift) accounts for 16 full-attention layers × K+V × 4 KV heads ×
256 dimensions × 2 bytes = **65536 bytes/token**. The 48 linear-attention GDN layers keep fixed recurrent/conv
state (~147 MiB per sequence), not token-growing KV; see [`GDNState` / `ModelCache`](../Sources/StrimCore/Cache.swift).
MTP adds at most 4096 bytes/token to admission. Thus a complete prompt+output sequence costs:

| sequence | attention KV | MTP reserve | fixed GDN | total request estimate |
|---|---|---|---|---|
| 32768 | 2 GiB | 128 MiB | 147 MiB | 2.269 GiB |
| 65536 | 4 GiB | 256 MiB | 147 MiB | 4.394 GiB |
| 131072 | 8 GiB | 512 MiB | 147 MiB | 8.644 GiB |

On a 64 GiB host the normal planner uses half RAM (32 GiB) for the engine, reserves **6 GiB** for live requests
and 800 MiB for one prefill workspace, estimates resident weights at 0.95× safetensors size, and sizes the MLX cache
to budget/32 (1 GiB here). Prefix cache is bounded by 12 GiB, budget/5 (6.4 GiB here), and remaining room
(minimum 1 GiB). With the engine's 16 GiB reference weight size the 64K request admits, while 128K with MTP is
rejected even without another active request (covered by `QwenPresetRequestTests`). Exact installed weight bytes
were not inspected; config geometry and quantization (4-bit/group64) were inspected read-only.

Therefore **xlong is capped to long (65536 accounting / 56000 compaction)**. Both larger-context variants cap
normal/thinking output at 8192/16384, and additionally clamp to remaining estimated context, the task's remaining
generated-token budget, and server output ceilings. An already oversized prompt after compaction returns blocked.
The context is estimated as in the legacy harness, not a tokenizer guarantee. No GPU/model run was performed;
these are admission-model estimates, not measured peak-memory or quality claims. Concurrent active requests can
still exhaust admission headroom and are rejected safely.

[`EngineConfig.fromEnvironment`](../Sources/StrimEngine/EngineCore.swift) reads `STRIM_MEM_FRACTION`,
`STRIM_MEM_BUDGET_GB`, `STRIM_PREFIX_CACHE_MB` / `STRIM_PREFIX_CACHE=0`, `STRIM_MLX_CACHE_MB`, and hot-session
settings. Explicit smaller budgets or larger prefix reservations can reject even long; the harness does not raise
memory budgets or bypass admission. Raising these settings does not lift this conservative xlong clamp.
[`ServerLimits`](../Sources/StrimServer/ServerLimits.swift) defaults to 1048576 output tokens
(`STRIM_MAX_OUTPUT_TOKENS`) and 32768 for background requests (`STRIM_BACKGROUND_MAX_TOKENS`);
[`ChatRequest.parse`](../Sources/StrimServer/ChatRequest.swift) clamps max_tokens rather than rejecting it.
The harness uses the same environment ceilings for long/xlong, without changing standard-mode traffic.

#### Qwen opt-in candidates

The [model card](https://huggingface.co/Qwen/Qwen3.8-27B) specifies the two sampling triples used above and
recommends retaining reasoning for agents. Presence/repetition penalties are not implemented by this engine;
`sampling=qwen` selects the supported temperature/top_p/top_k fields only. It overrides the existing temperature
coordinate. `sampling=greedy` in a candidate leaves the legacy temperature coordinate in charge, so old warm
candidates retain their bytes and behavior; explicit harness `knobs.json` sampling=greedy forces greedy.
Every Qwen evaluation writes its **row seed** into the live pack (without changing the stored candidate fingerprint);
generation n uses seed+n, and rows record decoding=sampled. Fixed seeds reproduce the sampling stream given the
same engine outputs; GPU determinism is not asserted.

`system_prompt=ambitious` replaces the system component (rather than appending contradictory instructions).
It removes size/design decline rules and asks for a numbered multi-file plan, running checklist, read-before-edit,
complete minimal changes and iterative verification. Sandbox/root, no-network, untrusted-content, and test-integrity
rules remain. It declines only network-dependent or unverifiable tasks; other blockers are reported honestly.

Exact minimal candidate objects (all omitted fields use baseline values):

```json
{
  "qwen_full": {"system_prompt":"ambitious","context":"long","thinking":"all_turns_xhigh","sampling":"qwen","preserve_thinking":"on"},
  "context_only": {"context":"long"},
  "system_only": {"system_prompt":"ambitious"},
  "thinking_only": {"thinking":"all_turns_xhigh"},
  "sampling_only": {"sampling":"qwen"},
  "preserve_thinking_only": {"preserve_thinking":"on"}
}
```

Paired dry-run, no GPU/model/server (a supplied split can contain exactly two tasks, e.g. one train and one val):

```sh
strim evolve run --dry-run --out /tmp/qk1/paired --tasks-dir bench/agenttasks --split /tmp/qk1/two-task-split.json \
  --candidate '{"system_prompt":"ambitious","context":"long","thinking":"all_turns_xhigh","sampling":"qwen","preserve_thinking":"on"}' --against baseline
```

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
strim evolve run    --candidate JSON|FILE [--against JSON|FILE|baseline] --split test --release-eval --out DIR
strim evolve report [--out DIR]
strim evolve adopt  [--out DIR] [--store DIR] [--no-active]
```

- `--coordinates a,b`: restricts the search to these coordinates, in ascent order. Names are the raw values of the
  table above (`system_prompt`, `tool_guidance`, `playbook_test_fix`, `playbook_repo_qa`, `playbook_mechanical_edit`,
  `result_cap`, `compaction_threshold`, `compaction_summary`, `thinking`, `temperature`, `stall_nudge`, `result_shape`, `progress_gate`, `test_status`, `context`, `sampling`, `preserve_thinking`). Default: all 17.
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

If a search was stopped by owner decision, use the fixed candidate form to evaluate the chosen candidate against the specified arm (baseline by default) on the frozen test split. Run this release evaluation once; rerunning the same command resumes any incomplete runs.

## First live run

Recommended: two knobs (`thinking`, `temperature`), at most 2 tasks per class in train and val, 1 rep on train.
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

## Fixed-candidate paired evaluation

`run --candidate <json|file> [--against <json|file|baseline>]` compares two fixed packs, A (`--against`, default
`baseline`) and B (`--candidate`), on TRAIN and VAL. Inline objects and JSON files use the strict `PackCandidate`
decoder: unknown fields and unknown enum values fail. Omitted fields use baseline defaults.

```sh
strim evolve run --out bench/results/paired-stall --tasks-dir bench/agenttasks \
  --candidate '{"thinking":"all_turns_medium","playbook_test_fix":"converge","stall_nudge":"on","result_shape":"errors_first","tool_guidance":"strict"}' \
  --against '{"thinking":"all_turns_medium"}' \
  --model <model-dir> --head <head-dir> --budget-minutes 240 --train-reps 1 --val-reps 2
strim evolve report --out bench/results/paired-stall --tasks-dir bench/agenttasks
```

All ordinary run controls apply, including `--dry-run`, `--max-tasks`, budget, model/head, timeouts and lock flags.
Use `--split <file>` to reuse an existing `split.json` assignment, for example
`--split /tmp/ev1/run2/split.json`. It is validated against the task corpus and frozen in the new output directory;
resume refuses a different assignment. Only that assignment's train and val tasks are evaluated.
Within each split, successive tasks alternate their first arm: the first runs A1,B1,B2,A2 (ABBA), the second
runs B1,A1,A2,B2 (BAAB), and subsequent repetitions keep alternating. Each side gets exactly `--train-reps` /
`--val-reps`, with matching seeds per task/rep.
Rows use the usual ledger and `phase: "paired"`. Resume repeats the same command, skips completed paired
candidate/split/task/rep keys, and retries infrastructure failures. `paired.json` records both packs and fingerprints;
changing either pack requires a new `--out`. Existing config/split and dry-run ledger isolation still apply.

The final summary and standalone `report` show each side's pass rate, mean wall time, mean local tokens,
false-done count/rate and timeout count per split, plus both-pass/only-A/only-B/neither counts per task over
completed matching repetitions. Coverage is shown so interrupted runs are visible. Infrastructure failures are
excluded from these statistics. There is no coordinate ascent, selection or adoption; `adopt` refuses a paired
output directory. This paired train/val mode does not run the test split; use the fixed candidate release form above for a test evaluation.
