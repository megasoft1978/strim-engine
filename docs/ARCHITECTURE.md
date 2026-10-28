# Strim architecture (2026-10-26)

Swift-only, single-process local inference for Qwen3.8-27B (dense, 4-bit) with MTP speculation. One process
hosts the engine and an OpenAI-, Anthropic- and Responses-compatible HTTP front on `127.0.0.1`. No Python at
runtime. Status and open work: `docs/HANDOFF.md`. Figures below are copied from result files; see HANDOFF section 12
for what is unverified on HEAD.

---

## 1. Targets and dependencies

| target | kind | role |
|---|---|---|
| `StrimCore` | library (MLX) | model: weights, Qwen layers, gated attention, GDN (gated DeltaNet) with Metal kernels, MTP head, speculative stream, KV/GDN caches, batch attention, exact prefix trie |
| `StrimTokenizer` | library | byte-level BPE from HF `tokenizer.json`; id parity with HF `tokenizers` (parity tests) |
| `StrimTemplate` | library | hand-written renderer of the Qwen3.8 chat template (not Jinja), `OrderedJSON` (key order kept), streaming tool-call parser |
| `StrimPrompt` | library | token ledger (exact ids per turn) and `PromptBuilder` (reconciles client messages with the ledger), content control-string handling |
| `StrimHTTP` | library | minimal HTTP/1.1 on Network.framework, loopback only, SSE, CORS, bearer hook, Host/Origin checks |
| `StrimEngine` | library (MLX) | engine thread, `EngineClient` protocol, `LocalEngineClient`, scheduler, admission, sampler |
| `StrimServer` | library | OpenAI chat, Anthropic Messages, Responses adapters; session table; token store; error shapes |
| `StrimCLI` | executable `strim` | serve, chat, gen, benchmarks, parity checks (`main.swift` dispatch plus `Cmd_*.swift`) |
| `StrimApp` | executable | AppKit menu-bar status app (see section 13: targets legacy endpoints) |

Dependencies (from `Package.swift`): `StrimCore` -> MLX, MLXNN, MLXFast, MLXRandom. `StrimPrompt` -> Tokenizer, Template.
`StrimEngine` -> Core, Prompt, Tokenizer, Template, MLX. `StrimServer` -> HTTP, Engine, Prompt, Template, Tokenizer.
`StrimHTTP`, `StrimTokenizer`, `StrimTemplate`, `StrimApp` have no internal deps. MLX Swift is pinned to 0.32.3.

Test targets: `StrimCoreTests`, `StrimTokenizerTests`, `StrimTemplateTests`, `StrimPromptTests`, `StrimHTTPTests`,
`StrimEngineTests`, `StrimServerTests` (`Tests/`). Test count: unverified in this pass.

---

## 2. Process model

- `strim serve` runs in one process: HTTP server and engine. Signal handlers (SIGINT, SIGTERM) stop the server and call `engine.shutdown()`.
- The engine runs on **one dedicated OS thread** (`EngineLoop`, `Inbox.swift`), not an actor or cooperative task. MLX streams
  are per-thread, so every MLX object (weights, caches, prefix trie, hot sessions) is created and touched only there.
  `EngineCore` documents this on its type.
- `EngineClient` (`EngineAPI.swift`) is the boundary. Operations: `openSession`, `fork`, `append`, `generate`
  (returns `AsyncThrowingStream<GenEvent>`), `cancel`, `prefetch`, `ledger`, `close`, `stats`. Arguments and results are
  `Sendable` values (ids, strings, small structs), so the same protocol could later sit behind IPC.
- `LocalEngineClient` posts commands to the inbox and bridges replies and events back to async callers. Engine work runs
  inside `withError` (`EngineCore.swift`, unit and generation paths), so MLX errors are reported instead of trapping.
- Benchmarks and checks (`enginebench`, `chat`) also go only through `LocalEngineClient`.

---

## 3. Scheduler and decode policy

Unit of work: one **decode pass** or one **prefill chunk of at most 1024 tokens** (`Scheduler.swift`).

- Interactive beats background. While any interactive request exists, only interactive requests are eligible.
  Background requests pause at their current unit boundary and keep their cache or finished chunks.
- Within a class, a prefill chunk and a decode pass alternate when both are pending, so no decode waits more than one chunk.
  Prefills run FIFO.
- Decode: one eligible request not in the batch runs solo (MTP when greedy). Two or more eligible decoders run one batched
  pass. Solos join the batch and stay on plain decode until they finish.
- Cancel: `cancelSession` / `cancelRequest` finish the active request with `.cancelled` on the engine thread, so it takes
  effect between units. The HTTP route is `POST /v1/strim/cancel/<id>`.
- Decode policy `STRIM_DECODE_POLICY` (default `auto`):
  - `batch`: as above.
  - `roundrobin`: never batch. Each decoder keeps its own `SpecStream`, units alternate least-recently-served first.
    Bitwise identical to each sequence's single-stream run.
  - `auto`: while no batch exists and two or more decoders run, compares estimated aggregate tok/s of time-sliced MTP
    against a measured plain-batch table (`batchStepMs`), with hysteresis (enter round-robin at +5%, leave at -10%, after
    every sequence has at least 3 measured units). Leaving to the batch is one-way: a joined sequence has no MTP head state to resume.

Results (section 11): round-robin and auto beat plain batch on greedy code at B=2 (73.7-74.2 vs 48.9 tok/s aggregate).

---

## 4. Token ledger and PromptBuilder

Why: re-rendering a finished assistant turn from text does not reproduce the ids the model generated. Re-tokenizing
history would change the prompt, which breaks prefix reuse and exactness. So the engine keeps the ids it produced.

- `Ledger` (`Ledger.swift`): exact token ids for a conversation, split into segments that mirror
  `ChatTemplate.renderSegments`. Each record has an origin: `rendered` (matched by fnv64 of the segment text) or
  `generated` (matched by role, trimmed content and canonical tool_calls JSON; reasoning optional). Generated records keep the
  model's ids. A generation cut off before the end token is marked incomplete and never reused.
- `PromptBuilder.prepare` (`PromptBuilder.swift`): the full message list is always rendered (cheap), but only segments after the
  longest matching ledger prefix are tokenized. The result reports `reusedPrefixIds` and the suffix (`newIds`) to prefill.
- `ContentSpecialTokens.disabled` (default): control strings inside user content (turn markers, tool-result markers, vision
  markers) are tokenized as plain text, so content cannot forge turns or tool results. `.hfCompat` exists only for oracle comparisons.
- `SessionTable` (server) maps a conversation fingerprint (system message, first user message, tools, template config; `ChatRequest.fingerprint`)
  to a pooled engine session with LRU capacity `STRIM_MAX_SESSIONS` (default 8). A concurrent request on the same
  conversation gets a throwaway session instead of waiting.
- Hot sessions (`HotState`, `EngineCore.swift`): up to `STRIM_HOT_SESSIONS` (default 2) sessions keep their finished turn's live cache,
  speculative stream and exact ids resident (oldest demoted first). A new turn continues hot only if those ids are a prefix of its ledger; otherwise it restores from the prefix trie.

---

## 5. Server adapters

Routes (`StrimOpenAIServer.swift`):

| method and path | auth | notes |
|---|---|---|
| `GET /health` | none | liveness |
| `GET /v1/models` | bearer | model id = model directory name (`qwen38-4bit`) |
| `GET /metrics` | bearer | counters |
| `POST /v1/chat/completions` | bearer | OpenAI chat, streaming, tools, stop sequences (`StopScanner`) |
| `POST /v1/messages` | bearer | Anthropic Messages; Anthropic error shape; `role: system` merged into the system header |
| `POST /v1/messages/count_tokens` | bearer | token count |
| `POST /v1/responses` | bearer | Responses; function tools; `previous_response_id` via bounded FIFO map of response id to conversation |
| `POST /v1/strim/cancel/<id>` | bearer | cancel a request |
| other | bearer | 404 |

- Auth: `Authorization: Bearer <token>` or `x-api-key: <token>` (Anthropic SDKs). Comparison is constant-time. Failure is 401 with `WWW-Authenticate: Bearer`.
- Priority: header `x-strim-priority: interactive|background`, else body `priority` or `strim_priority`. Default interactive. Other values are 400.
- Unsupported input: image, video and document content blocks are rejected with 400 in every adapter.
- `tool_choice`: `auto`, `none` (drops tools) and `required` are passed to the template. `required` is **not enforced** (no constrained decoding).
- Thinking: when tools are declared and `tool_choice != none`, `enable_thinking` is forced off (prompt ends `<think>\n\n</think>\n\n`), exposed as a `ReasoningPolicy`.

Server defaults (`strim serve`): port 8203, 127.0.0.1 only, token from `~/.strim/token`, `--no-auth` for loopback dev only.
`STRIM_SERVER_LOG=1` prints per-request engine timing to stderr.

---

## 6. Exact prefix cache

- `PrefixStore` (`PrefixCache.swift`): a trie whose nodes are aligned 1024-token blocks. Chunk boundaries are at absolute
  multiples of 1024, so a miss and a hit run identical arithmetic for every chunk.
- Node contents: attention KV for the block, GDN recurrent state and conv state for the block (conv is an owned 3-row copy),
  and the MTP head block state (head KV plus carry).
- Lookup returns the longest matched prefix (a multiple of 1024) and a fresh `ModelCache` positioned there; the rest is prefilled.
- Budget: `STRIM_PREFIX_CACHE_MB`, default 12288 (`defaultBudgetMB`). LRU leaves are evicted when the accounted size exceeds budget.
  Accounting is about 215 MiB per node (`MemoryModel`). `STRIM_PREFIX_CACHE=0` disables the trie.
- `Node.parent` is weak (children hold nodes strongly), so dropping a store frees it. Before this fix (`3321082`) the trie leaked.
- In memory only. No disk persistence. No LCP or radix matching beyond aligned chunk prefixes.
- Check: `strim checkprefix <model> [N=4096] [sharedBlocks=3] [mtpHead]` asserts hit == miss, eviction parity, unrelated-prompt miss, and reports TTFT and cost.

---

## 7. Speculative decode (MTP)

- `SpecStream` (`SpecStream.swift`): resumable speculative greedy decode over an external `ModelCache` and MTP state.
  A verify pass feeds the pending token plus the drafts through the target model and uses the full lm_head. Accepted drafts are kept;
  the rest roll back (`cache.rollback(drop:)`, `endVerify`).
- Drafting uses a truncated lm_head (`WeightStore.draftVocab`): first existing of `STRIM_DRAFT_VOCAB`, `<model>/draft_vocab.json`,
  `bench/draft_vocab_48k.json` (cwd-relative). Verify always uses the full vocab. `STRIM_DRAFT_VOCAB=off` disables.
  Generated by `strim draft-vocab --k 49152 --out bench/draft_vocab_48k.json --extra-dir vendor --extra-dir docs` (`DraftVocabBuilder`):
  token frequency over git-tracked text plus the extra walks, ties to the lower id, specials kept. `vendor/` is gitignored, so a clean clone cannot regenerate it.
- Depth: start 2, adaptive by acceptance EWMA (climb at > 0.82 to 3, > 0.84 to 4, fall below 0.60). Floor 2, ceiling `STRIM_MTP_MAX_DEPTH` (default 4). `STRIM_MTP_FIXED=1` disables adaptivity.
- Drafting index path is the default (no per-draft host sync); `STRIM_MTP_HOST=1` restores the host-sync path for A/B.
- Sampled requests (temperature > 0) also use MTP, with lossless speculative sampling (`SpecSampling.swift`: accept, residual, bonus on device).
  `STRIM_SAMPLED_DEPTH0=1` forces depth 0 for sampled requests (bench baseline).
- Prefill in an MTP session also runs the head over each chunk, so MTP state is available at every trie boundary.

---

## 8. Memory admission

- `MemoryModel` (`Admission.swift`): weights 0.95 x safetensors bytes; attention KV 64 KiB per token; MTP KV 4 KiB per token;
  GDN state 147 MiB per sequence; one prefill-chunk transient 800 MiB, reserved once.
- Budget: `STRIM_MEM_BUDGET_GB`, default 70% of physical RAM (44.8 GiB on 64 GB).
- Fixed bytes = weights + trie budget + MLX cache limit (`STRIM_MLX_CACHE_MB`, default 4 GiB).
- `Admission.decide`: evicts hot sessions (oldest first, never the one being reused) until the new request fits, else rejects with the needed and available bytes.
- Debug: `STRIM_MEM_TRACE=1` prints MLX active, cache and peak per work unit to stderr; `STRIM_MEM_CLEAR=1` (with trace) clears the MLX cache after each unit (experiment).
- Caveat: the trie's accounted cost (215 MiB per node) was 1,175 MiB real before fixes `f5c0ce3` and `3321082` (`docs/MEMORY-2026-10-26.md`). Post-fix real cost unmeasured.

---

## 9. Exactness contracts

The planning memory names contracts C1-C3, but those labels are not in `strim_architecture_decisions.md`. The contracts
below are the ones the checks enforce. The mapping to C1-C3 is unverified.

| id | contract | enforced by | status |
|---|---|---|---|
| X1 | gen16 greedy ids equal the reference | `strim gen <model> 16` vs `gen16-swift.txt` | gate |
| X2 | depth-0 greedy equals the reference, bitwise | `strim benchspec ... 64 0 <ids>` (EXACT) | gate |
| X3 | prefix hit equals miss (logit hash and 16 greedy tokens), with eviction | `strim checkprefix` | gate, MTP and no-MTP |
| X4 | round-robin decode equals single-stream decode, bitwise | `strim enginebench --only=concurrent-decode` | gate |
| X5 | depth-2 spec equals greedy | reported only | near-tie baseline; not a gate (first diff seen at token 53 on the prose prompt) |
| X6 | batch and auto decode equal single-stream | reported only | not bitwise (sampled 0/16 identical-to-solo) |
| X7 | hot-continue equals cold | reported only | tokens identical over 20; logits not bitwise |

Near-ties (bf16 rounding in differently ordered reductions) are the expected cause of X5-X7 differences.

---

## 10. Security notes

- Listener bound to IPv4 loopback (`127.0.0.1`) via `requiredLocalEndpoint`.
- Host header must be exactly one value and name `localhost`, `127.0.0.1` or `[::1]` (port stripped), else rejected. This blocks DNS rebinding.
- Origin, if present, must be a loopback origin. CORS echoes only loopback origins. Non-browser clients send no Origin.
- Bearer token required by default. Stored at `~/.strim/token` (directory 0700, file 0600, 32 random bytes as hex). The path is printed; the token is not.
- `--no-auth` disables the check (loopback dev only).
- User content cannot inject control tokens (section 4).
- Images, video and documents are rejected, so the server never decodes media.

---

## 11. Measured results (pointers; quote from the files)

| topic | file | key figures |
|---|---|---|
| decode corpus, depth-2 | `corpus.log` (local run log, not committed) | mean 55.11 decode-only; code 64.9; prose 37.5; 7/8 EXACT, prose first diff at 53 |
| 4 engines, in-process and HTTP | `bench/results/screen-20261026b/summary.md` | Strim S2 4K cold prefill medians 1019 and 1012 tok/s (post-fix); S1 decode 63.6 (in-process) |
| HTTP head-to-head vs rapid-mlx | `bench/results/h2h-20261026/summary.md` | greedy-64 decode 65.4 vs 50.3; 4K cold decode 64.0 vs 47.6; replay T8 TTFT 8.5 s (default budget) vs 7.3 s; built from commit not in repo |
| prefix cache exactness | `bench/results/prefix-cache-exact-20261026/`, `bench/results/dec-wave3-20261026/` | 4K miss 3.994 s, hit 1.022 s; 8K+MTP miss 22.906 s, hit 6.084 s; ALL PASS |
| concurrency and policy | `bench/results/rr-wave3/concurrent-decode.txt` | greedy code B=2: batch 48.9, roundrobin 74.2, auto 73.7; prose B=4 auto 73.7 vs batch 75.8; ALL PASS |
| long-context near-ties | `bench/results/longctx-validate-20261026/summary.md` | 4K greedy-16 default vs serial 16/16, 16/16, 16/16, 6/16, 4/16 |
| memory (pre-fix) | `bench/results/mem-20261026/`, `docs/MEMORY-2026-10-26.md` | trie 1,175 MiB real per node before fixes; MLX cache plateaus at its limit |
| batched verify cost | `docs/BATCH-MTP-2026-10-26.md` | verify ms grows steeply with B and S; in-batch MTP NO-GO |
| soak (clients against `strim serve`) | `bench/soak/README.md`, `bench/soak/results/` (git-ignored local run output; committed summaries in `bench/results/soak-20261027/`) | Claude Code and Codex tasks with unit-test checks; run only under the GPU lock |

---

## 12. Memory and design docs

- `docs/MEMORY-2026-10-26.md`: pre-fix memory breakdown and leak analysis. Its P1 (owned conv copy), P2 (weak parent) and admission formula
  are now in code (`f5c0ce3`, `3321082`, `4020c52`). Its 80% budget and 4 GiB trie defaults are superseded (70% and 12 GiB).
- `docs/BATCH-MTP-2026-10-26.md`: in-batch MTP phase-1 measurement. Verdict NO-GO for general BatchSpec; reasons: GDN recurrence for B>1 uses the tensor path, and quantized matmuls at M = B x S fall off the fast path.
- `docs/BLOCKED-GDN-PREFILL-2026-10-26.md`: blocked prefill kernel design. Its numbers predate the launch-grid fix (`b0d9ca1`); use HANDOFF 5.1.
- `docs/PREFIX-CACHE-2026-10-26.md`: superseded shared-prefix prototype (not token-exact). The exact trie is in section 6.

---

## 13. Not done

- SwiftUI chat app. `StrimApp` is an AppKit menu-bar status item only.
- MCP endpoint (no MCP code in `Sources/`).
- Disk-persisted prefix cache; LCP or radix matching.
- Forced `tool_choice` (constrained decoding).
- Image, video and document input.
- Crash-recovery journal. `EngineStats.lastHeartbeat` is set; nothing reads it.
- Swift-native Qwen3.6-35B-A3B (`qwen3_5_moe`, MoE). No MoE, router or expert code in `Sources/`. Weights are on disk in `models/qwen36-a3b-4bit`. Unsupported.
- `StrimApp` targets legacy `strimd.py` endpoints (`/v1/strim/status`, `/v1/strim/switch`, default port 8200). `strim serve` does not serve them.

---

## 14. Unverified in this pass

- Build, test count, and any gate run on HEAD (no GPU work in this pass).
- Post-fix real memory per trie node.
- h2h Strim numbers (built from commit `a797890`, not in this repo).
- Whether the exactness labels C1-C3 in the planning notes map to X1-X7.
- Exact contents of `/health` and `/metrics` responses.
- Whether `STRIM_SERVER_LOG` output format is stable.

---

## 15. Environment variables

Every `STRIM_*` name found by `grep -rhoE 'STRIM_[A-Z0-9_]+' Sources`. "set" means any value enables it.

| variable | default | meaning |
|---|---|---|
| `STRIM_MAX_SESSIONS` | 8 | `strim serve` pooled session capacity |
| `STRIM_HOT_SESSIONS` | 2 | sessions kept hot after a turn (0 disables) |
| `STRIM_PREFIX_CACHE` | on | `0` disables the prefix trie |
| `STRIM_PREFIX_CACHE_MB` | 12288 | trie accounting budget (MiB) |
| `STRIM_MEM_BUDGET_GB` | 70% RAM | admission budget |
| `STRIM_MLX_CACHE_MB` | 4096 | MLX buffer cache limit (MiB) |
| `STRIM_MEM_TRACE` | off | `[mem]` line per work unit on stderr |
| `STRIM_MEM_CLEAR` | off | with MEM_TRACE: clear MLX cache after each unit (experiment) |
| `STRIM_ENGINE_TRACE` | off | engine unit trace on stderr |
| `STRIM_DECODE_POLICY` | auto | `batch`, `roundrobin` or `auto`; other values mean batch |
| `STRIM_SAMPLED_DEPTH0` | off | sampled requests run depth 0 (bench baseline) |
| `STRIM_MTP_FIXED` | off | `set` disables adaptive MTP depth |
| `STRIM_MTP_MAX_DEPTH` | 4 | MTP depth ceiling |
| `STRIM_MTP_HOST` | off | `set` uses host-sync drafting (A/B) |
| `STRIM_DRAFT_VOCAB` | first existing of model `draft_vocab.json`, `bench/draft_vocab_48k.json` | draft lm_head vocab path; `off` disables |
| `STRIM_GDN_BLOCKED` | on | `0` disables blocked prefill kernel (S >= 512) |
| `STRIM_GDN_METAL` | on | `set` forces the Metal recurrence |
| `STRIM_GDN_TENSOR` | off | `set` (without METAL) uses reference TF32 tensor recurrence |
| `STRIM_GDN_METAL_MAX_S` | 1000000 | max S for Metal recurrence (8 restores tensor prefill) |
| `STRIM_GDN_BATCH_METAL` | off | `1` opts into per-sequence Metal recurrence for batched decode |
| `STRIM_BATCH_DECODE` | on | `0` opts out of the batch-dimension GDN decode/conv Metal kernels used for batched decode (B>1); see docs/PLAN-CONCURRENCY-2026-10-27.md |
| `STRIM_CONV_TENSOR` | off | `set` forces tensor depthwise conv at B=1 |
| `STRIM_REC_ELEM` | off | `set` uses elementwise recurrence formulation (A/B) |
| `STRIM_SKIP_REC` | off | `set` skips recurrence (measurement only; output invalid) |
| `STRIM_NO_COMPILE_ELEMENTWISE` | compiled | `1` uses eager elementwise ops (A/B) |
| `STRIM_TIMING` | off | `set` prints SpecStream timing split |
| `STRIM_DEBUG` | off | `set` prints per-pass accept details on stderr |
| `STRIM_SERVER_LOG` | off | `set` prints per-request engine timing on stderr |
| `STRIM_CHAT_MAX` | 512 | `strim chat` max tokens |
| `STRIM_TEMP` | 0 | `strim chat` temperature |
| `STRIM_BENCH_PROMPTS` | distinct | benchserve prompt mode (`distinct` or `legacy`) |
| `STRIM_DUMP_TOKENS` | unset | path: benchserve writes decode ids per request |
| `STRIM_CD_ROUNDS` | 4 | enginebench concurrent-decode rounds |
| `STRIM_CD_TOKENS` | 160 | concurrent-decode tokens per request |
| `STRIM_CD_B` | 2,3,4 | concurrent-decode batch sizes |
| `STRIM_CD_MIX` | code,prose,mixed | concurrent-decode prompt mixes |
| `STRIM_CD_MODE` | greedy,sampled | concurrent-decode sampling modes |
| `STRIM_CD_POLICIES` | batch,roundrobin,auto | concurrent-decode policies |
| `STRIM_HOT_STEPS` | 20 | checkprefix hot-continue steps |
| `STRIM_HOT_SEED` | 3 | checkprefix hot-continue seed |
| `STRIM_URL` | http://127.0.0.1:8200 | StrimApp endpoint (legacy strimd API) |

---

## 16. CLI commands

Dispatch: `Sources/StrimCLI/main.swift` (`args[1]`) and `Commands.swift` (`runExtraCommand`). Usage lines are in each file's header comment.

- Serve and chat: `serve <model> [mtpHead] [--port N=8203] [--token-file PATH] [--no-auth]`; `chat <model> [mtpHead]`; `gen <model> [n] [layers]`; `genmtp`.
- Parity and gates: `checkprefix <model> [N=4096] [sharedBlocks=3] [mtpHead]`; `enginebench <model> [mtpHead] [--only=single,four,prio,cancel,session,parity,concurrent-decode]`; `benchspec <model> <head> <n> <depth> <ids> [reps]`; `benchmtp`; `benchpathspec`; `checkbatch`; `checkbatch2`; `checkbatchparity`; `checkgdn`; `checkgdnbatch`; `checkconv`; `checkspec`; `checktie`; `checkcompile`; `checkmetal`; `checkrollback`; `mtpcombo`; `mtpacc`; `mtp`; `logithash`; `logits`; `layer0`; `layer3`; `gdn`; `probe <model> [token]`; `inspect <model>`; `quantinfo`.
- Benchmarks: `benchserve <model> <requests> <maxTokens> [slots] [mix] [ctx] [prefixMode]`; `benchprefill <model> <n> [reps]`; `benchbatch`; `benchbatchprefill`; `benchbatchsplit`; `benchbatchverify <model> <ctx> <B> [reps]`; `benchctx`; `benchppl`; `benchpass`; `benchpassS`; `benchpathS`; `benchlayer`; `benchmlp`; `benchops`; `benchfuse`; `benchcompile`; `benchgvS`; `benchqmm`; `benchqmmS`; `benchqmmM`; `benchsplit`; `benchsplitS`; `benchbuild`; `qgemv`; `probesplit`.

Commands registered but unverified in behaviour: most `bench*` and `check*` commands are research tools; only the ones named in HANDOFF section 1 were exercised by the recorded logs.
