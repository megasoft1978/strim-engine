"""Mutable state repository for one service instance."""
from .account import Account


class Store:
    def __init__(self):
        self._accounts = {}
        self._seen = set()

    def get(self, account):
        return self._accounts.get(account, Account()).copy()

    def put(self, account, state):
        self._accounts[account] = state.copy()

    def seen(self, event):
        return event.event_id in self._seen

    def mark(self, event):
        self._seen.add(event.event_id)
