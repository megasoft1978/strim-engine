# Agent replay summary

- fixture: `bench/results/final-20261026/synthetic-8turn.json` sha256:047d68e53e51efe3, 8 turns (user/tool messages), 17 messages
- max_tokens 48, ignore_eos, temperature 0, streamed; reps 3; session tag on
- order per rep: rep0: ollama; rep1: ollama; rep2: ollama
- all medians are over reps (one request per arm, turn and rep)

## Arms

| arm | URL | model | cache | server log |
| --- | --- | --- | --- | --- |
| ollama | http://127.0.0.1:11435 | qwen38-27b-q4km | on | /Users/user/Desktop/Freelance/strim-engine/bench/results/final-20261026/ollama/pass1/server.log |

## Per-turn TTFT (s, median over reps)

| turn | msg | prompt tok | ollama |
| --- | --- | --- | --- |
| 1 | 1 | 4128 | n/a |
| 2 | 3 | 9383 | n/a |
| 3 | 5 | 14664 | n/a |
| 4 | 7 | 19921 | 11.500 |
| 5 | 9 | 25193 | n/a |
| 6 | 11 | 30415 | n/a |
| 7 | 13 | 35674 | n/a |
| 8 | 15 | 40875 | n/a |

## Total prefill (sum of per-turn TTFT, s)

| arm | prefill s (median) | per rep | incomplete reps |
| --- | --- | --- | --- |
| ollama | n/a | n/a | 3 |

## Cached-token fraction per turn (cached / prompt tok, median over reps)

| turn | ollama |
| --- | --- |
| 1 | 0.0% |
| 2 | 44.0% |
| 3 | 64.0% |
| 4 | 73.6% |
| 5 | 79.1% |
| 6 | 82.8% |
| 7 | 85.2% |
| 8 | 87.3% |

## Decode tok/s per turn (median over reps)

| turn | ollama |
| --- | --- |
| 1 | n/a |
| 2 | n/a |
| 3 | n/a |
| 4 | 45.3 |
| 5 | n/a |
| 6 | n/a |
| 7 | n/a |
| 8 | n/a |

## Notes

- TTFT = first content chunk minus send; it includes the first decode step, so it is a prefill proxy.
- `unknown` cached fraction: server reported no cached_tokens and no `--server-log` hit was found.
- request errors: 21; rows excluded from decode (short / no_usage): 0.
