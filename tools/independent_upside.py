"""Independent upside evidence engines. No legacy recommendation scores or lists.

collect: enumerate market listings and collect raw daily bars for a liquidity pilot.
analyze: run source admission, regime, price/volume, flow, revision/event and risk engines.
Optional dated source envelopes can be supplied in reports/independent-upside/supplements.json.
"""
import argparse
from datetime import datetime, time, timedelta, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import time as clock
from urllib.request import Request, urlopen

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "reports" / "independent-upside"
KST = timezone(timedelta(hours=9))
VERSION = "independent-upside-v1"
DEFAULTS = {"minimumHistory": 61, "minimumAdvKrw": 5_000_000_000,
            "volumeExpansion": 1.5, "atrStopMultiple": 1.5,
            "maximumStructuralRiskPct": 8.0, "riskBudgetPct": 0.25,
            "maximumPositionPct": 5.0, "maximumAdvParticipation": 0.001,
            "netTargetPct": 10.0, "roundTripCostPct": 0.35,
            "slippagePct": {"KOSPI": 0.10, "KOSDAQ": 0.20},
            "maximumSpreadBps": 30, "minimumIndependentSupports": 2}


def now():
    return datetime.now(KST)


def timestamp(value):
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        raise ValueError("Explicit timezone required")
    return dt.astimezone(KST)


def number(value):
    if value is None or isinstance(value, bool): return None
    try:
        result = float(str(value).replace(",", ""))
        return result if math.isfinite(result) else None
    except (ValueError, TypeError): return None


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write(path, payload):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    tmp.replace(path)


def fetch(url):
    request = Request(url, headers={"User-Agent": "TopPicks independent research"})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def envelope_status(envelope, decision, max_age):
    if not isinstance(envelope, dict): return "missing"
    try:
        observed = timestamp(envelope["collectedAt"])
        available = max(observed, timestamp(envelope["publishedAt"])) if envelope.get("publishedAt") else observed
        if available > decision: return "future-information"
        if decision - available > max_age: return "stale"
        if not envelope.get("source"): return "missing-source"
        return "available"
    except (KeyError, TypeError, ValueError): return "invalid-provenance"


def market_engine(index_bars):
    closes = np.array([float(b["price"]) for b in index_bars[-61:]])
    if len(closes) < 61 or np.any(closes <= 0): return {"status": "missing", "regime": "unknown"}
    ret = np.diff(np.log(closes))
    five = float((closes[-1]/closes[-6]-1)*100)
    vol = float(np.std(ret[-20:], ddof=1)*100)
    regime = "supportive" if closes[-1] > closes[-20:].mean() and five > 0 else "defensive" if five < 0 and closes[-1] < closes[-20:].mean() else "mixed"
    return {"status": "available", "regime": regime, "return5Pct": five,
            "return20Pct": float((closes[-1]/closes[-21]-1)*100), "dailyVolatility20Pct": vol}


def price_volume_engine(bars, indices, config):
    close = np.array([b["price"] for b in bars], dtype=float)
    high = np.array([b["high"] for b in bars], dtype=float)
    low = np.array([b["low"] for b in bars], dtype=float)
    op = np.array([b["open"] for b in bars], dtype=float)
    volume = np.array([b["volume"] for b in bars], dtype=float)
    value = np.array([b["tradingValueKrw"] for b in bars], dtype=float)
    true_range = np.maximum(high[1:]-low[1:], np.maximum(abs(high[1:]-close[:-1]), abs(low[1:]-close[:-1])))
    atr = float(true_range[-14:].mean())
    volume_base = float(volume[-21:-1].mean())
    relative_volume = float(volume[-1]/volume_base) if volume_base > 0 else None
    adv = float(value[-21:-1].mean())
    last_range = high[-1]-low[-1]
    close_location = float((close[-1]-low[-1])/last_range) if last_range > 0 else .5
    index_by_date = {b["date"]: b["price"] for b in indices}
    common = [b for b in bars[-61:] if b["date"] in index_by_date]
    beta = residual = None
    if len(common) >= 41:
        sx = np.array([b["price"] for b in common], dtype=float)
        ix = np.array([index_by_date[b["date"]] for b in common], dtype=float)
        sr, ir = np.diff(np.log(sx)), np.diff(np.log(ix))
        if np.var(ir) > 1e-12:
            beta = float(np.cov(sr, ir, ddof=0)[0,1]/np.var(ir))
            residual = float((sr[-20:]-beta*ir[-20:]).sum()*100)
    breakout = bool(close[-1] > high[-21:-1].max() and relative_volume is not None
                    and relative_volume >= config["volumeExpansion"] and close_location >= .7)
    trend = bool(close[-1] > close[-20:].mean() > close[-60:].mean())
    short_atr, old_atr = float(true_range[-10:].mean()), float(true_range[-30:-10].mean())
    compression = short_atr/old_atr if old_atr > 0 else None
    gaps = (op[-20:]/close[-21:-1]-1)*100
    return {"status": "available", "atr14": atr, "atrPct": atr/close[-1]*100,
            "adv20Krw": adv, "relativeVolume": relative_volume, "closeLocation": close_location,
            "return5Pct": float((close[-1]/close[-6]-1)*100),
            "return20Pct": float((close[-1]/close[-21]-1)*100),
            "beta60": beta, "residualMomentum20Pct": residual, "breakoutConfirmed": breakout,
            "trendAligned": trend, "rangeCompression": compression,
            "distanceToPrior20HighPct": float((close[-1]/high[-21:-1].max()-1)*100),
            "worstOpeningGap20Pct": float(gaps.min()),
            "amihud20PctPerBillionKrw": float(np.mean(abs(np.diff(close[-21:])/close[-21:-1])*100/(value[-20:]/1e9))),
            "liquid": adv >= config["minimumAdvKrw"]}


def flow_engine(envelope, decision, price, market_cap):
    status = envelope_status(envelope, decision, timedelta(days=7))
    if status != "available": return {"status": status}
    if envelope.get("unit") != "KRW": return {"status": "invalid-unit"}
    rows = sorted(envelope.get("rows", []), key=lambda r:r["date"])
    if len(rows) < 20 or len({r["date"] for r in rows}) != len(rows): return {"status": "insufficient-or-duplicate-rows"}
    try:
        age = (decision.date()-datetime.strptime(rows[-1]["date"], "%Y%m%d").date()).days
        if not 0 <= age <= 7: return {"status": "stale-or-future-asof"}
    except ValueError: return {"status": "invalid-date"}
    fields = ("foreignNetKrw", "institutionNetKrw", "pensionNetKrw", "trustNetKrw")
    if any(number(r.get(k)) is None for r in rows[-20:] for k in fields): return {"status": "missing-components"}
    rows = [{**r, **{k:number(r[k]) for k in fields}} for r in rows[-20:]]
    foreign = sum(float(r["foreignNetKrw"]) for r in rows[-5:])
    institution = sum(float(r["institutionNetKrw"]) for r in rows[-5:])
    persistent = sum(r["foreignNetKrw"]+r["institutionNetKrw"] > 0 for r in rows[-5:])
    total20 = sum(r["foreignNetKrw"]+r["institutionNetKrw"] for r in rows[-20:])
    return {"status": "available", "asOf": rows[-1]["date"], "foreign5Krw": foreign,
            "institution5Krw": institution, "positiveDays5": persistent,
            "net20ToMarketCapPct": total20/market_cap*100 if market_cap else None,
            "net20ToTurnoverPct": total20/(price["adv20Krw"]*20)*100,
            "accumulationConfirmed": foreign>0 and institution>0 and persistent>=3}


def revision_engine(envelope, decision):
    status = envelope_status(envelope, decision, timedelta(days=30))
    if status != "available": return {"status": status}
    groups = {}
    for row in envelope.get("rows", []):
        if not row.get("broker") or not row.get("fiscalPeriod") or row.get("metric") not in ("EPS", "operatingProfit", "revenue", "targetPrice"): continue
        try:
            published = timestamp(row["publishedAt"])
            if published > decision or (decision-published).days > 90: continue
        except (KeyError, ValueError): continue
        value = number(row.get("value"))
        if value is None or not row.get("currency") or not row.get("unit"): continue
        key = (row["broker"], row["fiscalPeriod"], row["metric"], row["currency"], row["unit"])
        groups.setdefault(key, []).append((published,value))
    changes = []
    for key, series in groups.items():
        series = sorted(set(series))
        if len(series)<2 or series[-2][1] == 0 or series[-2][0] == series[-1][0]: continue
        change = (series[-1][1]-series[-2][1])/abs(series[-2][1])*100
        changes.append({"broker":key[0],"fiscalPeriod":key[1],"metric":key[2],"changePct":change})
    earnings = [x for x in changes if x["metric"] in ("EPS","operatingProfit")]
    brokers = {x["broker"] for x in earnings}
    return {"status": "available" if changes else "insufficient-comparable-revisions", "changes": changes,
            "positiveBreadth": sum(x["changePct"]>0 for x in earnings)/len(earnings) if earnings else None,
            "revisionConfirmed": len(brokers)>=2 and bool(earnings) and all(x["changePct"]>0 for x in earnings)}


def catalyst_engine(envelope, decision):
    status = envelope_status(envelope, decision, timedelta(days=7))
    if status != "available": return {"status": status}
    catalysts, risks = [], []
    for row in envelope.get("rows", []):
        try:
            published = timestamp(row["publishedAt"])
            if published > decision or decision-published > timedelta(days=7): continue
        except (KeyError, ValueError): continue
        if not row.get("sourceId"): continue
        if row.get("type") in ("dilution", "trading-halt", "adverse-audit", "delisting"):
            risks.append({"type":row["type"],"sourceId":row["sourceId"]})
        if row.get("type") == "earnings":
            actual, consensus = number(row.get("actual")), number(row.get("consensus"))
            try:
                prior = timestamp(row["consensusPublishedAt"]) < published
            except (KeyError, ValueError): prior = False
            if prior and actual is not None and consensus not in (None,0) and row.get("comparableBasis") is True:
                surprise = (actual-consensus)/abs(consensus)*100
                catalysts.append({"type":"earnings-surprise","surprisePct":surprise,"sourceId":row["sourceId"]})
    return {"status":"available", "catalysts":catalysts, "risks":risks,
            "positiveCatalyst":any(x["surprisePct"]>0 for x in catalysts)}


def execution_engine(envelope, decision, config):
    status = envelope_status(envelope, decision, timedelta(seconds=60))
    if status != "available": return {"status":status}
    try:
        age=decision-timestamp(envelope["quoteAt"])
        if not timedelta(0)<=age<=timedelta(seconds=60):return {"status":"stale-or-future-quote"}
    except (KeyError,TypeError,ValueError):return {"status":"missing-quote-timestamp"}
    bid, ask = number(envelope.get("bid")), number(envelope.get("ask"))
    if bid is None or ask is None or bid <= 0 or ask <= 0 or bid > ask or not envelope.get("venue"): return {"status":"invalid-quote"}
    spread = (ask-bid)/((ask+bid)/2)*10000
    return {"status":"available", "spreadBps":spread, "venue":envelope["venue"],
            "executable":spread<=config["maximumSpreadBps"] and envelope.get("tradingStatus")=="TRADING"}


def sector_engine(envelope, decision):
    status = envelope_status(envelope, decision, timedelta(days=7))
    if status != "available": return {"status":status}
    rows = sorted(envelope.get("rows",[]),key=lambda r:r["date"])
    if len(rows)<21 or len({r["date"] for r in rows}) != len(rows): return {"status":"insufficient-or-duplicate-rows"}
    if not envelope.get("sectorId") or not envelope.get("membershipAsOf"): return {"status":"missing-sector-membership"}
    if envelope["membershipAsOf"]>decision.strftime("%Y%m%d"):return {"status":"future-membership"}
    age=(decision.date()-datetime.strptime(rows[-1]["date"],"%Y%m%d").date()).days
    if not 0<=age<=7:return {"status":"stale-or-future-asof"}
    if any(number(r.get(k)) is None or number(r[k])<=0 for r in rows[-21:] for k in ("sectorClose","marketClose")):
        return {"status":"invalid-prices"}
    relative=[]
    for n in (5,20):
        relative.append(((number(rows[-1]["sectorClose"])/number(rows[-1-n]["sectorClose"])-1)-
                         (number(rows[-1]["marketClose"])/number(rows[-1-n]["marketClose"])-1))*100)
    return {"status":"available","sectorId":envelope["sectorId"],"relativeReturn5Pct":relative[0],
            "relativeReturn20Pct":relative[1],"rotationPersistent":all(x>0 for x in relative)}


def short_pressure_engine(envelope, decision):
    status=envelope_status(envelope,decision,timedelta(days=7))
    if status!="available":return {"status":status}
    if envelope.get("ratioUnit")!="percent":return {"status":"invalid-unit"}
    rows=sorted(envelope.get("rows",[]),key=lambda r:r["date"])
    if len(rows)<5 or len({r["date"] for r in rows})!=len(rows):return {"status":"insufficient-or-duplicate-rows"}
    age=(decision.date()-datetime.strptime(rows[-1]["date"],"%Y%m%d").date()).days
    if not 0<=age<=7:return {"status":"stale-or-future-asof"}
    if any(number(r.get("shortTurnoverPct")) is None or not 0<=number(r["shortTurnoverPct"])<=100 for r in rows[-5:]):
        return {"status":"invalid-short-ratio"}
    result={"status":"available","asOf":rows[-1]["date"],"shortTurnover5Pct":sum(number(r["shortTurnoverPct"]) for r in rows[-5:])/5,
            "balanceStatus":"missing","lendingStatus":"missing","squeezeConfirmed":False}
    for prefix,field in (("balance","shortBalancePct"),("lending","lendingBalanceShares")):
        observations=envelope.get(prefix+"Rows",[])
        eligible=[]
        for row in observations:
            lag=(decision.date()-datetime.strptime(row["date"],"%Y%m%d").date()).days
            value=number(row.get(field))
            if 0<=lag<=7 and value is not None and value>=0:eligible.append((row["date"],value))
        eligible=sorted(set(eligible))
        if eligible:
            result[prefix+"Status"]="available";result[prefix+"AsOf"]=eligible[-1][0]
            result[field]=eligible[-1][1]
            result[prefix+"Change"]=eligible[-1][1]-eligible[-2][1] if len(eligible)>1 else None
    return result


def risk_engine(bars, price, market, config):
    close = bars[-1]["price"]
    slip = config["slippagePct"][market]/100
    entry = close*(1+slip)
    # Independent invalidation: wider of a 5-session structural low and 1.5 ATR.
    stop = min(min(b["low"] for b in bars[-5:]), close-config["atrStopMultiple"]*price["atr14"])
    risk_pct = (entry-stop*(1-slip))/entry*100 + config["roundTripCostPct"]
    target = entry*(1+(config["netTargetPct"]+config["roundTripCostPct"])/100)/(1-slip)
    return {"status":"available", "referenceEntry":entry, "structuralStop":stop,
            "indicativeNet10Target":target, "netStopRiskPct":risk_pct,
            "targetDistanceAtr":(target-close)/price["atr14"] if price["atr14"]>0 else None,
            "positionCapPct":min(config["maximumPositionPct"],config["riskBudgetPct"]/risk_pct*100) if risk_pct>0 else 0,
            "liquidityOrderCapKrw":price["adv20Krw"]*config["maximumAdvParticipation"],
            "riskAcceptable":stop>0 and 0<risk_pct<=config["maximumStructuralRiskPct"],
            "assumptions":"Indicative close-based entry; reprice at execution; gaps can exceed stop risk."}


def analyze_instrument(raw, supplement, decision, config):
    status = envelope_status(raw, decision, timedelta(hours=24))
    if status != "available": return {"status":status}
    bars = sorted(raw.get("bars",[]),key=lambda r:r["date"])
    bars = [b for b in bars if datetime.combine(datetime.strptime(b["date"],"%Y%m%d").date(),time(16),KST)<=decision]
    if len(bars)<config["minimumHistory"] or len({b["date"] for b in bars})!=len(bars): return {"status":"insufficient-or-duplicate-bars"}
    bars = [{**b, **{k:number(b.get(k)) for k in ("open","high","low","price","volume","tradingValueKrw")}} for b in bars[-61:]]
    for bar in bars[-61:]:
        if any(number(bar.get(k)) is None or number(bar[k])<=0 for k in ("open","high","low","price","volume","tradingValueKrw")):
            return {"status":"invalid-ohlcv-or-turnover"}
        if not bar["low"]<=min(bar["open"],bar["price"])<=max(bar["open"],bar["price"])<=bar["high"]:
            return {"status":"inconsistent-ohlc"}
    if (decision.date()-datetime.strptime(bars[-1]["date"],"%Y%m%d").date()).days>7: return {"status":"stale-price-session"}
    indices=sorted(raw.get("indices",[]),key=lambda r:r["date"])
    indices=[b for b in indices if b["date"]<=bars[-1]["date"]]
    if (not indices or indices[-1]["date"] != bars[-1]["date"] or
        len({b["date"] for b in indices}) != len(indices) or
        any(number(b.get("price")) is None or number(b["price"]) <= 0 for b in indices)):
        indices=[]
    else:
        indices=[{**b,"price":number(b["price"])} for b in indices]
    regime=market_engine(indices)
    price=price_volume_engine(bars,indices,config)
    flow=flow_engine(supplement.get("flow"),decision,price,raw.get("marketCapKrw"))
    revisions=revision_engine(supplement.get("revisions"),decision)
    catalyst=catalyst_engine(supplement.get("events"),decision)
    execution=execution_engine(supplement.get("quote"),decision,config)
    sector=sector_engine(supplement.get("sector"),decision)
    short_pressure=short_pressure_engine(supplement.get("shortPressure"),decision)
    risk=risk_engine(bars,price,raw["market"],config)
    supports=[]
    if price["breakoutConfirmed"]:supports.append("price-volume-breakout")
    if flow.get("accumulationConfirmed"):supports.append("persistent-accumulation")
    if revisions.get("revisionConfirmed") or catalyst.get("positiveCatalyst"):supports.append("earnings-information-repricing")
    blockers=[]
    if regime.get("regime") in ("defensive","unknown"):blockers.append("market-not-supportive")
    if not price["liquid"]:blockers.append("insufficient-turnover")
    if not risk["riskAcceptable"]:blockers.append("structural-risk-too-large")
    if catalyst.get("risks"):blockers.append("adverse-event")
    if catalyst.get("status") != "available":blockers.append("event-risk-not-verified")
    if sector.get("status") != "available":blockers.append("sector-not-verified")
    if short_pressure.get("status") != "available":blockers.append("short-pressure-not-verified")
    if execution.get("executable") is not True:blockers.append("execution-not-verified")
    if len(supports)<config["minimumIndependentSupports"]:blockers.append("insufficient-independent-evidence")
    if raw.get("instrumentVerified") is not True:blockers.append("security-master-not-verified")
    if raw.get("venueScopeVerified") is not True:blockers.append("venue-scope-not-verified")
    if raw.get("corporateActionsVerified") is not True:blockers.append("corporate-actions-not-verified")
    components={"regime":regime,"sector":sector,"priceVolume":price,"flow":flow,"revisions":revisions,"catalysts":catalyst,"shortPressure":short_pressure,"execution":execution,"risk":risk}
    hypotheses=[]
    if price["breakoutConfirmed"]:hypotheses.append("breakout-continuation")
    if revisions.get("revisionConfirmed") or catalyst.get("positiveCatalyst"):hypotheses.append("information-repricing")
    if flow.get("accumulationConfirmed") and price["trendAligned"]:hypotheses.append("accumulation-trend")
    return {"status":"analyzed", "code":raw["code"],"name":raw.get("name"),"market":raw["market"],
            "decisionAt":decision.isoformat(),"sourceAvailableAt":max(timestamp(raw["collectedAt"]),timestamp(raw.get("publishedAt",raw["collectedAt"]))).isoformat(),
            "priceAsOf":bars[-1]["date"],"components":components,
            "hypotheses":hypotheses,"independentSupports":supports,"entryBlockers":blockers,
            "probabilities":{"targetBeforeStop":None,"stopBeforeTarget":None,"status":"independent-pit-training-required"},
            "action":"research-watchlist","productionEnabled":False}


def fetch_market_listings(market, page_size=100, max_passes=3):
    unique={}; pages=[]; expected=0
    for attempt in range(1,max_passes+1):
        for page in range(1,101):
            response=fetch(f"https://m.stock.naver.com/api/stocks/marketValue/{market}?page={page}&pageSize={page_size}")
            rows=response.get("stocks",[])
            expected=max(expected,int(response["totalCount"]))
            pages.append({"market":market,"pass":attempt,"page":page,"collectedAt":now().isoformat(),"payload":response})
            for row in rows:
                if row.get("itemCode"):unique.setdefault(row["itemCode"],row)
            if not rows or page*page_size>=int(response["totalCount"]):break
        if expected>0 and len(unique)>=expected:break
    return list(unique.values()),pages,{"market":market,"observedCount":len(unique),"reportedCount":expected,
                                       "passes":attempt,"completeByCount":expected>0 and len(unique)>=expected,
                                       "atomicSnapshot":False}


def collect(limit):
    created=now().strftime("%Y%m%d-%H%M%S-%f")
    folder=STORE/"raw"/created
    universe=[]; pages=[]; listing_coverage=[]
    for market in ("KOSPI","KOSDAQ"):
        rows,market_pages,coverage=fetch_market_listings(market)
        pages.extend(market_pages);listing_coverage.append(coverage)
        write(folder/"universe.json",{"source":"Naver market listings","collectedAt":now().isoformat(),"coverage":listing_coverage,"pages":pages})
        if not coverage["completeByCount"]:raise ValueError(f"Incomplete {market} listing after bounded retries; original pages archived")
        for row in rows:
            code=row.get("itemCode");name=row.get("stockName","")
            if row.get("stockEndType")!="stock" or not re.fullmatch(r"\d{6}",str(code)):continue
            if re.search(r"스팩|SPAC|우$|우B$|우C$",name):continue
            if row.get("tradeStopType",{}).get("name")!="TRADING":continue
            turnover=number(row.get("accumulatedTradingValueRaw"));market_cap=number(row.get("marketValueRaw"))
            if not turnover or turnover<=0:continue
            universe.append({"code":code,"name":name,"market":market,"turnoverKrw":turnover,"marketCapKrw":market_cap})
    # Liquidity capacity pilot, independent of legacy rankings and recommendation lists.
    selected=sorted(universe,key=lambda x:(-x["turnoverKrw"],x["code"]))[:limit]
    records=[];errors={}
    for i,stock in enumerate(selected,1):
        try:
            response=fetch(f"http://127.0.0.1:8787/history/{stock['code']}/{stock['market']}")
            raw={**stock,"source":"Kiwoom daily raw adapter","collectedAt":response.get("collectedAt",now().isoformat()),
                 "bars":response.get("stockHistory",[]),"indices":response.get("indexHistory",[]),
                 "priceBasis":"provider-adjusted","instrumentVerified":False,
                 "venueScopeVerified":False,"corporateActionsVerified":False}
            write(folder/(stock["market"]+"-"+stock["code"]+".json"),raw)
            records.append(raw)
        except Exception as error:errors[stock["code"]]=type(error).__name__
        if i%10==0 or i==len(selected):print(f"Independent raw collection {i}/{len(selected)}",flush=True)
        clock.sleep(.1)
    collected={"version":VERSION,"createdAt":now().isoformat(),"rawDirectory":str(folder.relative_to(ROOT)),
               "universeCount":len(universe),"listingCoverage":listing_coverage,"pilotLimit":limit,"errors":errors,"records":records}
    write(folder/"input.json",collected);write(STORE/"input.json",collected)
    print(f"Universe={len(universe)}, independent pilot={len(records)}, failures={len(errors)}",flush=True)


def analyze(config, decision=None, input_path=None):
    input_path=Path(input_path) if input_path else STORE/"input.json"; data=read(input_path)
    supplements=read(STORE/"supplements.json") if (STORE/"supplements.json").exists() else {}
    decision=decision or now()
    results=[]
    for raw in data["records"]:
        try:
            result=analyze_instrument(raw,supplements.get(raw["code"],{}),decision,config)
        except (ValueError,TypeError,KeyError,ZeroDivisionError) as error:
            result={"status":"invalid-source","errorType":type(error).__name__}
        results.append({"code":raw["code"],"name":raw["name"],**result})
    results.sort(key=lambda x:(-len(x.get("independentSupports",[])), -float(x.get("components",{}).get("priceVolume",{}).get("residualMomentum20Pct") or 0),x["code"]))
    report={"version":VERSION,"generatedAt":decision.isoformat(),"sourceInputHash":hashlib.sha256(input_path.read_bytes()).hexdigest(),
            "supplements":supplements,
            "sourceDirectory":data["rawDirectory"],"config":config,"productionEnabled":False,
            "universeCount":data["universeCount"],"pilotCount":len(results),"collectionErrors":data["errors"],
            "listingCoverage":data.get("listingCoverage"),
            "legacyScoresUsed":False,"legacyCandidateListUsed":False,"items":results,
            "validation":{"status":"independent-pit-training-required","target10LegacyHoldoutReused":False}}
    archive=STORE/"snapshots"/(now().strftime("%Y%m%d-%H%M%S-%f")+".json")
    write(archive,report);write(STORE/"latest.json",report)
    print(json.dumps({"analyzed":sum(x["status"]=="analyzed" for x in results),"total":len(results),"productionEnabled":False},ensure_ascii=False),flush=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode",choices=("collect","analyze","run"))
    parser.add_argument("--limit",type=int,default=30)
    parser.add_argument("--config",type=Path)
    parser.add_argument("--as-of",help="Explicit timezone timestamp for replay; future sources remain inadmissible")
    parser.add_argument("--input",type=Path,help="Archived input.json for analyze mode")
    args=parser.parse_args()
    if not 1<=args.limit<=200:parser.error("limit must be 1..200")
    if args.input and args.mode!="analyze":parser.error("--input requires analyze mode")
    config={**DEFAULTS,**(read(args.config) if args.config else {})}
    if set(config)!=set(DEFAULTS):parser.error("Unknown configuration key")
    for key in DEFAULTS:
        if key=="slippagePct":continue
        if number(config[key]) is None or config[key]<=0:parser.error("Configuration values must be positive finite numbers")
    if config["minimumHistory"]<61:parser.error("minimumHistory must be at least 61")
    if any(number(config["slippagePct"].get(m)) is None or not 0<=config["slippagePct"][m]<100 for m in ("KOSPI","KOSDAQ")):
        parser.error("Invalid slippage configuration")
    if args.mode in ("collect","run"):collect(args.limit)
    if args.mode in ("analyze","run"):analyze(config,timestamp(args.as_of) if args.as_of else None,args.input)
