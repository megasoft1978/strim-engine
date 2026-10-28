# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 2; session tag on
- order per rep: rep0: strim; rep1: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/strim/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 4.106 |
| 2 | 3 | 9348 | 6.558 |
| 3 | 5 | 14628 | 6.103 |
| 4 | 7 | 19886 | 6.556 |
| 5 | 9 | 25158 | 7.059 |
| 6 | 11 | 30380 | 7.492 |
| 7 | 13 | 35638 | 8.071 |
| 8 | 15 | 40840 | 8.548 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 54.493 | 54.601 / 54.384 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim |
| --- | --- |
| 1 | 0.0% |
| 2 | 32.9% |
| 3 | 63.0% |
| 4 | 72.1% |
| 5 | 77.3% |
| 6 | 80.9% |
| 7 | 83.3% |
| 8 | 85.3% |

## Decode tok/s per turn (median over reps)

| turn | strim |
| --- | --- |
| 1 | 54.7 |
| 2 | 62.0 |
| 3 | 58.8 |
| 4 | 57.0 |
| 5 | 51.9 |
| 6 | 51.4 |
| 7 | 48.2 |
| 8 | 46.3 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
