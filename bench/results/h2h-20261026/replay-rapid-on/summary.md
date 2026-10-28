# Agent replay summary

- fixture: `bench/results/h2h-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 2; session tag on
- order per rep: rep0: rapid-on; rep1: rapid-on
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| rapid-on | http://127.0.0.1:8202 | models/qwen38-4bit | on | bench/results/h2h-20261026/logs/rapid-on.server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | rapid-on |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 4.180 |
| 2 | 3 | 9348 | 5.562 |
| 3 | 5 | 14628 | 5.901 |
| 4 | 7 | 19886 | 6.140 |
| 5 | 9 | 25158 | 6.524 |
| 6 | 11 | 30380 | 6.725 |
| 7 | 13 | 35638 | 7.171 |
| 8 | 15 | 40840 | 7.303 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| rapid-on | 49.506 | 49.548 / 49.465 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | rapid-on |
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

| turn | rapid-on |
| --- | --- |
| 1 | 50.0 |
| 2 | 44.1 |
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
