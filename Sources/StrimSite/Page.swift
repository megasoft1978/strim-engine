import Foundation

extension SiteBuilder {
    /// site/benchmarks.html: the detailed results, method and engineering notes behind the landing page.
    func buildBenchmarksHTML() -> String {
        let soakDone = soakComplete() != nil
        var page = ""
        func A(_ s: String) { page += s }
        func F(_ cell: String, _ e: String) -> String { n(fid(cell, e)) }

        A(pageHead(title: "Strim benchmarks: five-engine head-to-head",
                   desc: "Strim benchmarks: every head-to-head cell against \(listWords(RIVALS.map { WIDE_NAMES[$0] ?? $0 })) on Qwen3.8-27B 4-bit, method, caveats and engineering notes.",
                   path: "benchmarks.html", bodyClass: "bench"))
        A(headerHTML([("Home", "index.html"), ("Install", "index.html#install"), ("Results", "#results"), ("Wide field", "#wide"), ("GitHub", REPO_URL)], brandHref: "index.html", sub: [("Claims", "#claims"), ("Compare", "#compare"), ("Wide field", "#wide"), ("Features", "#features"), ("Results", "#results"), ("How it works", "#how"), ("Quality", "#exact"), ("Agents", "#agents"), ("Security", "#security"), ("Scope", "#scope"), ("Limits", "#limits"), ("Roadmap", "#roadmap"), ("Reproduce", "#reproduce"), ("Method", "#method"), ("License", "#license"), ("Figures", "#figures")]))
        A("<main id=\"main\"><div class=\"wrap\">\n\n")

        A("<section class=\"hero\" id=\"top\" aria-labelledby=\"h-hero\"><h1 id=\"h-hero\">Strim benchmarks</h1>"
            + "<p class=\"lede\">Every head-to-head cell of Strim against \(esc(listWords(RIVALS.map { WIDE_NAMES[$0] ?? $0 }))) on Qwen3.8-27B 4-bit, plus the method, the caveats and the engineering notes behind the <a href=\"index.html\">landing page</a>. Wins and losses are drawn the same way.</p>"
            + runBannerHTML() + "</section>\n\n")
        A(claimsSection())
        A(compareSection())
        A(wideSectionHTML())
        A("<section id=\"results\" aria-labelledby=\"h-results\"><h2 id=\"h-results\">Results</h2>")
        A("<p>The headline rows first, then every cell. Bars always start at zero. Every number carries its figure id as a hover title and appears in the <a href=\"#figures\">figure index</a>.</p>")
        A(glanceTableHTML())
        A(finalSection())
        A("<h3 id=\"r-cache\">Prefix cache and memory</h3>")
        A("<p>Coding agents resend the same system prompt, tool schemas and history every turn. The cache stores engine state at chunk boundaries and restores the longest match, so only the new tail is prefilled. "
            + "The latest cache work added a cut at the start of each assistant turn, so the end of the previous prompt becomes a cache node, and a footprint cap that sheds stale nodes under memory pressure.</p>")
        A(table("Cache and memory work, before and after (committed A/B in the cache-footprint directory)", ["Measure", "Before", "After"], [
            ["Replay summed prefill, 8 turns (s)", td("cf.replay_before"), td("cf.replay_after_ab")],
            ["Cached tokens at replay turn 2", td("cf.cached_t2_before"), td("cf.cached_t2_after")],
            ["Lowest per-cell peak footprint (GB)", td("cf.fp_old_lo"), td("cf.fp_new_lo")],
            ["Highest per-cell peak footprint (GB)", td("cf.fp_old_hi"), td("cf.fp_new_hi")],
        ], numcols: [1, 2], foot: "Replay: the final head-to-head measured \(u(fid("rp8", "strim"))) for the same replay on the same build. Cold 16K first token stayed at \(u("cf.cold_16k")) (no regression). "
            + "The earlier footprint growth was by design (the trie filled to its cap), not a leak. The head-to-head numbers already include this work; do not add the two together."))
        A(table("Exact prefix cache: first token on a hit vs a miss (in-process checkprefix, synthetic prompts)", ["Case", "Miss (s)", "Hit (s)", "Speedup"], [
            ["4,096 tokens, 3,072 shared", td("pc.4k.miss"), td("pc.4k.hit"), td("pc.4k.speedup", unit: true)],
            ["8,192 tokens, 6,144 shared", td("pc.8k_6k.miss"), td("pc.8k_6k.hit"), td("pc.8k_6k.speedup", unit: true)],
            ["4,096 tokens, 3,072 shared, with MTP head state", td("pc.mtp4k.miss"), td("pc.mtp4k.hit"), td("pc.mtp4k.speedup", unit: true)],
        ], numcols: [1, 2, 3], foot: "n=1 per row, in-process, no HTTP, earlier build. A hit still pays for the unshared tail. The aligned-chunk policy costs \(u("pc.policy_cost_4k")) versus one-shot prefill at 4K. A trie node is \(u("pc.node_mb")); the MTP head adds \(u("pc.mtp_node_extra_mb")) per node."))
        A("</section>\n\n")

        A("""
<section id="how" aria-labelledby="h-how"><h2 id="h-how">How it works</h2>
<p>Decoding a 27B dense model is limited by memory bandwidth: every token streams the whole weight set. The gains come from more tokens per weight read, avoiding repeated work, and not wasting time between kernels.</p>
<h3>MTP speculative decoding</h3>
<p>The Qwen3.8 checkpoint ships a small multi-token-prediction head. Strim loads it (<code>models/qwen38-mtp-4bit</code>), drafts tokens with it and verifies them in one pass of the full model. Rejected drafts are rolled back exactly: the attention cache is sliced and per-token linear-attention (GDN) states are restored. Depth adapts (\(n("mtp.depth_range")) tokens). A 48k frequency-ranked draft vocabulary keeps the head cheap; verification uses the full vocabulary, so a missing token costs a rejected draft, never a wrong output. For sampled decoding the accept/residual/bonus rule keeps the output distribution unchanged.</p>
<h3>Exact, chunk-aligned prefix cache</h3>
<p>A trie over \(n("cfg.chunk"))-token chunks holds KV, GDN state, conv state and the MTP head state per node, with an LRU byte budget. Prefill always runs in aligned chunks of that size whether or not the cache is used, so a hit restores exactly the state a miss would have computed. The token ledger records the exact ids the model produced, so resent histories reuse the model's own tokens and keep hitting the cache.</p>
<h3>Blocked GDN prefill kernel</h3>
<p>Linear-attention layers need a sequential recurrence. A blocked Metal kernel stages \(n("bg.block"))-token blocks in threadgroup memory and keeps state in registers. It was ported from rapid-mlx (Apache-2.0, itself adapted from oMLX) and is credited in <a href="../NOTICE">NOTICE</a>. At 4K it measured \(n("bg.before")) tok/s before and \(n("bg.after_light")) tok/s after at light load (\(n("bg.after_heavy")) at heavier load). The reduction order differs from the serial kernel, which is the source of the near-tie differences in <a href="#exact">Quality</a>.</p>
<h3 id="how-batch">Batched decode kernels</h3>
<p>Concurrent requests decode in lockstep through one batched forward pass. Batch-dimension GDN decode and conv Metal kernels (one dispatch for all sequences, per-row arithmetic identical to the single-stream kernel) cut the B=4 step from \(n("cb.step_before")) to \(n("cb.step_after"))&nbsp;ms against a single-stream floor of \(n("cb.step_floor"))&nbsp;ms. Served aggregate throughput went from \(n("cb.c4_before")) to \(n("cb.c4_after"))&nbsp;tok/s at c=4 and from \(n("cb.c8_before")) to \(n("cb.c8_after")) at c=8 in that sweep.</p>
<p class="note">Those sweep numbers were taken under machine load and are already included in the build used for the head-to-head; they are not additional gains. The remaining c=4 gap is the quantized matmul at 4 to 8 rows. MTP inside the batch was measured and rejected (upper bound \(n("cb.mtp_bound")) before draft cost). See <a href="../docs/PLAN-CONCURRENCY-2026-10-27.md">PLAN-CONCURRENCY</a>.</p>
<h3>Admission control</h3>
<p>Every request takes a slot before the engine is touched. Interactive requests go first; background work (<code>x-strim-priority: background</code>, delegated jobs) is capped one slot below the total and re-queues between agent turns while interactive work is active, never mid-token. The default total is \(n("ad.max_inflight")) slots (an admission cap, not the engine batch size). The engine also admits by memory and refuses requests that would not fit. Waiters are bounded and have a deadline. See <a href="../docs/ADMISSION.md">ADMISSION.md</a>.</p>
<h3>Sandboxed harness</h3>
<p>Delegated jobs run the local model as a coding agent in an isolated git worktree under <code>sandbox-exec</code> (no network, no credential reads, scrubbed environment), with contained file tools and a harness-run <code>verify</code> command. See <a href="#agents">Agents</a> and <a href="#security">Security</a>.</p>
<h3 id="how-rejected">Tried, measured, rejected</h3>
<ul>
<li><strong>MTP inside the batch.</strong> Verify cost grows steeply with batch size: at 1K context \(n("bm.ms_b1_s1")) ms/pass for one token vs \(n("bm.ms_b4_s3")) ms/pass for three tokens each across four sequences. Upper-bound speedup over plain batching on prose \(n("bm.bound.b2.prose_s2"))× at B=2 and \(n("bm.bound.b4.prose_s2"))× at B=4, before draft and rollback costs. No-go. <a href="../docs/BATCH-MTP-2026-10-26.md">BATCH-MTP</a>.</li>
<li><strong>A custom 4-bit prefill GEMM.</strong> 4-bit matmul already runs at \(n("ps.qmm_ratio")) of dense bf16 and dense GEMM plateaus at \(n("ps.plateau")) TF/s; the optimistic end-to-end bound is \(n("ps.bound")), below the plan's gate. No-go. <a href="../docs/PREFILL-SPIKE-2026-10-26.md">PREFILL-SPIKE</a>.</li>
<li><strong>Batched prefill.</strong> B=4 at 4K ran at \(n("bp.b4_4k"))× the serial speed. Not adopted. <a href="../docs/BATCH-PREFILL-2026-10-26.md">BATCH-PREFILL</a>.</li>
</ul>
</section>

""")

        var lcrows: [[String]] = []
        for p in ["p4k_a", "p4k_b", "p4k_c", "p4k_d", "p4k_e", "p1k_a", "p1k_b", "p1k_c"] {
            let label = p.replacingOccurrences(of: "p4k", with: "4K prompt").replacingOccurrences(of: "p1k", with: "1K prompt").replacingOccurrences(of: "_", with: " ")
            lcrows.append([label, td("lc.\(p).serial"), td("lc.\(p).tensor")])
        }
        A("""
<section id="exact" aria-labelledby="h-exact"><h2 id="h-exact">Quality and exactness</h2>
<p>The claim is narrow and has two parts.</p>
<ul>
<li><strong>Exact where it says so.</strong> A prefix-cache hit equals a miss bitwise (final-position logits and greedy tokens), within one fixed chunking policy: prefill always runs in aligned chunks, so cached and uncached runs follow the same arithmetic. That policy itself differs from a one-shot prefill (it costs \(u("pc.policy_cost_4k")) at 4K).</li>
<li><strong>Not bitwise where it does not.</strong> Batched decode, the blocked GDN prefill kernel, speculative decoding and the cache cuts can change near-tie tokens (bf16 logits that tie within rounding; one flipped token changes every later one). Measured: greedy output over 8 fixed prompts and 64 tokens, Strim against itself across passes \(n("final.agree.self")) identical, against rapid-mlx \(n("final.agree.rapid-mlx")), against mlx-vlm \(n("final.agree.mlx-vlm")). The batch kernels raised agreement with each prompt's own single-stream run from \(n("cb.agree_off")) to \(n("cb.agree_on")) at 96 tokens.</li>
</ul>
<p>Multi-step agent quality has been checked on the corpora described in <a href="#agents">Agents</a> (a real-client soak with toy tasks, a small real-client delegation run, and a Swift and Go task corpus of \(n("ab.corpus")) tasks), not on a broad benchmark. What is not validated is listed under <a href="#limits">Limits</a>.</p>
<h3>Parity gates against Hugging Face</h3>
<ul>
<li><strong>Tokenizer.</strong> Byte-level BPE checked against the HF tokenizer on encode, decode (including special tokens) and every chunking of streamed decode. Fixture <a href="../bench/fixtures/tokenizer_parity.json">tokenizer_parity.json</a>, frozen; test <code>TokenizerParityTests</code> (skipped when the weights are absent).</li>
<li><strong>Chat template.</strong> The native Qwen3.8 renderer (tool calls, reasoning, generation prompts) against HF-rendered text. Fixture <a href="../bench/fixtures/template_parity.json">template_parity.json</a>.</li>
<li><strong>Prompt ids.</strong> Template then tokenizer, including incremental multi-turn sessions through the ledger, equals HF ids. Fixture <a href="../bench/fixtures/prompt_parity.json">prompt_parity.json</a>.</li>
<li><strong>Special-token injection.</strong> User text (messages, reasoning, tool results, tool names, arguments, schemas) is tokenized as plain text, so a user cannot smuggle control strings into the prompt. Fixture <a href="../bench/fixtures/prompt_adversarial.json">prompt_adversarial.json</a>.</li>
</ul>
<h3>Prefix cache gate</h3>
<p>The <code>checkprefix</code> gate compares a cold run against hits on the final-position logit hash and 16 greedy tokens, and checks a cold store against the no-store reference, a second hit (no aliasing), a short prompt hitting a longer stored prefix, a forked tail, eviction under a tiny budget and an unrelated prompt missing cleanly. With MTP it also compares head KV, seed hidden state, logits and 64 speculative tokens. Logs: <a href="../bench/results/prefix-cache-exact-20261026/checkprefix-4096.log">4K</a>, <a href="../bench/results/prefix-cache-exact-20261026/checkprefix-8192.log">8K</a>, <a href="../bench/results/dec-wave3-20261026/checkprefix-4096-mtp.log">MTP</a>. A hot session continued for 20 tokens equals a cold re-prefill (\(esc(D.text("pc.hot_continue")))).</p>
<h3>Known near-tie caveats</h3>
<p>On 8 natural prompts (1K and 4K) the first generated token agreed on \(n("lc.first_token")) prompts across all three kernel paths and every run was deterministic. The next 16 greedy tokens agree on most prompts and diverge at a bf16 near-tie on others:</p>

""")
        A(table("Greedy 16-token agreement of the default (blocked) path with two alternatives", ["Prompt", "vs serial kernel", "vs tensor recurrence"], lcrows, numcols: [1, 2],
                foot: "Divergences are at logits that tie within bf16 rounding. Speculative-vs-greedy parity at 4K is not exact: \(n("lc.spec_exact_4k")) prompts matched exactly. Source: <a href=\"../bench/results/longctx-validate-20261026/summary.md\">longctx-validate</a>. Earlier build; the kernel is unchanged."))
        A("</section>\n\n")

        A("""
<section id="agents" aria-labelledby="h-agents"><h2 id="h-agents">Agent harness, MCP and soak</h2>
<p>Status in three parts: what is built, what has evidence, and what has not been validated.</p>
<h3>Built</h3>
<ul>
<li>A job harness that runs the local model as a sandboxed coding agent in a git worktree, with a required <code>verify</code> command the harness runs itself (verified, failed or unverified).</li>
<li>An MCP endpoint on <code>strim serve</code> with \(n("harness.tools")) tools (<code>strim_task</code>, <code>strim_job</code>, <code>strim_cancel</code>, <code>strim_ask</code>).</li>
<li>A real-client soak driver (<code>strim soak</code>) and an agent benchmark (<code>strim agentbench</code>) over a corpus of \(n("ab.corpus")) Swift and Go tasks (12 test-fix, 3 mechanical-edit, 2 repo-qa).</li>
</ul>
<h3>Evidence</h3>
<ul>
<li><strong>Delegation works end to end on trivial tasks.</strong> Real Claude Code and Codex delegated through the MCP tools: \(n("harness.rerun_pass")) of \(n("harness.rerun_runs")) runs passed their deterministic checks on the stock release build (n=\(n("harness.rerun_n")) per cell, one-line fixes and questions).</li>
<li><strong>Token saving is not shown.</strong> On a one-line fix the parent used \(n("harness.delegated_in")) input tokens delegated against \(n("harness.alone_in")) alone, so no saving (n=1).</li>
<li><strong>Soak, earlier build.</strong> One 30-minute run of real <code>claude -p</code> and <code>codex exec</code> clients against the server on toy tasks (below). It shows the client-to-server path was stable, not how well the model codes. \(soakDone ? "Results: pass rates below." : "Result: soak: pending.")</li>
<li><strong>Agent benchmark, free arms.</strong> One run of \(n("ab.runs")) runs (harness arm and Claude Code arm on the local model) exists, on the earlier corpus. Part of it had an unusable test environment inside the sandboxes, so its pass rates measure the environment and are not quoted here. The corpus was then reduced to Swift and Go and has not been re-run.</li>
</ul>
""")
        A(soakBlock())
        A("""
<p class="note"><strong>Scope.</strong> This soak ran on the earlier build with the earlier harness (2026-10-27). The \(n("soak.failures")) failures were all Claude Code at one task whose test command the harness allow-list denied; fixed afterwards (\(n("soak.rerun_a")) before the fix, \(n("soak.rerun_b")) after, in short reruns outside the 30-minute result). A run that failed because of a harness path error is kept as evidence and excluded from every figure.</p>
<h3>Not yet validated</h3>
<ul>
<li>A live soak with real Claude Code and Codex on the current build under the current sandboxed harness (the sandbox path of the new harness has not been exercised live).</li>
<li>The paid agent-benchmark pilot (parent arms with real subscriptions). It has not been run, so there is no evidence that delegation saves parent tokens. Plan: <a href="../docs/PLAN-PRODUCT-2026-10-27.md">PLAN-PRODUCT</a>.</li>
<li>The agent benchmark on the current Swift and Go corpus, with multi-step tasks, for batched decode and the cache cuts against single-stream.</li>
</ul>
</section>

<section id="security" aria-labelledby="h-security"><h2 id="h-security">Security posture</h2>
<p>Strim is a local, single-user server. It is not designed to be exposed to a network, and it does not defend against another process running as the same macOS user.</p>
<h3>Design</h3>
<ul>
<li><strong>Loopback only</strong>, with Host and Origin checks (DNS-rebinding and cross-site defence) and a refusal of cross-site fetches.</li>
<li><strong>Bearer token by default</strong> (<code>~/.strim/token</code>, mode 0600, constant-time comparison), plus a separate control token for the menu-bar app. <code>--no-auth</code> opens only the API side for loopback development.</li>
<li><strong>The local model is untrusted.</strong> Its shell runs under <code>sandbox-exec</code> (no network, writes only to the job worktree, no reads of credential directories), file tools are contained to the job workspace, jobs run in an isolated worktree, and a patch is applied only after an explicit approval carrying the SHA-256 of the exact bytes reviewed.</li>
</ul>
<h3>Reviewed and fixed (2026-10-28)</h3>
<p>Three reviews: the server HTTP surface, every process launch and model-influenced code path, and release hygiene (secrets, personal data, licenses, supply chain).</p>
<ul>
<li><strong>Server surface:</strong> \(n("sec.server_findings")) findings, no critical and \(n("sec.server_high")) high (an integer overflow trap from a client-controlled token count). \(n("sec.server_fixed")) are fixed and one more partly: token-count clamping and saturating admission math, connection cap and head, body and idle deadlines, bounded request pipelining, a bounded response store, a waiter cap and queue deadline, a job-queue cap, and a minimal unauthenticated <code>/health</code>.</li>
<li><strong>Process launches:</strong> \(n("sec.exec_fixed")) findings fixed: credential directories refused as job working directories, sandbox reads of shared temp areas denied, paid benchmark arms without a shell tool, the MCP token passed by environment reference instead of written to a file, and an opt-in for the unsandboxed legacy scripts.</li>
<li><strong>Release hygiene:</strong> personal paths and a hostname scrubbed from committed results, token files ignored by git, license notices completed.</li>
</ul>
<h3>Residual risk, stated plainly</h3>
<ul>
<li>Any project under a non-denied home directory is allowed as a job working directory by default.</li>
<li>Paid benchmark arms must let the client read its own login file; file tools are denied it by permission rule, not by the sandbox.</li>
<li>No per-route body limit (one cap for all routes); no wall-clock limit on a running generation (output length is bounded instead); one API token means one priority class.</li>
<li>Token-store hardening against symlink races and permissive MCP token defaults are documented but not reworked (same-user only).</li>
<li>The reviews were read-only: no live server test, no fuzzing of the tokenizer or template parsers, and some sandbox fixes were not executed under <code>sandbox-exec</code>. The low and info items of the process-launch review were not addressed.</li>
</ul>
<p>Report a vulnerability through GitHub private vulnerability reporting (the repository's Security tab); see <a href="../SECURITY.md">SECURITY.md</a>. Reviews: <a href="../docs/SECURITY-REVIEW-2026-10-28-server.md">server</a>, <a href="../docs/SECURITY-REVIEW-2026-10-28-exec.md">process launches</a>, <a href="../docs/SECURITY-REVIEW-2026-10-28-release.md">release hygiene</a>.</p>
</section>

<section id="scope" aria-labelledby="h-scope"><h2 id="h-scope">Supported scope</h2>
<p><strong>Strim supports Qwen3.8-27B (dense), 4-bit affine g64 with its MTP head, and nothing else.</strong> It has been tested only on a 64&nbsp;GB M5 Max. Other quantizations are on the roadmap and not shipped; other models (including Qwen4) are not supported.</p>
""")
        A(tierTable())
        A("""
<p class="note">16&nbsp;GB and below are unsupported. The rows for 24 to 48&nbsp;GB are computed estimates, not measurements; no smaller Mac has run Strim.</p>
</section>

<section id="limits" aria-labelledby="h-limits"><h2 id="h-limits">Limitations</h2>
<ul>
<li>One model, one quantization, one machine class (64&nbsp;GB Apple Silicon), one user. All measurements come from a single M5 Max.</li>
<li>Two passes with one rep each. Treat differences of a few percent as noise; gaps of a few percent sit at the edge of the 2% tie band.</li>
<li>Not faster: \(notFasterSentence())</li>
<li>Only the build named in the run summary at the top was benchmarked; later commits were not.</li>
<li>The prefix cache is in memory only. Speculative decoding and batching can differ from greedy at bf16 near-ties.</li>
<li>Not yet validated: live soak on the current build and harness, the paid agent-benchmark pilot, token savings from delegation, multi-step quality of batched decode and the cache cuts, other Mac memory tiers (see <a href="#agents">Agents</a> and <a href="#scope">Scope</a>).</li>
<li>The shipped <code>StrimApp</code> is a menu-bar shell over an older service and does not drive <code>strim serve</code>.</li>
</ul>
</section>

<section id="roadmap" aria-labelledby="h-roadmap"><h2 id="h-roadmap">Roadmap</h2>
<ul>
<li><strong>Qwen4 readiness</strong> &mdash; <span class="tag">planned</span>. Make layer and head dimensions config-driven instead of fixed to Qwen3.8-27B (<a href="../docs/RESEARCH-QWEN4-2026-10-27.md">research note</a>).</li>
<li><strong>Mixed quantization per memory tier</strong> &mdash; <span class="tag">planned</span>. Other bit widths for other Macs, with a quality gate (<a href="../docs/RESEARCH-QUANT-TIERS-2026-10-27.md">research note</a>).</li>
<li><strong>GPU-index decode</strong> &mdash; <span class="tag">planned</span>.</li>
<li><strong>Batched-matmul tuning for c=4</strong> &mdash; <span class="tag">planned</span>: the quantized matmul at 4 to 8 rows is the remaining aggregate-throughput gap.</li>
<li><strong>Cold-prefill kernels</strong> &mdash; <span class="tag">planned</span>: the cold-prefill gap at long prompts.</li>
<li><strong>Paid agent-benchmark pilot</strong> &mdash; <span class="tag">planned</span>: the test that decides whether delegation saves parent tokens.</li>
<li>Menu-bar app and a disk-backed prefix cache, after the benchmark gate.</li>
</ul>
</section>

<section id="reproduce" aria-labelledby="h-repro"><h2 id="h-repro">Reproduce</h2>
<p>Hardware: \(esc(fig("ver.hw").raw["value"]?.pyStr ?? "None")), macOS \(esc(fig("ver.macos").raw["value"]?.pyStr ?? "None")). Versions: \(esc(fig("ver.strim_h2h").raw["value"]?.pyStr ?? "None")), \(RIVALS.filter { D.figs["ver.h2h.\($0)"] != nil }.map { esc(fig("ver.h2h.\($0)").raw["value"]?.pyStr ?? "None") }.joined(separator: ", ")).
Run GPU benchmarks one at a time in a foreground shell (the runner takes <code>lockf /tmp/strim-bench.lock</code>). Models live under <code>models/</code>; rival engines must be installed separately.</p>
<pre><code># head-to-head: OUTDIR [passes] [engines] [cell groups]; pass 2 runs the engines in reverse order
bench/h2h/run.sh bench/results/&lt;dir&gt; 1,2 \(ENGINES.joined(separator: ",")) g1,g2,g3
bench/h2h/summarize.sh bench/results/&lt;dir&gt;          # writes summary.md and results.json

# flags used
strim serve models/qwen38-4bit models/qwen38-mtp-4bit --port 8203 --no-auth
\(rivalLaunchLines())

# engine-level gates
swift test --disable-sandbox
.build/release/strim checkprefix models/qwen38-4bit 4096 3 models/qwen38-mtp-4bit
.build/release/strim enginebench models/qwen38-4bit models/qwen38-mtp-4bit

# real-client soak
lockf -k /tmp/strim-bench.lock .build/release/strim soak --duration 30 --arms both

# regenerate this page and the README from site/data/results.json
.build/release/strim site build
.build/release/strim site check</code></pre>
<p>The model-backed tests skip cleanly when <code>models/</code> is absent. Details: <a href="../docs/BENCH.md">BENCH.md</a>, <a href="../bench/h2h/run.sh">bench/h2h/run.sh</a>, <a href="../bench/soak/README.md">soak/README.md</a>.</p>
</section>

<section id="method" aria-labelledby="h-method"><h2 id="h-method">Methodology</h2>
<ul>
<li><strong>Final head-to-head.</strong> Runner <code>bench/h2h/{run,pass,summarize,watchdog,agree,agent-prompts}.sh</code> (shell, jq, awk). Per pass and engine, sessions are short and contiguous; each engine is the only GPU job; a watchdog aborts on memory limits. The figure rows are generated from <code>summary.md</code> by <code>strim site build</code> and re-checked cell by cell against it.</li>
<li><strong>Thinking off</strong> for all engines so the chat template is identical. <strong>Decode</strong> = (completion tokens &minus; 1) / (last chunk time &minus; first chunk time) from <code>usage.completion_tokens</code>. <strong>TTFT</strong> = first non-empty output chunk minus send time.</li>
<li><strong>Cold prompts</strong> carry a unique head so no engine can hit a cache across reps. <strong>Statistics:</strong> medians over two passes; no confidence intervals (the sample is too small).</li>
<li><strong>Earlier 8-engine run (2026-10-26) not repeated for the final build.</strong> Only the llama.cpp and Ollama decode points are shown as hollow dashed earlier-run beads; their full historical scoreboard is not mixed with this run.</li>
</ul>

""")
        A(versionRows())
        A("<p class=\"note\">Raw data: <a href=\"../\(FINAL_REL)/summary.md\">\(esc(FINAL_REL.split(separator: "/").last.map(String.init) ?? FINAL_REL))</a>, <a href=\"../bench/results/cache-footprint-20261027/NOTES.md\">cache-footprint</a>, <a href=\"../docs/PLAN-CONCURRENCY-2026-10-27.md\">concurrency plan</a>, <a href=\"../bench/results/soak-20261027/run2/summary.txt\">soak run</a>.</p></section>\n\n")

        A("""
<section id="license" aria-labelledby="h-license"><h2 id="h-license">License and credits</h2>
<p>MIT, see <a href="../LICENSE">LICENSE</a>. Third-party notices: <a href="../NOTICE">NOTICE</a> and <a href="../docs/THIRD-PARTY.md">THIRD-PARTY.md</a>. The blocked GDN prefill kernel is ported from Rapid-MLX (Apache-2.0), which adapted it from oMLX (Apache-2.0); the Apache-2.0 text is in <code>LICENSES/</code>. MLX Swift (MIT) is linked through SwiftPM. Contributions: <a href="../CONTRIBUTING.md">CONTRIBUTING.md</a>.</p>
</section>

<section id="figures" aria-labelledby="h-figs">
<h2 id="h-figs">Figure index</h2>
<p>Every number on this page is one of the \(D.figs.count) figures below, defined in <a href="data/results.json">site/data/results.json</a> with its source file, method note and caveat. <code>strim site check</code> verifies that each value occurs in its source file.</p>
<details><summary>Show all figures</summary>\(figureIndex())</details>
</section>
</div></main>
""")
        A(footerHTML())
        _ = soakDone
        return page
    }
}
