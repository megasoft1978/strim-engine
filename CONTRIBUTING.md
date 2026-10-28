# Contributing

Strim is a Swift inference engine and local agent harness for Apple Silicon (macOS 14+, Swift 6.0
tools version). Issues and pull requests are welcome; for anything larger than a small fix, open an
issue first.

## Build and test

```sh
swift build -c release --disable-sandbox     # .build/release/strim
swift test --disable-sandbox                 # unit and parity tests
```

`--disable-sandbox` is the flag used throughout the docs for builds that run Metal and MLX.

Quick smoke while iterating (no GPU or model needed for most targets):

```sh
swift test --disable-sandbox --filter StrimControlTests
swift test --disable-sandbox --filter StrimHarnessTests
swift test --disable-sandbox --filter StrimAgentBenchTests
```

`StrimTokenizerTests` and `StrimPromptTests` read the Qwen tokenizer from `models/qwen38-4bit`.
Model weights are not part of this repository and are git-ignored (`models/`); download them
yourself (see `README.md` and `docs/HANDOFF.md`). GPU gates (`strim checkprefix`, `strim
enginebench`) are listed in `README.md` under "Testing and gates".

## Guidelines

- Keep changes small and focused; add or update a test for behaviour changes.
- Do not weaken a test, tolerance or golden to make it pass. Parity fixtures in `bench/fixtures/`
  were generated from Hugging Face by generator scripts that are not published; the JSON fixtures are frozen data.
- Benchmark claims need raw data under `bench/results/` and a matching entry in
  `site/data/results.json`; `strim site check` verifies that.
- Do not commit model weights, tokens, logs or local paths. Run logs are git-ignored.
- By contributing you agree your work is licensed under the MIT License (`LICENSE`).

## Security issues

Report them privately, see `SECURITY.md`.
