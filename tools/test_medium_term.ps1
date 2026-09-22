$ErrorActionPreference='Stop'
. "$PSScriptRoot\medium_term.ps1"
$asOf=[datetimeoffset]'2026-09-22T12:00:00+09:00'
$item=[pscustomobject]@{
    tradingDate='2026-09-22';scoreBreakdown=@{industryMomentum=10;riskPenalty=0};valuationScore=10;per=10;pbr=1
    sectorRotationStatus='strong';targetUpside=50
    reportEvidence=@{latestPublishedAt='2026-09-01';uniqueBrokerCount=3}
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
