# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 3; session tag on
- order per rep: rep0: mlx-lm; rep1: mlx-lm; rep2: mlx-lm
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| mlx-lm | http://127.0.0.1:8651 | /Users/user/Desktop/Freelance/strim-engine/models/qwen38-4bit | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/mlx-lm/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | mlx-lm |
| --- | --- | --- | --- |
| 1 | 1 | 4093 | 4.465 |
| 2 | 3 | 9348 | 5.597 |
| 3 | 5 | 14629 | n/a |
| 4 | 7 | 19886 | n/a |
| 5 | 9 | 25158 | n/a |
| 6 | 11 | 30380 | n/a |
| 7 | 13 | 35639 | 7.389 |
| 8 | 15 | 40840 | 7.621 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| mlx-lm | n/a | n/a | 3 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | mlx-lm |
| --- | --- |
| 1 | 0.0% |
| 2 | 43.8% |
| 3 | 63.9% |
| 4 | 73.6% |
| 5 | 79.0% |
| 6 | 82.8% |
| 7 | 85.2% |
| 8 | 87.3% |

## Decode tok/s per turn (median over reps)

| turn | mlx-lm |
| --- | --- |
| 1 | 99.1 |
| 2 | 85.9 |
| 3 | n/a |
| 4 | n/a |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 13; rows excluded from decode (short / no_usage): 5.
