# Agent replay summary

- fixture: `bench/results/h2h-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 2; session tag on
- order per rep: rep0: strim-on; rep1: strim-on
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim-on | http://127.0.0.1:8203 | qwen38-4bit | on | bench/results/h2h-20261026/logs/strim-on-default.server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim-on |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.106 |
| 2 | 3 | 9348 | 6.545 |
| 3 | 5 | 14629 | 5.965 |
| 4 | 7 | 19886 | 6.464 |
| 5 | 9 | 25158 | 7.002 |
| 6 | 11 | 30380 | 7.419 |
| 7 | 13 | 35639 | 7.988 |
| 8 | 15 | 40840 | 8.489 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim-on | 53.978 | 53.893 / 54.064 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim-on |
| --- | --- |
| 1 | 0.0% |
| 2 | 32.9% |
| 3 | 63.0% |
| 4 | 72.1% |
| 5 | 77.3% |
| 6 | 80.9% |
| 7 | 83.3% |
| 8 | 85.2% |

## Decode tok/s per turn (median over reps)

| turn | strim-on |
| --- | --- |
| 1 | 59.2 |
| 2 | 69.5 |
| 3 | 65.5 |
| 4 | 62.7 |
| 5 | 54.4 |
| 6 | 52.5 |
| 7 | 50.0 |
| 8 | 47.3 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
