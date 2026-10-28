# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /tmp/perfval/new2-r2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.241 |
| 2 | 3 | 9348 | 5.681 |
| 3 | 5 | 14629 | 6.281 |
| 4 | 7 | 19886 | 6.427 |
| 5 | 9 | 25158 | 7.105 |
| 6 | 11 | 30380 | 7.072 |
| 7 | 13 | 35639 | 7.760 |
| 8 | 15 | 40840 | 10.185 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 54.753 | 54.753 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 62.9% |
| 4 | 73.5% |
| 5 | 78.5% |
| 6 | 82.8% |
| 7 | 84.9% |
| 8 | 86.7% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 66.4 |
| 2 | 65.0 |
| 3 | 46.4 |
| 4 | 59.7 |
| 5 | 49.6 |
| 6 | 47.8 |
| 7 | 19.2 |
| 8 | 48.8 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
