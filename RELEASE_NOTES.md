# Strim 0.1.1

## What's in 0.1.1

- Fixed parsing of responses with a stray `</think>` tag.
- Redesigned the menu bar app and added live screenshots.
- Redesigned the website and README.
- Added `strim pull` for downloading model files with pinned revisions, resume support, and hash verification.
- Added a macOS DMG and Homebrew cask for the app.

## Install

- CLI with Homebrew: `brew install megasoft1978/strim/strim`
- App with Homebrew: `brew install --cask megasoft1978/strim/strim-app`
- CLI with curl: `curl -fsSL https://raw.githubusercontent.com/megasoft1978/strim-engine/main/packaging/install.sh | bash`
- App DMG: download `Strim-0.1.1-arm64.dmg` from the [latest release](https://github.com/megasoft1978/strim-engine/releases/latest) and move Strim to Applications.

The app is ad-hoc signed and not notarized. If Gatekeeper blocks it, choose **Open Anyway** in System Settings > Privacy & Security, or run `xattr -dr com.apple.quarantine /Applications/Strim.app`.

After installing, download the model with `strim pull`.

## Benchmarks

On an M5 Max with 64 GB, Strim 0.1.1 was compared with rapid-mlx 0.15.7, mlx-vlm 0.7.10, mlx-lm 0.32.2, and oMLX 0.4.5.dev1. Strim decoded at 75.3, 65.2, and 52.2 tok/s at 4K, 16K, and 32K context, versus rapid-mlx's 50.1, 45.7, and 42.2; cold prefill was 994, 963, and 885 tok/s versus mlx-vlm's 1,017, 988, and 923, with TTFT of 4.13, 17.02, and 37.06 s versus 4.04, 16.59, and 35.51 s. Strim therefore trails mlx-vlm by 2–4% on cold prefill and TTFT, and loses c=4 short-prompt aggregate throughput to rapid-mlx by 3.5%; it wins decode and p50 TTFT in the measured contexts. oMLX has unavailable cells where its memory guard aborted or declined runs. Full results and methodology: [benchmarks](https://megasoft1978.github.io/strim-engine/benchmarks.html).

## Known limits

- Cold prefill is 2–4% behind mlx-vlm in the measured contexts.
- Some oMLX benchmark cells are unavailable because its memory guard aborted or declined runs.
- The DMG is not notarized.
- Benchmarks cover one model.
