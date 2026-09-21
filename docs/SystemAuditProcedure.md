# System Audit Procedure

Use this procedure when asked to audit the project. Keep findings grounded in the current code and report files.

## Stage 1: Runtime And Scope

- Confirm the project root.
- Identify active process state for the local proxy and dashboard.
- Check the latest recommendation, progress, sector rotation, and validation report timestamps.
- Do not modify files during this stage.

Relevant files:

- `tools/kiwoom_proxy.ps1`
- `reports/recommendation-progress.json`
- `reports/web-recommendations.json`
- `reports/sector-rotation-history.json`

## Stage 2: Data Source Audit

- Confirm Kiwoom availability for realtime stock, index, volume, and chart data.
- Confirm pykrx/KRX availability for investor flow, short selling, and securities lending data.
- Confirm DART availability for financial/risk disclosure checks.
- Confirm Naver Finance availability for reports, targets, consensus, and metadata.
- Classify each source as realtime, intraday, close, historical, stale, or unavailable.

## Stage 3: Recommendation Logic Audit

- Review the active scoring version in `scoringFormulaVersion`.
- Confirm TOP3 is driven by `shortTermScore` and the active `scoringFormulaVersion`, not an older medium-term proxy.
- Check that earnings revisions, target revisions, foreign/institutional buying, sector strength, liquidity, short pressure, and risk/reward are actually used.
- Flag displayed factors that are not stored or not scored.

## Stage 4: Sector Rotation Audit

- Review sector strength, sector persistence, and leader detection.
- Confirm strong/neutral sector candidates are preferred when enough candidates exist.
- Confirm weak or unknown sectors are penalized.
- Check `sectorRotationScore`, `sectorPersistenceScore`, and leader groups.

## Stage 5: Risk And Bias Audit

- Check stale data and market-session mismatch.
- Check excessive target-price reliance.
- Check rising-stock selection bias.
- Check survivorship and look-ahead bias.
- Check whether recommendations use only recommendation-time data.

## Stage 6: Validation And Backtest Audit

- Confirm daily recommendations are stored in `web-recommendation-history.json`.
- Confirm AI TOP3 history is stored in `ai-top3-history.json`.
- Confirm D+1, D+2, and D+3 tracking.
- Confirm net return, excess return, max drawdown, target hit, and stop hit.
- Confirm factor fields such as sector rotation, consensus trend, and institution quality are preserved for later analysis.

## Stage 7: Error And Runtime Audit

- Run PowerShell parser checks for touched scripts.
- Run Android/Kotlin compile only if Android files are changed.
- Check `/health` and `/api/recommendations` when the proxy is relevant.
- Inspect only directly relevant logs and reports.

## Stage 8: Findings And Minimal Fixes

- Report findings by severity.
- Propose minimal affected files.
- Apply only necessary changes.
- Re-run the smallest verification that proves the fix.
