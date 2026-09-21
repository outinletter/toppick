import argparse
import contextlib
import io
import json
import math
import os
import sys
from pathlib import Path
from datetime import datetime, timedelta, timezone

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")


def load_krx_credentials():
    if os.getenv("KRX_ID") and os.getenv("KRX_PW"):
        return
    key_path = Path(__file__).resolve().parent.parent / "key" / "KRXID.txt"
    if not key_path.exists():
        return
    values = []
    for line in key_path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line:
            continue
        values.append(line.split(":", 1)[-1].strip())
    if len(values) >= 2:
        os.environ.setdefault("KRX_ID", values[0])
        os.environ.setdefault("KRX_PW", values[1])


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def column_sum(frame, names, days):
    for name in names:
        if name in frame.columns:
            return window_sum(frame[name], days)
    return None


def positive_streak(series):
    streak = 0
    for value in reversed(series.tolist()):
        if number(value) is None or number(value) <= 0:
            break
        streak += 1
    return streak


def negative_streak(series):
    streak = 0
    for value in reversed(series.tolist()):
        if number(value) is None or number(value) >= 0:
            break
        streak += 1
    return streak


def window_sum(series, days):
    values = series.tail(days)
    if len(values) != days or any(number(value) is None for value in values):
        return None
    return number(values.sum())


def dated_frame(frame, end):
    if frame.empty:
        return frame
    # KRX dates must be unique and chronological before tail/window operations.
    if frame.index.has_duplicates:
        raise ValueError("duplicate source dates")
    frame = frame.sort_index()
    return frame.loc[frame.index.strftime("%Y%m%d") <= end]


def collect(stock, code, start, end):
    flow = dated_frame(stock.get_market_trading_value_by_date(
        start, end, code, detail=True, on="순매수"
    ), end)
    optional = {}
    source_status = {}
    for name, method in (("shorting", "get_shorting_volume_by_date"),
                         ("balance", "get_shorting_balance_by_date")):
        try:
            optional[name] = dated_frame(getattr(stock, method)(start, end, code), end)
            source_status[name] = "ok" if not optional[name].empty else "missing"
        except Exception as error:
            optional[name] = None
            source_status[name] = type(error).__name__
    shorting, balance = optional["shorting"], optional["balance"]

    foreign_name = next((x for x in ("외국인", "외국인합계") if x in flow.columns), None)
    institution_name = next(
        (x for x in ("기관합계", "기관") if x in flow.columns), None
    )
    foreign = flow[foreign_name] if foreign_name else []
    if institution_name:
        institution = flow[institution_name]
    else:
        institution_columns = [
            name
            for name in ("금융투자", "보험", "투신", "사모", "은행", "기타금융", "연기금등" if "연기금등" in flow.columns else "연기금")
            if name in flow.columns
        ]
        institution = (
            flow[institution_columns].sum(axis=1, min_count=7) if len(institution_columns) == 7 else []
        )

    flow_adjustment = 0.0
    metrics = {}
    for days in (5, 20, 60):
        foreign_sum = window_sum(foreign, days) if foreign_name else None
        institution_sum = window_sum(institution, days) if len(institution) else None
        metrics[f"foreign{days}"] = foreign_sum
        metrics[f"institution{days}"] = institution_sum
        if foreign_sum is None or institution_sum is None:
            continue
        if foreign_sum > 0 and institution_sum > 0:
            flow_adjustment += {5: 1.5, 20: 1.5, 60: 1.0}[days]
        elif foreign_sum < 0 and institution_sum < 0:
            flow_adjustment -= {5: 1.5, 20: 1.5, 60: 1.0}[days]

    metrics["foreignStreak"] = positive_streak(foreign) if foreign_name else 0
    metrics["institutionStreak"] = (
        positive_streak(institution) if len(institution) else 0
    )
    metrics["foreignSellStreak"] = negative_streak(foreign) if foreign_name else 0
    metrics["institutionSellStreak"] = (
        negative_streak(institution) if len(institution) else 0
    )
    metrics["pension20"] = column_sum(flow, ("연기금등", "연기금"), 20)
    metrics["trust20"] = column_sum(flow, ("투신",), 20)
    metrics["financialInvestment20"] = column_sum(flow, ("금융투자",), 20)
    if metrics["foreignStreak"] >= 3:
        flow_adjustment += 0.5
    if metrics["institutionStreak"] >= 3:
        flow_adjustment += 0.5
    if metrics["foreignSellStreak"] >= 3:
        flow_adjustment -= 0.5
    if metrics["institutionSellStreak"] >= 3:
        flow_adjustment -= 0.5
    if metrics["pension20"] is not None and metrics["pension20"] > 0:
        flow_adjustment += 0.5
    elif metrics["pension20"] is not None and metrics["pension20"] < 0:
        flow_adjustment -= 0.5
    if metrics["trust20"] is not None and metrics["trust20"] > 0:
        flow_adjustment += 0.25
    elif metrics["trust20"] is not None and metrics["trust20"] < 0:
        flow_adjustment -= 0.25

    short_penalty = 0.0
    if shorting is not None and len(shorting) >= 20 and "비중" in shorting.columns and all(number(x) is not None for x in shorting["비중"].tail(20)):
        recent_short_ratio = number(shorting["비중"].tail(5).mean())
        previous_short_ratio = number(shorting["비중"].tail(20).head(15).mean())
        metrics["shortRatio5"] = recent_short_ratio
        metrics["shortRatioChange"] = recent_short_ratio - previous_short_ratio
        if recent_short_ratio >= 10:
            short_penalty += 3
        elif recent_short_ratio >= 5:
            short_penalty += 2
        if recent_short_ratio - previous_short_ratio >= 2:
            short_penalty += 2
        elif recent_short_ratio - previous_short_ratio >= 1:
            short_penalty += 1

    if balance is not None and not balance.empty and "비중" in balance.columns:
        balance_series = balance["비중"].dropna()
        if len(balance_series) >= 2 and all(number(x) is not None for x in (balance_series.iloc[-1], balance_series.iloc[0])):
            metrics["shortBalanceRatio"] = number(balance_series.iloc[-1])
            metrics["shortBalanceChange"] = number(
                balance_series.iloc[-1] - balance_series.iloc[0]
            )
            if metrics["shortBalanceChange"] >= 0.5:
                short_penalty += 1

    return {
        "available": all(metrics.get(f"{factor}{days}") is not None for factor in ("foreign", "institution") for days in (5, 20, 60)),
        "flowAsOf": flow.index[-1].strftime("%Y-%m-%d") if not flow.empty else None,
        "flowRows": len(flow),
        "flowUnit": "KRW",
        "requestedEnd": end,
        "shortingAsOf": shorting.index[-1].strftime("%Y-%m-%d") if shorting is not None and not shorting.empty else None,
        "shortBalanceAsOf": balance.index[-1].strftime("%Y-%m-%d") if balance is not None and not balance.empty else None,
        "sourceStatus": source_status,
        "securitiesLendingAvailable": False,
        "flowAdjustment": max(-5.0, min(5.0, flow_adjustment)),
        "shortPenalty": min(5.0, short_penalty),
        **metrics,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--codes", required=True)
    args = parser.parse_args()
    codes = [code for code in args.codes.split(",") if code]
    result = {
        "generatedAt": datetime.now().astimezone().isoformat(),
        "available": False,
        "status": "KRX credentials missing",
        "items": {},
    }
    load_krx_credentials()
    if not os.getenv("KRX_ID") or not os.getenv("KRX_PW"):
        print(json.dumps(result, ensure_ascii=True, allow_nan=False))
        return

    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        from pykrx import stock
        from pykrx.website.comm.webio import get_session
        authenticated = get_session() is not None
    result["authenticationStatus"] = "authenticated" if authenticated else "unavailable"
    if not authenticated:
        result["status"] = "KRX authenticated session unavailable"
        print(json.dumps(result, ensure_ascii=True, allow_nan=False))
        return

    # Daily final investor data must not include a partial current session.
    end_date = datetime.now(timezone(timedelta(hours=9)))
    if end_date.hour < 18:
        end_date -= timedelta(days=1)
    start_date = end_date - timedelta(days=120)
    start = start_date.strftime("%Y%m%d")
    end = end_date.strftime("%Y%m%d")
    sectors = {}
    for market in ("KOSPI", "KOSDAQ"):
        for offset in range(7):
            try:
                sector_date = (end_date - timedelta(days=offset)).strftime("%Y%m%d")
                with contextlib.redirect_stdout(io.StringIO()):
                    frame = stock.get_market_sector_classifications(sector_date, market)
                if frame.empty:
                    continue
                for ticker, row in frame.iterrows():
                    sector = row.get("업종명") or row.get("업종")
                    if sector:
                        sectors[str(ticker).zfill(6)] = str(sector)
                break
            except Exception:
                continue
    errors = 0
    for code in codes:
        item_key = f"K{code}"
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                result["items"][item_key] = collect(stock, code, start, end)
            result["items"][item_key]["industryName"] = sectors.get(code)
        except Exception as error:
            errors += 1
            result["items"][item_key] = {
                "available": False,
                "status": type(error).__name__,
                "industryName": sectors.get(code),
            }
    result["available"] = any(
        item.get("available") for item in result["items"].values()
    )
    result["status"] = "ok" if result["available"] else f"no data ({errors} errors)"
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))


if __name__ == "__main__":
    main()
