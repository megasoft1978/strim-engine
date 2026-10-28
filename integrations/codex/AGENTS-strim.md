## Local delegation (strim MCP)

Delegate to the local Strim agent (`strim_task`, `strim_ask`, `strim_job`, `strim_cancel`) when a verify command exists (the shell command that proves the task is done, or a file:line check) AND at least one holds:

- The task needs reading or editing 2 or more files.
- Solo you expect 6 or more tool turns, or 15K or more tokens of tool output.

Never delegate design, cross-cutting refactors, security code, or a task with no oracle. Otherwise do the task yourself.

- Always pass `verify` with the verify command, and an absolute canonical `cwd` (symlinks resolved, `/private/var/...` not `/var/...`).
- A refusal for a cwd, path or allowed-roots error is a setup error: retry once with the canonical path named in the error, never twice.
- Wait with `strim_job` `wait_s: 25`. Do not poll after a reply starting with DONE.
- On `verify=verified`, trust the result: `git apply --check <patch>`, then `git apply <patch>`.
- On `failed`, `limit`, `unverified`, or a declined task, do it yourself.
- At most one delegation per task (a path-error retry does not count). Do not retry a failed job.
