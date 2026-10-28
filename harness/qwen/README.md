# Qwen-specific harness pack (Harness²-compatible Codex root)

This is the model-specific harness we install around the local Qwen models. It follows the
component surface of [Harness²](https://github.com/google-research/harness2) (AGENTS.md always
on; skills on demand; scripts; Codex root layout), but the content is tuned for this engine:

- **Qwen3.8-27B dense** (quality): 262K context, ~900 tok/s prefill, ~55 tok/s decode. Every
  unnecessary 1k tokens costs ~1.1s before the agent can act, so the harness forbids repo dumps
  and whole-file reads and routes large files through `strim_summarize`.
- **Qwen3.6-35B-A3B** (speed): broad search is cheap; final diff review switches to quality.
- **Local MCP tools**: `strim_summarize`, `strim_review_diff`, `strim_explain_error`,
  `strim_draft_patch`, `strim_generate_tests`, `strim_classify`, `strim_status`, `strim_switch`.
- **Deterministic helper**: `scripts/context_pack.py` builds a compact file/symbol map.

## Install into a workspace

```bash
cp -R harness/qwen/AGENTS.md harness/qwen/.agents harness/qwen/scripts <workspace>/
```

Codex finds `AGENTS.md` at the workspace root and the skills under `.agents/skills/`.

## Run Harness² itself with this pack

Harness²'s Codex executor uses a Responses endpoint (`HARNESS2_CODEX_BASE_URL`). Point it at
`strim serve` on 8203 (`strimd`, which exposed `/v1/responses`, was removed 2026-10-27; verify the Responses route before use):

```bash
export HARNESS2_CODEX_BASE_URL=http://127.0.0.1:8200/v1
export HARNESS2_CODEX_API_KEY=local
export HARNESS2_CODEX_MODEL=strim-quality
export HARNESS2_SOLVER_MODEL=openai/strim-quality
export HARNESS2_IMPROVER_MODEL=openai/strim-quality
# judge only matters when scoring a benchmark
export HARNESS2_JUDGE_BASE_URL=http://127.0.0.1:8200/v1
export HARNESS2_JUDGE_API_KEY=local
export HARNESS2_JUDGE_MODEL=strim-quality
```

Then use Harness²'s `harness2 --bench ... --substrate cx` flow (JobBench is the lightest
professional benchmark; `harness2-setup jb --substrate cx`). The pack above is the **base tree**
for the `cx` surface; Harness²'s Propose–Probe–Compose loop edits it and keeps the best variant.

The full Harness² JobBench/LAB/WorkBuddy setup is Linux-oriented and needs Node, uv and (for
WorkBuddy) Docker; the Codex path is the one that can target this machine's `strim serve` directly.
