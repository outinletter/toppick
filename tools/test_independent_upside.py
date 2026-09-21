import copy
from datetime import datetime, timedelta
import unittest
from unittest.mock import patch

import independent_upside as engine


class IndependentEngineTests(unittest.TestCase):
    def setUp(self):
        self.decision = datetime(2026, 9, 20, 17, tzinfo=engine.KST)
        self.envelope = {"source": "fixture", "collectedAt": self.decision.isoformat()}
        dates = []
        day = self.decision.date()-timedelta(days=2)
        while len(dates) < 61:
            if day.weekday() < 5: dates.append(day.strftime("%Y%m%d"))
            day -= timedelta(days=1)
        self.bars = [{"date": date, "price": 100+i, "open": 100+i,
                      "high": 101+i, "low": 99+i, "volume": 100000000,
                      "tradingValueKrw": 10000000000} for i,date in enumerate(reversed(dates))]
        self.bars[-1].update(price=165, high=166, volume=200000000)
        self.raw = {**self.envelope, "code":"000001", "market":"KOSPI", "name":"fixture",
                    "bars":self.bars, "indices":[{"date":b["date"], "price":3000+i} for i,b in enumerate(self.bars)]}

    def analyze(self, raw=None, supplement=None):
        return engine.analyze_instrument(raw or self.raw, supplement or {}, self.decision, engine.DEFAULTS)

    def test_no_legacy_score_dependency(self):
        before = self.analyze()
        changed = copy.deepcopy(self.raw)
        changed.update(shortScore=100, longScore=-999, riseProbability=1, stopLoss=1)
        self.assertEqual(before, self.analyze(changed))
        self.assertTrue(before["components"]["priceVolume"]["breakoutConfirmed"])
        self.assertIsNone(before["probabilities"]["targetBeforeStop"])
        self.assertFalse(before["productionEnabled"])

    def test_missing_volume_is_not_zero_evidence(self):
        del self.raw["bars"][-1]["volume"]
        self.assertEqual(self.analyze()["status"], "invalid-ohlcv-or-turnover")

    def test_future_provenance_rejected(self):
        self.raw["collectedAt"] = (self.decision+timedelta(seconds=1)).isoformat()
        self.assertEqual(self.analyze()["status"], "future-information")

    def test_raw_availability_is_preserved_and_cannot_be_refreshed(self):
        old = (self.decision-timedelta(hours=23)).isoformat()
        self.raw["collectedAt"] = old
        self.assertEqual(self.analyze()["sourceAvailableAt"],old)
        self.raw["collectedAt"] = (self.decision-timedelta(hours=25)).isoformat()
        self.assertEqual(self.analyze()["status"],"stale")

    def test_moving_listing_pages_retry_missing_codes(self):
        def response(codes):return {"totalCount":3,"stocks":[{"itemCode":c} for c in codes]}
        with patch.object(engine,"fetch",side_effect=[response(['a','b']),response(['b']),response(['a','c']),response(['b'])]):
            rows,pages,coverage=engine.fetch_market_listings('KOSPI',page_size=2)
        self.assertEqual({r['itemCode'] for r in rows},{'a','b','c'})
        self.assertEqual(coverage['passes'],2)
        self.assertTrue(coverage['completeByCount'])
        self.assertFalse(coverage['atomicSnapshot'])

    def test_incomplete_listing_stops_after_bounded_passes(self):
        response={"totalCount":2,"stocks":[{"itemCode":"a"}]}
        with patch.object(engine,"fetch",return_value=response) as request:
            _,_,coverage=engine.fetch_market_listings('KOSPI',page_size=2,max_passes=3)
        self.assertFalse(coverage['completeByCount'])
        self.assertEqual(request.call_count,3)

    def test_stale_index_is_not_supportive(self):
        self.raw["indices"].pop()
        result = self.analyze()
        self.assertEqual(result["components"]["regime"]["regime"], "unknown")
        self.assertIn("market-not-supportive", result["entryBlockers"])

    def test_missing_risk_sources_block_entry(self):
        blockers = self.analyze()["entryBlockers"]
        self.assertIn("event-risk-not-verified", blockers)
        self.assertIn("security-master-not-verified", blockers)
        self.assertIn("execution-not-verified", blockers)

    def test_cross_period_revision_not_comparable(self):
        rows = [{"broker":"A", "fiscalPeriod":str(2026+i), "metric":"EPS", "currency":"KRW", "unit":"won",
                 "value":100+i*50, "publishedAt":(self.decision-timedelta(days=2-i)).isoformat()} for i in range(2)]
        result = engine.revision_engine({**self.envelope,"rows":rows},self.decision)
        self.assertFalse(result["revisionConfirmed"])
        self.assertEqual(result["changes"], [])

    def test_future_revision_not_admitted(self):
        row = {"broker":"A", "fiscalPeriod":"2026", "metric":"EPS", "currency":"KRW", "unit":"won", "value":100}
        rows = [{**row,"publishedAt":(self.decision-timedelta(days=1)).isoformat()},
                {**row,"value":200,"publishedAt":(self.decision+timedelta(days=1)).isoformat()}]
        self.assertEqual(engine.revision_engine({**self.envelope,"rows":rows},self.decision)["changes"], [])

    def test_post_announcement_consensus_rejected(self):
        event = {"type":"earnings", "sourceId":"report", "publishedAt":self.decision.isoformat(),
                 "consensusPublishedAt":self.decision.isoformat(), "actual":200,"consensus":100,"comparableBasis":True}
        self.assertFalse(engine.catalyst_engine({**self.envelope,"rows":[event]},self.decision)["positiveCatalyst"])
        event["consensusPublishedAt"] = (self.decision-timedelta(days=1)).isoformat()
        self.assertTrue(engine.catalyst_engine({**self.envelope,"rows":[event]},self.decision)["positiveCatalyst"])

    def test_negative_or_stale_quotes_not_executable(self):
        quote = {**self.envelope,"quoteAt":self.decision.isoformat(),"bid":-100,"ask":-99,"venue":"KRX","tradingStatus":"TRADING"}
        self.assertEqual(engine.execution_engine(quote,self.decision,engine.DEFAULTS)["status"],"invalid-quote")
        quote.update(bid=100,ask=100.1,collectedAt=(self.decision-timedelta(seconds=61)).isoformat())
        self.assertEqual(engine.execution_engine(quote,self.decision,engine.DEFAULTS)["status"],"stale")

    def test_recollection_does_not_refresh_old_quote(self):
        quote={**self.envelope,"quoteAt":(self.decision-timedelta(minutes=5)).isoformat(),"bid":100,"ask":101,"venue":"KRX"}
        self.assertEqual(engine.execution_engine(quote,self.decision,engine.DEFAULTS)["status"],"stale-or-future-quote")

    def test_sector_and_short_pressure_not_implied_by_stock_momentum(self):
        result=self.analyze()
        self.assertEqual(result["components"]["sector"]["status"],"missing")
        self.assertEqual(result["components"]["shortPressure"]["status"],"missing")
        envelope={**self.envelope,"ratioUnit":"percent","rows":[{"date":b["date"],"shortTurnoverPct":4} for b in self.bars[-5:]]}
        short=engine.short_pressure_engine(envelope,self.decision)
        self.assertEqual(short["shortTurnover5Pct"],4)
        self.assertEqual(short["balanceStatus"],"missing")
        self.assertFalse(short["squeezeConfirmed"])

    def test_cost_adjusted_target_and_structural_stop(self):
        result = self.analyze()["components"]["risk"]
        net = (result["indicativeNet10Target"]*.999/result["referenceEntry"]-1)*100-.35
        self.assertAlmostEqual(net,10)
        self.assertLessEqual(result["structuralStop"],min(b["low"] for b in self.bars[-5:]))

    def test_flow_numeric_strings_and_future_dates(self):
        rows = [{"date":b["date"], **{k:"1,000" for k in ("foreignNetKrw","institutionNetKrw","pensionNetKrw","trustNetKrw")}} for b in self.bars[-20:]]
        envelope = {**self.envelope,"unit":"KRW","rows":rows}
        self.assertTrue(engine.flow_engine(envelope,self.decision,{"adv20Krw":1e10},1e12)["accumulationConfirmed"])
        rows[-1]["date"] = "20260921"
        self.assertEqual(engine.flow_engine(envelope,self.decision,{"adv20Krw":1e10},1e12)["status"],"stale-or-future-asof")


if __name__ == "__main__":
    unittest.main()
