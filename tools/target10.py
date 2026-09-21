"""Frozen, chronological research protocol for net +10% before a volatility stop.

No trading or messaging. Historical features come only from saved snapshots.
Run `python tools/target10.py build` to freeze inputs, fetch labels, and evaluate.
Run `python tools/target10.py predict` to score the latest saved candidates.
"""
import argparse
from collections import Counter, defaultdict
from datetime import datetime, time, timedelta, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import time as clock
from urllib.request import urlopen

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
REPORTS = ROOT / "reports"
STORE = REPORTS / "target10"
KST = timezone(timedelta(hours=9))
VERSION = "target10-first-passage-v1"
FEATURES = ("rsi", "ma20Deviation", "shortTermVolatility", "volumeSurge",
            "foreignFlowRatio", "institutionFlowRatio", "averageTradingValue",
            "twentyDayRise")
POLICY = {"netTargetPct": 10.0, "costPct": 0.35,
          "slippagePct": {"KOSPI": 0.10, "KOSDAQ": 0.20},
          "horizons": [1, 2, 3], "neighbors": 100, "priorWeight": 20,
          "minTrainRows": 200, "minTrainDates": 20, "minTrainEvents": 5,
          "holdoutFraction": 0.25, "embargoCalendarDays": 7,
          "minTestDates": 20, "minTestTargets": 10,
          "maxEntryGapPct": 2.5, "stopBoundsPct": [2.8, 5.5],
          "selection": "top3 positive expectancy and P(target)>P(stop)",
          "ambiguousBar": "stop-first", "missingBar": "exclude-not-bridge"}


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def dump(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def finite(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (ValueError, TypeError):
        return None


def stamp(value):
    result = datetime.fromisoformat(value)
    return (result.replace(tzinfo=KST) if result.tzinfo is None else result).astimezone(KST)


def vector(item):
    signals = item.get("signals", {})
    values = [float(signals[name]) if name == "volumeSurge" and isinstance(signals.get(name), bool)
              else finite(signals.get(name)) for name in FEATURES]
    if any(value is None for value in values):
        return None
    if not 0 <= values[0] <= 100 or values[2] <= 0 or values[3] < 0 or values[6] <= 0:
        return None
    values[3] = math.log1p(values[3])
    values[6] = math.log1p(values[6])
    return values


def stop_rate(item):
    signals = item.get("signals", {})
    vol = finite(signals.get("shortTermVolatility"))
    if vol is None or vol <= 0:
        return None
    result = round(max(2.8, min(5.5, vol * 1.35)), 2)
    if (finite(signals.get("ma20Deviation")) or 0) >= 10 or (finite(signals.get("intradayReturn")) or 0) >= 8:
        result = min(result, 4.2)
    return result


def eligible(item):
    s = item.get("signals", {})
    return (vector(item) is not None and (finite(s.get("openingGapRate")) is not None)
            and (finite(s.get("intradayReturn")) is not None)
            and s["averageTradingValue"] >= 100 and s["rsi"] < 80
            and s["ma20Deviation"] < 18 and s["intradayReturn"] < 12
            and s["openingGapRate"] <= 2.5
            and item.get("sectorRotationStatus") in ("strong", "neutral"))


def freeze():
    manifest_path = STORE / "manifest.json"
    if manifest_path.exists():
        manifest = read(manifest_path)
        if manifest["version"] != VERSION or manifest["policy"] != POLICY or manifest["features"] != list(FEATURES):
            raise ValueError("Frozen protocol changed: create a new version, do not reuse holdout.")
        return manifest
    # Choose files using names only, before looking at future price outcomes.
    first = {}
    for path in sorted((REPORTS / "pit-snapshots").glob("*/*.json"), key=lambda p: p.name):
        if re.fullmatch(r"\d{8}-\d{6}(?:-\d+)?", path.stem):
            first.setdefault(path.stem[:8], path)
    if len(first) < 8:
        raise ValueError("Insufficient dated snapshots to reserve a chronological holdout.")
    sources = []
    records = []
    rejected = Counter()
    for day, path in sorted(first.items()):
        raw = path.read_bytes()
        snapshot = json.loads(raw.decode("utf-8-sig"))
        captured = stamp(snapshot.get("dataAsOf") or snapshot["generatedAt"])
        if captured.strftime("%Y%m%d") != day or not snapshot.get("snapshotCaptured"):
            rejected["invalid-capture-provenance"] += 1
            continue
        items = snapshot.get("items", [])
        # Generation starts before collection; newest stored source time is the
        # conservative feature cutoff. No inference from recommendation-date labels.
        times = [captured] + [stamp(x["dataAsOf"]) for x in items if x.get("dataAsOf")]
        captured = max(times)
        sources.append({"path": str(path.relative_to(ROOT)), "sha256": digest_bytes(raw),
                        "capturedAt": captured.isoformat(), "historicalReplaySafe": snapshot.get("historicalReplaySafe")})
        seen = set()
        for item in items:
            code, market = item.get("code"), item.get("market")
            if not isinstance(code, str) or not re.fullmatch(r"\d{6}", code) or market not in POLICY["slippagePct"] or (market, code) in seen:
                rejected["invalid-or-duplicate-instrument"] += 1
                continue
            seen.add((market, code))
            features = vector(item)
            if features is None:
                rejected["missing-point-in-time-features"] += 1
                continue
            records.append({"id": f"{path.stem}-{market}-{code}", "code": code, "market": market,
                            "name": item.get("name"), "capturedAt": captured.isoformat(),
                            "sourceHash": sources[-1]["sha256"], "features": features,
                            "item": item, "stopRate": stop_rate(item), "eligible": eligible(item)})
    dates = sorted({r["capturedAt"][:10] for r in records})
    if len(dates) < 8:
        raise ValueError("Insufficient feature-complete dates.")
    boundary = dates[max(1, int(len(dates) * (1 - POLICY["holdoutFraction"])))]
    manifest = {"version": VERSION, "createdAt": datetime.now(KST).isoformat(),
                "policy": POLICY, "features": list(FEATURES), "sources": sources,
                "holdoutStart": boundary, "sourceRejections": dict(rejected),
                "recordCount": len(records), "recordDates": len(dates),
                "limitation": "New-model holdout only; prior human/model exposure to historical periods cannot be ruled out."}
    dump(STORE / "features.json", records)
    manifest["featuresHash"] = digest_bytes((STORE / "features.json").read_bytes())
    dump(manifest_path, manifest)
    return manifest


def fetch_prices(records):
    instruments = sorted({(r["market"], r["code"]) for r in records})
    errors = {}
    for index, (market, code) in enumerate(instruments, 1):
        path = STORE / "prices" / f"{market}-{code}.json"
        if path.exists():
            continue
        try:
            with urlopen(f"http://127.0.0.1:8787/history/{code}/{market}", timeout=45) as response:
                payload = json.load(response)
            if not payload.get("stockHistory") or not payload.get("indexHistory"):
                raise ValueError("empty price or session calendar")
            dump(path, {"fetchedAt": datetime.now(KST).isoformat(), "source": "Kiwoom proxy adjusted daily bars", "data": payload})
        except Exception as error:
            errors[f"{market}-{code}"] = type(error).__name__
        if index % 20 == 0 or index == len(instruments):
            print(f"Price history {index}/{len(instruments)}, failed={len(errors)}", flush=True)
        clock.sleep(0.1)
    return errors


def label_trade(record, history, now):
    item = record["item"]
    captured = stamp(record["capturedAt"])
    stock = history.get("stockHistory", [])
    if len({r["date"] for r in stock}) != len(stock):
        return None, "duplicate-stock-bars"
    by_date = {r["date"]: r for r in stock}
    index = {r["date"]: r for r in history.get("indexHistory", [])}
    sessions = sorted(date for date in index if date > captured.strftime("%Y%m%d"))[:3]
    if len(sessions) < 3 or datetime.combine(datetime.strptime(sessions[-1], "%Y%m%d").date(), time(16), KST) > now:
        return None, "pending-three-closed-sessions"
    if any(date not in by_date for date in sessions):
        return None, "missing-or-suspended-session"
    bars = [by_date[date] for date in sessions]
    for bar in bars:
        values = [finite(bar.get(k)) for k in ("open", "high", "low", "price")]
        if any(v is None or v <= 0 for v in values):
            return None, "invalid-ohlc"
        op, hi, lo, close = values
        if not lo <= min(op, close) <= max(op, close) <= hi:
            return None, "inconsistent-ohlc"
    # Compare a fixed same-session open, not a snapshot's intraday last price.
    source_day = (item.get("tradingDate") or "").replace("-", "")
    saved_open = finite(item.get("openPrice"))
    source_bar = by_date.get(source_day)
    if saved_open is None or saved_open <= 0 or not source_bar or not finite(source_bar.get("open")):
        return None, "unverifiable-price-basis"
    if abs(source_bar["open"] / saved_open - 1) > 0.01:
        return None, "corporate-action-or-price-basis-mismatch"
    planned = finite(item.get("entryPrice"))
    if planned is None or planned <= 0:
        return None, "missing-planned-entry"
    slip = POLICY["slippagePct"][record["market"]] / 100
    entry = bars[0]["open"] * (1 + slip)
    if bars[0]["open"] > planned * (1 + POLICY["maxEntryGapPct"] / 100):
        return None, "entry-gap-skipped"
    target = entry * (1 + (POLICY["netTargetPct"] + POLICY["costPct"]) / 100) / (1 - slip)
    stop = entry * (1 - record["stopRate"] / 100)
    event, event_day, exit_price, ambiguous = "unresolved", 3, None, False
    returns, benchmark = [], []
    for day, bar in enumerate(bars, 1):
        if exit_price is None:
            if bar["open"] <= stop:
                event, event_day, exit_price = "stop", day, bar["open"]
            elif bar["open"] >= target:
                event, event_day, exit_price = "target", day, target
            elif bar["low"] <= stop:
                event, event_day, exit_price = "stop", day, stop
                ambiguous = bar["high"] >= target
            elif bar["high"] >= target:
                event, event_day, exit_price = "target", day, target
        quote = exit_price if exit_price is not None else bar["price"]
        returns.append((quote * (1 - slip) / entry - 1) * 100 - POLICY["costPct"])
        index_open = finite(index[sessions[0]].get("open"))
        index_close = finite(index[bar["date"]].get("price"))
        benchmark.append((index_close / index_open - 1) * 100 if index_open and index_close else None)
    category = 6 if event == "unresolved" else (event_day - 1) * 2 + (0 if event == "target" else 1)
    return {**{k: record[k] for k in ("id", "code", "market", "name", "capturedAt", "features", "eligible", "stopRate", "sourceHash")},
            "entryDate": sessions[0], "labelEnd": sessions[-1], "entry": entry,
            "target": target, "stop": stop, "event": event, "eventDay": event_day,
            "category": category, "netReturns": returns, "benchmarkReturns": benchmark,
            "ambiguous": ambiguous}, None


def split_rows(rows, boundary):
    first_test = stamp(boundary + "T00:00:00+09:00")
    embargo = first_test - timedelta(days=POLICY["embargoCalendarDays"])
    train = [r for r in rows if stamp(r["capturedAt"]) < first_test
             and datetime.strptime(r["labelEnd"], "%Y%m%d").date() < embargo.date()]
    test = [r for r in rows if stamp(r["capturedAt"]) >= first_test]
    return train, test


def fit(rows):
    counts = Counter(r["event"] for r in rows)
    if (len(rows) < POLICY["minTrainRows"] or len({r["entryDate"] for r in rows}) < POLICY["minTrainDates"]
            or counts["target"] < POLICY["minTrainEvents"] or counts["stop"] < POLICY["minTrainEvents"]):
        return None
    x = np.array([r["features"] for r in rows], dtype=float)
    center = np.median(x, axis=0)
    scale = np.quantile(x, .75, axis=0) - np.quantile(x, .25, axis=0)
    scale[scale < 1e-6] = 1.0
    return {"version": VERSION, "center": center.tolist(), "scale": scale.tolist(),
            "x": ((x - center) / scale).clip(-10, 10).tolist(),
            "categories": [r["category"] for r in rows], "returns": [r["netReturns"] for r in rows],
            "dates": [r["entryDate"] for r in rows], "ids": [r["id"] for r in rows],
            "trainEnd": max(r["labelEnd"] for r in rows), "trainCount": len(rows),
            "trainDates": len({r["entryDate"] for r in rows}), "eventCounts": dict(counts)}


def forecast(model, features):
    x = np.asarray(model["x"])
    query = ((np.asarray(features) - model["center"]) / model["scale"]).clip(-10, 10)
    distances = np.sum((x - query) ** 2, axis=1)
    near = np.argsort(distances, kind="stable")[:POLICY["neighbors"]]
    categories = np.asarray(model["categories"])
    prior = np.bincount(categories, minlength=7) / len(categories)
    probs = (np.bincount(categories[near], minlength=7) + POLICY["priorWeight"] * prior) / (len(near) + POLICY["priorWeight"])
    returns = np.asarray(model["returns"])
    expected = (returns[near].sum(axis=0) + POLICY["priorWeight"] * returns.mean(axis=0)) / (len(near) + POLICY["priorWeight"])
    horizons = {}
    for h in (1, 2, 3):
        target = float(probs[:2*h:2].sum())
        stop = float(probs[1:2*h:2].sum())
        horizons[str(h)] = {"targetBeforeStopProbability": target,
                            "stopBeforeTargetProbability": stop,
                            "neitherProbability": max(0., 1 - target - stop),
                            "expectedNetReturnPct": float(expected[h-1])}
    return {"horizons": horizons, "neighborCount": len(near),
            "neighborDates": len({model["dates"][int(i)] for i in near}),
            "probabilityType": "research-cohort-estimate"}


def confidence_by_date(values, dates):
    if not values or len(set(dates)) < 2:
        return None
    groups = defaultdict(list)
    for v, day in zip(values, dates):
        groups[day].append(v)
    arrays = [np.asarray(v) for v in groups.values()]
    rng = np.random.default_rng(20260920)
    estimates = [float(np.concatenate([arrays[i] for i in rng.integers(0, len(arrays), len(arrays))]).mean()) for _ in range(1000)]
    return [float(x) for x in np.quantile(estimates, [.025, .975])]


def evaluate(model, test):
    if not model or not test:
        return {"status": "insufficient-data", "testCount": len(test), "passed": False}
    predicted = [{**row, "forecast": forecast(model, row["features"])} for row in test]
    metrics = {}
    prior = np.bincount(model["categories"], minlength=7) / model["trainCount"]
    for h in (1, 2, 3):
        out = {}
        for kind, key, offset in (("target", "targetBeforeStopProbability", 0), ("stop", "stopBeforeTargetProbability", 1)):
            y = np.array([int(r["event"] == kind and r["eventDay"] <= h) for r in test])
            p = np.array([r["forecast"]["horizons"][str(h)][key] for r in predicted])
            base = float(prior[offset:2*h:2].sum())
            out[kind] = {"events": int(y.sum()), "observedRate": float(y.mean()),
                         "brier": float(np.mean((p-y)**2)), "baselineBrier": float(np.mean((base-y)**2)),
                         "calibration": [{"count": int(((p>=a)&(p<b)).sum()),
                                          "predicted": float(p[(p>=a)&(p<b)].mean()),
                                          "observed": float(y[(p>=a)&(p<b)].mean())}
                                         for a,b in ((0,.1),(.1,.25),(.25,.5),(.5,.75),(.75,1.000001)) if ((p>=a)&(p<b)).any()]}
        metrics[str(h)] = out
    selected = []
    grouped = defaultdict(list)
    for row in predicted:
        h3 = row["forecast"]["horizons"]["3"]
        if row["eligible"] and h3["expectedNetReturnPct"] > 0 and h3["targetBeforeStopProbability"] > h3["stopBeforeTargetProbability"]:
            grouped[row["entryDate"]].append(row)
    for group in grouped.values():
        selected.extend(sorted(group, key=lambda r: (-r["forecast"]["horizons"]["3"]["expectedNetReturnPct"], r["code"]))[:3])
    returns = [r["netReturns"][2] for r in selected]
    ci = confidence_by_date(returns, [r["entryDate"] for r in selected])
    test_dates = len({r["entryDate"] for r in test})
    failures = []
    if test_dates < POLICY["minTestDates"]: failures.append("insufficient-independent-test-dates")
    if metrics["3"]["target"]["events"] < POLICY["minTestTargets"]: failures.append("insufficient-test-target-events")
    for kind in ("target", "stop"):
        if metrics["3"][kind]["brier"] >= metrics["3"][kind]["baselineBrier"]:
            failures.append(f"{kind}-probability-does-not-beat-base-rate")
    if ci is None or ci[0] <= 0: failures.append("positive-expectancy-not-established")
    gains = sum(max(0, r) for r in returns)
    losses = -sum(min(0, r) for r in returns)
    excess = [r["netReturns"][2] - r["benchmarkReturns"][2] for r in selected if r["benchmarkReturns"][2] is not None]
    return {"status": "evaluated", "passed": not failures, "failures": failures,
            "testCount": len(test), "testDates": test_dates, "metrics": metrics,
            "selectedCount": len(selected), "meanNetReturnPct": float(np.mean(returns)) if returns else None,
            "meanExcessReturnPct": float(np.mean(excess)) if excess else None,
            "netReturnDateBootstrap95CI": ci,
            "worstTradePct": min(returns) if returns else None,
            "profitFactor": gains / losses if losses else None,
            "ambiguousBarCount": sum(r["ambiguous"] for r in test),
            "predictions": predicted,
            "limitation": "Trade-level returns, not portfolio CAGR/Sharpe; overlapping holdings and execution capacity are not simulated."}


def build():
    manifest = freeze()
    if digest_bytes((STORE / "features.json").read_bytes()) != manifest["featuresHash"]:
        raise ValueError("Frozen features were modified.")
    if (STORE / "validation.json").exists():
        print("Frozen holdout already evaluated; use predict. No repeated holdout selection.", flush=True)
        return
    records = read(STORE / "features.json")
    print(f"Frozen {len(records)} records; holdout starts {manifest['holdoutStart']}", flush=True)
    errors = fetch_prices(records)
    if errors:
        dump(STORE / "collection-status.json", {"status": "blocked-price-collection", "errors": errors})
        raise RuntimeError("Price collection incomplete; repair source and rerun. Holdout has not been evaluated.")
    rows, rejected, price_hashes = [], Counter(), {}
    histories = {}
    for path in sorted((STORE / "prices").glob("*.json")):
        histories[path.stem] = read(path)["data"]
        price_hashes[path.name] = digest_bytes(path.read_bytes())
    seen = set()
    for record in sorted(records, key=lambda r: (r["capturedAt"], r["code"])):
        history = histories.get(f"{record['market']}-{record['code']}")
        if history is None:
            rejected["missing-price-source"] += 1
            continue
        row, reason = label_trade(record, history, datetime.now(KST))
        if reason:
            rejected[reason] += 1
            continue
        key = (row["entryDate"], row["market"], row["code"])
        if key in seen:
            rejected["duplicate-next-session-pick"] += 1
            continue
        seen.add(key)
        rows.append(row)
    train, test = split_rows(rows, manifest["holdoutStart"])
    model = fit(train)
    dump(STORE / "dataset.json", rows)
    if model:
        # Persist the model before reading held-out outcomes in evaluate().
        dump(STORE / "model.json", model)
    evaluation = evaluate(model, test)
    prediction_rows = evaluation.pop("predictions", [])
    dump(STORE / "holdout-predictions.json", prediction_rows)
    report = {"version": VERSION, "generatedAt": datetime.now(KST).isoformat(),
              "policy": POLICY, "holdoutStart": manifest["holdoutStart"],
              "featureCount": len(records), "maturedCount": len(rows),
              "trainCount": len(train), "trainDates": len({r["entryDate"] for r in train}),
              "trainEvents": dict(Counter(r["event"] for r in train)),
              "purgedCount": len(rows)-len(train)-len(test), "rejected": dict(rejected),
              "fetchErrors": errors, "priceHashes": price_hashes,
              "modelHash": digest_bytes((STORE / "model.json").read_bytes()) if model else None,
              "featuresHash": manifest["featuresHash"], "evaluation": evaluation,
              "productionEnabled": False,
              "limitations": ["Retrospective hypothesis; historical periods may have informed prior strategy design.",
                              "Derived snapshots, not full raw publication-time archive.",
                              "Universe is historical candidate lists, not the full exchange universe.",
                              "Corporate-action check excludes mismatches; missing/delisted prices can bias coverage.",
                              "Prospective paper validation and dated fee/slippage/venue review required before production."]}
    dump(STORE / "validation.json", report)
    print(json.dumps({k: report[k] for k in ("featureCount", "maturedCount", "trainCount", "trainEvents", "purgedCount", "rejected")}, ensure_ascii=False), flush=True)
    print(json.dumps(evaluation, ensure_ascii=False), flush=True)
    predict()


def predict():
    source = REPORTS / "web-recommendations.json"
    snapshot = read(source)
    validation = read(STORE / "validation.json") if (STORE / "validation.json").exists() else {}
    model = read(STORE / "model.json") if (STORE / "model.json").exists() else None
    if model and validation.get("modelHash") != digest_bytes((STORE / "model.json").read_bytes()):
        raise ValueError("Model digest does not match evaluated artifact.")
    now = datetime.now(KST)
    captured = stamp(snapshot.get("dataAsOf") or snapshot["generatedAt"])
    fresh = timedelta(0) <= now-captured <= timedelta(hours=24)
    model_available = model is not None and datetime.combine(
        datetime.strptime(model["trainEnd"], "%Y%m%d").date(), time(16), KST) < captured
    items = []
    for item in snapshot.get("items", []):
        features = vector(item)
        blockers = []
        if not model: blockers.append("insufficient-training-evidence")
        elif not model_available: blockers.append("model-not-available-at-snapshot")
        if not validation.get("evaluation", {}).get("passed"): blockers.append("holdout-not-passed")
        if not fresh: blockers.append("stale-or-future-snapshot")
        if not eligible(item): blockers.append("entry-quality-gate")
        if not item.get("signals", {}).get("pykrx", {}).get("available"): blockers.append("unverified-investor-flow")
        prediction = forecast(model, features) if model_available and features is not None else None
        planned = finite(item.get("entryPrice"))
        slip = POLICY["slippagePct"].get(item.get("market"))
        entry = planned * (1 + slip/100) if planned and slip is not None else None
        target = entry * (1 + (10 + POLICY["costPct"])/100) / (1-slip/100) if entry else None
        stop = stop_rate(item)
        items.append({"code": item.get("code"), "name": item.get("name"), "market": item.get("market"),
                      "plannedEntryWithSlippage": entry, "indicativeTargetPrice": target,
                      "indicativeStopPrice": entry*(1-stop/100) if entry and stop else None,
                      "stopRatePct": stop, "forecast": prediction, "entryBlockers": blockers,
                      "action": "research-watchlist"})
    items.sort(key=lambda r: (-(r["forecast"]["horizons"]["3"]["expectedNetReturnPct"] if r["forecast"] else -1e9), r["code"]))
    dump(STORE / "latest.json", {"version": VERSION, "generatedAt": now.isoformat(),
                                 "snapshotGeneratedAt": snapshot.get("generatedAt"),
                                 "sourceSnapshotHash": digest_bytes(source.read_bytes()),
                                 "status": "research-only", "productionEnabled": False,
                                 "netTargetPct": 10, "horizons": [1, 2, 3],
                                 "validation": validation.get("evaluation", {}), "items": items})
    print(f"Saved {len(items)} research forecasts; production disabled.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("build", "predict"))
    args = parser.parse_args()
    build() if args.mode == "build" else predict()
