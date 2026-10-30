"""Readable content-only diff for comparing two document revisions."""
from difflib import unified_diff
from .changes import changes


def content_diff(before, after):
    lines = []
    for change in changes(before, after):
        lines.append(f'{change.kind}: {change.key}\n')
        old = [] if change.before is None else [change.before.title + '\n', *change.before.body.splitlines(keepends=True)]
        new = [] if change.after is None else [change.after.title + '\n', *change.after.body.splitlines(keepends=True)]
        lines.extend(unified_diff(old, new, fromfile='before', tofile='after'))
    return ''.join(lines)
