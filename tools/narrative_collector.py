"""
narrative_collector.py
Collects raw text signals for the daily growth-narrative pipeline.

Scope (skeleton only — fill in real API calls before production use):
  - DART disclosures (business reports, IR materials, order/contract disclosures)
  - News articles (target ~500/day)
  - Broker reports (target price / earnings-outlook upgrades)
  - Patent / hiring / gov R&D signals

Output: reports/narrative-raw/<YYYYMMDD>.jsonl
  One line per raw item: {source, ticker(optional), title, body, url, published_at, collected_at}

Note: per spec section 7, do not persist full copyrighted article bodies long-term —
only enough text for the classifier step, then narrative_writer.py stores summaries only.
"""
import json
import os
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "reports" / "narrative-raw"
DART_API_KEY_FILE = ROOT / "key" / "opendart API key.txt"


def collect_dart():
    """TODO: call DART Open API (list.json / document.xml) for today's filings."""
    return []


def collect_news():
    """TODO: call news API / crawler. Target ~500 items/day."""
    return []


def collect_reports():
    """TODO: broker report source (crawl or provider API)."""
    return []


def collect_patents_and_hiring():
    """TODO: KIPRIS patent API, gov R&D notices, job posting sources."""
    return []


def run():
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    today = datetime.now().strftime("%Y%m%d")
    out_path = RAW_DIR / f"{today}.jsonl"

    items = []
    items += collect_dart()
    items += collect_news()
    items += collect_reports()
    items += collect_patents_and_hiring()

    with open(out_path, "w", encoding="utf-8") as f:
        for item in items:
            item.setdefault("collected_at", datetime.now().isoformat())
            f.write(json.dumps(item, ensure_ascii=False) + "\n")

    print(f"[narrative_collector] wrote {len(items)} items to {out_path}")
    return out_path


if __name__ == "__main__":
    run()
