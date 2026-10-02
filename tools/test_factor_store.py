import sqlite3
import tempfile
import unittest
from pathlib import Path
from factor_store import connect, add_observation, add_event, asof, import_snapshot

class FactorStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.db=connect(Path(self.tmp.name)/'factors.db')
        self.row=dict(code='000660',factor='hbm_demand',value=100,unit='index',observedAt='2026-01-01T00:00:00Z',availableAt='2026-01-02T00:00:00Z',collectedAt='2026-01-03T00:00:00Z',source='synthetic-test')
    def tearDown(self):
        self.db.close();self.tmp.cleanup()
    def test_point_in_time_and_immutable_dedup(self):
        add_observation(self.db,self.row)
        add_observation(self.db,self.row)
        self.assertEqual(self.db.execute('SELECT count(*) FROM observations').fetchone()[0],1)
        self.assertEqual(asof(self.db,'000660','2026-01-01T00:00:00Z')['observations'],[])
        self.assertEqual(asof(self.db,'000660','2026-01-02T12:00:00Z')['observations'],[])
        self.assertEqual(len(asof(self.db,'000660','2026-01-04T00:00:00Z')['observations']),1)
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('UPDATE observations SET value=123')
    def test_missing_profile_never_becomes_probability(self):
        result=asof(self.db,'000660','2026-01-04T00:00:00Z')
        self.assertIn('hbm_demand',result['missingProfileFactors'])
        self.assertEqual(result['sensitivityStatus'],'not-estimated')
        self.assertFalse(result['productionEnabled'])
    def test_invalid_units_values_and_timing(self):
        for change in [dict(unit='KRW'),dict(value=float('nan')),dict(value=True),dict(availableAt='2025-01-01T00:00:00Z'),dict(collectedAt='2030-01-01T00:00:00Z'),dict(observedAt='2026-01-01')]:
            with self.assertRaises(ValueError):add_observation(self.db,self.row|change)
    def test_source_events_do_not_leak_or_become_scores(self):
        row=dict(code='000660',category='capacity',publishedAt='2026-01-01T00:00:00Z',collectedAt='2026-01-02T00:00:00Z',source='synthetic IR',text='Synthetic capacity event')
        add_event(self.db,row);add_event(self.db,row)
        self.assertEqual(asof(self.db,'000660','2026-01-01T12:00:00Z')['events'],[])
        self.assertEqual(len(asof(self.db,'000660','2026-01-03T00:00:00Z')['events']),1)
        self.assertEqual(asof(self.db,'000660','2026-01-03T00:00:00Z')['sensitivityStatus'],'not-estimated')
    def test_audited_snapshot_adapter(self):
        snapshot=dict(generatedAtISO='2026-01-03T00:00:00Z',mediumTerm=dict(items=[dict(code='000660',mediumTerm=dict(profitYoYPct=20,revenueYoYPct=10,financialEvidence=dict(periodEnd='2025-09-30',receiptNo='synthetic'),evidenceAudit=dict(financialFresh=True,flowAsOf='2026-01-01',netFlow20MarketCapPct=0.5)))]))
        self.assertEqual(import_snapshot(self.db,snapshot),3)
        self.assertEqual(len(asof(self.db,'000660','2026-01-04T00:00:00Z')['observations']),3)
        self.assertEqual(asof(self.db,'000660','2026-01-02T00:00:00Z')['observations'],[])

if __name__=='__main__':unittest.main()
