# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: rapid-mlx
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| rapid-mlx | http://127.0.0.1:8651 | models/qwen38-4bit | on | bench/results/h2h-final3-20261028/rapid-mlx/pass2/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | rapid-mlx |
| --- | --- | --- | --- |
| 1 | 1 | 4095 | 4.088 |
| 2 | 3 | 9350 | 5.533 |
| 3 | 5 | 14631 | 5.869 |
| 4 | 7 | 19888 | 6.070 |
| 5 | 9 | 25160 | 6.503 |
| 6 | 11 | 30382 | 6.663 |
| 7 | 13 | 35641 | 7.101 |
| 8 | 15 | 40842 | 7.219 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| rapid-mlx | 49.046 | 49.046 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | rapid-mlx |
| --- | --- |
| 1 | unknown |
| 2 | 43.5% |
| 3 | 63.8% |
| 4 | 73.5% |
| 5 | 78.9% |
| 6 | 82.8% |
| 7 | 85.2% |
| 8 | 87.2% |

## Decode tok/s per turn (median over reps)

| turn | rapid-mlx |
| --- | --- |
| 1 | 51.3 |
| 2 | 44.0 |
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
