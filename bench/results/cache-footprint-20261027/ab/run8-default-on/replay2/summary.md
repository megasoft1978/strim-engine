# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8223 | qwen38-4bit | on | bench/results/cache-footprint-20261027/ab/run8-default-on/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4091 | 4.186 |
| 2 | 3 | 9346 | 5.620 |
| 3 | 5 | 14627 | 5.932 |
| 4 | 7 | 19884 | 6.212 |
| 5 | 9 | 25156 | 6.522 |
| 6 | 11 | 30378 | 6.771 |
| 7 | 13 | 35637 | 7.185 |
| 8 | 15 | 40838 | 7.435 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 49.864 | 49.864 | 0 |

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
| 1 | 61.0 |
| 2 | 72.8 |
| 3 | 62.4 |
| 4 | 63.2 |
| 5 | 57.7 |
| 6 | 56.9 |
| 7 | 55.1 |
| 8 | 53.8 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
