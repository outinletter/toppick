# TopPicks System Specification

Last updated: 2026-09-20

## Mission

TopPicks is an analysis-first Korean stock recommendation and validation system.

The current recommendation horizon is 1 to 3 trading days.

The system does not perform live trading execution. It selects, stores, monitors, and validates recommendation candidates.

## Primary Output

The main output is AI TOP 3 TODAY.

Each recommendation run produces:

- Top 3 short-term candidates
- Entry status: active entry candidate or watchlist
- Target price
- Stop-loss price
- Maximum entry price
- Short-term score
- Recommendation reasons
- Entry blockers
- Activation requirements
- Strategy engine classification
- Strategy tags
- Validation-ready stored snapshot

## Current Recommendation Horizon

The system is optimized for 1 to 3 trading day movement.

It is not currently optimized for 1 month or 1 to 3 month holding periods.

## Data Collection

Primary runtime source:

- Kiwoom OpenAPI through the local PowerShell proxy

Supplemental sources:

- pykrx investor flow, short selling, and market data snapshots
- OpenDART where available
- Stored local report JSON files
- Cached point-in-time snapshots

Important generated files:

- `reports/web-recommendations.json`
- `reports/web-recommendation-history.json`
- `reports/web-recommendation-runs.json`
- `reports/ai-top3-history.json`
- `reports/ai-top3-validation.json`
- `reports/pykrx-latest.json`
- `reports/pit-snapshots/`

## Runtime Components

Main proxy:

- `tools/kiwoom_proxy.ps1`

Validation:

- `tools/monthly_validation.ps1`

Storage helper:

- `tools/store_top3.py`

Tuning suggestion:

- `tools/auto_tuning.ps1`
- `tools/daily_validation_tuning.ps1`

Entry alert monitoring:

- `tools/entry_alert_monitor.ps1`

Main local URL:

- `http://127.0.0.1:8787/`

Core API endpoints:

- `/health`
- `/api/recommendations`
- `/api/recommendations?refresh=1`
- `/api/progress`
- `/api/top3-history`
- `/api/top3-validation`

Recommendation response includes:

- `marketIndexes.KOSPI.value`
- `marketIndexes.KOSPI.changeRate`
- `marketIndexes.KOSDAQ.value`
- `marketIndexes.KOSDAQ.changeRate`

Scheduled alert behavior:

- `EntryAlertMonitor` runs every 5 minutes during the market session.
- It skips execution when another recommendation analysis is already running.
- It sends Telegram only for strict buy-entry candidates: `pending`, entry-band method, score 45 or higher, no entry blockers, and `strategyAction = long-candidate`.
- It stores sent alert keys in `reports/entry-alert-state.json` to prevent duplicate alerts.

## Scoring Formula

Current formula version:

- `short-term-v3-gapguard-1to3d`

The formula emphasizes:

- Short-term relative strength
- Trading value and liquidity expansion
- Volume surge
- Sector rotation strength
- Sector persistence
- Foreign and institutional flow quality
- Market regime
- Technical breakout quality
- VWAP or price structure evidence where available
- Overheating control
- Gap-up entry risk
- Short-term volatility-based stop risk

## Strategy Engine Classification

Each AI TOP 3 item stores a strategy classification.

Main fields:

- `strategyEngine`
- `strategyAction`
- `strategyTags`
- `strategyScores`
- `secondaryStrategies`

Current strategy engines:

- `trendMomentum`: rising trend and relative strength.
- `pullback`: controlled pullback near short-term support.
- `sectorRotation`: strong or improving sector rotation.
- `flowFollowing`: foreign, institution, or quality flow support.
- `liquidityBurst`: trading value and volume expansion.
- `earningsRevision`: consensus or earnings improvement.
- `eventCatalyst`: disclosure, theme, or event catalyst.
- `meanReversion`: oversold rebound candidate.
- `defensiveCash`: weak market, weak sector, or overheat risk where cash/watchlist is preferred.
- `inverseHedge`: weak index regime where inverse or cash should be considered instead of ordinary long entries.

The current system still outputs Korean stock long candidates as AI TOP 3.

`inverseHedge` is a strategy classification and action hint. It does not execute inverse trades automatically.

## Candidate Eligibility

The system excludes or downranks instruments that do not fit common-stock short-term recommendation logic.

Examples:

- ETF
- ETN
- Leveraged or inverse products
- SPAC-like names
- Preferred shares
- Non-numeric or invalid stock codes
- Insufficient liquidity candidates

## Entry Policy

The system separates recommendation visibility from actual entry readiness.

Entry-ready candidates require:

- Short-term score at or above 45
- No entry blockers
- Acceptable market regime
- Acceptable sector rotation condition
- Acceptable liquidity
- No excessive opening gap
- No excessive 20-day moving-average deviation
- No severe RSI overheating
- Usable current or cached data status

If the short-term score is below 45, the candidate is stored as:

- `entryStatus = watchlist`
- `entryMethod = watchlist-low-confidence`

If the score is 45 or higher but entry blockers remain, the candidate is stored as:

- `entryStatus = watchlist`
- `entryMethod = watchlist-blocked-entry`

The system may still show watchlist candidates in AI TOP 3 TODAY, but they are not active entry candidates.

## Target And Stop Logic

Target price:

- Usually 2.5% to 8% upside range
- Default target around 4% when no stronger calibrated upside exists

Stop-loss:

- Uses recent 10-day volatility
- Stored as `stopMethod = recent-10d-volatility`
- Overheated or extended names receive tighter stops

Entry band:

- Maximum entry gap is currently 2.5%
- Stored as `maxEntryGapRate`
- If next trading day open is above `maxEntryPrice`, validation treats it as skipped entry

## Dashboard Behavior

The local dashboard displays:

- AI TOP 3 TODAY
- Professional trading dashboard layout
- Top status metric bar
- KOSPI and KOSDAQ index value/change-rate display
- Dense TOP3 table
- Dense full candidate table
- Entry and watchlist counts
- Current scoring formula
- pykrx status
- Candidate cards
- Target and stop price
- Maximum entry price
- Short-term volatility
- Market and sector diagnostics
- Entry blockers
- Activation requirements
- Strategy classification fields through the recommendation API
- Near-miss candidates and activation hints
- Current formula validation summary
- Saved, pending, and matured current-formula recommendation counts

Refreshing `/api/recommendations?refresh=1` recalculates recommendations from the current available data path.

## Validation Logic

Validation is point-in-time oriented.

Stored recommendation snapshots are evaluated only with future data after the recommendation was saved.

Current validation horizons:

- D+1
- D+2
- D+3

Validation records:

- Entry price
- Slippage
- Entry skipped state
- Skip reason
- Target reached
- Stop reached
- D+1 return
- D+2 return
- D+3 return
- Hypothetical watchlist returns
- Market excess return
- Failure reasons

The validation report includes:

- Overall statistics
- Active entry statistics
- Watchlist statistics
- Failure summary
- Current formula statistics
- Strategy-level current formula statistics

Daily post-close automation:

- Runs validation after market close.
- Generates tuning suggestion reports.
- Includes strategy-level observations and strategy upweight/downweight review suggestions when enough samples exist.
- Does not automatically change scoring or trading rules.

Current formula statistics are stored under:

- `currentFormulaStatistics`

If a current formula recommendation has been saved but has no future trading day data yet, it is counted under:

- `pendingRecommendationCount`

Tuning suggestion outputs:

- `reports/tuning-suggestions.json`
- `reports/tuning-suggestions.md`

## Backtesting Rules

The system must not use look-ahead data.

Recommendation scoring may only use data available at recommendation time.

Future prices are allowed only during validation after a snapshot has been stored.

Historical factors must not be backfilled with later values.

## Documentation Update Rule

When system behavior changes, update this file in the same change set.

Examples that require a SystemSpec update:

- Recommendation horizon changes
- Scoring formula version changes
- Entry threshold changes
- Target or stop logic changes
- Data source behavior changes
- API endpoint changes
- Dashboard behavior changes
- Alert behavior changes
- Validation horizon or metric changes
- Stored report schema changes


## Reliability hardening (2026-09-20)

The scoring formula identifier remains `short-term-v3-gapguard-1to3d`. New recommendation snapshots separately identify `entryPolicyVersion = entry-risk-v1`; its risk/quality gates change entry eligibility, not factor weights. Do not attribute performance changes to the unchanged formula alone.

### Collection integrity

- DART monetary parsing preserves negative amounts and represents missing/nonfinite amounts as null. Nonpositive reported equity excludes candidates. Financial queries include the current year, then the two preceding years; the selected year/report code is saved. Disclosure API errors are not treated as verified data. OFS fallback and complete disclosure pagination are not implemented yet.
- Provider daily transaction value is retained rather than replaced by last price times volume. Quantity-based investor ratios use actual daily share volume.
- pykrx frames are sorted, duplicate dates rejected, and dates after the requested endpoint excluded. Full 5/20/60-row nonmissing windows are required for an available flow signal. Detailed institution totals require all seven components, including the pension naming alias.
- Collection uses KST and requests prior-day data before 18:00. This is a conservative collection policy, not a verified publication schedule. The actual returned `flowAsOf`, `flowRows`, and `flowUnit` are saved. Source dates older than seven calendar days or in the future are not used for flow scoring. Exchange-calendar freshness checks remain necessary.
- Optional short-selling endpoint failures preserve valid flow data and retain separate source status. Missing short data is shown as unverified; short balance is not securities-lending balance. The latter remains unavailable.
- pykrx caches require a collection timestamp, at most 60 minutes of age, and valid source-dated flow. Warm starts require full requested coverage. Daily performance-history cache expires after five minutes.
- TOP3 stores `sourceQuality`, `flowSource`, `recordedAt`, and `runId`; source quality labels consensus scoring as a report-keyword proxy.

### Entry risk

The additional gate rejects missing/nonfinite key signals, unverified flow, unknown/weak sectors, opening gaps above 2.5%, and net reward/risk below 1.0. The 1.0 cutoff is an explicit initial policy, not an empirically optimized institutional threshold. Net reward/risk uses the validation assumptions (0.35% round trip cost, 0.10% KOSPI / 0.20% KOSDAQ exit slippage) and the entry-relative target/stop rates. Existing score, liquidity and overheating gates still apply.

### Validation and storage

- `validationVersion = ohlc-exit-v2`: active TOP3 D+1/D+2/D+3 returns use stop/target exits, with cash held after exit through the horizon. A gap below stop fills at the opening price. A gap above target uses the target conservatively. For an intraday bar touching both levels, stop is assumed first. Exit slippage and costs apply once.
- `d1Close`/`d2Close`/`d3Close` remain observed market closes. Hypothetical watchlist returns remain separate close-based diagnostics. Highest/lowest prices remain observation-window extrema, not post-exit portfolio drawdown.
- Benchmark returns use the matching first-session open and horizon close. Missing index opens produce null excess returns. This prevents a forced-zero D+1 benchmark.
- Actual recorded date supersedes an older price-date label when choosing future sessions. Same-day bars are excluded before 16:00 KST; future and duplicate dates are rejected/excluded. This cutoff applies to the regular-session model and is not a consolidated KRX/NXT calendar.
- Current-formula and strategy hit/profit statistics exclude hypothetical watchlist trades. Version matching is exact. Tuning sample gates count active, matured D+3 trades only.
- SQLite partial imports no longer delete unrelated records. Compatibility tables remain latest projections; `audit_snapshots` preserves canonical full recommendation/performance payloads by SHA-256 digest, including scores, versions and D+2/D+3 fields. Existing same-date JSON projections still replace prior runs; run files and the new audit table are the revision trail.
- Historical rows lacking `recordedAt` retain the legacy date assumption; they are not upgraded to proven point-in-time records. Previously generated reports are not rewritten automatically by this code change.

### Verification and remaining evidence

Run `tools/test_engine.ps1`, Python unittest discovery for `tools/test_*.py`, and `tools/test_validation_integration.ps1 -WorkRoot <scratch-directory>`. Integration tests mock market APIs and use isolated reports. Passing tests do not establish live feed parity, execution capacity, or profitable out-of-sample performance. See `docs/DataReliabilityReview.md` for collection priorities and known gaps.

Bulk pykrx collection timeout (2026-09-20 operational fix): max(90, 30 + 5 * requestedCodeCount) seconds, capped at 900 seconds. The former fixed 90-second budget aborted healthy multi-stock collection. Source freshness and entry gates remain unchanged.
Windows PowerShell collector launches now retain the native process handle and drain redirected output after completion before testing ExitCode.
Calibration CSV input is now loaded once per recommendation run and reused without changing filtering or score semantics. Worker failures include script stack locations for diagnosis.


## Net +10% first-passage research model (2026-09-20)

### Reliability and model governance hardening (2026-09-21)

Current formula version: `short-term-v5-governed-evidence`. Entry risk policy: `entry-risk-v2-cost-stress`. The independent report now preserves raw `sourceAvailableAt`; the bridge enforces its 24-hour age independently of analysis/report time. Old reports lacking this field are not admitted. Parsed source contents and their hash come from the same byte read, avoiding a report/hash race.

Malformed, boolean, nonfinite and invalid-domain risk signals fail closed without numeric conversion crashes. Minimum net reward/risk must be finite and at least 1. Base cost remains the research assumption (0.35% round trip and market-dependent slippage); an additional scenario doubles both cost and slippage and requires the same minimum reward/risk. This is stress testing, not measured execution-cost calibration. Both ratios and policy version are stored on TOP3.

TOP3 admits at most two stocks from one industry name; unknown industries share one bucket. If diversification cannot be met, fewer than three names are returned. This is a candidate concentration constraint, not an account allocation or covariance model.

Each recommendation includes governance: attempted/analyzed/excluded counts, collection failures by code/market/type/HTTP status, selected evidence coverage, per-module coverage, eight source file hashes and a combined model fingerprint. Source stability is checked at the beginning and end of the run. Validation status remains explicitly unvalidated for this fingerprint and productionEnabled is false. The dashboard displays evidence coverage and collection failures. Already-running refresh requests return HTTP 409; a competing worker does not overwrite active progress as a failed run.

Independent listing collection now tolerates moving market-cap pagination by merging distinct codes over at most three passes. Observed/reported counts, pass counts and all returned pages are archived. A remaining count deficit aborts publication of new input. Count completion is explicitly not an atomic, point-in-time universe guarantee. It cannot repair survivorship bias or corporate-action history.

### Dashboard information hierarchy (2026-09-21)

The dashboard uses a single vertical reading flow: four primary market/recommendation metrics, short-term candidates, long-term candidates, and a collapsed research/validation section. Short- and long-term tables are no longer placed in two columns. Market is combined with the stock identity, labels are translated for display, decision reasons wrap instead of truncating, and numeric columns retain tabular alignment. Desktop uses full-width tables; screens up to 760px render each stock as a labeled card without horizontal overflow. Section navigation, keyboard-openable stock rows, dialog semantics, visible focus states and reduced-motion behavior are included. Scores are explicitly described as non-probabilities and the UI remains research/observation only.

Stock details use a compact decision view instead of the generated narrative paragraph. It shows the current entry state and at most two immediate blockers, up to five positive observations, up to five explicit risks, and the first two analyst-report highlights truncated to 150 characters. Internal source states such as `missing-or-stale` are not presented as investment reasons. The compact view is derived from the same stored numeric fields; it does not add or infer new evidence.

### Existing recommendation integration (2026-09-21)

`tools/upside_bridge.ps1` connects the independent evidence snapshot to the existing recommendation engine before market TOP10 selection and TOP3 ranking. The join requires matching market and code; report and per-stock decision timestamps must be non-future and at most 24 hours old. Price sessions must match, except that before 16:00 KST today's intraday candidate may use the immediately preceding weekday's completed-session features (Monday accepts Friday). This exception is marked `sessionBasis=prior-completed-session-intraday` with the actual `priceAsOf`; holiday gaps fail closed pending an exchange calendar. Missing/stale/malformed evidence gives zero adjustment and blocks entry. This is a snapshot bridge, not automatic collection of unconnected feeds; the 30-stock independent pilot does not cover every legacy candidate.

`selectionScore` preserves `shortTermScore` and adds a research adjustment bounded to [-6,+6]: +2 per distinct price-volume/flow/earnings information group (maximum +6), -3 for defensive regime, -4 for unacceptable structural risk, -6 for adverse events. These are unvalidated policy parameters, not fitted probabilities. Existing market diversification remains in effect. TOP10 and TOP3 use selectionScore; the UI uses the same score and propagates evidence blockers. Long-term fundamental scoring remains unchanged because these rules target 1-3 sessions.

The complete components, unique supports, source report hash, source time, adjustment and blockers are attached to each selected item and TOP3, and retained in the full PIT snapshots. Existing risk gates continue to apply; independent blockers are additive. A fresh quote must be checked at entry, and the new policy must pass separate unused-data validation before active recommendations are enabled. Old rise probabilities are preserved as `legacyRiseProbability` for audit but are not displayed as probabilities of the new policy. TOP3 probability is null, never a score cast as confidence. Formula version is `short-term-v4-upside-evidence`; previous performance cannot establish this policy's quality.

Recommendation generation is protected by a cross-process named mutex. JSON publication uses same-directory temporary files and File.Replace for existing destinations (NullString for Windows PowerShell compatibility). This fixes the observed collision between an old auto-refresh worker and manual generation; the lock must be present in every worker, so pre-upgrade workers must finish before a new run. Regression checks: `tools/test_upside_bridge.ps1`, `tools/test_upside_storage.ps1`, existing engine and validation tests.

Independent source-driven successor: `tools/independent_upside.py` now collects a separate market-listing liquidity pilot and runs regime, sector, price/volume, flow, revisions, catalysts, short-pressure, execution and structural-risk modules. It does not consume legacy recommendation scores, candidate lists or stop values. Missing optional feeds remain explicit and block entry; the new feature set has no trained probability model yet. Reports retain null probabilities and `productionEnabled=false`. `/api/independent-upside` serves reports at most 24 hours old. Raw adapters, snapshot hashes and supplement payloads are archived; no automatic trading or replacement of existing recommendations is enabled. Architecture, contracts, actual collection results and the separate validation plan are documented in `docs/IndependentUpsideEngine.md`.

`tools/target10.py` implements a separate `target10-first-passage-v1` research model for next-session entry and net +10% before a volatility stop within 1/2/3 trading days. Target quotes include the existing cost/slippage assumptions. Daily-bar ordering, gap stops, missing sessions, corporate-action price-basis checks, training-label purging and a seven-calendar-day embargo are explicit.

Inputs come from the first archived run per actual recording day; price outcomes are fetched only after freezing source hashes, feature records, a fixed policy and holdout boundary. Latest 25% of dates are held out (2026-08-28 onward in v1). A fixed 100-neighbor empirical model estimates seven mutually exclusive first-passage categories; period-specific target/stop/neither probabilities sum to one. Existing riseProbability scores are not features or labels. Probabilities are research estimates, not validated investment confidence.

`build` freezes and evaluates once; an existing evaluated holdout cannot be silently reused to select new parameters. `predict` uses the frozen model only, after checking its digest and training cutoff. Each recommendation generation invokes predict after saving normal reports. `/api/target10` serves `reports/target10/latest.json` only when its source snapshot hash matches the current recommendation and its forecast age is at most 24 hours. The web dashboard shows a dedicated research table with 1/2/3-day target/stop probabilities and expected net return. Android integration remains outstanding.

Actual v1 validation: 1,280 feature records, 174 successfully fetched instruments, 531 valid mature observations, 383 training cases, 53 purged cases, 95 held-out cases across five entry dates. D3 target-first: 8/95; stop-first: 52/95. Target Brier 0.08195 versus base-rate 0.08164. Selected test trades: zero. Sample-size, target-probability improvement and positive-expectancy gates failed. `productionEnabled=false`; outputs remain research/watchlist. Historical selection/price-basis exclusions and prior human exposure mean prospective verification is still required. Full assumptions, exclusions and results: `docs/Target10Model.md`.
