# Data Sources

## Primary Source

### Kiwoom OpenAPI

Used for:

- Realtime stock snapshot.
- Current price.
- Open and previous close.
- Daily chart data.
- Daily volume and transaction value.
- Investor flow where available.
- Index chart data.

Role:

- Primary market data source.
- Main realtime/intraday data source.
- Recommendation refresh source during the local proxy run.

## Supplementary Sources

### pykrx / KRX

Used for:

- Foreign and institution flow.
- Pension and trust flow.
- Short selling ratio.
- Short selling balance.
- Sector classification.

Key fields:

- `flowAdjustment`
- `shortPenalty`
- `pension20`
- `trust20`
- `institutionStreak`
- `institutionSellStreak`

Runtime behavior:

- Fresh pykrx collection is preferred.
- Same-day cached snapshots may be used as warm-start data when fresh collection is unavailable or slow.
- Cache status and coverage must be surfaced in recommendation output.
- Cached pykrx use should appear as an entry blocker or activation requirement when it materially affects confidence.

### DART

Used for:

- Financial statement cross-checks.
- Operating profit and debt ratio.
- Risk disclosures.
- Capital increase, CB/BW, delisting, audit, and other risk events where detected.

### Naver Finance

Used for:

- Research reports.
- Target prices.
- Broker coverage.
- Consensus metadata.
- Basic stock and industry metadata.

### Macro And Industry Data

Used where available:

- KRX market breadth.
- Exchange rate.
- DRAM spot proxy.
- Customs export growth.

## Stored Reports

Recommendation:

- `reports/web-recommendations.json`
- `reports/web-recommendation-history.json`
- `reports/web-recommendation-runs.json`
- `reports/ai-top3-history.json`
- `reports/pit-snapshots/`

Sector rotation:

- `reports/sector-rotation-history.json`

Validation:

- `reports/validation-YYYY-MM.csv`
- `reports/validation-master.csv`
- `reports/ai-top3-validation.json`

Current short-term validation fields:

- `currentFormulaStatistics`
- `savedRecommendationCount`
- `pendingRecommendationCount`
- `totalRecommendations`
- `activeEntryCount`
- `watchlistCount`

Progress and diagnostics:

- `reports/recommendation-progress.json`
- `reports/pykrx-latest.json`
- `logs/*.jsonl`

## Data Quality Rules

- Mark unavailable data explicitly.
- Prefer realtime data during market hours.
- Prefer close data after market close.
- Do not silently mix stale and realtime data.
- Do not use future data in recommendation scoring.
- Store recommendation-time snapshots before using future data for validation.
- Treat cached data as usable only when its status, age, and coverage are visible.


## 2026-09-20 integrity update

See `DataReliabilityReview.md` for source audit findings, prioritized additional datasets, and live collection limitations. Collection now records actual flow dates/units/window coverage, isolates optional short-data failures, preserves signed DART amounts, and checks for an authenticated pykrx session before querying. Short-selling balance is not securities-lending balance. New source-quality metadata identifies report-keyword consensus proxies explicitly. See `SystemSpec.md` for cache/freshness and entry-gate policies.
