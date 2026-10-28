# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8219 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run4-new/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4089 | 4.175 |
| 2 | 3 | 9344 | 5.594 |
| 3 | 5 | 14625 | 5.901 |
| 4 | 7 | 19882 | 6.200 |
| 5 | 9 | 25154 | 6.535 |
| 6 | 11 | 30376 | 6.764 |
| 7 | 13 | 35635 | 7.181 |
| 8 | 15 | 40836 | 7.399 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 49.749 | 49.749 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.7% |
| 3 | 63.8% |
| 4 | 73.5% |
| 5 | 79.0% |
| 6 | 82.8% |
| 7 | 85.2% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 67.1 |
| 2 | 73.3 |
| 3 | 62.6 |
| 4 | 63.7 |
| 5 | 58.3 |
| 6 | 56.1 |
| 7 | 55.3 |
| 8 | 53.7 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
