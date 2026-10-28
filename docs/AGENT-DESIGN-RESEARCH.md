# Local agent design for a 27B Qwen: research and gap list (2026-10-27)

Model: Qwen3.8-27B, 4-bit MLX, with MTP. Sources are numbered, listed at the end with dates. "UNVERIFIED" means I could not confirm it from a primary source in this pass. Where no Qwen3.8 evidence exists I use Qwen3 / 3.5 / 3.6 / Coder-Next and say so. This document does not change any code.

## 0. Bottom line

1. We have no measured quality number for our own harness. `soak-20261027` and `mcp-clients-20261027` test third-party clients (Claude Code, Codex) against our server on toy tasks (n=1 per cell). The first job is a baseline on the 30-task corpus. Everything below is a hypothesis list ranked by expected effect.
2. The biggest divergence from vendor practice is the thinking policy plus sampling. We force thinking off and use temperature 0. Qwen's published agentic numbers use thinking on, temperature 1.0 (3.8) or 0.6 (3.5/3.6 coding), and say not to use greedy decoding [1][2][5]. Independent data shows thinking helps tool use by 6 to 11 points on Qwen3 [4][8]. Test this first.
3. Our tool set, prefix-stable prompt, and exact-match edit are sound (KEEP). The weak points are tool feedback (edit result echoes nothing), compaction (drops everything but a call log), and no early-decline gate.
4. Vendor benchmarks do not transfer. They use 256K context, hours of wall time and up to hundreds of turns [1][2][6]. We run 24-28K context, 40 turns, 15 min. Treat the 27B as a strong model on small, oracle-checked tasks and refuse the rest.

## 1. How Qwen models do on agentic coding

### 1.1 Reported numbers (all vendor-reported unless noted)

| Model | Benchmark | Score | Setup |
|---|---|---|---|
| Qwen3.8-27B | Terminal-Bench 2.1 | 73.0 | Terminus harness, thinking default, temp 1.0 [1] |
| Qwen3.8-27B | SWE-bench Pro | 61.7 | Claude Code harness, 256K ctx, temp 1.0 [1] |
| Qwen3.8-27B | LiveCodeBench v6 | 90.3 | [1] |
| Qwen3.6-27B | SWE-bench Verified / Terminal-Bench 2.0 | 77.2 / 59.3 | internal bash+edit scaffold; Harbor/Terminus-2, 3 h timeout, avg of 5 [2] |
| Qwen3.5-27B | SWE-V / LiveCodeBench v6 / BFCL-V4 / TAU2 | 72.4 (75.0 in later table) / 80.7 / 68.5 / 79.0 | model card via search; not re-opened [3] |
| Qwen3-Coder-Next (80B, 3B active) | SWE-V, 300-turn cap | 70.6 SWE-Agent, 71.1 mini-SWE-agent, 71.3 OpenHands | [6] |
| same | Terminal-Bench 2.0 | 36.2 Terminus2-json, 34.2 -xml, 30.9 Claude Code, 25.8 Qwen Code | [6] |
| Qwen3-32B (older gen) | SWE-V in SWE-agent | 17.0 non-thinking, 23.0 thinking | [8] |
| Qwen3-Coder 480B | same | 53.4 | [8] |

Reading:
- The 3.8 card has no SWE-bench Verified, BFCL or tau rows [1]; I found no independent 3.8 harness study.
- A third party (llama.cpp Q4_K_M, not our MLX 4-bit) found no 4-bit drop vs BF16 on Terminal-Bench 2.1; 1-bit collapsed [7]. Our parity: UNVERIFIED.
- Scaffold matters: Coder-Next scored 25.8 in Qwen's own CLI vs 36.2 in Terminus2-json; cross-scaffold transfer was "limited" [6]. Do not assume vendor numbers for our harness.
- Coder-Next trained on ~20 tool templates and added the XML `qwen3_coder` format for string-heavy args [6]; the 3.6 card recommends that parser [2]. Our parser follows it; KEEP.

### 1.2 What 27B-class models do reliably vs poorly

Evidence is indirect; I found no 27B-specific breakdown.
- Reliable: single-file, localized fixes; mechanical edits; test running and log reading. The SWE-bench Live paper (via search summary, UNVERIFIED against the table) reports single-file fixes under 5 lines solved ~48%, falling below 10% at 3+ files or 100+ lines, 0% at 7+ files [20]. Roo Code's local evaluation (Qwen2.5-Coder-14B/Phi-4, an older generation) found simple self-contained tasks finish in ~2 iterations and multi-function refactors degrade tool stability [24]. Lowering task complexity was the most reliable stabiliser.
- Poor: frontend/UI and very large complex tasks (Coder-Next's own stated limits, plus "may need more turns on hard problems") [6]; cross-cutting changes; anything needing long-horizon planning.
- Edit quality, not localisation, is the dominant failure for capable models: 60-69% of failures on SWE-Agent/OpenHands touched the right functions but the patch was wrong; in 5 cases the agent produced the gold patch mid-trajectory and later destroyed it ("coherence collapse") [19]. Cheap fix there: an edit-commit checkpoint recovered all 5 [19].

### 1.3 Known failure modes in agent loops

Documented modes (trajectory studies are search snippets, UNVERIFIED; [24] is older-generation):
- Repeated identical calls and search loops [24]; our guard: repeat-3 abort.
- Tool-call format errors: fsWrite success 29% for Qwen3-8B vs 98% for Coder-480B in OpenHands (snippet of 2603.24631).
- Diff/edit mismatch retry spirals, printing code instead of editing, re-reading the same file [24].
- Premature finish without verification (kernel-exploit and trajectory studies).
- Summaries lengthen trajectories 13-15% and can fabricate paths [8].
- Thinking drift: at 1-bit, higher effort lowered scores by exhausting the token budget [7]; Qwen says lower effort "does not always cut total task time" [1].
- Greedy repetition: "DO NOT use greedy decoding" [5]; we run temperature 0.

## 2. Harness designs that work for small/open models

### 2.1 Evidence by design question

| Question | Evidence | Verdict for us |
|---|---|---|
| Dedicated edit tool vs raw shell | SWE-agent ACI ablation (GPT-4 Turbo, Lite): full 18.0%; no edit command 10.3%; edit without lint 15.0% [9] | KEEP dedicated edit; add feedback |
| Linting/feedback after edit | lint on edit +3.0 pts [9]; Anthropic: change arguments to make mistakes harder (poka-yoke) [15] | CHANGE: echo snippet, near-miss hint |
| Bash-only / minimal (mini-SWE-agent [10], pi: 4 tools, <1K-token prompt [25]) | strong-model results only; no weak-model claim | do not copy; ablation only |
| Search tool design | iterative one-at-a-time search 12.0% vs none 15.7% vs summarised 18.0% [9] | KEEP grep (summarised, capped at 200 matches) |
| File viewer window | 100 lines best; 30 lines 14.3, full file 12.7 [9] | KEEP 400-line default? TEST 150-200 |
| Context history | last 5 observations 18.0 vs full history 15.0 [9] | CHANGE: mask old observations |
| Agentless (no loop) | localize, repair, validate: 32.0% Lite at $0.70 (v2) vs 27.3% without validation; contemporaneous agents ~12-16% (secondary) [14] | informs `verify`-first design |
| Plan-then-act vs ReAct | no controlled small-model ablation found (only an 8-instance pilot) | TEST |
| Self-verification with tests | no direct ablation found; Agentless validation +4.7 pts is indirect [14]; coherence-collapse checkpoint [19] | KEEP rule; make harness-side verify authoritative |
| Tool count | 9-10 pt retrieval loss from 10 to 100 tools for three closed models [23]; no small-open-model study | 7 tools is fine; not a priority |
| Constrained decoding | JSON-mode hurt reasoning tasks in "Let Me Speak Freely" (2024, closed-ish models) [22]; nothing on tool-call grammars for Qwen | do not add |

### 2.2 Edit format

- Aider: unified diff cut GPT-4 Turbo laziness ~3x (20% to 61% on its refactor set); lessons: familiar format, no line numbers, no JSON escaping, high-level hunks, flexible patch application (disabling flexibility raised errors ~9x) [11]. GPT-4-era result.
- Diff-XYZ (2025): search/replace best for larger models; udiff variants slightly worse; smaller open models gain little from any format [12]. A 2026 cascaded-editing paper (secondary): whole and search/replace about equal, udiff worst [13].
- Aider's Qwen3-235B result: whole 65.3% vs diff 59.6% (92.9% well-formed), but different providers and settings, so confounded [aider.chat Qwen3 post, May 2025].
- Anthropic: avoid line counting and string escaping overhead [15]. Our edit_file passes `old`/`new` as XML-style args (the `qwen3_coder` format is designed for this [6]), so no JSON escaping.
- Verdict: exact-match tool is the right base. Gains are likely in tolerance and feedback, not in switching to udiff. Whole-file rewrite remains the cheapest reliable path for files under ~150 lines.

### 2.3 Context management

JetBrains (SWE-agent, SWE-V, 500 instances) [8]:

| Model | Raw | Obs. masking (M=10) | LLM summary |
|---|---|---|---|
| Qwen3-Coder 480B | 53.4% / $1.29 | 54.8% / $0.61 | 53.8% / $0.64 |
| Qwen3-32B (non-think) | 17.0 | 15.0 | 16.0 |
| Qwen3-32B (thinking) | 23.0 | 24.6 | 24.8 |

Masking halves cost at equal solve rate; summaries add ~13-15% more turns; a hybrid saves a further 7% on a 50-instance subset [8]. Note the small-model case: masking cost 2 pts on non-thinking Qwen3-32B. Our compaction is a summary-only design with no verbatim tail.

## 3. Harness2 (vendor/harness2): what applies

Read: README and paper (arXiv 2610.14224, Oct 2026) [16].
- It does not use small models. Executors are GLM-5 and Gemini 3.5 Flash under OpenCode and Codex. Benchmarks are JobBench, LAB, WorkBuddy-Bench (code/web/office), not SWE-bench [16]. No claim about 27B models.
- Results: one step lifts GLM-5/OpenCode WorkBuddy average 64.2 to 75.7 (+11.5); Code subset 58.4 to 77.1. Weaker executors gain more. k=5 parallel recursion adds 3 to 4 points more [16].
- Ablations on the improved harness (Gemini Flash, OpenCode, k=5): remove skills -5.3, scripts -3.7, prompt group -1.5 on average; skills mattered most on code and web [16]. Process ablations at k=1: w/o library -3.1, w/o scoped editors -2.9, w/o composition -1.6 [16].
- Editing a harness without execution evidence hurts: Code 73.4 to 63.2 [16].
- Blind selection without ground truth picked a 55 over a 95 candidate [16]; our deterministic verify judge avoids this.
- Applicable to `strim evolve` v0: (1) evolve per-class playbooks/skills and helper scripts before the system prompt, since they carried more weight; (2) always probe on the same tasks with execution evidence, never edit blind; (3) keep a small lessons library across tasks; (4) compose rather than pick one winner; (5) budget k<=2 first, since gains grow with k but compute does too.

## 4. Speed and context

- Prefix cache: stable system prompt plus tool order, task and environment in user #1, append-only turns. Already designed this way; KEEP. Our exact-id ledger protects generated turns from re-tokenisation [docs/ARCHITECTURE.md section 4].
- Template pitfalls (Qwen3.5/3.6 Jinja; third-party fixes UNVERIFIED for our hand renderer):
  - An empty `<think>\n\n</think>` wrapper appears on a "current" assistant turn inside a tool chain and vanishes after the next user turn, so the same message renders differently and the cache misses (llama.cpp: 0 vs 1,578 cached tokens with a patch). Qwen answered with `preserve_thinking`, not the patch [17].
  - Qwen3.8 defaults `preserve_thinking` to True, which "improves KV cache utilization" [1]. With thinking off, rendering is stable if the generation prompt is identical every turn. Add a multi-turn tool-call golden (render turn N and N+1, compare common-prefix bytes).
  - Consecutive `<tool_call>` blocks: community templates use one newline to match official generation [18, third party]. Check against the official 3.8 template.
- KV size: our `MemoryModel` uses 64 KiB per token of attention KV [ARCHITECTURE.md], so 24K = 1.5 GiB, 28K = 1.75 GiB, 64K = 4 GiB, plus 4 KiB/token for the MTP head. GDN state is constant per node. Memory is not the constraint at 64K on this model; prefill time and quality are.
- When long context hurts: no 27B measurement found. General evidence is "context rot" claims from secondary sources (UNVERIFIED) and SWE-agent's finding that full history loses 3 pts vs last-5 observations [9]. Qwen says keep at least 128K context configured for thinking quality [2] (a setting, not a usage target). My read: at 24-64K, the loss comes from stale observations, not model length limits. Masking old tool outputs addresses that; raising compaction from 28K is a TEST, not a decision.
- MTP: our measurements show code accepts 94% (S=4, 3.13x at B=1) while prose accepts ~51% (1.46x at S=2, 1.79x at S=3) [docs/BATCH-MTP-2026-10-26.md]. A 2026 paper (search snippet) reports tool-call regions near 100% acceptance and prose under 10% in another system [21]. Implication: tool-call arguments and code decode fast; free-form reasoning decodes slowly. Thinking tokens cost real wall time (they are prose). If thinking is turned on, the MTP advantage shrinks on the thinking part.
- Custom prompt rendering pays when (a) history is re-rendered (we avoid with the ledger), (b) conversations are compacted (new session reuses segments 0-1: fine), (c) clients send thinking differently. Not worth more work until the multi-turn golden test shows a miss.

## 5. Task routing for a local 27B

Data is thin; success falls steeply with patch size [20] (UNVERIFIED against the table).

| Give to local 27B | Refuse or decline on turn 1 |
|---|---|
| Fix a failing test; failure and test command given; one to two files, <~40 changed lines | Cross-cutting refactor (3+ files or ~100+ lines) |
| Repo Q&A with file:line answers | No oracle (no test, no check, no file:line target) |
| Mechanical edits (rename, add parameter, boilerplate) with a grep-able pattern | Design, architecture, API shape decisions |
| Write unit tests for a named function | Security, auth, crypto, secrets |
| Run tests/build and summarise failures | Environment, network, credential problems |
| Small single-file refactor with tests | UI/frontend visual work [6]; dependency upgrades |

Decline gate: tell the model in the system prompt the exact refuse list and allow `finish(declined=true)` on turn 1 only. Product plan already says "the local model may decline on turn 1" [docs/PLAN-PRODUCT-2026-10-27.md]; the current `system.md` does not give the criteria.

## 6. Our design vs evidence: KEEP / CHANGE / TEST

Our state (read at HEAD with uncommitted edits by other agents in the tree): tools `read_file, list_files, grep, edit_file, write_file, bash, finish`; temp 0; `reasoningPolicy: .disableWhenTools`; 40 turns, 900 s, 60K generated tokens; compaction above 28K via deterministic call log; tool output cap 8,000 chars; repeat-3 abort; 5 consecutive errors abort.

| # | Choice | Call | Evidence | Expected effect |
|---|---|---|---|---|
| 1 | Thinking forced off with tools | TEST (first) | thinking on: BFCL v3 70.3 vs 63.0 (Qwen3-32B), 69.1 vs 58.6 (30B-A3B) [4]; SWE-agent 23.0 vs 17.0 [8]; Qwen3.8 ships thinking on and preserved [1] | +3 to +8 pts verified pass if the same holds; costs tokens (prose decodes slowly under MTP) |
| 2 | Temperature 0 | TEST | Qwen: do not use greedy [5]; cards give 1.0 / 0.6 thinking, 0.7 non-thinking [1][2]; but presence penalty 1.5 (non-thinking advice) may hurt verbatim `old` copying (my hypothesis) | fewer loops; risk of edit mismatches |
| 3 | Fixed 7 tools, stable order | KEEP | dedicated edit matters [9]; tool-count loss is small at 7 [23]; prefix cache | none |
| 4 | `list_files` | TEST remove | bash `ls`/grep overlap; no evidence either way | -1 schema, fewer wasted turns |
| 5 | edit_file exact, unique | KEEP + CHANGE | Aider tolerant patching ~9x fewer errors [11]; lint +3 pts [9] | add whitespace-tolerant unique fallback, near-miss hint on 0 matches, echo +/-3 lines after edit (result today is only "edited path"); expected fewer retry spirals |
| 6 | `read_file` numbered `N<TAB>text`, 400 lines | TEST | 100-line window best in [9] | measure edit "not found" caused by pasted line numbers; test 200-line default |
| 7 | write_file | KEEP | cheapest reliable path for small files | add to playbooks: rewrite files <150 lines |
| 8 | Compaction: log-only, no tail, 28K | CHANGE | masking matches summaries at half cost [8]; log drops findings and the last failing output | keep last 4-6 tool exchanges verbatim plus last failing test output and diffs of edited files in the progress block; mask stale observations at compaction only (masking mid-run breaks prefix cache) |
| 9 | Compaction threshold 28K | TEST 28K vs 48K | no 27B long-context data | fewer cache breaks and fewer lossy compactions |
| 10 | 40 turns / 900 s | TEST 25/40/60 + early-bail nudge | Coder-Next RL traces average 50 to 130 turns but at 300-turn cap [6]; coherence collapse suggests late turns destroy good work [19] | save time on doomed runs; add commit/checkpoint after each verified-green edit |
| 11 | System prompt (~2.8K chars, ~0.9K tokens) | KEEP + CHANGE | pi runs under 1K tokens [25]; Roo shrank prompts to help local models [24] | already small; add decline criteria, an "edit_file failed twice: re-read then use a larger span or rewrite the file" rule, "do not print code instead of editing" |
| 12 | "State a plan of 1-5 bullets" | KEEP | with thinking off, visible plan is the only reasoning; no ablation found | TEST on/off |
| 13 | Harness-side `verify` (product plan) | KEEP | Agentless validation [14]; verify statuses cut false-done | make it authoritative; do not trust model summary |
| 14 | Tool output cap 8,000 chars head+tail | KEEP | [8][9] | tighten bash to ~4K? TEST |
| 15 | `required` tool_choice unenforced, no grammar | KEEP | [22] | recovery by nudge is enough; revisit only if no-action rate >3% |
| 16 | Plain text ends the turn as `done` | CHANGE | `out.calls.isEmpty && text` returns `.done` with model prose; premature-finish risk | treat prose-only reply as `unverified`, not done, unless the final `verify` passes |
| 17 | Repeat-3 abort | KEEP | loops documented [24] | also detect same file read 3x with no edit (my addition) |
| 18 | Sequential tool dispatch of parallel calls | KEEP | order-dependence of edits | none |
| 19 | Skills/AGENTS.md index in user #1 | KEEP | Harness2 skills worth most [16] | start with 3 task-class playbooks |

## 7. Experiment list for `strim evolve`

Fitness as in product plan: hidden verify pass, -2 per false-done, tie-break local tokens then wall. Corpus: `bench/agenttasks/` 30 tasks (test-fix, repo-QA, mechanical edit), 3 reps per arm; paired comparison; adopt at >= +5 pp paired (product-plan rule). Log per run: turns to first edit, edit_file failure rate, repeated-call aborts, no-action nudges, false-done, prompt/completion tokens, wall.

| Rank | Experiment | Arms | Primary metric | Why this order |
|---|---|---|---|---|
| E0 | Baseline | current harness, 30 tasks x 3 | verified pass %, false-done %, edit failure %, turns | no number exists today |
| E1 | Thinking and sampling | A: off, t=0 (now). B: off, t=0.7/top-p 0.8/top-k 20 (card). C: off, card + presence 1.5. D: on, effort medium, t=0.6 (3.5/3.6 coding) or 1.0 (3.8 card), preserve_thinking. E: thinking on first turn only | verified pass; wall per success; tokens | largest evidence-backed delta |
| E2 | Edit tool feedback and tolerance | exact (now) vs +whitespace-tolerant unique match + near-miss hint + snippet echo | edit-failure rate; turns to green | cheap, low risk, ACI evidence |
| E3 | Decline gate and early bail | no gate vs decline criteria in prompt vs +nudge at turn 12 with no edit | false-done; wasted tokens on declined/failed tasks; wall | protects the parent-token thesis (failed delegation is costly) |
| E4 | Repo map / context pack | none vs `strim pack` ~1K-token map in user #1 vs map + files hint | turns to first edit; tokens; pass | Aider-style map; our `PLAN` already has `strim pack` |
| E5 | Edit format | `edit_file` exact vs search/replace block in assistant text (Aider diff) vs unified diff vs write_file-only for <150-line files | first-try apply rate; pass; completion tokens | expect exact ~ S/R > udiff [12][13]; run late, small payoff |
| E6 | Tool set | 7 (now) vs 6 (no list_files) vs 5 (no list_files, no write_file) | pass; tool-error rate | low expected effect [23] |
| E7 | Step budget | 25 / 40 / 60 turns, 600 / 900 / 1500 s | pass per wall-second | ties to checkpoint idea |
| E8 | Compaction | 28K log-only (now) vs 28K + verbatim tail vs 48K log + tail vs mid-run masking in batches | pass on long tasks; cache hit rate; prefill seconds | only matters on tasks that exceed 24K |
| E9 | Playbooks | no playbook vs one per class (test-fix, repo-QA, mechanical edit), <= 400 tokens each | pass by class | Harness2: skills > prompt [16] |
| E10 | Plan bullets | required / optional / removed | pass; tokens | only if thinking stays off |

Run E1 and E2 together as a 2x2 only after E0 shows the harness is not broken. Use `strim evolve` coordinate ascent: lock the winner of each experiment before the next.

## 8. System-prompt skeleton principles (no full prompt)

1. Byte-stable prefix (role, tool names, rules); nothing dated, path-specific or access-dependent. Task, environment, AGENTS.md, playbooks go in user #1.
2. Under ~1K tokens always-on; longer material lives in on-demand playbooks [16].
3. Order: scope and refusal criteria, working loop (locate, read small ranges, edit, verify, finish), testing rules, untrusted-content rule, finish contract.
4. Concrete numeric rules ("read at most 200 lines", "if edit_file fails twice, rewrite the function").
5. Name the verify command; the harness runs it; never claim a pass unseen.
6. Decline explicitly, only before the first edit; list the refuse set.
7. Poka-yoke lives in tool descriptions (example `old`, failure shape, recovery) [15].
8. No "think step by step" when thinking is off; use the plan bullets or turn thinking on.
9. Fingerprint every pack; each change is an experiment arm.

## 9. Risks and open questions

- Thinking on may blow the 15-minute budget; prose decodes at roughly half MTP's code speed [BATCH-MTP]. Measure wall per success, not accuracy alone.
- Template byte-drift in multi-turn tool chains is the main silent cost; we have a tools-spec golden test but I did not verify a multi-turn render golden against the official 3.8 template.
- No 27B data on context length vs quality at 24-64K; no evidence on non-thinking Qwen3.8 agent performance (all vendor numbers use thinking).
- Presence penalty and exact-copy edits: hypothesis only.
- Our 4-bit MLX vs the llama.cpp Q4_K_M result [7]: not the same quantiser.
- Evidence on "fewer tools" and "plan-then-act" for small open models is absent; treat as untested.
- Corpus overfit: 30 tasks, 3 reps, tie to the same repos; hold out the test split.
- Open: does thinking-on interact badly with `maxTurnTokens=4096` (cut-off thinking triggers nudges)? Raise per-turn cap in arm D.

## Sources (fetched 2026-10-27 unless noted)

1. Qwen3.8-27B model card, https://huggingface.co/Qwen/Qwen3.8-27B (Aug 2026)
2. Qwen3.6-27B model card, https://huggingface.co/Qwen/Qwen3.6-27B (Apr 2026)
3. Qwen3.5-27B model card, https://huggingface.co/Qwen/Qwen3.5-27B (2026; via search result only)
4. Qwen3 technical report, https://arxiv.org/abs/2505.09388 (May 2025)
5. Qwen3-32B card, https://huggingface.co/Qwen/Qwen3-32B (2025)
6. Qwen3-Coder-Next report, https://arxiv.org/abs/2603.00729 (Mar 2026)
7. Quesma quantisation benchmark, https://quesma.com/blog/qwen38-27b-quantizations-benchmarked/ (Aug 2026)
8. JetBrains, observation masking vs summarisation, https://arxiv.org/abs/2508.21433 (Aug 2025, v3)
9. SWE-agent ACI, https://arxiv.org/abs/2405.15793 (May 2024)
10. mini-SWE-agent, https://github.com/SWE-agent/mini-swe-agent
11. Aider unified diffs, https://aider.chat/docs/unified-diffs.html (2023-12-21); edit formats https://aider.chat/docs/more/edit-formats.html
12. Diff-XYZ, https://arxiv.org/abs/2510.12487 (Oct 2025; abstract only)
13. Cascaded code editing, https://arxiv.org/pdf/2604.19201 (Apr 2026; search summary only)
14. Agentless, https://arxiv.org/abs/2407.01489 (Jul 2024; numbers via search summary)
15. Anthropic, Building effective agents, https://www.anthropic.com/engineering/building-effective-agents (Dec 2024)
16. Harness2, https://arxiv.org/abs/2610.14224 (Oct 2026), PDF read via pdftotext; `vendor/harness2/README.md`
17. Qwen chat-template issue (empty think blocks), https://github.com/QwenLM/Qwen3.6/issues/131 (2026-04-09 to 04-22)
18. froggeric fixed templates, https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates (v22.5, 2026-09-03; third party)
19. Coherence Collapse, https://arxiv.org/abs/2603.24631 (Mar 2026)
20. SWE-bench Live, https://arxiv.org/abs/2505.23419 (May 2025; via search summary, UNVERIFIED)
21. Stateful inference for tool calling, https://arxiv.org/pdf/2605.26289 (May 2026; search snippet only)
22. Let Me Speak Freely?, https://arxiv.org/abs/2408.02442 (Aug 2024)
23. HumanMCP, https://arxiv.org/pdf/2602.23367 (Feb 2026; search snippet)
24. RooCode-Local-Evaluation, https://github.com/olilanz/RooCode-Local-Evaluation (undated; Qwen2.5/Phi-4 era)
25. Pi coding agent, https://agentic-ai.readthedocs.io/en/latest/AgentHarness/pi-dev/ (2026; third party)
Local: `Sources/StrimHarness/{AgentLoop,Compaction,ToolCatalog,FileTools}.swift`, `Resources/pack/system.md`, `docs/ARCHITECTURE.md`, `docs/BATCH-MTP-2026-10-26.md`, `docs/PLAN-AGENT-HARNESS-2026-10-26.md`, `docs/PLAN-PRODUCT-2026-10-27.md`, `bench/results/{soak,mcp-clients}-20261027/`.
