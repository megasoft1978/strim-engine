# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 3; session tag on
- order per rep: rep0: omlx; rep1: omlx; rep2: omlx
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| omlx | http://127.0.0.1:8651 | qwen38-4bit | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/omlx/pass2/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | omlx |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 4.527 |
| 2 | 3 | 9347 | 8.240 |
| 3 | 5 | 14628 | 7.771 |
| 4 | 7 | 19885 | 7.153 |
| 5 | 9 | 25157 | 9.011 |
| 6 | 11 | 30379 | 8.368 |
| 7 | 13 | 35638 | 10.387 |
| 8 | 15 | 40839 | 9.641 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| omlx | 65.184 | 68.512 / 64.997 / 65.184 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | omlx |
| --- | --- |
| 1 | 0.0% |
| 2 | 21.9% |
| 3 | 56.0% |
| 4 | 72.1% |
| 5 | 73.3% |
| 6 | 80.9% |
| 7 | 80.5% |
| 8 | 85.3% |

## Decode tok/s per turn (median over reps)

| turn | omlx |
| --- | --- |
| 1 | 34.4 |
| 2 | 34.2 |
| 3 | n/a |
| 4 | n/a |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 18.
