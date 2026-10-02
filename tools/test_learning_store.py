import json
import tempfile
import unittest
from pathlib import Path
from learning_store import archive
from factor_store import connect, asof

class LearningStoreTests(unittest.TestCase):
    def test_dedup_scalers_and_availability(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);run=root/'run';run.mkdir();dbpath=root/'factors.db'
            model=dict(features=['return20'],mean=[0.1],scale=[0.2],commonReturnCoefficients=[1,2],stockSensitivities={'000660':dict(trainRows=150,shrinkageWeight=0.25,coefficientDelta=[0,4])})
            for name,value in [('manifest',dict(datasetHash='synthetic',codeHash='synthetic')),('models',{'20':model}),('result',dict(generatedAt='2026-01-01T00:00:00Z',validation={'20':dict(standaloneDiagnosticsPassed=False)}))]:
                (run/f'{name}.json').write_text(json.dumps(value),encoding='utf-8')
            archive(run,dbpath);archive(run,dbpath)
            db=connect(dbpath)
            try:
                self.assertEqual(db.execute('SELECT count(*) FROM learned_sensitivities').fetchone()[0],2)
                before=asof(db,'000660','2025-12-31T00:00:00Z')
                self.assertEqual(before['learnedPriceSensitivities'],[])
                after=asof(db,'000660','2026-01-02T00:00:00Z')
                coefficient=next(r['coefficient'] for r in after['learnedPriceSensitivities'] if r['feature']=='return20')
                self.assertEqual(coefficient,3)
                self.assertFalse(after['productionEnabled'])
                metadata=json.loads(db.execute('SELECT model_json FROM sensitivity_models').fetchone()[0])
                self.assertEqual(metadata['scale'],[0.2])
            finally:db.close()

if __name__=='__main__':unittest.main()
