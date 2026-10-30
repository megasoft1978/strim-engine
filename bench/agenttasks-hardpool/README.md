# Combined hard task pool

This pool combines the hard benchmark tasks in one directory for offline agentbench validation and Strim evolution loading. Task directories are copied under `tasks/`; `manifest.json` at the pool root records their metadata and aggregate counts.

## Origins

- `hd-js-*`, `hd-rx-*`, `hd-ts-*`: `bench/agenttasks-hard-js`, `bench/agenttasks-hard-rx`, and `bench/agenttasks-hard-ts`.
- `hd2-fs-*`, `hd2-rx-*`, `hd2-js-01`, `hd2-ts-01`: `bench/agenttasks-hard2-fs`, `bench/agenttasks-hard2-rx`, and `bench/agenttasks-hard2-tsjs`.
- `h3-*`: `bench/agenttasks-hard3-gors`, `bench/agenttasks-hard3-pyrbjv`, and `bench/agenttasks-hard3-webswift`.
- `rx-01`: `bench/agenttasks/tasks/rx-01`; included because it was part of `/tmp/ev1/pool`.

## Validate

Run the offline validator with caches and temporary files under `/tmp/hp1`:

```sh
TMPDIR=/tmp/hp1 GOCACHE=/tmp/hp1/go-cache GOPATH=/tmp/hp1/gopath GOPROXY=off .build/debug/strim agentbench validate --tasks-dir bench/agenttasks-hardpool
```

If `.build/debug/strim` is unavailable or stale, build it offline with `swift build --scratch-path /tmp/hp1/build --product strim` and use `/tmp/hp1/build/debug/strim`.
