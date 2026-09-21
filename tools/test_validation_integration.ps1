param([Parameter(Mandatory=$true)][string]$WorkRoot)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) ([guid]::NewGuid().ToString('N'))
$testTools = Join-Path $root 'tools'
$reports = Join-Path $root 'reports'
New-Item -ItemType Directory -Path $testTools,$reports -Force | Out-Null
foreach ($file in @('monthly_validation.ps1','validation_core.ps1','auto_tuning.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $testTools
}
@'
$ErrorActionPreference = 'Stop'
$script:ReportDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'reports'
function Start-TopPicksProxy {}
function Invoke-RestMethod { param($Uri, $TimeoutSec)
    Get-Content -Raw (Join-Path $script:ReportDir 'fixture.json') | ConvertFrom-Json
}
function Write-TopPicksLog { param($Task, $Status, $Message, $Data)
    if ($Status -eq 'failure') { throw $Message }
}
'@ | Set-Content (Join-Path $testTools 'automation_common.ps1') -Encoding UTF8
$stock = @(
    @{date='20260914';open=100;high=102;low=94;price=101},
    @{date='20260915';open=101;high=112;low=100;price=111},
    @{date='20260916';open=111;high=115;low=110;price=114}
)
@{stockHistory=$stock;indexHistory=@(
    @{date='20260914';open=100;price=102},
    @{date='20260915';open=102;price=104},
    @{date='20260916';open=104;price=105}
)} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $reports 'fixture.json') -Encoding UTF8
$base = @{recommendationDate='2026-09-11';recordedAt='2026-09-11T18:00:00+09:00';market='KOSPI';code='005930';name='fixture';rank=1;entryStatus='pending';targetPrice=110;stopPrice=95;scoringFormulaVersion='short-term-v3-gapguard-1to3d';strategyEngine='trendMomentum'}
$watch = $base.Clone(); $watch.code='000660'; $watch.entryStatus='watchlist'; $watch.entryMethod='watchlist-blocked-entry'
$old = $base.Clone(); $old.code='035420'; $old.scoringFormulaVersion='old'; $old.probabilityType='calibrated-3d'
@($base,$watch,$old) | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $reports 'ai-top3-history.json') -Encoding UTF8
@(@{date='2026-09-11';code='005930';market='KOSPI';score=50;model='dynamic'}) | ConvertTo-Json -AsArray | Set-Content (Join-Path $reports 'web-recommendation-history.json') -Encoding UTF8
$shell = (Get-Process -Id $PID).Path
& $shell -NoProfile -File (Join-Path $testTools 'monthly_validation.ps1')
if ($LASTEXITCODE -ne 0) { throw "Validation integration failed: $LASTEXITCODE" }
$result = Get-Content -Raw (Join-Path $reports 'ai-top3-validation.json') | ConvertFrom-Json
if ($result.items.Count -ne 3) { throw 'Lost validation rows.' }
$active = $result.items | Where-Object code -eq '005930'
if ($active.d1Return -ge 0 -or $active.d3Return -ne $active.d1Return -or $active.exitEvent -ne 'stop') { throw 'Exit return integration failed.' }
if ([math]::Abs($active.d1ExcessReturn - ($active.d1Return - 2)) -gt 0.0001) { throw 'D+1 benchmark integration failed.' }
if ($result.currentFormulaStatistics.savedRecommendationCount -ne 2 -or $result.currentFormulaStatistics.hitRate3Day -ne 0) { throw 'Formula or watchlist contamination.' }
if ($result.currentFormulaStatistics.strategyStatistics[0].matured3DayCount -ne 1) { throw 'Strategy sample must include active matured picks only.' }
if ($result.statistics.watchlistStatistics.count -ne 1) { throw 'Blocked watchlist was omitted.' }
& $shell -NoProfile -File (Join-Path $testTools 'auto_tuning.ps1')
if ($LASTEXITCODE -ne 0) { throw "Tuning integration failed: $LASTEXITCODE" }
$tuning = Get-Content -Raw (Join-Path $reports 'tuning-suggestions.json') | ConvertFrom-Json
if ($tuning.maturedRecommendationCount -ne 1 -or $tuning.hitRateD3 -ne 0 -or $tuning.suggestions[0].action -ne 'wait') { throw 'Tuning sample gate failed.' }
Write-Output 'PASS validation/tuning integration (8 assertions; isolated reports, mocked API)'
