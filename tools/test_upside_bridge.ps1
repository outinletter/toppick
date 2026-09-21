$ErrorActionPreference='Stop'
. "$PSScriptRoot\upside_bridge.ps1"
$checks=0
function Assert($Condition,$Message) { if(-not $Condition){throw $Message}; $script:checks++ }
$at=[datetimeoffset]'2026-09-21T08:00:00+09:00'
$candidate=[pscustomobject]@{code='005930';market='KOSPI';tradingDate='2026-09-18';shortTermScore=50}
$missing=Add-IntegratedUpsideEvidence $candidate @{} $at
Assert ($missing.selectionScore -eq 50 -and $missing.upsideEvidence.blockers.Count -gt 0) 'Missing inputs must not improve score or allow entry'
$item=[pscustomobject]@{code='005930';market='KOSPI';decisionAt=$at.AddMinutes(-5).ToString('o');sourceAvailableAt=$at.AddHours(-2).ToString('o');priceAsOf='20260918';status='analyzed';
    independentSupports=@('price-volume-breakout','earnings-information-repricing');entryBlockers=@('security-master-not-verified');
    components=[pscustomobject]@{risk=[pscustomobject]@{riskAcceptable=$true};priceVolume=[pscustomobject]@{status='available'};regime=[pscustomobject]@{regime='supportive'};catalysts=[pscustomobject]@{risks=@()}}}
$map=@{'KOSPI|005930'=[pscustomobject]@{item=$item;hash='fixture';generatedAt=$at.ToString('o')}}
$result=Add-IntegratedUpsideEvidence $candidate $map $at
Assert ($result.selectionScore -eq 54 -and $result.shortTermScore -eq 50) 'Evidence must affect selection while preserving base score'
Assert ($result.upsideEvidence.blockers.Count -eq 3) 'Source blockers, execution recheck and model validation must persist'
$item.sourceAvailableAt=$at.AddHours(-25).ToString('o')
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).status -ne 'available') 'Reanalysis must not refresh expired raw evidence'
$item.sourceAvailableAt=$at.AddSeconds(1).ToString('o')
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).status -ne 'available') 'Future raw availability must not join'
$item.sourceAvailableAt=$at.AddHours(-2).ToString('o')
$item.components.catalysts=[pscustomobject]@{status='missing'}
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).adjustment -eq 4) 'Missing events must not be treated as an observed adverse event'
$item.components.catalysts=[pscustomobject]@{risks=@()}
$item.independentSupports=@('same','same')
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).adjustment -eq 2) 'Duplicate supports must not count twice'
$item.components.risk.riskAcceptable=$false
$item.components.catalysts.risks=@('dilution')
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).adjustment -eq -6) 'Adverse risk must reduce rank with bounded adjustment'
$item.priceAsOf='20260917'
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).status -ne 'available') 'Different price sessions must not join'
$item.priceAsOf='20260918';$candidate.tradingDate='2026-09-21'
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).sessionBasis -eq 'prior-completed-session-intraday') 'Monday intraday can use Friday completed evidence'
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at.AddHours(9)).status -ne 'available') 'Prior-session allowance must expire after close'
$candidate.tradingDate='2026-09-18'
$item.priceAsOf='20260918';$item.decisionAt=$at.AddMinutes(1).ToString('o')
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).status -ne 'available') 'Future decision evidence must not join'
$item.decisionAt=$at.AddHours(-25).ToString('o')
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).status -ne 'available') 'Stale per-stock evidence must not join'
$candidate.market='KOSDAQ'
Assert ((Get-IntegratedUpsideEvidence $candidate $map $at).status -ne 'available') 'Market must match'
$fixturePath=Join-Path ([IO.Path]::GetTempPath()) ('upside-map-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $report=@{version='independent-upside-v1';generatedAt=$at.ToString('o');items=@($item)}
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding UTF8
    Assert ((Get-UpsideEvidenceMap $fixturePath $at).Count -eq 1) 'Fresh report must load'
    $report.generatedAt=$at.AddMinutes(1).ToString('o')
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding UTF8
    Assert ((Get-UpsideEvidenceMap $fixturePath $at).Count -eq 0) 'Future report must be rejected'
    $report.generatedAt=$at.ToString('o');$report.items=@($item,$item)
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixturePath -Encoding UTF8
    Assert ((Get-UpsideEvidenceMap $fixturePath $at).Count -eq 0) 'Duplicate source keys must fail closed'
    'invalid json' | Set-Content -LiteralPath $fixturePath -Encoding UTF8
    Assert ((Get-UpsideEvidenceMap $fixturePath $at).Count -eq 0) 'Broken source must not crash generation'
} finally { if(Test-Path -LiteralPath $fixturePath){Remove-Item -LiteralPath $fixturePath} }
Write-Output "PASS $checks upside integration assertions"
