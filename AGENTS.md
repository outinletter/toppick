# AGENTS.md

## Mission

Build and maintain a Korean stock recommendation and validation platform.

Primary objective:

- Select Korean stocks with the highest expected upside over the next 1 to 3 trading days.

Do not optimize for simple win rate.

Optimize for:

- Expectancy
- Risk-adjusted return
- Drawdown control
- Validation accuracy
- Point-in-time correctness

## Operating Model

- This project is analysis-first.
- Do not add live trading execution.
- Preserve working code unless the requested task requires a change.
- Keep recommendations, validation, and audit outputs reproducible from stored report files.
- When system behavior changes, update `docs/SystemSpec.md` in the same change set.

## Development Workflow

Before code changes:

1. Inspect only directly related files.
2. Explain findings.
3. Explain the minimal proposed change.
4. Modify only affected files.
5. Verify with the smallest useful test.

Do not rewrite entire code files unless explicitly requested.

## Required Recommendation Factors

Recommendation logic must consider:

- Earnings revisions
- Target price revisions
- Institutional buying quality
- Foreign buying
- Sector strength and sector rotation persistence
- Liquidity and transaction value expansion
- Market-cap normalized flow
- Short selling pressure
- Securities lending balance where available
- Risk/reward ratio
- Overheating and drawdown risk

## Required Validation Behavior

Every daily recommendation must be stored.

Required stored fields include:

- Recommendation date
- Stock code and name
- Rank
- Entry/opening price
- Target price
- Stop-loss price
- Score
- Recommendation reason
- Main scoring factor values available at recommendation time

Required tracking horizons:

- D+1
- D+2
- D+3

## Backtesting Rules

- Never introduce look-ahead bias.
- Recommendation scoring may only use data available at recommendation time.
- Future prices may only be used after the recommendation snapshot has been stored.
- Do not backfill historical recommendation factors with later values.

## Documentation Map

- `docs/SystemArchitecture.md`: complete system structure.
- `docs/SystemSpec.md`: current implemented system specification.
- `docs/ScoringLogic.md`: recommendation and scoring logic.
- `docs/ValidationRules.md`: validation and backtesting rules.
- `docs/DataSources.md`: source systems and report storage.
- `docs/SystemAuditProcedure.md`: Stage 1 to Stage 8 audit process.
