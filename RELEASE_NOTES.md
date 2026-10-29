# Strim 0.1.4

## What's in 0.1.4

- Quitting the app stops the server it started, so the model no longer stays in memory after Quit.
- A refused chat (for example a project folder outside your home folder, which the host does not allow unless `mcp.allowedRoots` is set) now shows the host's reason instead of "loopback only".

## Also in 0.1.3

- Starting the server needs no manual setup: a blank or missing model path in `~/.strim/app.json` now means the default model, and the first-run download flow covers a missing model.
- Corrected release build: the 0.1.2 app and DMG were built from stale compiled output and showed the old UI. 0.1.3 is a clean rebuild; if you installed 0.1.2 from the DMG or cask, update.

## Also in 0.1.2

- The app, the DMG and the `strim` binary are signed with a Developer ID and notarized by Apple. The DMG opens without a Gatekeeper warning.
- Tool results in chat keep their line breaks (secrets are still redacted before the text is clipped).

Everything in 0.1.1 is included: the redesigned app with per-project chats and a first-run model download, the redesigned website and README, `strim pull` with pinned revisions, resume and hash verification, and the DMG and Homebrew cask.

## Install

- CLI with Homebrew: `brew install megasoft1978/strim/strim`
- App with Homebrew: `brew install --cask megasoft1978/strim/strim-app`
- CLI with curl: `curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash`
- App DMG: download `Strim-0.1.4-arm64.dmg` from the [latest release](https://github.com/megasoft1978/strim-engine/releases/latest) and move Strim to Applications.

After installing, download the model with `strim pull`.

## Benchmarks

On an M5 Max with 64 GB, Strim was compared with rapid-mlx 0.15.7, mlx-vlm 0.7.10, mlx-lm 0.32.2, and oMLX 0.4.5.dev1. Strim decoded at 75.3, 65.2, and 52.2 tok/s at 4K, 16K, and 32K context, versus rapid-mlx's 50.1, 45.7, and 42.2; cold prefill was 994, 963, and 885 tok/s versus mlx-vlm's 1,017, 988, and 923, with TTFT of 4.13, 17.02, and 37.06 s versus 4.04, 16.59, and 35.51 s. Strim therefore trails mlx-vlm by 2–4% on cold prefill and TTFT, and loses c=4 short-prompt aggregate throughput to rapid-mlx by 3.5%; it wins decode and p50 TTFT in the measured contexts. oMLX has unavailable cells where its memory guard aborted or declined runs. Full results and methodology: [benchmarks](https://megasoft1978.github.io/strim-engine/benchmarks.html).

## Known limits

- Cold prefill is 2–4% behind mlx-vlm in the measured contexts.
- Some oMLX benchmark cells are unavailable because its memory guard aborted or declined runs.
- Benchmarks cover one model.
