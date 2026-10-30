"""An append-only in-memory event journal.

The journal uses a stable sequence number, starting at one. The service stores
only successfully committed events here. Entries are returned as copies to
avoid letting callers mutate the journal's records.
"""
from dataclasses import asdict


class Journal:
    def __init__(self):
        self._entries = []

    def append(self, event):
        item = asdict(event)
        item["sequence"] = len(self._entries) + 1
        self._entries.append(item)
        return item["sequence"]

    def entries(self, account=None):
        return [dict(item) for item in self._entries
                if account is None or item["account"] == account]
