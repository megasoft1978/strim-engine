# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: omlx
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| omlx | http://127.0.0.1:8653 | qwen38-4bit | on | bench/results/h2h-final3-20261028/omlx/pass1/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | omlx |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.478 |
| 2 | 3 | 9348 | 8.213 |
| 3 | 5 | 14629 | 7.747 |
| 4 | 7 | 19886 | 7.142 |
| 5 | 9 | 25158 | 8.955 |
| 6 | 11 | 30380 | 8.365 |
| 7 | 13 | 35639 | 10.375 |
| 8 | 15 | 40840 | 9.645 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| omlx | 64.921 | 64.921 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | omlx |
| --- | --- |
| 1 | 0.0% |
| 2 | 21.9% |
| 3 | 56.0% |
| 4 | 72.1% |
| 5 | 73.3% |
| 6 | 80.9% |
| 7 | 80.5% |
| 8 | 85.2% |

## Decode tok/s per turn (median over reps)

| turn | omlx |
| --- | --- |
| 1 | 34.8 |
| 2 | 34.7 |
| 3 | n/a |
| 4 | n/a |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 6.
