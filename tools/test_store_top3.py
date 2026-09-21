import json
import unittest

from store_top3 import connect, store_performance, store_recommendations


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.db = connect(":memory:")
        self.addCleanup(self.db.close)
        self.pick = {"recommendationDate": "2026-09-14", "code": "005930", "score": 51, "entryStatus": "pending"}

    def test_partial_update_preserves_history_and_original_factors(self):
        with self.db:
            store_recommendations(self.db, [self.pick])
            store_recommendations(self.db, [{**self.pick, "recommendationDate": "2026-09-15"}])
            store_recommendations(self.db, [{**self.pick, "score": 60}])
        self.assertEqual(self.db.execute("SELECT count(*) FROM recommendations").fetchone()[0], 2)
        snapshots = [json.loads(row[0]) for row in self.db.execute("SELECT payload FROM audit_snapshots")]
        self.assertEqual(sorted(x["score"] for x in snapshots), [51, 51, 60])

    def test_idempotent_snapshot(self):
        with self.db:
            store_recommendations(self.db, [self.pick, self.pick])
        self.assertEqual(self.db.execute("SELECT count(*) FROM audit_snapshots").fetchone()[0], 1)

    def test_performance_retains_short_horizons_and_partial_history(self):
        with self.db:
            store_performance(self.db, {"items": [{**self.pick, "d2Close": 103, "d3Return": -3, "exitEvent": "stop"}]})
            store_performance(self.db, {"items": [{**self.pick, "code": "000660"}]})
        self.assertEqual(self.db.execute("SELECT count(*) FROM performance").fetchone()[0], 2)
        payload = json.loads(self.db.execute("SELECT payload FROM audit_snapshots WHERE code='005930'").fetchone()[0])
        self.assertEqual(payload["d2Close"], 103)
        self.assertEqual(payload["d3Return"], -3)

    def test_invalid_batch_rolls_back(self):
        with self.assertRaises(KeyError):
            with self.db:
                store_recommendations(self.db, [self.pick, {"code": "000660"}])
        self.assertEqual(self.db.execute("SELECT count(*) FROM recommendations").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT count(*) FROM audit_snapshots").fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
