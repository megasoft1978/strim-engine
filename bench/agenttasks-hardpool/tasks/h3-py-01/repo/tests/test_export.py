import unittest

from settlement import SettlementService
from settlement.export import ExportError, from_csv, from_json, to_csv, to_json
from tests.test_service import event


class ExportTests(unittest.TestCase):
    def entries(self):
        service = SettlementService()
        for item in [event('a,é', '1', 'credit', 100),
                     event('a,é', '2', 'reserve', 40, 'one'),
                     event('a,é', '3', 'release', 40, 'one')]:
            service.process(item)
        return service.journal()

    def test_round_trip_and_independence(self):
        entries = self.entries()
        for encode, decode in [(to_csv, from_csv), (to_json, from_json)]:
            restored = decode(encode(entries))
            self.assertEqual(restored, entries)
            restored[0]['amount'] = 1
            self.assertEqual(entries[0]['amount'], 100)
            self.assertEqual(decode(encode([])), [])

    def test_reject_invalid_documents(self):
        for text in ['{}', '{"version":true,"entries":[]}',
                     '{"version":1,"entries":[{}]}', 'not json']:
            with self.subTest(text=text), self.assertRaises(ExportError):
                from_json(text)
        for text in ['wrong,header\na,b\n',
                     'sequence,account,event_id,kind,amount,reference\n1,a,1,credit,-3,\n',
                     'sequence,account,event_id,kind,amount,reference\n1,a,1,credit,5,\n1,a,2,credit,5,\n']:
            with self.subTest(text=text), self.assertRaises(ExportError):
                from_csv(text)
