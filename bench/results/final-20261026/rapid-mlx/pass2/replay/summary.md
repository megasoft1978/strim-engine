# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 2; session tag on
- order per rep: rep0: rapid-mlx; rep1: rapid-mlx
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| rapid-mlx | http://127.0.0.1:8651 | models/qwen38-4bit | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/rapid-mlx/pass2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | rapid-mlx |
| --- | --- | --- | --- |
| 1 | 1 | 4094 | 4.152 |
| 2 | 3 | 9348 | 5.598 |
| 3 | 5 | 14630 | 5.958 |
| 4 | 7 | 19886 | 6.194 |
| 5 | 9 | 25158 | 6.569 |
| 6 | 11 | 30380 | 6.767 |
| 7 | 13 | 35640 | 7.281 |
| 8 | 15 | 40840 | 7.393 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| rapid-mlx | 49.913 | 49.899 / 49.927 | 0 |

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
| 1 | 50.3 |
| 2 | 44.2 |
| 3 | n/a |
| 4 | n/a |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 12.
