"""Classify content changes independently from document ordering."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Change:
    key: str
    kind: str
    before: object
    after: object


def changes(base, revised):
    old = base.by_key()
    new = revised.by_key()
    result = []
    for key in dict.fromkeys((*base.keys(), *revised.keys())):
        before, after = old.get(key), new.get(key)
        if before == after:
            continue
        kind = 'added' if before is None else 'deleted' if after is None else 'edited'
        result.append(Change(key, kind, before, after))
    return tuple(result)
