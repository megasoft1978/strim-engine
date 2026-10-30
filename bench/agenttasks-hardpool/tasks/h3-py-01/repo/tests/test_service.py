import unittest

from settlement import InvalidEvent, SettlementService
from settlement.errors import InvalidRecord
from settlement.report import totals


def event(account, event_id, kind, amount, reference=""):
    return dict(account=account, event_id=event_id, kind=kind,
                amount=amount, reference=reference)


class SettlementTests(unittest.TestCase):
    def setUp(self):
        self.service = SettlementService()

    def send(self, account, event_id, kind, amount, reference=""):
        return self.service.process(event(account, event_id, kind, amount, reference))

    def test_two_accounts_can_reuse_external_ids(self):
        self.assertTrue(self.send("alice", "1", "credit", 900))
        self.assertTrue(self.send("bob", "1", "credit", 600))
        self.assertEqual(self.service.account("bob")["available"], 600)
        self.assertEqual(len(self.service.journal()), 2)

    def test_partial_capture_keeps_remaining_hold_and_available(self):
        self.send("alice", "1", "credit", 1000)
        self.send("alice", "2", "reserve", 700, "booking")
        self.send("alice", "3", "capture", 200, "booking")
        self.assertEqual(self.service.account("alice"), dict(balance=800,
            reserved=500, available=300, holds={"booking": 500}))
        self.send("alice", "4", "release", 100, "booking")
        self.send("alice", "5", "capture", 400, "booking")
        self.assertEqual(self.service.account("alice"), dict(balance=400,
            reserved=0, available=400, holds={}))

    def test_duplicate_does_not_replay_or_append(self):
        self.send("a", "x", "credit", 100)
        self.assertFalse(self.send("a", "x", "credit", 100))
        self.assertEqual(self.service.account("a")["balance"], 100)
        self.assertEqual(len(self.service.journal()), 1)

    def test_rejected_event_can_be_retried(self):
        with self.assertRaises(InvalidEvent):
            self.send("a", "r", "reserve", 50, "ref")
        self.send("a", "c", "credit", 50)
        self.assertTrue(self.send("a", "r", "reserve", 50, "ref"))
        self.assertEqual([x["sequence"] for x in self.service.journal()], [1, 2])

    def test_over_capture_is_atomic(self):
        self.send("a", "c", "credit", 100)
        self.send("a", "r", "reserve", 80, "ref")
        before = self.service.account("a")
        with self.assertRaises(InvalidEvent):
            self.send("a", "bad", "capture", 81, "ref")
        self.assertEqual(self.service.account("a"), before)
        self.assertEqual(len(self.service.journal()), 2)

    def test_holds_and_journal_are_defensive_copies(self):
        self.send("a", "c", "credit", 100)
        self.send("a", "r", "reserve", 40, "ref")
        self.service.account("a")["holds"].clear()
        self.service.journal()[0]["amount"] = 999
        self.assertEqual(self.service.account("a")["reserved"], 40)
        self.assertEqual(self.service.journal()[0]["amount"], 100)

    def test_missing_reserve_and_duplicate_reference(self):
        self.send("a", "c", "credit", 100)
        self.send("a", "r", "reserve", 40, "ref")
        with self.assertRaises(InvalidEvent):
            self.send("a", "r2", "reserve", 10, "ref")
        with self.assertRaises(InvalidEvent):
            self.send("a", "r3", "release", 10, "other")
        self.assertEqual(self.service.account("a")["available"], 60)

    def test_bad_amount_rejected(self):
        for amount in [0, -1, 1.0, True]:
            with self.subTest(amount=amount), self.assertRaises(InvalidRecord):
                self.send("a", "c", "credit", amount)
        self.assertEqual(self.service.journal(), [])

    def test_account_filter_and_report(self):
        self.send("a", "1", "credit", 100)
        self.send("a", "2", "reserve", 30, "r")
        self.send("b", "3", "credit", 200)
        entries = self.service.journal("a")
        self.assertEqual([e["sequence"] for e in entries], [1, 2])
        self.assertEqual(totals(entries), dict(credit=100, reserve=30, capture=0, release=0))


if __name__ == "__main__":
    unittest.main()
