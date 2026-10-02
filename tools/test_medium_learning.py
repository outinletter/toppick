import unittest
from datetime import datetime, timedelta
import numpy as np
from medium_learning import make_rows, feature_vector, valid_bars, split_rows, nonoverlap_test, fit_logistic, sigmoid

def fixture():
    rows=[];date=datetime(2020,1,1)
    for i in range(700):
        while date.weekday()>4:date+=timedelta(days=1)
        price=100*np.exp(0.0001*i+0.15*np.sin(i/23))
        rows.append(dict(date=date.strftime('%Y%m%d'),open=price*0.999,price=price,low=price*0.97,volume=1000+100*np.sin(i/7)))
        date+=timedelta(days=1)
    return dict(stockHistory=rows,indexHistory=[dict(date=r['date'],open=100,price=100) for r in rows])

class LearningTests(unittest.TestCase):
    def test_labels_and_no_future_feature_leak(self):
        payload=fixture();rows,latest,missing=make_rows(payload,'000001','KOSPI')
        self.assertEqual(missing,0)
        row=next(r for r in rows if r['horizon']==20)
        bars=payload['stockHistory'];self.assertEqual(row['entryDate'],bars[61]['date'])
        expected=100*(bars[80]['price']/bars[61]['open']-1)-0.30
        self.assertAlmostEqual(row['netReturnPct'],expected)
        original=row['x']
        payload['stockHistory'][81]['price']*=10
        mutated=make_rows(payload,'000001','KOSPI')[0]
        self.assertEqual(next(r for r in mutated if r['horizon']==20)['x'],original)
    def test_purged_split_and_nonoverlap(self):
        rows,_,_=make_rows(fixture(),'000001','KOSPI');rows=[r for r in rows if r['horizon']==60]
        train,cal,test,partition=split_rows(rows)
        self.assertLess(max(r['exitDate'] for r in train),partition['calibrationStart'])
        self.assertLess(max(r['exitDate'] for r in cal),partition['testStart'])
        periods=nonoverlap_test(test)
        for prior,later in zip(periods,periods[1:]):self.assertLess(prior['exitDate'],later['entryDate'])
    def test_invalid_bars_and_missing_calendar(self):
        payload=fixture()
        with self.assertRaises(ValueError):valid_bars(payload['stockHistory']+[payload['stockHistory'][0]])
        indexes={r['date']:r for r in payload['indexHistory']}
        bars=valid_bars(payload['stockHistory']);bars.pop(30)
        self.assertIsNone(feature_vector(bars,indexes,60))
    def test_regularized_logistic(self):
        x=np.c_[np.ones(100),np.linspace(-2,2,100)];y=(x[:,1]>0).astype(float)
        beta=fit_logistic(x,y,ridge=10)
        self.assertGreater(sigmoid(x[-1]@beta),sigmoid(x[0]@beta))
        with self.assertRaises(ValueError):fit_logistic(x,np.ones(100))

if __name__=='__main__':unittest.main()
