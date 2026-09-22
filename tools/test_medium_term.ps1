$ErrorActionPreference='Stop'
. "$PSScriptRoot\medium_term.ps1"
$item=[pscustomobject]@{scoreBreakdown=@{earnings=25;reports=16;financial=5;industryMomentum=10};valuationScore=10;fcf=1;signals=@{risingMa60=$true;foreignFlowRatio=1;institutionFlowRatio=1}}
$full=Get-MediumTermAssessment $item
if($full.score -ne 100 -or $full.productionEnabled -or $null -ne $full.riseProbability){throw 'Score/release gate failure'}
$item.fcf=$null;$missing=Get-MediumTermAssessment $item
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
if((Get-MediumTermAssessment $item).missingFactors -notcontains 'valuation'){throw 'Invalid numeric evidence accepted'}
$candidates=@(1..4|ForEach-Object {[pscustomobject]@{code="$_";liquid=$true;industryName='same';mediumTerm=@{score=$_}}})
if(@(Select-MediumTermCandidates $candidates).Count -ne 2){throw 'Industry cap failure'}
'PASS: invalid numeric evidence and industry concentration'
