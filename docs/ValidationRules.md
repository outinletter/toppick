# Validation Rules

## Objective

Validation measures expectancy, risk-adjusted return, drawdown, target achievement, and market/sector excess return.

Do not judge the system only by hit rate.

## Stored Recommendation Sets

### Daily Recommendation History

Stored in:

- `reports/web-recommendation-history.json`

Purpose:

- Preserve all daily recommendation candidates.
- Preserve dynamic and fixed shadow model records.
- Store point-in-time factor values for later validation.

### AI TOP3 History

Stored in:

- `reports/ai-top3-history.json`
- `reports/top3.db`

Purpose:

- Track ranked daily AI TOP3 selections.
- Support dashboard date navigation and validation.

## Required Stored Fields

Each recommendation should include:

- Recommendation date
- Market
- Stock code
- Stock name
- Rank where applicable
- Entry/open price
- Target price or target upside
- Stop price or stop rate where applicable
- Score fields
- Recommendation reasons
- Sector rotation fields
- Consensus trend field
- Institution quality field
- Data timestamp

## Tracking Horizons

Track future performance at:

- D+1
- D+2
- D+3

## Required Metrics

For each horizon:

- Gross return
- Net return after transaction cost and slippage
- Excess return versus market index
- Excess return versus industry peers where available
- Maximum drawdown
- Target reached
- Stop reached where applicable

For immature picks:

- Current price
- Current return
- Maximum rise
- Maximum decline

For current short-term formula picks:

- Saved recommendation count
- Pending recommendation count before D+1 data exists
- Active entry count
- Watchlist count
- Hypothetical watchlist return
- Current formula failure summary

## Validation Scripts

Primary script:

- `tools/monthly_validation.ps1`

Key outputs:

- `reports/validation-YYYY-MM.csv`
- `reports/validation-master.csv`
- `reports/validation-YYYY-MM-summary.json`
- `reports/ai-top3-validation.json`

Current short-term formula statistics are stored in:

- `currentFormulaStatistics`

## Bias Rules

- Recommendation factors must come from recommendation-time snapshots.
- Future prices may only be used in validation after recommendation storage.
- Do not recompute historical recommendation scores with newer factor data.
- Keep slippage and transaction cost explicit.

## Interpretation Rules

Prioritize:

- Positive average net return.
- Positive excess return.
- Controlled drawdown.
- Favorable payoff ratio.
- Target achievement with acceptable drawdown.

Hit rate alone is insufficient.


## 2026-09-20 validation version

Active TOP3 returns now use `ohlc-exit-v2`: stop/target-aware exits with gap handling, fees and slippage, followed by cash through each horizon. Watchlist close-based hypothetical returns remain separate. Excess returns use matched index open-to-close horizons; missing index opens remain null. Partial same-day bars are withheld before 16:00 KST, and new recorded timestamps constrain the first eligible session. Current-formula and tuning statistics use exact formula matching and active matured samples. Legacy rows without capture timestamps remain unverified for point-in-time correctness. See `SystemSpec.md` for full assumptions and limitations.


## Net +10% research validation

The independent `target10-first-passage-v1` protocol is specified in `Target10Model.md`. Its held-out source dates and policies are frozen before price-label collection. Labels use net +10% before stop, never later highs after a stop. Training requires label completion before the embargo. Validation reports target/stop Brier scores against training base rates, calibration bins, exclusions, and selected-trade net expectancy. It does not rewrite legacy short-term performance reports or claim portfolio returns. The first evaluated version failed release gates and remains research-only.
