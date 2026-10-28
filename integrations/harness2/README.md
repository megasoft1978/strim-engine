# Harness² + local Qwen

We cloned [google-research/harness2](https://github.com/google-research/harness2) and checked
what transfers to this engine. It is **not an eval harness**: it is a recursive agent-harness
optimizer (Propose–Probe–Compose) around OpenCode/Codex, with a clear eight-component surface
(system prompt, guardrails, memory, tool guidance, subagents, skills, scripts, plugins).

## What we took

`harness/qwen/` is a **Harness²-compatible Codex root** for the models this engine serves:

- `AGENTS.md` (2.9 KB / ~740 tokens, under Harness²'s 8 KB Codex cap): context budget rules for
  the 27B dense model (~900 tok/s prefill), tool routing, verification loop.
- `.agents/skills/repo-context`, `diff-review`, `test-fix`: on-demand procedures with Harness²'s
  required trigger lines and frontmatter.
- `scripts/context_pack.py`: deterministic compact file/symbol map, no dependencies. Removed 2026-10-27; recoverable from the history bundle.

It validates with Harness²'s own surface checker:

```
always_on_chars: 2942, n_files: 5, skills: 3, scripts: 1
```

`harness2-demo --k 1` runs successfully (2/2 tasks, no model credentials).

## Local model findings (fixed)

1. **rapid-mlx needs the Qwen tool parser.** Without
   `--enable-auto-tool-choice --tool-call-parser qwen3`, the local model emits literal
   `<tool_call>…</tool_call>` text. `strimd` now passes both flags to the speed/quality backends.
2. **`strimd`'s `/v1/responses` dropped `tools`.** Codex uses the Responses API; the old proxy
   only forwarded messages and only streamed content. It now converts Responses tool schemas,
   forwards tool calls, converts `function_call` / `function_call_output` history back to chat
   messages, and emits `function_call` output items/events. Tested with `codex exec` against
   `strim-quality`: the local Qwen model called the shell tool and the command ran.

## Run it

`run_local_codex.sh` was removed (2026-10-28): it targeted the retired daemon on port 8200 (`/v1/strim/switch`) and ran Codex with
`danger-full-access` and `--dangerously-bypass-approvals-and-sandbox`, so any file in the workspace could steer the local model into
arbitrary commands as you. Point Codex at `strim serve` (port 8203) with a workspace-write sandbox instead, for example
`scripts/agents.sh codex "<task>"`.

## Open issue

Unverified on current Codex. Codex 0.164 once listed `strim` but failed calls with
`unsupported call: mcp__strim`. Re-test before relying on MCP tools. If calls are rejected for
approval, set `default_tools_approval_mode = "approve"` for `[mcp_servers.strim]` (see docs/MCP.md).

## Harness² benchmarks

The JobBench/LAB/WorkBuddy adapters need Linux, Node/uv and (WorkBuddy) Docker. The Codex
substrate is the one that can target this machine's `strimd` directly:
`HARNESS2_CODEX_BASE_URL=http://127.0.0.1:8203/v1` (`strim serve`; `strimd` was removed 2026-10-27), model = the served model id.
The pack above is the base tree; Harness²'s recursion edits it. Full benchmark setup is not yet
run on this machine.
