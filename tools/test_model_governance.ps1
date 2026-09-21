$ErrorActionPreference='Stop'
. "$PSScriptRoot\model_governance.ps1"
. "$PSScriptRoot\entry_risk.ps1"
$checks=0
function Assert($Condition,$Message){if(-not $Condition){throw $Message};$script:checks++}
$candidate=[pscustomobject]@{market='KOSPI';sectorRotationStatus='strong';signals=[pscustomobject]@{
    averageTradingValue=100;rsi=50;ma20Deviation=2;intradayReturn=1;openingGapRate=0;pykrx=@{available=$true}}}
$candidate.signals.rsi='corrupt'
Assert ((Get-EntryRisk $candidate 5 3).blockers -contains 'missing-or-invalid-rsi') 'Malformed numeric input must block without crashing'
$candidate.signals.rsi=101
Assert ((Get-EntryRisk $candidate 5 3).blockers -contains 'signal-out-of-domain') 'RSI domain violation must block'
$candidate.signals.rsi=50
foreach($invalid in @('bad',[double]::NaN,[double]::PositiveInfinity,$true)){
    Assert ((Get-EntryRisk $candidate $invalid 3).blockers -contains 'invalid-risk-input') 'Invalid target must block'
}
Assert ((Get-EntryRisk $candidate 5 3 ([double]::NaN)).blockers -contains 'invalid-risk-input') 'NaN reward-risk threshold must not disable gate'
$risk=Get-EntryRisk $candidate 4.1 3
Assert ($risk.netRewardRisk -gt 1 -and $risk.stressedRewardRisk -lt 1 -and $risk.blockers -contains 'insufficient-stressed-reward-risk') 'Cost stress must block fragile payoff'
$rows=@(
    [pscustomobject]@{code='1';industryName='A';selectionScore=90},
    [pscustomobject]@{code='2';industryName='A';selectionScore=89},
    [pscustomobject]@{code='3';industryName='A';selectionScore=88},
    [pscustomobject]@{code='4';industryName='B';selectionScore=87})
$selected=@(Select-RiskDiversifiedTop $rows)
Assert ($selected.Count -eq 3 -and $selected[2].code -eq '4') 'TOP3 must not concentrate three stocks in one industry'
$rows|ForEach-Object {$_.industryName=$null}
Assert (@(Select-RiskDiversifiedTop $rows).Count -eq 2) 'Unknown industries must not be assumed diversified'
$selected=@([pscustomobject]@{upsideEvidence=@{status='available';components=@{risk=@{status='available'}}}},[pscustomobject]@{upsideEvidence=@{status='missing-or-stale'}})
$audit=Get-RecommendationGovernance @('a','b','c') $selected 5 @(@{code='failed'}) @{fingerprint='A';files=@{}} @{fingerprint='B'}
Assert ($audit.evidenceCoveragePct -eq 50 -and $audit.collectionFailureCount -eq 1 -and $audit.excludedOrUnavailableCount -eq 1) 'Audit denominators must retain failures and exclusions'
Assert ($audit.moduleAvailableCounts.risk -eq 1 -and $audit.moduleAvailableCounts.flow -eq 0) 'Unknown module must not count as verified'
Assert (-not $audit.productionEnabled -and $audit.blockers -contains 'source-code-changed-during-run') 'Changed code cannot claim validated production status'
$manifest=Get-ModelManifest $PSScriptRoot
Assert ($manifest.fingerprint.Length -eq 64 -and $manifest.files.Count -eq 8) 'Model fingerprint must cover decision, data and validation modules'
Write-Output "PASS $checks model governance assertions"
