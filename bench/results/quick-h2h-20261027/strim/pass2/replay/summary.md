# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | bench/results/quick-h2h-20261027/strim/pass2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4090 | 4.087 |
| 2 | 3 | 9345 | 6.589 |
| 3 | 5 | 14626 | 6.523 |
| 4 | 7 | 19883 | 6.155 |
| 5 | 9 | 25155 | 7.255 |
| 6 | 11 | 30377 | 6.704 |
| 7 | 13 | 35636 | 7.865 |
| 8 | 15 | 40837 | 7.350 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 52.528 | 52.528 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 32.9% |
| 3 | 59.7% |
| 4 | 73.5% |
| 5 | 76.4% |
| 6 | 82.8% |
| 7 | 83.5% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 58.2 |
| 2 | 64.4 |
| 3 | 61.8 |
| 4 | 59.7 |
| 5 | 57.5 |
| 6 | 52.4 |
| 7 | 54.6 |
| 8 | 49.7 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
