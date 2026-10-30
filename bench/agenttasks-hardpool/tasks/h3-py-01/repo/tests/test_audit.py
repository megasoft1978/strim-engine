import unittest

from settlement.audit import AuditError, differences, replay, reconcile
from tests.test_service import event
from settlement import SettlementService


class AuditTests(unittest.TestCase):
    def test_replay_and_reconcile(self):
        service = SettlementService()
        for record in [event("a", "one", "credit", 90),
                       event("a", "two", "reserve", 60, "h"),
                       event("a", "three", "capture", 20, "h")]:
            service.process(record)
        entries = service.journal()
        self.assertEqual(replay(entries), {"a": service.account("a")})
        self.assertEqual(reconcile(entries, {"a": service.account("a")}), [])
        self.assertEqual(differences({"a": {"balance": 2}}, {"a": {"balance": 3}})[0]["field"], "balance")

    def test_invalid_exports_are_rejected(self):
        first = dict(event("a", "one", "credit", 90), sequence=1)
        with self.assertRaises(AuditError):
            replay([first, dict(first, sequence=2)])
        with self.assertRaises(AuditError):
            replay([first, dict(event("a", "two", "release", 1, "h"), sequence=2)])
        with self.assertRaises(AuditError):
            replay([first, dict(first, sequence=1)])

    def test_ids_are_scoped_to_accounts(self):
        entries = [dict(event("a", "one", "credit", 90), sequence=1),
                   dict(event("b", "one", "credit", 80), sequence=4)]
        self.assertEqual(replay(entries)["b"]["balance"], 80)
