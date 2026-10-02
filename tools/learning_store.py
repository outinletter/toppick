"""Archive learned standardized associations in the local factor database."""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path
from factor_store import ROOT, connect, stamp

def archive(run, db_path):
    run=Path(run)
    manifest=json.loads((run/'manifest.json').read_text(encoding='utf-8'))
    models=json.loads((run/'models.json').read_text(encoding='utf-8'))
    result=json.loads((run/'result.json').read_text(encoding='utf-8'))
    available=stamp(result['generatedAt'])
    count=0
    db=connect(db_path)
    try:
        db.executescript('''CREATE TABLE IF NOT EXISTS sensitivity_models(
          model_id TEXT PRIMARY KEY, dataset_hash TEXT NOT NULL, source_hash TEXT NOT NULL,
          model_json TEXT NOT NULL, validation_json TEXT NOT NULL, available_at TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS learned_sensitivities(
          model_id TEXT NOT NULL, code TEXT NOT NULL, horizon INTEGER NOT NULL,
          feature TEXT NOT NULL, coefficient REAL NOT NULL, available_at TEXT NOT NULL,
          training_rows INTEGER NOT NULL, shrinkage_weight REAL NOT NULL,
          interpretation TEXT NOT NULL, PRIMARY KEY(model_id,code,horizon,feature));
          CREATE TRIGGER IF NOT EXISTS sensitivities_no_update BEFORE UPDATE ON learned_sensitivities
          BEGIN SELECT RAISE(ABORT,'learned sensitivities are immutable'); END;
          CREATE TRIGGER IF NOT EXISTS sensitivities_no_delete BEFORE DELETE ON learned_sensitivities
          BEGIN SELECT RAISE(ABORT,'learned sensitivities are immutable'); END;''')
        with db:
            for horizon,model in models.items():
                model_id=hashlib.sha256(json.dumps([manifest['datasetHash'],model],sort_keys=True).encode()).hexdigest()
                validation=result['validation'][horizon]
                db.execute('INSERT OR IGNORE INTO sensitivity_models VALUES(?,?,?,?,?,?)',
                           (model_id,manifest['datasetHash'],manifest['codeHash'],json.dumps(model),json.dumps(validation),available))
                status='standalone diagnostics passed, incremental engine validation pending' if validation.get('standaloneDiagnosticsPassed') else 'heldout validation failed'
                common=model['commonReturnCoefficients']
                for code,individual in model['stockSensitivities'].items():
                    for feature,base,delta in zip(['intercept']+model['features'],common,individual['coefficientDelta']):
                        coefficient=base+individual['shrinkageWeight']*delta
                        db.execute('INSERT OR IGNORE INTO learned_sensitivities VALUES(?,?,?,?,?,?,?,?,?)',
                                   (model_id,code,int(horizon),feature,coefficient,available,individual['trainRows'],individual['shrinkageWeight'],
                                    'Expected excess-return percentage points per training-standardized factor; conditional association, not causal; '+status+'; score weight zero'))
                        count+=1
        return dict(status='archived-research-associations',processedCoefficients=count,productionEnabled=False,scoreAdjustment=0)
    finally:db.close()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--run',required=True);parser.add_argument('--db',default=str(ROOT/'reports/factors.db'))
    args=parser.parse_args();print(json.dumps(archive(args.run,args.db)))
