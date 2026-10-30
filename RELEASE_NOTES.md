# Strim 0.1.7

## What's in 0.1.7

- Faster with several requests at once: about 10% more total decode throughput at 8 concurrent requests on M5-class Macs (MLX kernel tuning; outputs identical; single-request speed unchanged).
- Tool calls: a call cut off in the middle is no longer executed; everything else parses as before.
- Server: an explicit `enable_thinking` in a request is now respected (omitted keeps the default).
- Opt-in "thinking on every turn" for the agent (pack `knobs.json`: `"thinking": "all_turns"`, `"reasoningEffort"`): in our agent benchmark it solved more tasks (21/23 vs 16/21) but took about 3x longer, so it stays off by default.
- Benchmarks: the local agent benchmark runs out of the box; Bun/TypeScript task checks fixed.

## Also in 0.1.6

Stability release: every release now goes through one automated gate (all tests, a headless end-to-end run, a clean build, and a self-test of the packaged app with the real model).

- Chat: a reply that ends through the agent's finish step no longer shows up empty.
- Server start: clear messages for a missing model or binary, an early crash shows its log lines, no duplicate servers, the window stays responsive while starting.
- Settings: a corrupt `~/.strim/app.json` is backed up instead of lost; one bad value no longer resets everything; "Default thinking" and "MTP: None" are saved.
- Quit: stops only the server this app started (verified before any signal), force-stops a hung server, cancels downloads, finishes within 4 seconds; relaunch never starts a second server.
- Errors: accurate messages for every server and network error (no raw codes, no misleading "loopback only").
- Chat history: corrupt files are backed up, a truncated history keeps every complete message.
- `strim doctor` checks your install: duplicate or stale Strim.app copies, version mismatches, an app or server running from the wrong place.
- `Strim --selftest <dir>`: headless self-check of the installed app.
- Fixed a race that could make approving a job fail under load.

## Also in 0.1.5

- Folder access: a project can live anywhere on disk. Opening a folder outside your home folder asks once ("Allow Strim to read, change files and run commands in this folder?"). Strim still works in an isolated copy and every change comes back as a patch you review in Jobs. Granted folders show a lock, can be revoked from the project menu or Settings, and survive restarts. Only the app can grant access; agents and MCP clients cannot. Credential folders (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.strim`) and system folders are always refused.
- Starting a second `strim serve` no longer kills the first one's running job processes.
- Headless app smoke test (`scripts/app-smoke.sh`, about a minute, no windows).

## Also in 0.1.4

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
