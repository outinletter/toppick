"""
run_daily_narrative.py
Entry point for the daily narrative pipeline (spec section 4, steps 1-6 minus
the technical/flow/final-selection steps, which stay in kiwoom_proxy.ps1).

Runs: collector -> classifier -> scorer -> writer

Intended schedule: Windows Task Scheduler, 16:00 (post-close) and optionally
08:30 (pre-open). Register with:
  schtasks /Create /SC DAILY /ST 16:00 /TN "TopPicks_Narrative_Daily" ^
    /TR "\"<python.exe path>\" \"<repo>\\tools\\run_daily_narrative.py\""
"""
import sys
from datetime import datetime

import narrative_collector
import narrative_classifier
import narrative_scorer
import narrative_writer


def main():
    date_str = datetime.now().strftime("%Y%m%d")
    print(f"[run_daily_narrative] starting for {date_str}")

    narrative_collector.run()
    narrative_classifier.run(date_str)
    scores = narrative_scorer.run(date_str)
    narrative_writer.upsert(scores)

    print("[run_daily_narrative] done")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # keep scheduler exit code meaningful
        print(f"[run_daily_narrative] FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
