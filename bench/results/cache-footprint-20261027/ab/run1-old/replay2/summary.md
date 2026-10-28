# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8216 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run1-old/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.141 |
| 2 | 3 | 9348 | 6.624 |
| 3 | 5 | 14629 | 6.566 |
| 4 | 7 | 19886 | 6.162 |
| 5 | 9 | 25158 | 7.294 |
| 6 | 11 | 30380 | 6.715 |
| 7 | 13 | 35639 | 7.913 |
| 8 | 15 | 40840 | 7.343 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 52.757 | 52.757 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 32.9% |
| 3 | 59.8% |
| 4 | 73.5% |
| 5 | 76.4% |
| 6 | 82.8% |
| 7 | 83.5% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 59.7 |
| 2 | 66.0 |
| 3 | 62.5 |
| 4 | 56.6 |
| 5 | 58.1 |
| 6 | 53.3 |
| 7 | 54.6 |
| 8 | 50.3 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
