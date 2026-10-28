# Tool guidance

- read_file: give a path inside the workspace plus a start line and a line limit. Keep limits small.
- list_files: give a directory and a glob or depth limit. Never list the repository root unfiltered.
- grep: give a fixed pattern or regex and a path or glob. Prefer it to reading files you have not located.
- edit_file: replace one exact, unique span of old text with new text. On "not found" or "not unique", re-read the region and retry with more context.
- write_file: only for new files or a full rewrite you have already justified. Prefer edit_file for existing files.
- bash: run one command per call from the workspace root. Keep output short with tail, head or grep. Never run destructive commands (recursive deletes, force pushes, resets) and never leave the workspace.
- finish: final call. Give summary and status as described in the system prompt.
