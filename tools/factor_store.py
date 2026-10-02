"""Append-only, point-in-time company factor store. No inferred investment probabilities."""
import argparse
import hashlib
import json
import math
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FACTORS = {
    'profit_yoy': ('DART operating profit growth', 'pct'),
    'revenue_yoy': ('DART revenue growth', 'pct'),
    'flow20_cap': ('20-session net investor flow / market cap', 'pct'),
    'hbm_demand': ('HBM demand', 'index'),
    'hbm_supply': ('HBM supply capacity', 'index'),
    'memory_price': ('Memory selling price', 'index'),
    'customer_capex': ('Customer capital expenditure', 'KRW'),
    'usdkrw': ('USD/KRW exchange rate', 'KRW/USD'),
}

def stamp(value):
    result = datetime.fromisoformat(str(value).replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('Availability timestamps require an explicit timezone')
    return result.astimezone(timezone.utc).isoformat()

def connect(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA foreign_keys=ON')
    db.execute('PRAGMA busy_timeout=5000')
    db.executescript('''
      CREATE TABLE IF NOT EXISTS factor_definitions(
        factor TEXT PRIMARY KEY, description TEXT NOT NULL, unit TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS stock_profiles(
        code TEXT NOT NULL, factor TEXT NOT NULL REFERENCES factor_definitions(factor),
        rationale TEXT NOT NULL, sensitivity_status TEXT NOT NULL,
        PRIMARY KEY(code,factor));
      CREATE TABLE IF NOT EXISTS observations(
        digest TEXT PRIMARY KEY, code TEXT NOT NULL,
        factor TEXT NOT NULL REFERENCES factor_definitions(factor), value REAL NOT NULL,
        observed_at TEXT NOT NULL, available_at TEXT NOT NULL, collected_at TEXT NOT NULL,
        source TEXT NOT NULL, unit TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS factor_asof ON observations(code,factor,available_at);
      CREATE TABLE IF NOT EXISTS events(
        digest TEXT PRIMARY KEY, code TEXT NOT NULL, category TEXT NOT NULL,
        published_at TEXT NOT NULL, collected_at TEXT NOT NULL,
        source TEXT NOT NULL, text TEXT NOT NULL);
      CREATE TRIGGER IF NOT EXISTS events_no_update BEFORE UPDATE ON events
        BEGIN SELECT RAISE(ABORT,'events are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS events_no_delete BEFORE DELETE ON events
        BEGIN SELECT RAISE(ABORT,'events are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS observations_no_update BEFORE UPDATE ON observations
        BEGIN SELECT RAISE(ABORT,'observations are immutable'); END;
      CREATE TRIGGER IF NOT EXISTS observations_no_delete BEFORE DELETE ON observations
        BEGIN SELECT RAISE(ABORT,'observations are immutable'); END;
    ''')
    with db:
        db.executemany('INSERT OR IGNORE INTO factor_definitions VALUES(?,?,?)',
                       [(key, *value) for key, value in FACTORS.items()])
        db.executemany('INSERT OR IGNORE INTO stock_profiles VALUES(?,?,?,?)',
                       [('000660', factor, 'User-supplied HBM causal hypothesis; empirical sensitivity not fitted', 'hypothesis-only')
                        for factor in ('hbm_demand','hbm_supply','memory_price','customer_capex','usdkrw')])
    return db

def add_observation(db, row, now=None):
    now = stamp(now or datetime.now(timezone.utc).isoformat())
    factor = row['factor']
    if factor not in FACTORS or row['unit'] != FACTORS[factor][1]:
        raise ValueError('Unknown factor or incompatible units')
    value = row['value']
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('A finite numeric observation is required')
    observed, available, collected = map(stamp, (row['observedAt'], row['availableAt'], row['collectedAt']))
    if not observed <= available <= collected <= now:
        raise ValueError('Require observed <= available <= collected <= now')
    if not row['source'] or not row['code']:
        raise ValueError('Source and entity are required')
    canonical = json.dumps([row['code'],factor,value,observed,available,collected,row['source'],row['unit']],ensure_ascii=False,separators=(',', ':'))
    digest = hashlib.sha256(canonical.encode()).hexdigest()
    db.execute('INSERT OR IGNORE INTO observations VALUES(?,?,?,?,?,?,?,?,?)',
               (digest,row['code'],factor,value,observed,available,collected,row['source'],row['unit']))
    return digest

def add_event(db, row):
    if row['category'] not in ('contract','capacity','regulation','customer','guidance'):
        raise ValueError('Unknown event category')
    published, collected = stamp(row['publishedAt']), stamp(row['collectedAt'])
    if not published <= collected <= stamp(datetime.now(timezone.utc).isoformat()):
        raise ValueError('Require published <= collected <= now')
    if not row['code'] or not row['source'] or not row['text']:
        raise ValueError('Event entity, source and text are required')
    payload=[row['code'],row['category'],published,collected,row['source'],row['text']]
    digest=hashlib.sha256(json.dumps(payload,ensure_ascii=False).encode()).hexdigest()
    db.execute('INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?)',(digest,*payload))
    return digest

def import_snapshot(db, snapshot):
    generated = snapshot.get('generatedAtISO') or snapshot.get('generatedAt')
    if not generated:
        raise ValueError('Snapshot generation time is required')
    available = stamp(generated)
    imported = 0
    seen = set()
    with db:
        for item in snapshot.get('mediumTerm', {}).get('items', []):
            code = item['code']
            if code in seen:
                continue
            seen.add(code)
            medium = item.get('mediumTerm', {})
            audit = medium.get('evidenceAudit', {})
            financial = medium.get('financialEvidence') or {}
            for factor, field in [('profit_yoy','profitYoYPct'),('revenue_yoy','revenueYoYPct')]:
                value = medium.get(field)
                if value is None or not audit.get('financialFresh'):
                    continue
                observed = financial.get('periodEnd')
                if not observed:
                    continue
                add_observation(db,dict(code=code,factor=factor,value=value,unit='pct',
                    observedAt=observed+'T00:00:00+09:00',availableAt=available,collectedAt=available,
                    source='DART-CFS:'+str(financial.get('receiptNo','unknown'))))
                imported += 1
            value = audit.get('netFlow20MarketCapPct')
            if value is not None and audit.get('flowAsOf'):
                add_observation(db,dict(code=code,factor='flow20_cap',value=value,unit='pct',
                    observedAt=audit['flowAsOf']+'T00:00:00+09:00',availableAt=available,collectedAt=available,source='KRX/pykrx+Kiwoom-marketcap'))
                imported += 1
    return imported

def asof(db, code, decision_at):
    decision = stamp(decision_at)
    rows = db.execute('''SELECT * FROM observations WHERE code=? AND available_at<=? AND collected_at<=?
      ORDER BY factor, observed_at DESC, available_at DESC, collected_at DESC, digest''', (code,decision,decision))
    selected = {}
    for row in rows:
        selected.setdefault(row['factor'], dict(row))
    profile = [dict(row) for row in db.execute('SELECT * FROM stock_profiles WHERE code=?', (code,))]
    events=[dict(row) for row in db.execute('SELECT * FROM events WHERE code=? AND published_at<=? AND collected_at<=? ORDER BY published_at DESC LIMIT 100',(code,decision,decision))]
    return dict(code=code,decisionAt=decision,observations=list(selected.values()),profile=profile,
                events=events,
                missingProfileFactors=[row['factor'] for row in profile if row['factor'] not in selected],
                sensitivityStatus='not-estimated',productionEnabled=False)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--db',default=str(ROOT/'reports/factors.db'))
    parser.add_argument('--snapshot')
    parser.add_argument('--observations',help='JSON array of dated numeric observations from connected sources')
    parser.add_argument('--events',help='JSON array of dated source events; no automatic sentiment score')
    parser.add_argument('--code',default='000660')
    parser.add_argument('--as-of',default=datetime.now(timezone.utc).isoformat())
    args = parser.parse_args()
    with connect(args.db) as db:
        imported = 0
        if args.snapshot:
            imported = import_snapshot(db,json.loads(Path(args.snapshot).read_text(encoding='utf-8-sig')))
        if args.observations:
            for row in json.loads(Path(args.observations).read_text(encoding='utf-8-sig')):
                add_observation(db,row)
        if args.events:
            for row in json.loads(Path(args.events).read_text(encoding='utf-8-sig')):
                add_event(db,row)
        result=asof(db,args.code,args.as_of)
        result['importedObservationCount']=imported
        result['totalObservationCount']=db.execute('SELECT count(*) FROM observations').fetchone()[0]
        print(json.dumps(result,ensure_ascii=False,allow_nan=False))

if __name__ == '__main__':
    main()
