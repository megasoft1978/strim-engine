# bench — Phase 0 measurement harness

Everything here is throwaway measurement code, not product code.

## Environment

The system Python has the scientific stack (transformers 5.16.1, numpy, tokenizers,
huggingface_hub) but MLX 0.31.1. Phase 0 needs MLX 0.32.4 / mlx-lm 0.32.2, so the venv is
built with `--system-site-packages` and only the MLX wheels are installed locally:

Historical (Python env removed 2026-10-27; the repo has no Python tooling now):

```text
uv venv .venv-sprint --python /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 --system-site-packages
uv pip install --python .venv-sprint/bin/python --no-deps wheelhouse/*.whl
```

PyPI is throttled to ~200 KB/s per connection here, so the wheels in `wheelhouse/` were
fetched with `aria2c -x8` (4–20× faster). Same for the checkpoints:
`aria2c -x 4 -s 4 -k 1M -c -d <dir> -o <file> <url>` (direct URL `https://huggingface.co/<repo>/resolve/<revision>/<filename>`).
Python bench scripts (`download.py`, `speed.py`, `run_task.py`, `ref_*.py`) were removed; use `strim download`, `strim enginebench` / `strim bench http`, and `strim agentbench`.

## Scripts

| Script | Purpose |
|---|---|
| `prompt_seed.txt` | coding-ish text used to build 4k/16k/64k prompts |

## Commands

```sh
# speed and memory measurement: use `strim enginebench` / `strim bench http` (see docs/BENCH.md)
```

Results are appended as JSON lines to `--out`. Run one process at a time on a quiet
machine; record the checkpoint, quant, context, and whether anything else was running.

## `strim agentbench`: paid arms (P, M) and credentials

The paid arms run the real Claude Code under `sandbox-exec` with file tools only (no Bash; the harness runs the verify command
itself after the client exits). The sandbox must still let Claude read `~/.claude/.credentials.json` and reach the network to
log in, so a prompt-injected task repo could in principle make the client's own tool layer misuse them. Residual risk: the file
tools are denied for `~/.claude*` by permission rule, not by the sandbox. Run paid arms only on corpora you control. Arm M passes
the Strim bearer token through the `STRIM_MCP_TOKEN` environment variable; `mcp.json` holds no secret.
