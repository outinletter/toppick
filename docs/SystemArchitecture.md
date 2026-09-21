# System Architecture

## Purpose

TopPicks is a Korean stock recommendation and validation system.

The primary operating goal is to identify stocks with the highest expected upside over the next 1 to 3 trading days while controlling drawdown and preserving validation accuracy.

## Main Runtime Components

### Local Proxy And Dashboard

File:

- `tools/kiwoom_proxy.ps1`

Responsibilities:

- Authenticate with Kiwoom.
- Serve the local dashboard at `http://127.0.0.1:8787/`.
- Generate recommendations.
- Expose recommendation, progress, indicator, history, and validation APIs.
- Save recommendation snapshots and history files.

Important endpoints:

- `/`
- `/health`
- `/api/recommendations`
- `/api/recommendations?refresh=1`
- `/api/progress`
- `/api/indicators`
- `/api/top3-history`
- `/api/top3-validation`

### pykrx Collector

File:

- `tools/collect_pykrx.py`

Responsibilities:

- Collect KRX investor flow.
- Calculate foreign/institution flow metrics.
- Calculate pension and trust accumulation.
- Calculate short selling and securities lending pressure.
- Return pykrx factor data to the proxy.

### Validation

File:

- `tools/monthly_validation.ps1`

Responsibilities:

- Validate daily recommendations and AI TOP3.
- Track D+1, D+2, and D+3.
- Calculate net return, excess return, target hit, stop hit, and drawdown.
- Save validation CSV and JSON outputs.

### Android App

File:

- `app/src/main/java/com/addvalue/toppicks/MainActivity.kt`

Responsibilities:

- Provide Android UI and fallback analysis path.
- Prefer proxy-generated data where available.
- Keep fallback scoring aligned with proxy scoring principles.

## Recommendation Pipeline

1. Read market regime and macro indicators.
2. Build candidate universe from rising, active, stable, and quiet candidates.
3. Analyze each stock with Kiwoom, Naver, DART, and finance data.
4. Apply liquidity, financial, risk, report, target, flow, and trend factors.
5. Add pykrx investor flow, short selling, and securities lending factors.
6. Calculate sector rotation and persistence.
7. Calculate `shortTermScore`.
8. Select diversified market candidates.
9. Select AI TOP3 from full-evidence candidates.
10. Prefer strong or neutral sector-rotation candidates when possible.
11. Store recommendation and validation-ready history.

## Active Recommendation Formula

Current version:

- `short-term-v3-gapguard-1to3d`

Primary TOP3 score:

- `shortTermScore`

Secondary score:

- `oneMonthScore` and `mediumTermScore` compatibility fields currently aligned to `shortTermScore`

Key current factor fields:

- `consensusTrendScore`
- `institutionQualityScore`
- `sectorRotationScore`
- `sectorRotationStatus`
- `sectorPersistenceScore`
- `targetBiasPenalty`
- `ma20Deviation`
- `rsi`
- `twentyDayRise`
- `averageTradingValue`
- `openingGapRate`
- `gapRiskPenalty`
- `shortTermVolatility`

## Sector Rotation Engine

Implemented in:

- `tools/kiwoom_proxy.ps1`

Stored in:

- `reports/sector-rotation-history.json`

Calculates:

- Sector average return.
- Rising stock ratio.
- Relative strength versus KOSPI/KOSDAQ.
- Transaction value increase.
- Intraday momentum proxy.
- 20-day momentum proxy.
- Strong/neutral/weak status.
- Persistence score from recent history.
- Strong sector leader groups.

## Storage Model

Latest recommendation:

- `reports/web-recommendations.json`

All daily recommendation candidates:

- `reports/web-recommendation-history.json`

AI TOP3 history:

- `reports/ai-top3-history.json`

AI TOP3 database:

- `reports/top3.db`

Sector history:

- `reports/sector-rotation-history.json`

Validation:

- `reports/validation-master.csv`
- `reports/validation-YYYY-MM.csv`
- `reports/validation-YYYY-MM-summary.json`
- `reports/ai-top3-validation.json`

## Validation Logic

The validation process evaluates recommendations only after snapshots are stored.

Validation tracks:

- D+1
- D+2
- D+3

It calculates:

- Net return after slippage and transaction cost.
- Excess return versus market index.
- Excess return versus industry peers where available.
- Target reached.
- Stop reached for TOP3.
- Maximum drawdown.
- Payoff and hit-rate statistics.
- Current formula statistics and pending recommendation counts.

## Backtesting Principle

Recommendation scoring must only use data available at the recommendation time.

Future prices are allowed only in validation and backtesting after the recommendation snapshot has already been saved.

Do not recompute old recommendations with later factor data.

## Safety Boundary

The project is analysis and validation first.

Do not add live trading execution unless explicitly requested and separately gated.
