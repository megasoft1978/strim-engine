"""Validate event records at the API boundary.

Amounts are integer cents; floating point inputs are deliberately not accepted.
A caller can retry a record using the same event id. Event ids are only unique
within an account, not across the entire settlement service.
"""
from dataclasses import dataclass
from .errors import InvalidRecord

KINDS = frozenset(("credit", "reserve", "capture", "release"))


@dataclass(frozen=True)
class Event:
    account: str
    event_id: str
    kind: str
    amount: int
    reference: str = ""

    @classmethod
    def from_record(cls, record):
        if not isinstance(record, dict):
            raise InvalidRecord("record must be a mapping")
        account = record.get("account")
        event_id = record.get("event_id")
        kind = record.get("kind")
        amount = record.get("amount")
        reference = record.get("reference", "")
        if not isinstance(account, str) or not account:
            raise InvalidRecord("account is required")
        if not isinstance(event_id, str) or not event_id:
            raise InvalidRecord("event_id is required")
        if kind not in KINDS:
            raise InvalidRecord("unknown event kind")
        if type(amount) is not int or amount <= 0:
            raise InvalidRecord("amount must be positive integer cents")
        if kind != "credit" and (not isinstance(reference, str) or not reference):
            raise InvalidRecord("reference is required")
        return cls(account, event_id, kind, amount, reference)
