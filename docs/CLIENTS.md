# Clients: endpoints, Claude Code, Codex, MCP

`strim serve` binds to 127.0.0.1 only and requires a bearer token, created on first start at `~/.strim/token` (mode 0600). Options: `--port N` (default 8203), `--token-file PATH`, `--no-auth` (loopback development only), `--max-inflight N`, `--max-background N`, `--no-admission`. The model id the API reports is the model directory name (`qwen38-4bit`). Install and model download: [INSTALL.md](INSTALL.md).

## The three endpoints

```sh
TOKEN="$(cat ~/.strim/token)"
curl -s http://127.0.0.1:8203/health

# OpenAI Chat Completions
curl -s http://127.0.0.1:8203/v1/chat/completions -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"model":"qwen38-4bit","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'

# Anthropic Messages
curl -s http://127.0.0.1:8203/v1/messages -H "Authorization: Bearer $TOKEN" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
  -d '{"model":"qwen38-4bit","max_tokens":32,"messages":[{"role":"user","content":"hi"}]}'

# OpenAI Responses
curl -s http://127.0.0.1:8203/v1/responses -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"model":"qwen38-4bit","input":"hi","max_output_tokens":32}'
```

## Claude Code

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:8203
export ANTHROPIC_AUTH_TOKEN="$(cat ~/.strim/token)"
claude --model qwen38-4bit
```

Claude Code prints an `unrecognized_model` warning on stderr for the local id; requests are served normally.

## Codex (custom Responses provider)

Codex needs a custom Responses provider. The exact argument list the soak driver uses is `codexArgv` in [Sources/StrimSoak/SoakClients.swift](../Sources/StrimSoak/SoakClients.swift); the provider definition is:

```sh
export STRIM_SOAK_TOKEN="$(cat ~/.strim/token)"
# -c 'model_provider="strim"'
# -c 'model_providers.strim={name="strim", base_url="http://127.0.0.1:8203/v1", env_key="STRIM_SOAK_TOKEN", wire_api="responses"}'
# -c 'approval_policy="never"'   and   -m qwen38-4bit
```

Send `x-strim-priority: background` to let interactive requests go first.

## MCP and the agent harness

`strim serve` hosts an MCP endpoint at `http://127.0.0.1:8203/mcp` with four tools: `strim_task`, `strim_job`, `strim_cancel`, `strim_ask`. A parent agent hands a bounded task to the local model, which works in a sandboxed git worktree; the harness runs the required `verify` command itself and returns a summary and a patch for review.

```sh
strim mcp-config --claude     # prints the claude mcp add command
strim mcp-config --codex      # prints the codex mcp add command
strim jobs list               # jobs on disk, no server needed
strim jobs show <id>
```

See [MCP.md](MCP.md). Whether delegation saves parent tokens is not proven.
