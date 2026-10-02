"""Frozen price-factor research training with purged chronological calibration/test.

Uses historical bars only; never backfills past earnings/HBM with current values.
No production approval or automatic score activation.
"""
import argparse
import hashlib
import json
import math
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.request import urlopen

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
STORE = ROOT/'reports/medium-learning'
KST = timezone(timedelta(hours=9))
VERSION = 'medium-price-learning-v1'
FEATURES = ['return5','return20','return60','volatility20','ma20Deviation','volumeRatio20','marketReturn20','relativeReturn20']
POLICY = dict(horizons=[20,40,60],costPct=0.30,stressCostPct=0.60,trainFraction=0.60,
              calibrationFraction=0.20,ridge=10.0,minTrainDates=120,minCalibrationDates=20,
              minTestDates=20,minNonoverlapPeriods=6,selectionProbability=0.55,
              maximumScoreAdjustment=5,automaticActivation=False)

def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def save(path, data):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(data,ensure_ascii=False,indent=2,allow_nan=False),encoding='utf-8')
    tmp.replace(path)

def fingerprint(data):
    return hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()

def finite(value):
    if isinstance(value,bool):return None
    try:
        result=float(value)
        return result if math.isfinite(result) else None
    except (ValueError,TypeError):return None

def valid_bars(rows, stock=True):
    seen=set();result=[]
    cutoff=datetime.now(KST).strftime('%Y%m%d')
    for row in rows:
        date=str(row.get('date',''))
        if len(date)!=8 or not date.isdigit():raise ValueError('Invalid bar date')
        datetime.strptime(date,'%Y%m%d')
        if date in seen:raise ValueError('Duplicate price bar')
        seen.add(date)
        if date>=cutoff:continue
        fields=['open','price','low','volume'] if stock else ['open','price']
        values={name:finite(row.get(name)) for name in fields}
        if any(value is None or value<=0 for value in values.values()):continue
        result.append(dict(date=date,**values))
    return sorted(result,key=lambda row:row['date'])

def feature_vector(bars, indexes, i):
    if i<60:return None
    window=bars[i-60:i+1]
    # Exchange-index sessions provide the calendar; do not bridge missing stock bars.
    calendar=[date for date in indexes if window[0]['date']<=date<=window[-1]['date']]
    if [row['date'] for row in window]!=calendar:return None
    prices=np.array([row['price'] for row in window]);volumes=np.array([row['volume'] for row in window])
    last=prices[-1]
    r5=last/prices[-6]-1;r20=last/prices[-21]-1;r60=last/prices[0]-1
    market=indexes[window[-1]['date']]['price']/indexes[window[-21]['date']]['price']-1
    vol=float(np.std(np.diff(np.log(prices[-21:])),ddof=1))
    features=[r5,r20,r60,vol,last/float(prices[-20:].mean())-1,
              math.log(volumes[-1]/float(volumes[-21:-1].mean())),market,r20-market]
    return features if all(math.isfinite(v) for v in features) else None

def make_rows(payload, code, market):
    bars=valid_bars(payload['stockHistory']);index_bars=valid_bars(payload['indexHistory'],False)
    indexes={row['date']:row for row in index_bars}
    calendar=list(indexes);bydate={row['date']:row for row in bars};rows=[];latest=None;missing=0
    for i,bar in enumerate(bars):
        x=feature_vector(bars,indexes,i)
        if x is None:continue
        latest=dict(code=code,market=market,date=bar['date'],x=x)
        future=[date for date in calendar if date>bar['date']]
        for horizon in POLICY['horizons']:
            dates=future[:horizon]
            if len(dates)<horizon:continue
            if any(date not in bydate for date in dates):missing+=1;continue
            entry=bydate[dates[0]]['open'];exit=bydate[dates[-1]]['price']
            gross=100*(exit/entry-1);net=gross-POLICY['costPct']
            bench=100*(indexes[dates[-1]]['price']/indexes[dates[0]]['open']-1)
            rows.append(dict(code=code,market=market,date=bar['date'],entryDate=dates[0],exitDate=dates[-1],
                             horizon=horizon,x=x,netReturnPct=net,excessPct=net-bench,
                             stressReturnPct=gross-POLICY['stressCostPct'],
                             adverseExcursionPct=min(0,100*(min(bydate[d]['low'] for d in dates)/entry-1)),
                             y=int(net>0),excessY=int(net-bench>0)))
    return rows,latest,missing

def split_rows(rows):
    dates=sorted({row['date'] for row in rows})
    if len(dates)<180:raise ValueError('Insufficient chronological history')
    calibration_start=dates[int(len(dates)*POLICY['trainFraction'])]
    test_start=dates[int(len(dates)*(POLICY['trainFraction']+POLICY['calibrationFraction']))]
    train=[r for r in rows if r['date']<calibration_start and r['exitDate']<calibration_start]
    calibration=[r for r in rows if calibration_start<=r['date']<test_start and r['exitDate']<test_start]
    test=[r for r in rows if r['date']>=test_start]
    for values,minimum in [(train,POLICY['minTrainDates']),(calibration,POLICY['minCalibrationDates']),(test,POLICY['minTestDates'])]:
        if len({r['date'] for r in values})<minimum:raise ValueError('Insufficient purged partition dates')
    return train,calibration,test,dict(calibrationStart=calibration_start,testStart=test_start,
                                      purge='label exit strictly before next partition signal date')

def sigmoid(z):return 1/(1+np.exp(-np.clip(z,-30,30)))

def date_weights(rows):
    counts=defaultdict(int)
    for row in rows:counts[row['date']]+=1
    w=np.array([1/counts[r['date']] for r in rows]);return w/w.mean()

def fit_logistic(x,y,weights=None,ridge=10.0):
    if len(np.unique(y))!=2:raise ValueError('Both label classes are required')
    weights=np.ones(len(y)) if weights is None else weights
    beta=np.zeros(x.shape[1]);penalty=np.eye(x.shape[1])*ridge;penalty[0,0]=0
    for _ in range(60):
        p=sigmoid(x@beta);v=np.maximum(p*(1-p),1e-5)*weights
        step=np.linalg.solve(x.T@(v[:,None]*x)+penalty,x.T@((y-p)*weights)-penalty@beta)
        beta+=step
        if np.max(np.abs(step))<1e-7:break
    return beta

def nonoverlap_test(rows):
    groups=defaultdict(list)
    for row in rows:groups[row['date']].append(row)
    result=[];previous_exit=''
    for date,group in sorted(groups.items()):
        if previous_exit and min(r['entryDate'] for r in group)<=previous_exit:continue
        result.extend(group);previous_exit=max(r['exitDate'] for r in group)
    return result

def metrics(rows, probabilities, baseline):
    w=date_weights(rows);y=np.array([r['y'] for r in rows]);p=np.array(probabilities)
    bins=[]
    for low in np.arange(0,1,0.2):
        mask=(p>=low)&(p<min(1.0000001,low+0.2))
        if mask.any():bins.append(dict(low=round(float(low),2),count=int(mask.sum()),predicted=float(np.average(p[mask],weights=w[mask])),observed=float(np.average(y[mask],weights=w[mask]))))
    selected=p>=POLICY['selectionProbability']
    def avg(field,mask=None):
        values=np.array([r[field] for r in rows]);mask=np.ones(len(rows),dtype=bool) if mask is None else mask
        return float(np.average(values[mask],weights=w[mask])) if mask.any() else None
    return dict(rows=len(rows),nonOverlappingPeriods=len({r['date'] for r in rows}),
                brier=float(np.average((p-y)**2,weights=w)),baselineBrier=float(np.average((baseline-y)**2,weights=w)),
                calibrationBins=bins,selectedCount=int(selected.sum()),meanAllNetReturnPct=avg('netReturnPct'),
                selectedNetReturnPct=avg('netReturnPct',selected),selectedExcessPct=avg('excessPct',selected),
                selectedStressReturnPct=avg('stressReturnPct',selected),meanAdverseExcursionPct=avg('adverseExcursionPct'))

def train_horizon(rows, latest):
    train,calibration,test,partition=split_rows(rows)
    raw=np.array([r['x'] for r in train]);mean=raw.mean(axis=0);scale=np.maximum(raw.std(axis=0),1e-8)
    def design(values):return np.c_[np.ones(len(values)),(np.array([r['x'] for r in values])-mean)/scale]
    x=design(train);w=date_weights(train);models={};predicted={}
    for label in ['y','excessY']:
        beta=fit_logistic(x,np.array([r[label] for r in train]),w,POLICY['ridge'])
        cal_logits=design(calibration)@beta
        calibrator=fit_logistic(np.c_[np.ones(len(calibration)),cal_logits],np.array([r[label] for r in calibration]),date_weights(calibration),POLICY['ridge'])
        models[label]=dict(coefficients=beta.tolist(),calibrator=calibrator.tolist())
        predicted[label]=lambda values,b=beta,c=calibrator:sigmoid(c[0]+c[1]*(design(values)@b))
    # Ridge regression describes conditional return association, not causal sensitivity.
    penalty=np.eye(x.shape[1])*POLICY['ridge'];penalty[0,0]=0
    regression=np.linalg.solve(x.T@(w[:,None]*x)+penalty,x.T@(w*np.array([r['excessPct'] for r in train])))
    code_models={}
    for code in sorted({r['code'] for r in train}):
        subset=[r for r in train if r['code']==code]
        if len(subset)<120:continue
        cx=design(subset);cy=np.array([r['excessPct'] for r in subset])-cx@regression
        delta=np.linalg.solve(cx.T@cx+np.eye(cx.shape[1])*100,cx.T@cy)
        shrink=min(0.25,len(subset)/1000)
        code_models[code]=dict(trainRows=len(subset),shrinkageWeight=shrink,coefficientDelta=delta.tolist())
    holdout=nonoverlap_test(test);baseline=float(np.average([r['y'] for r in train],weights=w))
    validation=metrics(holdout,predicted['y'](holdout),baseline)
    validation['partitions']=partition
    validation['trainRows']=len(train);validation['calibrationRows']=len(calibration);validation['testRows']=len(test)
    diagnostics=(validation['nonOverlappingPeriods']>=POLICY['minNonoverlapPeriods'] and validation['brier']<validation['baselineBrier'] and
                 (validation['selectedStressReturnPct'] or -1)>0 and (validation['selectedExcessPct'] or -1)>0)
    validation['standaloneDiagnosticsPassed']=bool(diagnostics)
    forecasts=[]
    for row,prob,excess_prob in zip(latest,predicted['y'](latest),predicted['excessY'](latest)):
        expected=float(design([row])[0]@regression)
        individual=code_models.get(row['code'])
        if individual:expected+=individual['shrinkageWeight']*float(design([row])[0]@np.array(individual['coefficientDelta']))
        forecasts.append(dict(code=row['code'],market=row['market'],priceAsOf=row['date'],researchRiseProbability=float(prob),
                              researchOutperformanceProbability=float(excess_prob),researchExpectedExcessPct=expected,
                              scoreAdjustment=0,activationBlockers=['incremental-legacy-engine-validation-required','point-in-time-universe-and-corporate-actions-required']+
                              ([] if diagnostics else ['standalone-holdout-diagnostics-not-passed'])))
    model=dict(features=FEATURES,mean=mean.tolist(),scale=scale.tolist(),classifiers=models,
               commonReturnCoefficients=regression.tolist(),stockSensitivities=code_models,
               sensitivityInterpretation='shrunk standardized conditional associations; not causal')
    predictions=[dict(code=r['code'],date=r['date'],exitDate=r['exitDate'],netReturnPct=r['netReturnPct'],probability=float(p)) for r,p in zip(holdout,predicted['y'](holdout))]
    return model,validation,forecasts,predictions

def collect(snapshot, run):
    universe={(r['market'],r['code']) for r in snapshot.get('items',[])+snapshot.get('mediumTerm',{}).get('items',[]) if r.get('market') in ('KOSPI','KOSDAQ') and r.get('code')}
    universe.add(('KOSPI','000660'))
    save(run/'universe.json',dict(sourceGeneratedAt=snapshot.get('generatedAtISO'),instruments=sorted(universe),selection='current saved candidate universe plus user HBM example; survivorship unresolved'))
    failures={};histories=[]
    for i,(market,code) in enumerate(sorted(universe),1):
        try:
            with urlopen(f'http://127.0.0.1:8787/history/{code}/{market}',timeout=60) as response:payload=json.load(response)
            valid_bars(payload.get('stockHistory',[]));valid_bars(payload.get('indexHistory',[]),False)
            save(run/'prices'/f'{market}-{code}.json',payload)
            histories.append((market,code,payload))
        except Exception as error:failures[f'{market}-{code}']=type(error).__name__
        print(f'Collected {i}/{len(universe)}; failed={len(failures)}',flush=True)
        time.sleep(0.15)
    save(run/'collection.json',dict(attempted=len(universe),successful=len(histories),failures=failures))
    if failures:raise RuntimeError('Collection incomplete; refusing survivor-only training')
    return histories

def build(run):
    if (run/'manifest.json').exists():raise ValueError('Frozen run already exists; do not reuse its holdout for tuning')
    histories=[(p.stem.split('-')[0],p.stem.split('-')[1],read(p)) for p in sorted((run/'prices').glob('*.json'))]
    if len(histories)<5:raise ValueError('At least five instruments required')
    if (run/'collection.json').exists() and read(run/'collection.json').get('failures'):raise ValueError('Incomplete collection')
    dataset=[];latest=[];missing=0
    for market,code,payload in histories:
        rows,current,excluded=make_rows(payload,code,market);dataset.extend(rows);missing+=excluded
        if current:latest.append(current)
    # A previously evaluated short-term holdout cannot become a fresh medium-term holdout.
    reserved_path=ROOT/'reports/target10/manifest.json'
    reserved_start=read(reserved_path).get('holdoutStart') if reserved_path.exists() else None
    excluded_reserved=0
    if reserved_start:
        reserved_start=reserved_start.replace('-','')
        allowed=[row for row in dataset if row['exitDate']<reserved_start]
        excluded_reserved=len(dataset)-len(allowed);dataset=allowed
    manifest=dict(version=VERSION,policy=POLICY,features=FEATURES,datasetHash=fingerprint(dataset),
                  codeHash=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),generatedAt=datetime.now(KST).isoformat(),
                  status='frozen-before-fit',excludedMissingSessionLabels=missing,
                  reservedPriorHoldoutStart=reserved_start,excludedPriorHoldoutLabels=excluded_reserved,
                  limitations=['current-selected-universe-survivorship','latest-adjusted-bars-not-point-in-time-adjustment-history','no-historical-earnings-revisions-or-HBM-data','no-causal-inference','no-incremental-engine-comparison','nonoverlap-does-not-prove-independence'])
    save(run/'dataset.json',dataset);save(run/'manifest.json',manifest)
    (run/'training-source.py').write_bytes(Path(__file__).read_bytes())
    models={};validation={};forecasts=defaultdict(dict)
    for horizon in POLICY['horizons']:
        try:
            model,metrics_,predictions,test=train_horizon([r for r in dataset if r['horizon']==horizon],latest)
            models[str(horizon)]=model;validation[str(horizon)]=metrics_
            save(run/f'holdout-{horizon}.json',test)
            for row in predictions:forecasts[row['code']][str(horizon)]=row
        except ValueError as error:validation[str(horizon)]=dict(status='insufficient-data',reason=str(error))
    save(run/'models.json',models);save(run/'validation.json',validation)
    result=dict(version=VERSION,generatedAt=datetime.now(KST).isoformat(),status='trained-shadow-only' if models else 'insufficient-data',
                productionEnabled=False,runDirectory=str(run),policy=POLICY,manifest=manifest,validation=validation,
                modelsTrained=len(models),items=[dict(code=code,horizons=values) for code,values in sorted(forecasts.items())])
    save(run/'result.json',result);save(STORE/'latest.json',result)
    print(json.dumps(dict(status=result['status'],modelsTrained=len(models),validation=validation),ensure_ascii=False),flush=True)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['collect','train','build'])
    parser.add_argument('--run');parser.add_argument('--snapshot',default=str(ROOT/'reports/web-recommendations.json'))
    args=parser.parse_args();run=Path(args.run) if args.run else STORE/'runs'/datetime.now(KST).strftime('%Y%m%d-%H%M%S')
    if args.action in ('collect','build') and (run/'manifest.json').exists():
        raise ValueError('Cannot recollect into a frozen training run')
    if args.action in ('collect','build'):collect(read(args.snapshot),run)
    if args.action in ('train','build'):build(run)

if __name__=='__main__':main()
