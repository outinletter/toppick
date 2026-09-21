import copy
from datetime import datetime
import unittest

import target10 as t


def fixture():
    signals = dict(rsi=55, ma20Deviation=3, shortTermVolatility=2.5,
                   volumeSurge=True, foreignFlowRatio=1, institutionFlowRatio=1,
                   averageTradingValue=200, twentyDayRise=5,
                   openingGapRate=1, intradayReturn=1)
    item = dict(entryPrice=100, openPrice=100, tradingDate="2026-09-11",
                signals=signals, sectorRotationStatus="strong")
    record = dict(id="test", code="005930", market="KOSPI", name="fixture",
                  capturedAt="2026-09-11T18:00:00+09:00", features=t.vector(item),
                  eligible=True, stopRate=3, sourceHash="fixture", item=item)
    bars = [dict(date=d, open=100, high=105, low=99, price=104)
            for d in ("20260911", "20260914", "20260915", "20260916")]
    history = dict(stockHistory=bars,
                   indexHistory=[dict(date=b["date"], open=100, price=101) for b in bars])
    return record, history


class TargetTests(unittest.TestCase):
    now = datetime(2026, 9, 20, tzinfo=t.KST)

    def test_net_target_accounts_for_both_execution_legs(self):
        record, history = fixture()
        history["stockHistory"][1]["high"] = 112
        row, error = t.label_trade(record, history, self.now)
        self.assertIsNone(error)
        self.assertEqual(row["event"], "target")
        self.assertGreater(row["target"], 110)
        for result in row["netReturns"]:
            self.assertAlmostEqual(result, 10)

    def test_no_future_event_leaks_into_day_one(self):
        record, history = fixture()
        history["stockHistory"][2]["high"] = 112
        row, _ = t.label_trade(record, history, self.now)
        self.assertEqual(row["eventDay"], 2)
        self.assertLess(row["netReturns"][0], 10)
        self.assertAlmostEqual(row["netReturns"][1], 10)

    def test_same_bar_ambiguity_is_stop_first(self):
        record, history = fixture()
        history["stockHistory"][1].update(high=115, low=90)
        row, _ = t.label_trade(record, history, self.now)
        self.assertTrue(row["ambiguous"])
        self.assertEqual(row["event"], "stop")
        self.assertLess(row["netReturns"][2], -3)

    def test_gap_stop_does_not_fill_at_stop_price(self):
        record, history = fixture()
        history["stockHistory"][2].update(open=90, high=94, low=89, price=93)
        row, _ = t.label_trade(record, history, self.now)
        self.assertLess(row["netReturns"][2], -10)

    def test_open_target_precedes_intraday_stop(self):
        record, history = fixture()
        history["stockHistory"][2].update(open=112, high=115, low=90, price=95)
        row, _ = t.label_trade(record, history, self.now)
        self.assertEqual(row["event"], "target")

    def test_missing_calendar_session_is_not_bridged(self):
        record, history = fixture()
        history["stockHistory"].pop(2)
        self.assertEqual(t.label_trade(record, history, self.now)[1], "missing-or-suspended-session")

    def test_adjusted_price_basis_mismatch_excluded(self):
        record, history = fixture()
        history["stockHistory"][0]["open"] = 50
        self.assertEqual(t.label_trade(record, history, self.now)[1], "corporate-action-or-price-basis-mismatch")

    def test_partial_third_session_not_mature(self):
        record, history = fixture()
        now = datetime(2026, 9, 16, 15, tzinfo=t.KST)
        self.assertEqual(t.label_trade(record, history, now)[1], "pending-three-closed-sessions")

    def test_entry_gap_skipped(self):
        record, history = fixture()
        history["stockHistory"][1]["open"] = 104
        self.assertEqual(t.label_trade(record, history, self.now)[1], "entry-gap-skipped")

    def test_labels_end_before_embargo_not_just_recommendation_date(self):
        rows = [dict(id="safe", capturedAt="2026-08-01T10:00:00+09:00", labelEnd="20260805"),
                dict(id="overlap", capturedAt="2026-08-18T10:00:00+09:00", labelEnd="20260824"),
                dict(id="test", capturedAt="2026-08-28T10:00:00+09:00", labelEnd="20260902")]
        train, test = t.split_rows(rows, "2026-08-28")
        self.assertEqual([r["id"] for r in train], ["safe"])
        self.assertEqual([r["id"] for r in test], ["test"])

    def test_probability_sums_and_horizon_monotonicity(self):
        model = dict(x=[[0]*8]*210, center=[0]*8, scale=[1]*8,
                     categories=list(range(7))*30, returns=[[1, 2, 3]]*210,
                     dates=[f"date-{i%30}" for i in range(210)])
        result = t.forecast(model, [0]*8)
        previous = dict(targetBeforeStopProbability=0, stopBeforeTargetProbability=0)
        for h in ("1", "2", "3"):
            p = result["horizons"][h]
            self.assertAlmostEqual(p["targetBeforeStopProbability"]+p["stopBeforeTargetProbability"]+p["neitherProbability"], 1)
            for key in previous:
                self.assertGreaterEqual(p[key], previous[key])
                previous[key] = p[key]

    def test_sparse_evidence_does_not_invent_probability(self):
        self.assertIsNone(t.fit([]))
        self.assertFalse(t.evaluate(None, [dict(id=1)])["passed"])

    def test_boolean_volume_feature_and_null_preserved(self):
        record, _ = fixture()
        self.assertIsNotNone(t.vector(record["item"]))
        record["item"]["signals"]["rsi"] = float("nan")
        self.assertIsNone(t.vector(record["item"]))


if __name__ == "__main__":
    unittest.main()
