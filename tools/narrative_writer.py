"""
narrative_writer.py
Upserts per-ticker narrative scores (from narrative_scorer.py) into
reports/narrative-scores.json, the file read by tools/kiwoom_proxy.ps1
(see Get-NarrativeScores in that file).

File format (flat map, ticker -> record):
  {
    "005930": {
      "narrativeScore": 62.4,
      "confidence": 0.78,
      "category": "supply_chain",
      "summary": "...",
      "itemCount": 4,
      "updatedAt": "2026-07-25T16:03:00"
    },
    ...
  }

Existing entries not present in today's scoring run are kept as-is (so a
ticker with no fresh news today doesn't lose its last known narrative score
outright) but callers should check `updatedAt` staleness if needed.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_PATH = ROOT / "reports" / "narrative-scores.json"


def load_existing() -> dict:
    if not OUT_PATH.exists():
        return {}
    try:
        with open(OUT_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {}


def write_atomic(data: dict):
    tmp_path = OUT_PATH.with_suffix(".json.tmp")
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp_path.replace(OUT_PATH)


def upsert(new_scores: dict) -> dict:
    existing = load_existing()
    existing.update(new_scores)
    write_atomic(existing)
    print(f"[narrative_writer] upserted {len(new_scores)} tickers, "
          f"{len(existing)} total in {OUT_PATH}")
    return existing


if __name__ == "__main__":
    # Standalone test: upsert an empty dict (no-op) to verify file I/O.
    upsert({})
