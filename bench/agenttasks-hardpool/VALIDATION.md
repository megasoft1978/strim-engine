# Offline validation

Validated with:

```sh
TMPDIR=/tmp/hp1 GOCACHE=/tmp/hp1/go-cache GOPATH=/tmp/hp1/gopath GOPROXY=off .build/debug/strim agentbench validate --tasks-dir bench/agenttasks-hardpool
```

All tasks reported `fails` for the broken snapshot and `passes` after applying the reference solution. Every result was `OK`; no failures or validator errors occurred. Seconds are the validator's displayed whole-second broken/solved durations.

| Task | Language | Class | Validator | Broken / solved seconds |
|---|---|---|---|---:|
| h3-go-01 | go | test-fix | OK | 2 / 2 |
| h3-go-02 | go | feature-impl | OK | 2 / 2 |
| h3-go-03 | go | test-fix | OK | 2 / 4 |
| h3-js-01 | javascript | test-fix | OK | 0 / 0 |
| h3-js-02 | javascript | feature-impl | OK | 0 / 0 |
| h3-jv-01 | java | feature-impl | OK | 1 / 1 |
| h3-jv-02 | java | test-fix | OK | 1 / 1 |
| h3-py-01 | python | test-fix | OK | 0 / 0 |
| h3-py-02 | python | feature-impl | OK | 0 / 0 |
| h3-rb-01 | ruby | test-fix | OK | 1 / 0 |
| h3-rs-01 | rust | test-fix | OK | 4 / 3 |
| h3-rs-02 | rust | feature-impl | OK | 3 / 4 |
| h3-rx-01 | react | test-fix | OK | 1 / 0 |
| h3-sw-01 | swift | test-fix | OK | 26 / 24 |
| h3-ts-01 | typescript | feature-impl | OK | 0 / 0 |
| h3-ts-02 | typescript | test-fix | OK | 0 / 0 |
| hd-js-01 | javascript | test-fix | OK | 0 / 0 |
| hd-js-02 | javascript | feature-impl | OK | 0 / 0 |
| hd-js-03 | javascript | test-fix | OK | 0 / 0 |
| hd-rx-01 | react | test-fix | OK | 0 / 0 |
| hd-rx-02 | react | feature-impl | OK | 0 / 0 |
| hd-rx-03 | react | test-fix | OK | 0 / 0 |
| hd-ts-01 | typescript | test-fix | OK | 0 / 0 |
| hd-ts-02 | typescript | feature-impl | OK | 0 / 0 |
| hd-ts-03 | typescript | test-fix | OK | 0 / 0 |
| hd2-fs-01 | react | test-fix | OK | 0 / 0 |
| hd2-fs-02 | react | feature-impl | OK | 0 / 0 |
| hd2-js-01 | javascript | feature-impl | OK | 0 / 0 |
| hd2-rx-01 | react | test-fix | OK | 0 / 0 |
| hd2-rx-02 | react | feature-impl | OK | 0 / 0 |
| hd2-ts-01 | typescript | test-fix | OK | 0 / 0 |
| rx-01 | react | test-fix | OK | 0 / 0 |

`strim evolve run --dry-run` also loaded the pool with a one-task split (`hd-js-01` in train, empty val/test), using one coordinate and one round. It executed three fake runs and exited via the expected no-validation-gain kill rule (exit 6); no model or server was started.

The requested 31 named hard tasks plus `rx-01` from `/tmp/ev1/pool` make 32 tasks total. The isolated Swift rebuild was stopped when it attempted to clone an uncached Git submodule; the existing `.build/debug/strim` binary completed both offline commands successfully.
