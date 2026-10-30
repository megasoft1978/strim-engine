"""Apply a validated event to a working copy of account state.

A reserve reduces available funds, but does not debit balance. A capture
consumes part or all of an existing reserve and debits the same amount.
A release only reduces the reserve. Both operations require a live reference.
"""
from .errors import InvalidEvent


def apply(account, event):
    if event.kind == "credit":
        account.balance += event.amount
        return
    if event.kind == "reserve":
        if event.reference in account.holds:
            raise InvalidEvent("reference already exists")
        if event.amount > account.available:
            raise InvalidEvent("insufficient available funds")
        account.holds[event.reference] = event.amount
        return
    held = account.holds.get(event.reference)
    if held is None:
        raise InvalidEvent("unknown reserve")
    if event.amount > held:
        raise InvalidEvent("amount exceeds reserve")
    remaining = held - event.amount
    if remaining:
        account.holds[event.reference] = remaining
    else:
        del account.holds[event.reference]
    if event.kind == "capture":
        account.balance -= held
