#!/usr/bin/env bash
# Run Codex and/or Claude Code against the local Strim endpoint.
#
#   scripts/agents.sh env                 print the exports
#   scripts/agents.sh codex "prompt"     Codex CLI against strim
#   scripts/agents.sh claude "prompt"    Claude Code against strim
#   scripts/agents.sh both "prompt"      both, in parallel
#   scripts/agents.sh mcp-install        register Strim as an MCP server in both CLIs
#
# STRIM_MODEL=<dir>      model dir (default models/qwen38-4bit)
# STRIM_HEAD=<dir>       MTP head dir (default models/qwen38-mtp-4bit)
# STRIM_MODE=<model id>  model name sent to the client (default: basename of STRIM_MODEL)
# STRIM_PORT=8203        (default, `strim serve` default)
# STRIM_TOKEN_FILE       bearer token (default ~/.strim/token, written by `strim serve`)
# STRIM_UNSAFE_LOCAL_AGENT=1  run claude with --dangerously-skip-permissions (off by default; disposable checkouts only)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${STRIM_PORT:-8203}"
BASE="http://127.0.0.1:${PORT}"
BIN="$ROOT/.build/release/strim"
MODEL_DIR="${STRIM_MODEL:-$ROOT/models/qwen38-4bit}"
HEAD_DIR="${STRIM_HEAD:-$ROOT/models/qwen38-mtp-4bit}"
MODE="${STRIM_MODE:-$(basename "$MODEL_DIR")}"
TOKEN_FILE="${STRIM_TOKEN_FILE:-$HOME/.strim/token}"
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

ensure_server() {
  if ! curl -sf --max-time 3 "$BASE/health" >/dev/null 2>&1; then
    echo "[strim] starting strim serve on :$PORT"
    mkdir -p "$ROOT/logs"
    [ -x "$BIN" ] || { echo "[strim] build first: swift build -c release --disable-sandbox" >&2; return 1; }
    (cd "$ROOT" && nohup "$BIN" serve "$MODEL_DIR" "$HEAD_DIR" --port "$PORT" --token-file "$TOKEN_FILE" \
      > logs/strim-serve.out 2>&1 &)
    for _ in $(seq 1 120); do
      curl -sf --max-time 2 "$BASE/health" >/dev/null 2>&1 && return 0
      sleep 0.5
    done
    echo "[strim] server did not start; see $ROOT/logs/strim-serve.out" >&2
    return 1
  fi
}

token() { tr -d '\n' < "$TOKEN_FILE"; }

codex_cmd() {
  ensure_server
  OPENAI_API_KEY="$(token)" codex exec --skip-git-repo-check \
    -c model_provider=local \
    -c 'model_providers.local={name="Strim",base_url="'"$BASE"'/v1",env_key="OPENAI_API_KEY",wire_api="responses"}' \
    -m "$MODE" "$@"
}

claude_cmd() {
  ensure_server
  # Default: Claude Code applies its normal permission rules. The local model reads untrusted workspace files, so
  # bypassing permissions lets any file steer it into running arbitrary commands as you. Opt in explicitly.
  local perm=() cfg="$CLAUDE_HOME"
  if [ "${STRIM_UNSAFE_LOCAL_AGENT:-}" = "1" ]; then
    echo "[strim] WARNING: STRIM_UNSAFE_LOCAL_AGENT=1 runs claude with --dangerously-skip-permissions against a local model;" >&2
    echo "[strim] any file in the workspace can make it run commands as your user. Use a disposable checkout only." >&2
    perm=(--dangerously-skip-permissions)
    cfg="$(mktemp -d "${TMPDIR:-/tmp}/strim-claude-cfg.XXXXXX")"  # throwaway config dir, not your real ~/.claude
  fi
  ANTHROPIC_BASE_URL="$BASE" \
  ANTHROPIC_AUTH_TOKEN="$(token)" \
  ANTHROPIC_API_KEY="$(token)" \
  ANTHROPIC_MODEL="$MODE" \
  CLAUDE_CONFIG_DIR="$cfg" \
  claude ${perm[@]+"${perm[@]}"} "$@"
}

case "${1:-}" in
  env)
    cat <<ENV
export OPENAI_BASE_URL=$BASE/v1
export OPENAI_API_KEY=\$(cat $TOKEN_FILE)
export ANTHROPIC_BASE_URL=$BASE
export ANTHROPIC_AUTH_TOKEN=\$(cat $TOKEN_FILE)
export ANTHROPIC_MODEL=$MODE
export CLAUDE_CONFIG_DIR=$CLAUDE_HOME
# Codex needs a provider block (Responses API), not just OPENAI_BASE_URL:
codex exec -c model_provider=local \\
  -c 'model_providers.local={name="Strim",base_url="$BASE/v1",env_key="OPENAI_API_KEY",wire_api="responses"}' \\
  -m $MODE "your prompt"
ENV
    ;;
  codex)
    shift; codex_cmd "$@"
    ;;
  claude)
    shift; claude_cmd -p "$@"
    ;;
  mcp)
    cat <<MCP
Register Strim as an MCP server:

  Claude Code:
    claude mcp add --transport http strim $BASE/mcp

  Codex (~/.codex/config.toml):
    [mcp_servers.strim]
    url = "$BASE/mcp"

Tools: strim_summarize, strim_review_diff, strim_explain_error,
       strim_draft_patch, strim_generate_tests, strim_classify,
       plus strim_status / strim_switch.
MCP
    ;;
  mcp-install)
    ensure_server
    cp ~/.codex/config.toml ~/.codex/config.toml.bak.$(date +%s) 2>/dev/null || true
    if ! grep -q "\[mcp_servers.strim\]" ~/.codex/config.toml 2>/dev/null; then
      printf '\n[mcp_servers.strim]\nurl = "%s/mcp"\n' "$BASE" >> ~/.codex/config.toml
      echo "[strim] added MCP server to ~/.codex/config.toml"
    fi
    CLAUDE_CONFIG_DIR="$CLAUDE_HOME" claude mcp add --transport http strim "$BASE/mcp" 2>/dev/null \
      && echo "[strim] registered MCP server in Claude Code ($CLAUDE_HOME)" || true
    ;;
  both)
    shift
    ensure_server
    tmp=$(mktemp -d)
    ( codex_cmd "$@" >"$tmp/codex.out" 2>&1 ) & p1=$!
    ( claude_cmd -p "$@" >"$tmp/claude.out" 2>&1 ) & p2=$!
    wait $p1 || true; wait $p2 || true
    echo "===== codex ====="; cat "$tmp/codex.out"
    echo "===== claude ====="; cat "$tmp/claude.out"
    rm -rf "$tmp"
    ;;
  *)
    sed -n '2,10p' "$0"; exit 1
    ;;
esac
