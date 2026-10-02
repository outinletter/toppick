$ErrorActionPreference='Stop'
. "$PSScriptRoot\medium_term.ps1"
$asOf=[datetimeoffset]'2026-09-22T12:00:00+09:00'
$item=[pscustomobject]@{
    tradingDate='2026-09-22';scoreBreakdown=@{industryMomentum=10;riskPenalty=0};valuationScore=10;per=10;pbr=1
    sectorRotationStatus='strong';targetUpside=50
    reportEvidence=@{latestPublishedAt='2026-09-01';uniqueBrokerCount=3;targetBrokerCount=3}
    mediumFinancialEvidence=@{source='DART-CFS';currency='KRW';reportCode='11012';periodEnd='2026-06-30';publishedDate='2026-08-14';collectedAt='2026-09-22T11:00:00+09:00';profit=150;priorYearProfit=100;revenue=130;priorYearRevenue=100;equity=100;liabilities=80;operatingCashFlow=10}
    signals=@{risingMa60=$true;pykrx=@{available=$true;flowUnit='KRW';flowRows=80;flowAsOf='2026-09-21';foreign20=1;foreign60=1;institution20=1;institution60=1}}
}
$full=Get-MediumTermAssessment $item $asOf
if($full.score -ne 100 -or $full.productionEnabled -or $null -ne $full.riseProbability){throw 'Score/release gate failure'}
$item.mediumFinancialEvidence.operatingCashFlow=$null;$missing=Get-MediumTermAssessment $item $asOf
if($missing.score -ne 95 -or $missing.missingFactors -notcontains 'cashFlow'){throw 'Missing data redistributed'}
$rows=@(0..60|ForEach-Object {@{date=([datetime]'2020-01-01').AddDays($_).ToString('yyyyMMdd');open=100;price=110;low=95}})
$result=Get-MediumTermOutcome $rows $rows '20200101' 20
if($result.status -ne 'observed' -or [math]::Abs($result.netReturnPct-9.7) -gt 0.0001){throw 'Return/cost calculation failure'}
if((Get-MediumTermOutcome $rows[0..18] $rows '20200101' 20).status -ne 'missing-bars'){throw 'Missing sessions silently skipped'}
if((Get-MediumTermOutcome $rows $rows[0..18] '20200101' 20).status -ne 'pending'){throw 'Immature outcome treated as observed'}
$rows[1].price=80
if((Get-MediumTermOutcome $rows $rows '20200101' 20).closeMaxDrawdownPct -ne -20){throw 'Drawdown calculation failure'}
'PASS: medium-term score, missingness, research gate, net costs, missing sessions, maturity, drawdown'
$item.valuationScore=[double]::NaN
if((Get-MediumTermAssessment $item $asOf).missingFactors -notcontains 'valuation'){throw 'Invalid numeric evidence accepted'}
$candidates=@(1..4|ForEach-Object {[pscustomobject]@{code="$_";liquid=$true;industryName='same';mediumTerm=@{score=$_;candidateEligible=$true}}})
if(@(Select-MediumTermCandidates $candidates).Count -ne 2){throw 'Industry cap failure'}
'PASS: invalid numeric evidence and industry concentration'

$item | Add-Member -NotePropertyName liquid -NotePropertyValue $true
$item.valuationScore=10;$item.mediumFinancialEvidence.operatingCashFlow=10
$ready=Get-MediumTermAssessment $item $asOf
if($ready.entryStatus -ne 'conditional-candidate' -or $ready.productionEnabled){throw 'Conditional evidence candidate incorrectly released or hidden'}
if($ready.blockers -contains 'estimate-revision-api-not-connected' -or $ready.limitations -notcontains 'estimate-revision-api-not-connected'){throw 'Optional paid feed became permanent blocker'}
if($ready.validationRequirements -notcontains '20-40-60-day-unused-data-validation-required'){throw 'Validation gate removed'}
$item.signals.risingMa60=$false
if((Get-MediumTermAssessment $item $asOf).entryStatus -ne 'watchlist'){throw 'Weak trend promoted to conditional candidate'}
$item.signals.risingMa60=$true
$item.tradingDate='2026-08-01'
if((Get-MediumTermAssessment $item $asOf).entryStatus -ne 'data-insufficient'){throw 'Stale data promoted to candidate'}
$item.tradingDate='2026-09-22'
'PASS: conditional status, optional-feed limitation, validation gate, weak trend and stale-data states'

$item.tradingDate='2026-10-01'
if((Get-MediumTermAssessment $item $asOf).candidateEligible){throw 'Future price accepted'}
$item.tradingDate='2026-09-22';$item.signals.pykrx.flowAsOf='2026-08-01'
if($null -ne (Get-MediumTermAssessment $item $asOf).components.flow20){throw 'Stale flows awarded points'}
$item.mediumFinancialEvidence.publishedDate='2027-01-01'
if((Get-MediumTermAssessment $item $asOf).candidateEligible){throw 'Future financial disclosure accepted'}
. "$PSScriptRoot\data_quality.ps1"
$financials=@{list=@(@{account_id='dart_OperatingIncomeLoss';sj_div='IS';currency='KRW';thstrm_amount='150';frmtrm_amount='999';frmtrm_q_amount='100';rcept_no='20260814000001'})}
$quarter=Get-DartMediumEvidence $financials 2026 '11012'
$annual=Get-DartMediumEvidence $financials 2025 '11011'
if($quarter.priorYearProfit -ne 100 -or $annual.priorYearProfit -ne 999){throw 'Annual/quarter comparative periods confused'}
'PASS: future/stale source exclusion and DART comparable-period mapping'
if(Test-MediumDate '2026-09-22T20:00:00+09:00' $asOf 90){throw 'Same-day future report accepted'}

$rows=@(0..60|ForEach-Object {@{date=([datetime]'2020-01-01').AddDays($_).ToString('yyyyMMdd');open=100;price=110;low=90}})
$outcome=Get-MediumTermOutcome $rows $rows '20200101' 20
if([math]::Abs($outcome.stressedNetReturnPct-9.4) -gt 0.0001 -or $outcome.adverseExcursionPct -ne -10){throw 'Cost stress or intraday adverse excursion failure'}
if((Get-MediumTermOutcome ($rows+@($rows[1])) $rows '20200101' 20).status -ne 'duplicate-bars'){throw 'Duplicate stock bars accepted'}
$rows[1].low=[double]::NaN
if((Get-MediumTermOutcome $rows $rows '20200101' 20).status -ne 'missing-bars'){throw 'Nonfinite price accepted'}
$auditRows=@(
    [pscustomobject]@{signalDate='20200101';modelFingerprint='current';outcomes=@([pscustomobject]@{status='observed';horizon=20;entryDate='20200102';exitDate='20200122';netReturnPct=10;benchmarkExcessPct=3;stressedNetReturnPct=9})},
    [pscustomobject]@{signalDate='20200102';modelFingerprint='current';outcomes=@([pscustomobject]@{status='observed';horizon=20;entryDate='20200103';exitDate='20200123';netReturnPct=90;benchmarkExcessPct=80;stressedNetReturnPct=89})},
    [pscustomobject]@{signalDate='20200201';modelFingerprint='old';outcomes=@([pscustomobject]@{status='observed';horizon=20;entryDate='20200202';exitDate='20200222';netReturnPct=99;benchmarkExcessPct=90;stressedNetReturnPct=98})}
)
$summary=Get-MediumValidationSummary $auditRows 'current'
if($summary.horizons[0].observedStockCount -ne 2 -or $summary.horizons[0].nonOverlappingPeriodCount -ne 1 -or $summary.horizons[0].meanNetReturnPct -ne 10 -or $summary.excludedModelRows -ne 1){throw 'Overlap or model-version contamination'}
if($summary.horizons[1].meanNetReturnPct -ne $null -or $summary.productionEnabled){throw 'Missing performance treated as zero or released'}
if((Get-MediumValidationSummary $auditRows '').horizons[0].nonOverlappingPeriodCount -ne 0){throw 'Unidentified model accepted'}
'PASS: cost stress, adverse excursion, invalid bars, nonoverlap, model fingerprint and empty validation'
$failed=[pscustomobject]@{signalDate='20200101';modelFingerprint='current';outcomes=@([pscustomobject]@{status='collection-failed';horizon=20})}
$incomplete=Get-MediumValidationSummary ($auditRows+@($failed)) 'current'
if($incomplete.horizons[0].incompleteCohortCount -ne 1 -or $incomplete.horizons[0].periods[0].signalDate -eq '20200101'){throw 'Failed stocks excluded to inflate cohort returns'}
'PASS: incomplete-cohort exclusion'
