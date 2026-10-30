"""Public settlement API.

process returns True when an event is committed and False on a duplicate.
Rejected events raise an exception and may be retried after state changes.
The service is intended for sequential use by a single consumer.
"""
from .events import Event
from .journal import Journal
from .reducer import apply
from .store import Store


class SettlementService:
    def __init__(self):
        self._store = Store()
        self._journal = Journal()

    def process(self, record):
        event = Event.from_record(record)
        if self._store.seen(event):
            return False
        state = self._store.get(event.account)
        apply(state, event)
        self._store.put(event.account, state)
        self._journal.append(event)
        self._store.mark(event)
        return True

    def account(self, name):
        return self._store.get(name).view()

    def journal(self, account=None):
        return self._journal.entries(account)
