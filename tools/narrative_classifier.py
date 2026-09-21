"""
narrative_classifier.py
Calls the Claude API to turn raw collected items (from narrative_collector.py)
into structured per-ticker growth-story classifications.

Output schema per item (spec section 4, step 5):
  {
    "ticker": "005930",
    "category": one of the 7 source categories (dart/news/report/patent/hiring/supply_chain/social),
    "sentiment": "positive" | "neutral" | "negative",
    "confidence": 0.0-1.0,
    "summary": "<= 2-3 sentence summary, no raw article text>"
  }

Skeleton only — wire up the actual Claude API call (anthropic SDK) before use.
"""
import json
import os
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "reports" / "narrative-raw"
CLASSIFIED_DIR = ROOT / "reports" / "narrative-classified"

CATEGORIES = [
    "dart", "news", "report", "patent", "hiring", "supply_chain", "social",
]

CLASSIFY_PROMPT = """You are classifying a raw text item about a Korean-listed company
into a structured growth-story record. Respond with strict JSON only:
{{"ticker": "<6-digit code or null>", "category": "<one of {categories}>",
  "sentiment": "positive|neutral|negative", "confidence": <0.0-1.0>,
  "summary": "<short Korean summary, no verbatim article text>"}}

Item:
title: {title}
body: {body}
"""


def classify_item(item: dict) -> dict | None:
    """TODO: call Claude API with CLASSIFY_PROMPT.format(...), parse JSON response.
    Return None if the item doesn't map to a specific ticker or is too low-signal.
    """
    raise NotImplementedError("Wire up Claude API call here")


def run(date_str: str | None = None):
    date_str = date_str or datetime.now().strftime("%Y%m%d")
    raw_path = RAW_DIR / f"{date_str}.jsonl"
    CLASSIFIED_DIR.mkdir(parents=True, exist_ok=True)
    out_path = CLASSIFIED_DIR / f"{date_str}.jsonl"

    if not raw_path.exists():
        print(f"[narrative_classifier] no raw file at {raw_path}, skipping")
        return out_path

    results = []
    with open(raw_path, "r", encoding="utf-8") as f:
        for line in f:
            item = json.loads(line)
            try:
                classified = classify_item(item)
            except NotImplementedError:
                classified = None
            if classified and classified.get("ticker"):
                results.append(classified)

    with open(out_path, "w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print(f"[narrative_classifier] classified {len(results)} items to {out_path}")
    return out_path


if __name__ == "__main__":
    run()
