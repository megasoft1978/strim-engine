# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 1; session tag on
- order per rep: rep0: strim
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| strim | http://127.0.0.1:8203 | qwen38-4bit | on | bench/results/h2h-final-20261028/strim/pass1/server.txt |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | strim |
| --- | --- | --- | --- |
| 1 | 1 | 4091 | 4.139 |
| 2 | 3 | 9346 | 5.584 |
| 3 | 5 | 14627 | 5.875 |
| 4 | 7 | 19884 | 6.225 |
| 5 | 9 | 25156 | 6.521 |
| 6 | 11 | 30378 | 6.759 |
| 7 | 13 | 35637 | 7.181 |
| 8 | 15 | 40838 | 7.405 |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| strim | 49.688 | 49.688 | 0 |

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
| 1 | 61.7 |
| 2 | 72.6 |
| 3 | 63.9 |
| 4 | 61.8 |
| 5 | 59.2 |
| 6 | 56.6 |
| 7 | 55.7 |
| 8 | 53.6 |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 0; rows excluded from decode (short / no_usage): 0.
