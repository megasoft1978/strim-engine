# Product shell — menu-bar app, local API, MCP

**Date:** 2026-10-25 · Requested shape: one top-right icon, click to see what the engine is doing and
talk to it, usable by Codex / Claude Code / any OpenAI client, with memory and speed controls.

---

## 1. Form factor

```
┌──────────────────────────── macOS menu bar ────────────────────────────┐
│  …                          [◉ Strim 33 t/s]                          │
└────────────────────────────────────────────────────────────────────────┘
                                    │ click
                                    ▼
                    ┌──────────────────────────────┐
                    │ Strim                        │
                    │ ● Ready · 6-bit + MTP        │
                    │ 33.3 tok/s · 26.4 GB · 4k ctx│
                    │ ──────────────────────────── │
                    │ [ Ask Strim…            ] ↑  │
                    │ ──────────────────────────── │
                    │ Requests   ▸ 3 active        │
                    │ Last: prefill 2.1s · 41 t/s  │
                    │ ──────────────────────────── │
                    │ Speed ◐──────○  Quality      │
                    │ Memory 26.4 / 52 GB          │
                    │ [Server on] [MCP on] [Open…] │
                    └──────────────────────────────┘
```

- **`Strim.app`** is a menu-bar app (`NSStatusItem` + `NSPopover`). No Dock icon by default.
- **`strimd`** is a launchd agent that owns the engine, the OpenAI server and the MCP server. It keeps
  running when the menu closes, so Codex/Claude Code never lose the endpoint.
- The app talks to `strimd` over a local Unix socket (JSON-RPC). The same messages are exposed as
  HTTP `/v1/strim/*` for automation.
- First launch: model download, digest check, quant/context defaults from RAM, one-time setup.

Icon states: idle (hollow), loading (spinner), ready (filled), busy (pulse), degraded (triangle:
memory pressure, reduced context), error (red).

---

## 2. What the panel shows ("the steps")

Per request, a compact timeline:

```
queue 0.0s → prefill 2.1s (1,940 tok/s) → decode 7.4s (33.3 tok/s, MTP 2.6 tok/step) → done
prefix cache: 3,584 / 4,096 tokens reused
```

- **Now**: model, quant, context used/limit, tok/s (instant + 30 s), TTFT, memory (weights/KV/other),
  active sessions, queue depth, MTP acceptance.
- **Recent requests**: last 20 with phase breakdown, cache hit, tokens, stop reason, client name.
- **Engine log tail** and "Open logs / Open model folder" buttons.
- **Health**: memory pressure, swap, thermal state, wired limit.

That is the "see what it is doing" surface, and it is the same data the benchmark harness records.

## 3. Talk to it directly

The panel has a chat box that uses the same engine and the same prefix cache as API clients. It can
switch modes:

- **Chat** — normal conversation.
- **Ask about this Mac** — the model gets a small tool set (`system_info`, `list_processes`,
  `disk_usage`) so it can answer "what is using memory" and "why is this slow".
- **Agent** — file read/write/shell inside a user-approved folder, with a visible per-step log.

The panel is not a second engine: a request typed there is just another session, so it benefits from
the same batching and priority rules (interactive class).

---

## 4. Interfaces

### 4.1 OpenAI-compatible HTTP (for Codex, Claude Code, anything)

```
POST /v1/chat/completions   (stream + non-stream, tools, thinking flag)
GET  /v1/models
POST /v1/completions        (legacy clients)
POST /v1/messages           (Anthropic-shaped bridge, for Claude Code)
GET  /health, /metrics
POST /v1/strim/{load,unload,cancel,config}
```

- Bind `127.0.0.1` only by default; bearer token written to `~/.strim/token` and shown in the panel.
- Codex: `OPENAI_BASE_URL=http://127.0.0.1:8123/v1`, model id `strim-qwen38-27b`.
- Claude Code: point `ANTHROPIC_BASE_URL` at the same port; the `/v1/messages` bridge translates to
  the engine's chat path. (If the bridge is not ready, use the OpenAI-compatible path via LiteLLM.)
- Any other client (Continue, Cursor, OpenWebUI) works through the OpenAI surface.

### 4.2 MCP

Two transports from the same server: **stdio** (for a client that spawns it) and **streamable HTTP**
(`http://127.0.0.1:8123/mcp`).

Tools:

| Tool | Purpose |
|---|---|
| `strim_status` | model, quant, memory, tok/s, queue, health |
| `strim_chat` | one completion with optional tools/thinking/context limit |
| `strim_generate` | raw completion (no chat template) |
| `strim_load` / `strim_unload` / `strim_config` | model and runtime control |
| `strim_cancel` | cancel a request by id |
| `strim_bench` | run the built-in speed probe and return the numbers |

Resources: `strim://status`, `strim://requests/recent`, `strim://logs/tail`.

Why both: Codex and Claude Code consume **models** through an OpenAI/Anthropic endpoint, and **tools**
through MCP. Exposing both means the same local model can be the backend *and* a tool other agents
call ("ask the local model to review this diff").

### 4.3 Security

Localhost-only default; token required for non-loopback; no telemetry; model files and logs stay in
`~/Library/Application Support/Strim`. MCP HTTP requires the same token.

---

## 5. Memory and speed controls (panel → engine)

| Control | Effect | Guardrail |
|---|---|---|
| **Profile** | Quality / Balanced / Speed preset | maps to quant + context + MTP depth |
| **Quant** | 8-bit / 6-bit graded / 5-bit / 4-bit | shows measured quality delta and size |
| **Context** | 8k / 32k / 64k / 128k | admission check against 52 GB budget |
| **KV cache** | fp16 / int8 (above 32k) | quality note |
| **Batch slots** | 1–4 sessions | per-request speed shown |
| **MTP depth** | 2 / 3 / 4 | acceptance rate shown live |
| **Prefill chunk** | 512 / 1k / 2k | TTFT vs memory |
| **Wired limit** | 40–44 GB | hard cap, never the 75% default |
| **Unload** | free all GPU memory | confirms footprint after |

The panel shows the trade-off before applying: "6-bit graded: −0.24% code PPL, −7 GB, +25% decode".
That is the product version of the quantization research.

---

## 6. Build order (fits the existing plan)

| Phase | Shell work |
|---|---|
| 1 (graph parity) | `strimd` skeleton, Unix socket, CLI |
| 2 (speed layer) | OpenAI server, status/metrics, panel read-only |
| 3 (product) | menu-bar app, chat box, profiles, model manager, MCP |
| 4 (tuning) | live timeline, priority classes, batch controls |

MCP is Phase 3, but the tool schemas can be frozen early so Codex/Claude Code integration is tested
against mocks before the engine is finished.
