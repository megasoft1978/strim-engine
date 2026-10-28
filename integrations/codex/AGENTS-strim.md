## Local delegation (strim MCP)

Delegate to the local Strim agent (`strim_task`, `strim_ask`, `strim_job`, `strim_cancel`) only when all hold:

- A verify command exists (the shell command that proves the task is done), or the answer is checkable by file:line.
- The task fits in about 150 words.
- Solo cost would be at least 6 tool turns or 15K tokens of tool output.
- It is not design, a cross-cutting refactor, security code, or a task with no oracle.

Otherwise do the task yourself.

- Always pass `verify` with the verify command.
- Wait with `strim_job` `wait_s: 25`. Do not poll after a reply starting with DONE.
- On `verify=verified`, trust the result: `git apply --check <patch>`, then `git apply <patch>`.
- On `failed`, `limit`, `unverified`, or a declined task, do it yourself.
- At most one delegation per task. Do not retry.
