"""Human-readable summaries for a merge review queue."""


def summary(result):
    if result.clean:
        return 'Merge is clean.'
    lines = [f'{len(result.conflicts)} section conflict(s):']
    for conflict in result.conflicts:
        lines.append(f'- {conflict.key}: {conflict.reason}')
    return '\n'.join(lines)


def conflict_keys(result):
    return tuple(conflict.key for conflict in result.conflicts)
