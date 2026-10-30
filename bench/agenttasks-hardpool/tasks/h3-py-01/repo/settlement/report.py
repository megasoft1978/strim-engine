"""Summaries for support tooling; they do not alter account state."""


def totals(entries):
    result = {"credit": 0, "reserve": 0, "capture": 0, "release": 0}
    for entry in entries:
        result[entry["kind"]] += entry["amount"]
    return result


def activity_by_account(entries):
    grouped = {}
    for entry in entries:
        grouped.setdefault(entry["account"], []).append(entry)
    return {account: totals(items) for account, items in grouped.items()}


def latest_activity(entries):
    """Return the last journal sequence per account in an export.

    An empty export has no active accounts. Sequence numbers are compared
    rather than trusting the input order, allowing callers to summarize a
    merged export before checking it with the audit module.
    """
    result = {}
    for entry in entries:
        account = entry["account"]
        sequence = entry["sequence"]
        if account not in result or sequence > result[account]:
            result[account] = sequence
    return result
