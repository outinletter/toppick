# Scoring Logic

## Objective

The active recommendation objective is to select Korean stocks with the highest expected upside over the next 1 to 3 trading days.

The system should optimize expectancy, risk-adjusted return, and drawdown control rather than simple win rate.

## Active Model

The current proxy scoring model is:

- `short-term-v3-gapguard-1to3d`

The current TOP3 selection path is:

1. Build market candidates.
2. Analyze each stock with realtime, financial, report, flow, and risk data.
3. Add pykrx investor flow, short selling, and securities lending data.
4. Calculate sector rotation strength and persistence.
5. Calculate `shortTermScore`.
6. Prefer full-evidence candidates.
7. Prefer strong or neutral sector-rotation candidates when enough exist.
8. Select AI TOP3 by `shortTermScore`.

## Main Score Fields

- `shortTermScore`: primary TOP3 score.
- `oneMonthScore`: compatibility field currently aligned to `shortTermScore`.
- `mediumTermScore`: compatibility field currently aligned to `shortTermScore`.
- `score`: dynamic base score after regime weights.
- `fixedScore`: shadow score for validation comparison.

## Strategy Classification Fields

AI TOP3 items also store strategy classification fields:

- `strategyEngine`
- `strategyAction`
- `strategyTags`
- `strategyScores`
- `secondaryStrategies`

These fields explain which strategy engine best describes the recommendation, such as trend momentum, pullback, sector rotation, flow following, liquidity burst, earnings revision, event catalyst, mean reversion, defensive cash, or inverse hedge.

## Required Factor Groups

### Earnings And Revision Momentum

Inputs include:

- Quarterly finance data where available.
- Annual finance fallback.
- Operating profit growth.
- EPS growth.
- Recent earnings-upgrade reports.
- `consensusTrendScore` from recent target and earnings revisions.

Purpose:

- Prefer stocks with improving future expectations.
- Penalize stale optimism and downgrade pressure.

### Report And Target Price Logic

Inputs include:

- Weighted median target price from recent reports.
- Target upside.
- Target upgrades and downgrades.
- Broker count capped to avoid over-rewarding broad coverage.
- Target bias penalty for high upside without upgrade support.

Purpose:

- Use target price as one input, not the dominant factor.

### Flow And Institution Quality

Inputs include:

- Foreign and institution buying.
- pykrx `flowAdjustment`.
- Market-cap and turnover normalized flow.
- Pension and trust accumulation.
- Institution 20/60 day direction.
- Institution buy/sell streak.
- `institutionQualityScore`.

Purpose:

- Prefer sustained accumulation over noisy one-day flow.

### Sector Rotation

Inputs include:

- Sector average return.
- Rising stock ratio.
- Relative strength versus KOSPI/KOSDAQ.
- Sector transaction value increase.
- Intraday momentum proxy.
- 20-day momentum proxy.
- Historical sector persistence.

Key fields:

- `sectorRotationScore`
- `sectorRotationStatus`
- `sectorPersistenceScore`

Purpose:

- Prefer stocks in strong or improving sectors.
- Penalize weak or unknown sectors when sector-confirmed alternatives exist.

### Liquidity And Transaction Value

Inputs include:

- Average 20-day trading value.
- Recent liquid days.
- Current transaction value.
- Transaction value increase.

Purpose:

- Avoid stocks that cannot be entered or exited realistically.

### Risk And Overheating

Inputs include:

- DART disclosure risk.
- Debt ratio and operating-profit quality.
- Short selling pressure.
- Securities lending balance where available.
- RSI.
- 20-day rise.
- 20-day moving-average deviation.
- Opening gap and entry-band risk.
- Short-term volatility.
- Stop-loss and target distance.

Purpose:

- Avoid high-upside names with poor risk/reward or sharp drawdown risk.

## Android Fallback Logic

The Android `MainActivity.kt` contains a fallback analysis path.

It should stay aligned with proxy rules:

- Do not rely only on rising stocks.
- Reduce target-price overweight.
- Penalize weak flow and negative trend.
- Use capped relative valuation scoring.
- Treat fallback output as secondary to proxy-generated recommendations.

## Guardrails

- No future data in scoring.
- No live trading execution.
- No silent fallback to stale data.
- Store key scoring factors with every recommendation snapshot.
- Store `scoringFormulaVersion` with AI TOP3 snapshots.
