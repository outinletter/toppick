"""
narrative_scorer.py
Aggregates per-item classifications (from narrative_classifier.py) into one
narrativeScore per ticker, on a 0-100 scale, matching the convention of the
other 0-100 category scores in tools/kiwoom_proxy.ps1 (scoreBreakdown fields).

Aggregation approach (skeleton — tune later):
  - Group classified items by ticker.
  - sentiment -> signed value: positive=+1, neutral=0, negative=-1
  - Each item contributes: signed_value * confidence * category_weight
  - Sum contributions per ticker, then squash into 0-100 with a bounded curve.
  - confidence is also stored so kiwoom_proxy.ps1 can further discount low-confidence
    scores at read time (see Get-AnalyzedStock narrative lookup).
"""
import json
import math
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLASSIFIED_DIR = ROOT / "reports" / "narrative-classified"

# Relative weight per source category (tune based on backtest reliability).
CATEGORY_WEIGHT = {
    "dart": 1.2,
    "news": 0.8,
    "report": 1.1,
    "patent": 0.9,
    "hiring": 0.7,
    "supply_chain": 1.1,
    "social": 0.5,
}

SENTIMENT_VALUE = {"positive": 1.0, "neutral": 0.0, "negative": -1.0}


def score_ticker(items: list[dict]) -> dict:
    total = 0.0
    confidences = []
    categories = set()
    for it in items:
        weight = CATEGORY_WEIGHT.get(it.get("category"), 0.5)
        sentiment = SENTIMENT_VALUE.get(it.get("sentiment"), 0.0)
        confidence = float(it.get("confidence", 0.0))
        total += sentiment * confidence * weight
        confidences.append(confidence)
        categories.add(it.get("category"))

    # Bounded squash: tanh maps unbounded sum to (-1, 1), then rescale to 0-100.
    squashed = math.tanh(total / 3.0)
    narrative_score = round((squashed + 1) * 50, 1)
    avg_confidence = round(sum(confidences) / len(confidences), 2) if confidences else 0.0

    return {
        "narrativeScore": narrative_score,
        "confidence": avg_confidence,
        "itemCount": len(items),
        "categories": sorted(categories),
        "updatedAt": datetime.now().isoformat(),
    }


def run(date_str: str | None = None) -> dict:
    date_str = date_str or datetime.now().strftime("%Y%m%d")
    path = CLASSIFIED_DIR / f"{date_str}.jsonl"
    if not path.exists():
        print(f"[narrative_scorer] no classified file at {path}, skipping")
        return {}

    by_ticker: dict[str, list[dict]] = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            item = json.loads(line)
            ticker = item.get("ticker")
            if not ticker:
                continue
            by_ticker.setdefault(ticker, []).append(item)

    scores = {ticker: score_ticker(items) for ticker, items in by_ticker.items()}
    # attach one representative summary per ticker (most confident item)
    for ticker, items in by_ticker.items():
        best = max(items, key=lambda x: x.get("confidence", 0.0))
        scores[ticker]["summary"] = best.get("summary", "")
        scores[ticker]["category"] = best.get("category", "")

    print(f"[narrative_scorer] scored {len(scores)} tickers")
    return scores


if __name__ == "__main__":
    run()
