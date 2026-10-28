# Agent task corpus

Swift and Go only (no Python). 17 tasks: test-fix 12 (tf-02..05 Go, tf-11..18 Swift), mechanical-edit 3 (me-06..08, Go), repo-qa 2 (qa-01, qa-07, Go).
Go tasks are mined from small MIT/BSD repos (see `manifest.json`); the Swift tf-* tasks are original tiny SwiftPM libraries (MIT) with an injected bug.

| class | what | verify |
|---|---|---|
| `test-fix` | tests kept, source bug present in the snapshot | `verify_cmd` fails on the snapshot and passes with `solution.patch` |
| `mechanical-edit` | rename / move / add-parameter; tests already use the new API | `verify_cmd` = tests (+ grep checks) |
| `repo-qa` | question with a checkable answer, no edits | `verify_cmd` greps `$ANSWER_FILE`; `known_answer` accepted, `wrong_answer` and empty rejected |

Per task dir: `task.json`, `snapshot.tar.gz`, `solution.patch` (validation only, never shown to agents), `setup.patch` (mined tasks).
`test_paths` are restored from the snapshot and hash-checked (`test_sha256`) before `verify_cmd`.
Swift verify uses `swift test --build-system native --disable-sandbox`: the default xcbuild path needs mach services that the harness sandbox denies.

- `strim agentbench validate [--task-ids a,b]` offline check (CPU only, no model): table, exit 1 on any BAD, verify must stay under 60 s.
- `strim agentbench prepare [--write]` recompute `tree_sha256`/`test_sha256` and regenerate `manifest.json`.
