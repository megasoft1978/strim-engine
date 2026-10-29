# Release gate

Run `packaging/release/release-gate.sh --out /path/to/empty-directory` from a clean tracked working tree. The default warm scratch is `/tmp/strim-build-e2e`; override it with `--scratch`. The gate copies it, runs all tests and the headless smoke test, then builds both products separately from a sanitized archive with stale build outputs removed. It packages, self-tests, checks versions and prints artifact hashes and timings. The output directory must be empty.

For a quick unsigned dry run, add `--skip-model`; this skips server inference and its version check. A full gate uses the existing `~/.strim/models/qwen38-4bit` model read-only. For a release supply `--sign "Developer ID Application: ..." --notarize <keychain-profile>`; this signs, notarizes and checks Gatekeeper acceptance. No upload, tag or publication is performed. The DMG is built headlessly without Finder layout.
