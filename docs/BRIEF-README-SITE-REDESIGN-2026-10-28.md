# Brief: README and website redesign (2026-10-28)

Status: research brief, no README/site edits made. Numbers come from `bench/results/h2h-final-20261028/summary.md` and `site/data/headline.json` (build 2df65e7, 64 GB M5 Max, 2 passes x 1 rep, 2% tie band). The final rerun replaces them; every number below must be pulled through the `{{final.*}}` figure ids, never typed.

Source limits: x.com pages return HTTP 402 to WebFetch, so X evidence is quoted from WebSearch result snippets (post text as shown there, not re-read in full). HN/blog/GitHub pages were fetched directly. First-screen notes for GitHub pages come from a summarizing fetch, so treat exact wording as approximate.

## (a) Diagnosis of the current README and site

Measured: README.md 260 lines, 22 headings; site/index.html 349 KB, 16 top-level h2 sections plus a figure index; README template is 218 lines.

1. No single claim. The README opens with a 5-line paragraph (Swift-only, one model, MTP, three APIs, MCP, 64 GB M5 Max, license, generated-by note) before any proof. Three different identities compete: inference engine, drop-in Claude Code/Codex backend, agent harness.
2. The first section is "What the data supports" (a scoreboard of 33 cells, 18/6/5 and 14/2/13). A visitor must parse WIN/TIE/LOSS counts to learn the product. The honest losses are good, but leading with a verdict matrix reads as a lab report.
3. Install is section 4 of 15 (README line 90) and after two tables, a chart and a functionality list. Compare rapid-mlx and Ollama: install command is on screen one.
4. Same content three times: README claims, site "claims", site "compare", site "results" all restate the h2h numbers. Security review, soak, parity gates, "tried and rejected", roadmap and a 300-line reproduce block are all inline.
5. Three rivals, 33 cells, 3 charts, plus scoreboard: no single image answers "so what?". Mixed-direction cells (lower-is-better inverted into speed-up) need a caption to read.
6. Internal vocabulary leaks to page 1: MTP, GDN, chunk-aligned, ABBA, tie band, "near-tie caveats". Fine in docs, wrong on a landing page.
7. The site is a document (349 KB, 16 sections, anchor index) not a landing page: no hero visual, no terminal demo, no one-line install above the fold, no FAQ.
8. Strengths to keep: caveats are stated, losses are drawn the same way as wins, figures are generated from one data file, nothing is hand-typed. This honesty is the differentiator; it just needs to be the second layer, not the first.

## (b) Positioning and proof points

Positioning sentence (one, reused as README H1 subtitle, site h1, X post 1, GitHub About):

> **Strim is a single-binary Swift engine that runs Qwen3.8-27B on your Mac fast enough to be the local backend for Claude Code and Codex, with the fastest decode and shared-prefix agent throughput we could measure.**

Shorter fallback for GitHub About (<=120 chars): "One Swift binary. Qwen3.8-27B + MTP on Apple Silicon. Local backend for Claude Code, Codex and a sandboxed agent."

Why this and not "engine + server + harness + MCP": rapid-mlx owns "reliable tool calling for coding agents, up to 4x faster" (fetched README), oMLX owns "menu bar, admin dashboard, many models", exo owns "cluster". Strim's honest niche is one model, deep, with an agent workload (shared prefixes) where it wins big. "One model" is the feature, not the limitation: say it as "built for one model".

Three proof points (all measured; final rerun replaces values):

| # | Claim on page | Number (h2h-final-20261028) | Figure id |
|---|---|---|---|
| 1 | Fastest decode | 24-41% faster than rapid-mlx (MTP on), 1.9-2.3x mlx-vlm, 4K to 32K context (67.1 vs 50.5 vs 29.5 tok/s at 4K; 52.1 vs 36.9 vs 25.7 at 32K) | `final.claim.decode_vs_rapid` |
| 2 | Agents sharing a prefix are 2.7-2.9x faster | 4 clients, 16K shared prefix: 9.46 tok/s vs 3.31 / 3.47; p50 first token 20.7 s vs 74.2 / 70.4 s | `final.claim.w5_speedup` |
| 3 | Lower median first-token latency under load | p50 TTFT 21-44% lower at 4-8 concurrent requests (e.g. 8 agent prompts 14.3 s vs 22.4 s) | `final.claim.ttft_p50_lower` |

Supporting facts, shown as a strip not as proof points: peak memory 30.8 GB vs 33.3 / 36.2 GB over the whole run (per-cell it is mixed, say "whole-run peak"); one 34 MB Swift binary (`.build/release/strim` measures 33.7 MB; re-measure at release, put it in a figure id); sandboxed agent harness + MCP; three wire APIs.

Mandatory honest line directly under the proof points (not in a footnote):

> Cold long prefill is at parity, not faster: 2-3% slower at 16K/32K, tied at 4K. Aggregate throughput at 4-8 concurrent short prompts is 4-14% lower than the best rival, and p95 first-token at 512-token concurrency is 22-31% worse. Details: link to results.

Do not lead with: win/loss counts (18/6/5), "ties on replay", security review, soak counts, quality gates. They are second-screen credibility, not the hook. Claim "lower memory" only as whole-run peak. Do not claim "faster than llama.cpp/Ollama/LM Studio": no head-to-head exists.

## (c) Proposed README

Target: 120-150 lines, 3-4 screens (today 260). Template remains `site/README.template.md`.

Order:

1. **Title + subtitle** (the positioning sentence) + 4 badges max (license MIT, Apple Silicon, Swift, build/test if CI exists). No 10-badge row (rapid-mlx has ten and the page is the longest of the set).
2. **Hero visual**: ONE image, `site/assets/h2h-hero.svg` (new, see chart spec in (d)): horizontal bars, Strim vs rapid-mlx vs mlx-vlm on 3 bars groups = decode 4K, decode 32K, 4-agent shared 16K prefix. Replaces the 29-dot log chart. Directly under it a one-line caption with machine, model, date, "own benchmark, reproduce with ...". Alt text complete.
3. **Install + first run** (above the fold, before any table): see block below.
4. **Three proof points** (3 bullets from (b)) + the honest line.
5. **What you can do with it** (5 lines): Claude Code and Codex as clients (2 env-var snippets, collapsed in `<details>`), `strim agent` sandboxed harness, MCP delegate endpoint, three APIs.
6. **Results at a glance**: compact 6-row table (decode 4K, decode 32K, cold 16K TTFT, 4-agent shared prefix, c=8 p50 TTFT, peak memory) x 3 engines, best bold, losses visible. Link "all 33 cells" to site.
7. **Honest limits** (5 bullets: one model, 64 GB M5 Max only, text only, cold prefill parity, concurrency throughput lower, not validated list).
8. **Docs index**: one-line links to docs/ARCHITECTURE.md, BENCH.md, CONTROL-API.md, MCP.md, security, roadmap, reproduce.
9. **License and credits**.

Cut or move out of README (to site and docs/, README links only): functionality matrix (move to site compare, <=8 rows), full 33-cell table, scoreboard table (keep one-line "18 wins / 6 ties / 5 losses vs rapid-mlx" sentence under the table), "How it works" (to docs/ARCHITECTURE.md), "Quality wording", Security review details (keep 2 bullets + link), soak/evidence lists, Roadmap, Reproduce flags block (keep the one-command repro only), Architecture tree, Methodology, figure index, "Tried and rejected".

Install/quickstart block (verify the commands against the real CLI before writing; below is the shape, not final syntax):

```sh
# 1. get it (one binary, no Python, no runtime)
brew install strim            # or: curl -fsSL <release url> | sh   (decide, then show ONE)
# 2. pull the model and serve on 127.0.0.1:8203
strim serve                    # downloads Qwen3.8-27B 4-bit + MTP head on first run
# 3. point Claude Code at it
ANTHROPIC_BASE_URL=http://127.0.0.1:8203 claude
```

Rule: three steps, copy-pasteable, no flags, one install path (opencode lists 8 but leads with one; llama.cpp leads with curl). If there is no brew/curl path yet, that is the first marketing blocker: a "git clone && swift build" start is a 90% bounce for non-Swift users. State the minimum macOS/RAM requirement on the line right after (64 GB tested; give the 32 GB estimate only if measured).

## (d) Proposed website

Goal: landing page first, document second. Keep a single `site/index.html` (offline-capable is a feature) but split it: `index.html` (landing, <= ~60 KB without inline figures) and `results.html` (all current detailed content: full table, methodology, parity gates, how it works, security, reproduce). Today's 349 KB page becomes `results.html` with minimal edits.

Landing sections, in order:

1. **Hero**: h1 = positioning sentence (shortened: "Run Qwen3.8-27B on your Mac like a server."); sub = one line (single 34 MB Swift binary, local backend for Claude Code and Codex). CTA 1 = copy-button install command; CTA 2 = "See the benchmarks". Right/below: the terminal demo (below).
2. **Proof strip**: three big numbers with plain labels ("+24-41% decode", "2.7-2.9x shared-prefix agents", "-21-44% median first token"), each with a one-line "vs rapid-mlx 0.15.7, M5 Max, link to method". Under it the cold-prefill parity sentence in the same type size, not smaller.
3. **One benchmark chart**: grouped horizontal bars, three engines, 6 groups, each bar labelled with its value; lower-is-better cells (TTFT) drawn as time with the shorter bar winning, separate small caption, never inverted ratios. Sort so the loss/parity group (cold 16K prefill) is visible in the chart, not hidden.
4. **Compact table**: the 6-row table from the README plus two honest rows (cold 32K prefill, c=8 aggregate throughput) marked as losses. Caption lists engine versions, flags (rapid-mlx `--max-num-seqs 4`, mlx-vlm defaults, no MTP) and "1 rep x 2 passes, 2% tie band, own benchmark, rivals' load average in pass 1 was higher (see method)".
5. **What it is for** (3 cards): Local backend for Claude Code / Codex (2-line snippets); Sandboxed agent harness (`strim agent`, what the sandbox forbids); MCP delegate endpoint. One sentence each, link to docs.
6. **Comparison matrix** (<= 8 rows, Strim / rapid-mlx / mlx-vlm / Ollama or LM Studio only if a verified fact): single binary and no Python; models supported (one vs many, state it as the trade-off); MTP speculative decode; exact prefix cache; Anthropic Messages + OpenAI Chat + Responses; sandboxed harness; MCP server; maturity (new, 1 machine tested). Rows where a rival wins are included (many models, community size, platform coverage).
7. **FAQ** (6): Why only one model? Does MTP change outputs? (link parity gates) Does it run on 32 GB / M1? Why is cold prefill not faster? How does this differ from rapid-mlx/mlx-lm/Ollama? Is it safe to let the agent run commands? (sandbox + residual risk link).
8. **Footer**: GitHub, results page, docs, license, "numbers generated from site/data/headline.json".

Terminal demo / GIF idea (the single most proven hero asset: aider ships a looping terminal screencast, opencode a TUI screenshot, exo a dashboard screenshot, Ollama's blog a themed illustration): 20-30 s, no cuts, split screen. Left: `strim serve` loading in <N> s with the binary size shown (`ls -lh`). Right: Claude Code driven at the local endpoint doing a real 4-agent same-repo task, with a live tok/s and first-token counter overlay. Second take if time: same 4-agent prefix workload on rapid-mlx at 1x speed side by side, lower-third text "same Mac, same model, same prompts". Record with real timings, no speed-up edits; render as MP4 + poster, not a heavy GIF. Owner decides if a rival side-by-side is shown.

## (e) X launch thread outline (draft, NOT posted; owner-gated)

Pattern distilled from the examples in (f): claim with a number in line 1, exact machine and model in line 2, visual in post 1, honest "where it loses" post, repro link, no thread-bait emoji spam.

1. Hook + video (the demo clip): "Strim: one 34 MB Swift binary that runs Qwen3.8-27B on a Mac as a local backend for Claude Code and Codex. Decode is 24-41% faster than rapid-mlx and 4 agents sharing a 16K prefix finish 2.7-2.9x faster. MIT."
2. Setup line + hero chart image: "M5 Max 64 GB, Qwen3.8-27B 4-bit + MTP, rapid-mlx 0.15.7 with MTP on, mlx-vlm 0.7.10. 2 ABBA passes. Own benchmark, scripts in repo."
3. Why shared prefix matters: agents re-send the same 16K context; exact chunk-aligned prefix cache gives p50 first token 20.7 s vs 74 s (one sentence, one number).
4. Latency: p50 first token 21-44% lower at 4-8 concurrent requests.
5. **Where it loses** (this is the credibility post): cold long prefill is 2-3% slower at 16K/32K; throughput at 4-8 short concurrent prompts is 4-14% lower; p95 at 512-token concurrency is worse. 18 wins / 6 ties / 5 losses vs rapid-mlx.
6. What is in the box: single binary, three APIs, sandboxed harness, MCP delegate.
7. Limits: one model, one machine tested, text only. Why only one model (specialization is why numbers are possible).
8. Try it: install command + repo link + "tell us your M-series numbers, `strim bench` prints a shareable block".
Pin post 1. Reply to every number question with the raw file path. Post HN (Show HN) first at a US morning, X ~1 h later, per the common launch sequence (source in (f)).

## (f) Evidence: what worked, what got dunked

Competitor pages (fetched):

| Project | First screen | Lesson |
|---|---|---|
| [rapid-mlx](https://github.com/raullenchai/Rapid-MLX) | "Run Codex, Claude Code, OpenCode... with a local model on Mac", `rapid-mlx launch <agent>`, bold "Up to 4x faster", two installs, ten badges | Strongest direct competitor; names the user's actual agent in the H1; but README is very long (15 sections), benchmarks tables carry "single run" caveats. Copy the agent-first H1 and the install-above-the-fold, not the length. |
| [oMLX](https://github.com/jundot/omlx) | "LLM inference, optimized for your Mac", dashboard screenshot, author's first-person quote, no install on screen 1 | Personal founder note builds trust; benchmarks off-page on a separate site: keeps README short. |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | "LLM inference in C/C++", curl one-liner, no benchmarks | A mature project can be terse; a challenger cannot skip proof. |
| [Ollama](https://github.com/ollama/ollama) / [ollama.com](https://ollama.com) | One tagline, platform install tabs; site: one claim + three usage metrics + logo wall | Install is the hero; zero feature lists. |
| [mlx-lm](https://github.com/ml-explore/mlx-lm) | "Run LLMs with MLX", pip install, no numbers | Plain and instructional. |
| [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) | 35-row model table before install | Anti-pattern: install buried; "2-3x faster" claim with no setup stated. |
| [vLLM](https://github.com/vllm-project/vllm) | "Easy, fast, and cheap LLM serving for everyone", link row, About bullets | Benchmarks live in docs/blog, not README. |
| [SGLang](https://github.com/sgl-project/sglang) | Title + 3 badges + link bar + Docker/uv install, hardware table, adoption logos | Social proof through logos; zero inline benchmarks. |
| [exo](https://github.com/exo-explore/exo) | "Run frontier AI locally", one dashboard screenshot, 3 benchmark charts credited to an outside reviewer | Third-party benchmark charts are the strongest proof; Strim should invite reproduction. |
| [Jan](https://github.com/janhq/jan) | "Open-source ChatGPT replacement", banner, install table by OS | Positioned against a known product, not a spec list. |
| [Aider](https://github.com/Aider-AI/aider) | Looping terminal screencast, metric badges, user testimonials | Terminal GIF + usage proof; no on-page leaderboard. |
| [OpenCode](https://github.com/sst/opencode) | Logo, "The open source AI coding agent.", TUI screenshot, `curl ... | bash` labelled "# YOLO" | One install line, a TUI screenshot, personality. |
| [Cline](https://github.com/cline/cline) | One-line value + install matrix + product table | Long; works because the product is broad. |
| [Zed](https://zed.dev) | "Your last next editor", Fast / Agentic / Collaborative pillars, named dev testimonials ("My god it is so fast.") | Speed shown by who says it, not by a chart; needs fame Strim lacks, so use numbers + reproducibility instead. |
| [Ollama MLX post](https://ollama.com/blog/mlx) | Two bar charts, 112 vs 58 tok/s decode, 1810 vs 1154 prefill | Simple bars, caveat in small print (different quantization NVFP4 vs Q4_K_M; chip not named). That omission was called out by independent write-ups. Name the chip and flags in the caption, not a footnote. |

X and social examples (post text as shown in search snippets; X pages could not be fetched):

1. [Raullen, Rapid-MLX launch](https://x.com/Raullen/status/2035004368102322433): "This might be the fastest local LLM inference engine on Mac... Tested across 18 models vs Ollama, mlx-lm, llama.cpp, fastest on 16 of them." Worked: hedged hook ("might be"), verifiable count, honest 16/18. Cost: later coverage repeats "4.2x vs Ollama" and an independent test found ~1.17-1.36x ([borncity](https://borncity.com/news/rapid-mlx-0-11-1-apple-ki-wird-42-mal-schneller-als-ollama/), [promptquorum review](https://www.promptquorum.com/power-local-llm/rapid-mlx-review)): headline multipliers get re-measured and shrink. Lesson: lead with the number you can defend on others' machines.
2. [Akshay, "4x faster than llama.cpp" (Uzu)](https://x.com/akshay_pachaar/status/2108497955049345102): "Qwen3.5 9B on a base M5 MacBook Pro... llama.cpp 22.0, MLX 25.1, Uzu 92.1 tok/s". Worked: one model, one laptop, three numbers in one line, a story format anyone can parse. Weakness: speedup comes from speculative decoding vs non-speculative baselines (the thread itself notes this); say what the baseline lacks.
3. [Tom Greenwald, Magnitude](https://x.com/tomgreenwald/status/2110718297255670071): "We made open models run over 2x faster than Ollama, without any new hardware", average across 11 models. Worked: plain-language hook; risk: averages across many models hide per-model losses.
4. [Kapitsa threads](https://x.com/TiagerBao/status/2113210864232984833) and [TeksEdge](https://x.com/TeksEdge/status/2112665167947510155): "llama.cpp 69, Ollama 89, Kapitsa 161 tok/s" on M4 Pro 48 GB; a third party repeated 154 tok/s. Worked: independent reproduction repeated in public is the strongest credibility signal; it spread the claim. Do: ask early users to post numbers.
5. [RobbiewOnline on Apple's "4x faster for LLM inference"](https://x.com/RobbiewOnline/status/2033044546645307843): community benchmarks show dense 27B at ~23 tok/s, "well below what the claim implies". The dunk template: headline multiplier vs measured dense-model reality. Strim runs a dense 27B, so state tok/s in absolute terms next to every ratio.
6. [Rapid-MLX release post](https://x.com/rapidmlx/status/2095375539452481537): "14-31% higher throughput under concurrent workloads", model named (Qwen3.8-27B). Worked: a bounded percentage on a named workload, no superlative.
7. [GitHub Projects Community, README advice](https://x.com/GithubProjects/status/1905901313394679976): README is the first impression; a header image previews the project; a live demo link helps; clear roadmap. Consistent with the structure in (c).
8. [Hesam on Warp open source](https://x.com/Hesamation/status/2049286399778541866): "32K GitHub stars in 10 hours". A reply noted the repo had been issue-only before the source landed. Lesson: a hyped launch gets audited within hours; every claim must already be verifiable at post time.
9. [steipete on OpenClaw](https://x.com/steipete/status/2028575910027313248): "actual software that people install and run" framing; the later [security-nightmare post](https://x.com/HedgieMarkets/status/2029337090844946791) (9 vulnerabilities, thousands of exposed instances) shows that an agent harness is judged on security the moment it trends. Strim's sandbox and its "residual risk stated plainly" section are an asset; surface two bullets of it on the site.
10. HN: [Kyle Howells local coding agent on macOS](https://hn.nuxt.dev/item/48507020) (~350-400 points): worked because reproducible commands plus a demo video and concrete tok/s (38-72); criticized for 128-token outputs (early tokens inflate MTP acceptance), no realistic system prompt, no 32K/64K context. Strim's h2h already uses 4K-32K context and 2.8K-token agent prompts: say so explicitly. [Mirai Show HN](https://hn.svelte.dev/item/44570048): "faster than llama.cpp in all use cases" got attacked for a 5 tok/s baseline that "doesn't make sense", a new model format, and a quick start asking for an API key. Do not claim "all use cases"; verify rival is configured sanely; no signup in quickstart.
11. Papers as contrast: [BaseRT](https://huggingface.co/papers/2607.00501.md) states where it loses (dense prefill roughly even, uzu leads prefill) and omits standard deviations; being specific about losses reads credible, omitting variance reads weak. Strim publishes noise: link it.

Do:
- Lead with agent workload (shared prefix, p50 TTFT) where Strim wins by multiples; it is the unique angle and a real coding-agent pain.
- Name machine, model, quantization, rival versions and flags in the caption of every chart.
- Show loss rows in the same table style as wins; state parity in prose near the top.
- Use one hero visual and one demo; put install above any table.
- Show absolute tok/s next to ratios; show context length and prompt size.
- Ask for third-party reproduction and give a one-command bench that prints a pasteable block.
- Keep the final-run number set in one data file (already done) and regenerate.

Don't:
- No "fastest local engine" or "all use cases"; no averages across models; no superlatives without a cell behind them.
- No win/loss counts as the hook (they read as score-keeping); no 33-cell table on the first screen.
- No acronyms on screen 1 (MTP, GDN, ABBA); define once as "speculative decoding" then link.
- No ten-badge row, no feature matrix longer than 8 rows, no roadmap or security review above the fold.
- Do not describe numbers as current after the build changes: the h2h build 2df65e7 predates the security/server hardening commits; keep that sentence in method, and rerun before launch.
- No claims against Ollama/LM Studio/llama.cpp until measured.

## (g) Implementation mapping (Sources/StrimSite)

Files and sizes: Page.swift 347 lines (all site sections, one big string-builder `buildHTML()`), Readme.swift 95 (`buildReadme()`, `readmeBlock(name)` expands `{{@block}}` and `{{figure|n}}` ids in `site/README.template.md`), Compare.swift 61 (`compareSection()`: rapid-mlx/mlx-vlm at a glance, memory, latency; the `hvFigure` helper), Builder.swift 157 (figure id helpers `fid`, `fratio`, `fverdict`, `figSpan`, fail-on-missing-figure), Charts.swift (heroSVG/memorySVG/latency), Headline.swift (`headline.json` generation and claim ranges), Checks.swift (HTML and markdown link checks, `checkFigures`).

Changes:

1. **README (low risk, do first).** Rewrite `site/README.template.md` to the outline in (c). Blocks to reuse: `@hero_alt`, `@scoreboard` (shrink to a one-line sentence), `@h2h` (replace with a new `@glance` block). Add `readmeBlock("glance")` in Readme.swift emitting the 6-row table from existing figure ids (decode d4k/d32k, cold 16K TTFT, W5 aggregate, c=8 agent p50, whole-run memory) plus loss rows. Remove blocks no longer referenced (`@features`, `@soak_line` may stay for results page). Keep "unknown block" and "unknown figure" errors: they are the guard that no number is hand-typed.
2. **Hero chart.** New `heroBarsSVG()` in Charts.swift (3 engines x 6 groups, horizontal bars, labelled values, lower-is-better as time, dark/light safe) writing `site/assets/h2h-hero.svg`; keep the old dot chart for `results.html`. Register the new asset in FinalSync.swift/Checks `checkFigures` so figure-index and asset checks pass.
3. **Site split.** Page.swift: extract current `buildHTML()` to `buildResultsHTML()` (output `site/results.html`, unchanged content, sections reordered only if needed); new `buildLandingHTML()` for the sections in (d). Compare.swift: reuse `scoreboardHTML`, `hvFigure`, memory and latency blocks for results page; add `compactCompareHTML()` with <= 8 rows driven by a small array of `(feature, [engine: value])` so the matrix is data, not hand HTML. Builder.swift: `Run.swift` build command writes both pages and README in one run (`wrote site/index.html (...) and README.md` output line changes; see tests).
4. **Install block and FAQ text** are static copy in the landing builder; the install command and binary size should come from figure ids (add `bin.size_mb` to headline.json via Headline.swift, `cfg.install` string) so a release cannot go stale.
5. **Demo asset.** `site/assets/demo.mp4` + poster PNG, referenced with relative links; add to checkFigures asset list; no external hosts (the site is offline-capable, Checks flags external links).

Tests and goldens that change (Tests/StrimSiteTests/): `SiteSmokeTests`, `SiteEquivalenceTests` (compares built output to committed index.html/README.md: both regenerate, equivalence goldens must be re-baselined only after review, not weakened), `SiteCheckTests` line 151 expects `wrote site/index.html (N bytes) and README.md` (update to the new output line, keep the assertion strict), `SiteComparisonTests` (new compact matrix rows, <= 8 asserted), `SiteUnitTests` (new `glance` block and unknown-id errors). Add tests: landing page contains the parity sentence and at least one LOSS row; every proof-point number resolves through a figure id; README line count <= 160; no hand-typed digits in landing copy outside figure ids (extend the existing figure check). Run: `swift test --filter StrimSiteTests` then `strim site build` and diff `git status`.

Order of work: (1) pull-through numbers frozen after final rerun, (2) README + hero chart, (3) landing + results split, (4) demo recording and thread, (5) owner review of every public claim before posting.

Open decisions for owner: install path (brew tap vs curl release), whether to name Ollama/LM Studio in the matrix (needs measurement), whether the demo shows a rival side by side, whether to publish the X thread and the Show HN, and the final v1.0 vs 0.1.0 label.
