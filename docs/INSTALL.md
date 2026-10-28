# Install

Apple Silicon only, macOS 14 (Sonoma) or newer. Tested only on a 64 GB M5 Max.

## 1. Homebrew (recommended)

```sh
brew install megasoft1978/strim/strim
strim pull && strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
```

## 2. curl installer

No sudo; installs to `~/.local/strim`, command in `~/.local/bin/strim`.

```sh
curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash
# options: --version 0.1.0   --prefix DIR
```

The tarball is checked against its published SHA-256 before anything is installed.

## 3. From source (developers)

Needs Xcode with the Swift 6 toolchain.

```sh
git clone https://github.com/megasoft1978/strim-engine && cd strim-engine
swift build -c release --disable-sandbox
.build/release/strim --version
```

## Model download

```sh
strim pull          # 4-bit text model + MTP head, about 16.3 GB, into ~/.strim/models
strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
```

`strim pull` prints the exact `strim serve` line when it finishes. It downloads from Hugging Face at pinned commit revisions (never `main`), uses up to 4 parallel connections per large shard, resumes interrupted runs (`.part` files, atomic rename), verifies every file against the published SHA-256 (git blob SHA-1 for small files) and refuses to start with less than the download size plus 5 GB free. It fetches only what the loader reads: config, generation config, tokenizer, chat template and the safetensors with their index. `HF_TOKEN`, if set, is sent as a bearer token and never printed. Progress goes to stderr (a single updating line on a terminal, one line per file otherwise).

```sh
strim pull --list                    # tiers, sizes, repos, pinned revisions
strim pull --tier 6bit|8bit|oq4e     # other quantizations
strim pull --dir /Volumes/X/models   # default ~/.strim/models
strim pull --verify                  # re-hash files already on disk
strim pull --revision-lock           # refuse to replace a directory pulled at a different revision
strim doctor                         # GPU smoke test (matmul) and model directory status
```

Re-running `strim pull` skips files that are already complete. The first run over a directory that was not pulled by `strim pull` (for example from the manual loop below) hashes the existing files once and records `.strim-pull.json`. The model id the API reports is the directory name (`qwen38-4bit`).

Memory: only 4-bit has a measured peak (about 31 GB on a 64 GB M5 Max). 6-bit, 8-bit and oq4e are larger on disk and their peaks are not measured.

`strim --version` prints the version and the built-in model defaults without touching the GPU.

### Fallback for flaky links

If `strim pull` cannot get through (proxy, captive network), download the same files by hand. This pulls `main`, not the pinned revision; run `strim pull` afterwards to verify the files against the pinned hashes (a mismatch is re-downloaded).

```sh
brew install aria2   # or use curl -L -C - -O
M=~/.strim/models
dl() { # <repo> <dir> <file>...
  repo=$1; dir=$M/$2; shift 2; mkdir -p "$dir"
  for f in "$@"; do aria2c -x 4 -s 4 -k 1M -c -d "$dir" -o "$f" "https://huggingface.co/$repo/resolve/main/$f"; done
}
dl mlx-community/Qwen3.8-27B-4bit qwen38-4bit \
  config.json generation_config.json chat_template.jinja tokenizer.json tokenizer_config.json model.safetensors.index.json \
  model-00001-of-00003.safetensors model-00002-of-00003.safetensors model-00003-of-00003.safetensors
dl mlx-community/Qwen3.8-27B-MTP-4bit qwen38-mtp-4bit \
  config.json chat_template.jinja tokenizer.json tokenizer_config.json model.safetensors.index.json model.safetensors
```

## First run

```sh
strim serve ~/.strim/models/qwen38-4bit ~/.strim/models/qwen38-mtp-4bit --port 8203
curl -s http://127.0.0.1:8203/health
TOKEN="$(cat ~/.strim/token)"   # created on first start, mode 0600
curl -s http://127.0.0.1:8203/v1/chat/completions -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"model":"qwen38-4bit","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'
```

The server binds to 127.0.0.1 only. State lives in `~/.strim` (token, control-token, packs, jobs, worktrees, logs, cache); uninstalling does not remove it.

## Requirements

- Apple Silicon, macOS 14+.
- Memory: measured only on a 64 GB machine (4-bit, peak about 31 GB). Use a 64 GB Mac. Smaller memory tiers and other quantizations are not supported yet.
