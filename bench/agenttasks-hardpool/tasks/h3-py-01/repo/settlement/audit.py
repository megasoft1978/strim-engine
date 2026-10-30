"""Read-only checks for exported settlement journals.

These checks are intended for operational exports; they never modify the
live service. An export can contain entries from multiple accounts. Sequence
numbers identify the global append order, whereas event identifiers are
scoped to an account. The validator accepts a filtered export, so sequences
need not be contiguous, but they must be strictly increasing.
"""
from .errors import InvalidEvent, InvalidRecord
from .events import Event
from .account import Account
from .reducer import apply


class AuditError(ValueError):
    """The export cannot be replayed or contains malformed journal entries."""


def _entry_event(entry, previous):
    if not isinstance(entry, dict):
        raise AuditError("journal entry must be a mapping")
    sequence = entry.get("sequence")
    if type(sequence) is not int or sequence <= previous:
        raise AuditError("journal sequence must increase")
    try:
        event = Event.from_record(entry)
    except (InvalidRecord, TypeError) as error:
        raise AuditError("invalid journal event") from error
    return event, sequence


def replay(entries):
    """Return independent account views produced by the supplied entries.

    Reject duplicate account/id pairs and impossible transitions rather than
    silently producing a partial answer. Duplicate ids in different accounts
    are allowed. Caller-owned records are never modified.
    """
    accounts = {}
    seen = set()
    previous = 0
    for entry in entries:
        event, previous = _entry_event(entry, previous)
        key = (event.account, event.event_id)
        if key in seen:
            raise AuditError("duplicate event")
        state = accounts.get(event.account, Account()).copy()
        try:
            apply(state, event)
        except InvalidEvent as error:
            raise AuditError("invalid account transition") from error
        seen.add(key)
        accounts[event.account] = state
    return {name: account.view() for name, account in accounts.items()}


def differences(expected, actual):
    """Describe mismatching fields without modifying either input mapping.

    Missing accounts have a zero balance and no holds. The list is sorted by
    account and field so that support output is deterministic.
    """
    fields = ("balance", "reserved", "available", "holds")
    empty = Account().view()
    result = []
    for name in sorted(set(expected) | set(actual)):
        left = expected.get(name, empty)
        right = actual.get(name, empty)
        for field in fields:
            if left.get(field) != right.get(field):
                result.append({"account": name, "field": field,
                               "expected": left.get(field),
                               "actual": right.get(field)})
    return result


def reconcile(entries, current):
    """Compare journal-derived balances with externally supplied snapshots.

    This convenience function first validates and replays the export. If the
    export is filtered, callers should supply snapshots for those accounts
    only; missing records cannot be reconstructed from a partial history.
    """
    return differences(replay(entries), current)
