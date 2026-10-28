# Agent replay summary

- fixture: `bench/results/h2h-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 2; session tag on
- order per rep: rep0: strim-off; rep1: strim-off
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim-off | http://127.0.0.1:8203 | qwen38-4bit | off | bench/results/h2h-20261026/logs/strim-off.server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim-off |
| --- | --- | --- | --- |
| 1 | 1 | 4092 | 4.091 |
| 2 | 3 | 9348 | 9.551 |
| 3 | 5 | 14628 | 15.281 |
| 4 | 7 | 19886 | 21.295 |
| 5 | 9 | 25158 | 27.786 |
| 6 | 11 | 30380 | 34.214 |
| 7 | 13 | 35638 | 41.190 |
| 8 | 15 | 40840 | 48.257 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim-off | 201.666 | 201.511 / 201.821 | 0 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | strim-off |
| --- | --- |
| 1 | 0.0% |
| 2 | 0.0% |
| 3 | 0.0% |
| 4 | 0.0% |
| 5 | 0.0% |
| 6 | 0.0% |
| 7 | 0.0% |
| 8 | 0.0% |

## Decode tok/s per turn (median over reps)

| turn | strim-off |
| --- | --- |
| 1 | 59.8 |
| 2 | 73.5 |
| 3 | 61.9 |
| 4 | 60.1 |
| 5 | 55.1 |
| 6 | 52.8 |
| 7 | 49.2 |
| 8 | 47.9 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
