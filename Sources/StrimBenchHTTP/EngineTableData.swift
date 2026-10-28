import Foundation

/// Engine launch recipes as data (from bench/final_run.py `ENGINES` and bench/final_all.sh).
/// Embedded as JSON because SwiftPM resources need a Package.swift declaration; `--engines-file` overrides it.
/// Placeholders: ${ROOT} repo root, ${SCRATCH} scratch dir, ${MODEL} ${HEAD} ${GGUF} ${PORT} from `vars`.
public enum EngineTableData {
    public static let json = #"""
{
 "vars": {
  "MODEL": "models/qwen38-4bit",
  "HEAD": "models/qwen38-mtp-4bit",
  "GGUF": "models/gguf/Qwen3.8-27B-Q4_K_M.gguf",
  "PORT": "8651"
 },
 "scratch_default": "/private/tmp/claude-501/final-20261026-scratch",
 "engines": {
  "strim": {
   "port": 8203,
   "cache": "default (STRIM_PREFIX_CACHE_MB default 12288)",
   "quant": "MLX 4-bit + MTP head",
   "cmd": [
    ".build/release/strim",
    "serve",
    "${MODEL}",
    "${HEAD}",
    "--port",
    "8203",
    "--no-auth"
   ]
  },
  "rapid-mlx": {
   "port": 8651,
   "cache": "default on",
   "quant": "MLX 4-bit + MTP head",
   "cmd": [
    "rapid-mlx",
    "--no-telemetry",
    "serve",
    "${MODEL}",
    "--port",
    "${PORT}",
    "--max-num-seqs",
    "4",
    "--speculative-config",
    "{\"method\":\"mtp\",\"model\":\"${HEAD}\"}"
   ]
  },
  "mlx-lm": {
   "port": 8651,
   "cache": "default on",
   "quant": "MLX 4-bit (no MTP)",
   "cmd": [
    "${ROOT}/.venv-sprint/bin/mlx_lm.server",
    "--model",
    "${MODEL}",
    "--port",
    "${PORT}",
    "--decode-concurrency",
    "4",
    "--prompt-concurrency",
    "4"
   ]
  },
  "tensorfold": {
   "port": 8651,
   "cache": "default on",
   "quant": "MLX 4-bit",
   "cmd": [
    "tensorfold",
    "serve",
    "${MODEL}",
    "--port",
    "${PORT}",
    "--parallel",
    "4",
    "--no-update-check"
   ]
  },
  "tensorfold-ctx64k": {
   "port": 8651,
   "cache": "default on",
   "quant": "MLX 4-bit (supplemental: --context 65536)",
   "cmd": [
    "tensorfold",
    "serve",
    "${MODEL}",
    "--port",
    "${PORT}",
    "--parallel",
    "4",
    "--no-update-check",
    "--context",
    "65536"
   ]
  },
  "omlx": {
   "port": 8651,
   "cache": "default on",
   "quant": "MLX 4-bit (qwen38-4bit linked into omlx model dir)",
   "env": {
    "HOME": "${SCRATCH}/omlx-home"
   },
   "prepare": [
    {
     "mkdir": "${SCRATCH}/omlx-home"
    },
    {
     "mkdir": "${SCRATCH}/omlx-models"
    },
    {
     "symlink": "${SCRATCH}/omlx-models/qwen38-4bit",
     "to": "${ROOT}/${MODEL}"
    }
   ],
   "cmd": [
    "omlx",
    "serve",
    "--model-dir",
    "${SCRATCH}/omlx-models",
    "--port",
    "${PORT}"
   ]
  },
  "mlx-vlm": {
   "port": 8651,
   "cache": "default",
   "quant": "MLX 4-bit",
   "cmd": [
    "${ROOT}/.venv-sprint/bin/mlx_vlm.server",
    "--model",
    "${ROOT}/${MODEL}",
    "--port",
    "${PORT}"
   ]
  },
  "llama.cpp": {
   "port": 8080,
   "cache": "--cache-prompt --cache-ram 8192",
   "quant": "GGUF Q4_K_M",
   "cmd": [
    "llama-server",
    "-m",
    "${ROOT}/${GGUF}",
    "-ngl",
    "all",
    "-fa",
    "on",
    "-c",
    "65536",
    "-np",
    "2",
    "--cache-prompt",
    "--cache-ram",
    "8192",
    "--jinja",
    "--host",
    "127.0.0.1",
    "--port",
    "8080"
   ]
  },
  "ollama": {
   "port": 11435,
   "cache": "default (ollama prompt reuse per slot)",
   "quant": "GGUF Q4_K_M (imported via Modelfile)",
   "probe": "/api/version",
   "env": {
    "OLLAMA_HOST": "127.0.0.1:11435",
    "OLLAMA_MODELS": "${SCRATCH}/ollama-models",
    "OLLAMA_NUM_PARALLEL": "2",
    "OLLAMA_CONTEXT_LENGTH": "65536",
    "OLLAMA_KEEP_ALIVE": "2h",
    "OLLAMA_FLASH_ATTENTION": "1",
    "OLLAMA_NOPRUNE": "1"
   },
   "cmd": [
    "ollama",
    "serve"
   ],
   "post_ready": {
    "kind": "ollama_create",
    "name": "qwen38-27b-q4km",
    "gguf": "${ROOT}/${GGUF}",
    "num_ctx": 65536,
    "stop": "<|im_end|>",
    "modelfile": "${SCRATCH}/Modelfile"
   },
   "cleanup": [
    "ollama",
    "rm",
    "qwen38-27b-q4km"
   ]
  }
 },
 "ollama_template": "{{- range .Messages }}\n{{- if eq .Role \"user\" }}<|im_start|>user\n{{ .Content }}<|im_end|>\n{{ else if eq .Role \"assistant\" }}<|im_start|>assistant\n{{ .Content }}{{ range .ToolCalls }}\n<tool_call>\n{\"name\": \"{{ .Function.Name }}\", \"arguments\": {{ .Function.Arguments }}}\n</tool_call>{{ end }}<|im_end|>\n{{ else if eq .Role \"tool\" }}<|im_start|>user\n<tool_response>\n{{ .Content }}\n</tool_response><|im_end|>\n{{ else }}<|im_start|>{{ .Role }}\n{{ .Content }}<|im_end|>\n{{ end }}{{ end }}<|im_start|>assistant\n<think>\n\n</think>\n\n",
 "schedule": [
  {
   "engine": "strim",
   "pass": 1,
   "sb_reps": 2,
   "replay_reps": 2
  },
  {
   "engine": "rapid-mlx",
   "pass": 1,
   "sb_reps": 2,
   "replay_reps": 2
  },
  {
   "engine": "strim",
   "pass": 2,
   "sb_reps": 2,
   "replay_reps": 2
  },
  {
   "engine": "rapid-mlx",
   "pass": 2,
   "sb_reps": 2,
   "replay_reps": 2
  },
  {
   "engine": "mlx-lm",
   "pass": 1,
   "sb_reps": 3,
   "replay_reps": 3
  },
  {
   "engine": "tensorfold",
   "pass": 1,
   "sb_reps": 3,
   "replay_reps": 3
  },
  {
   "engine": "omlx",
   "pass": 1,
   "sb_reps": 3,
   "replay_reps": 3
  },
  {
   "engine": "mlx-vlm",
   "pass": 1,
   "sb_reps": 3,
   "replay_reps": 3
  },
  {
   "engine": "llama.cpp",
   "pass": 1,
   "sb_reps": 3,
   "replay_reps": 3
  },
  {
   "engine": "ollama",
   "pass": 1,
   "sb_reps": 3,
   "replay_reps": 3
  }
 ]
}
"""#
}
