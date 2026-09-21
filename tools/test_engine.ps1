$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\validation_core.ps1"
. "$PSScriptRoot\entry_risk.ps1"
. "$PSScriptRoot\data_quality.ps1"
$script:checks = 0
function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Bar($Date, $Open, $High, $Low, $Close) {
    [pscustomobject]@{ date = $Date; open = $Open; high = $High; low = $Low; price = $Close }
}
$bars = @((Bar '20260914' 100 102 94 101), (Bar '20260915' 101 112 100 111), (Bar '20260916' 111 115 110 114))
$stop = Get-TradeOutcome 100 110 95 $bars 3 0.1 0.35
Assert ($stop.exitEvent -eq 'stop' -and $stop.netReturn -eq -5.445) 'Stop must freeze return before the later rally.'
Assert ($stop.exitDate -eq '20260914') 'Stop exit date.'
$both = Get-TradeOutcome 100 110 95 @((Bar '20260914' 100 112 94 111)) 1 0 0
Assert ($both.exitEvent -eq 'stop-first-ambiguous' -and $both.netReturn -eq -5) 'Unknown intraday ordering must be conservative.'
$gap = Get-TradeOutcome 100 110 95 @((Bar '20260914' 100 103 98 102), (Bar '20260915' 90 94 89 93)) 2 0 0
Assert ($gap.exitEvent -eq 'stop-gap' -and $gap.netReturn -eq -10) 'Gap stop fills at open, not stop price.'
$target = Get-TradeOutcome 100 110 95 @((Bar '20260914' 100 105 98 104), (Bar '20260915' 112 114 94 96)) 2 0 0
Assert ($target.exitEvent -eq 'target-gap' -and $target.netReturn -eq 10) 'Opening target precedes later stop.'
$close = Get-TradeOutcome 100 110 95 @((Bar '20260914' 100 105 98 104)) 1 0.1 0.35
Assert ($close.netReturn -eq 3.546) 'Horizon exit must include slippage and fees.'
Assert ($null -eq (Get-TradeOutcome 100 110 95 $bars 4 0 0)) 'Immature horizons remain null.'
$thrown = $false
try { Get-TradeOutcome 100 110 95 @((Bar '20260914' 100 99 98 101)) 1 0 0 } catch { $thrown = $true }
Assert $thrown 'Invalid OHLC must not become a return.'
$bench = @((Bar '20260914' 100 103 99 102), (Bar '20260915' 102 106 101 105))
Assert ([math]::Abs((Get-BenchmarkReturn $bench '20260914' '20260914') - 2) -lt 0.000001) 'D+1 benchmark must include its opening-to-close return.'
Assert ([math]::Abs((Get-BenchmarkReturn $bench '20260914' '20260915') - 5) -lt 0.000001) 'D+2 benchmark alignment.'
Assert ($null -eq (Get-BenchmarkReturn @([pscustomobject]@{date='20260914';price=102}) '20260914' '20260914')) 'Missing benchmark open remains unknown.'
$filtered = @(Get-ValidationBars $bars '2026-09-13' '2026-09-14T18:00:00+09:00' ([datetimeoffset]'2026-09-16T15:00:00+09:00'))
Assert ($filtered.Count -eq 1 -and $filtered[0].date -eq '20260915') 'Exclude bars before actual recording and partial current day.'
$filtered = @(Get-ValidationBars $bars '2026-09-13' '' ([datetimeoffset]'2026-09-16T16:00:00+09:00'))
Assert ($filtered.Count -eq 3) 'Closed bar eligible after cutoff.'
$thrown = $false
try { Get-ValidationBars @($bars[0],$bars[0]) '2026-09-13' '' ([datetimeoffset]'2026-09-20T00:00:00Z') | Out-Null } catch { $thrown = $true }
Assert $thrown 'Duplicate sessions must not advance horizons.'
$candidate = [pscustomobject]@{ market='KOSPI'; sectorRotationStatus='strong'; signals=[pscustomobject]@{
    averageTradingValue=200; rsi=55; ma20Deviation=3; intradayReturn=1; openingGapRate=1; pykrx=[pscustomobject]@{available=$true}
} }
$risk = Get-EntryRisk $candidate 5 3
Assert ($risk.blockers.Count -eq 0 -and $risk.netRewardRisk -gt 1) 'Valid risk inputs pass.'
Assert ((Get-EntryRisk $candidate 2.5 5.5).blockers -contains 'insufficient-net-reward-risk') 'Poor net payoff blocks entry.'
$candidate.signals.pykrx.available = $false
$candidate.signals.openingGapRate = 3
$candidate.signals.rsi = $null
$risk = Get-EntryRisk $candidate 5 3
Assert ($risk.blockers -contains 'unverified-investor-flow') 'Missing flow blocks entry.'
Assert ($risk.blockers -contains 'opening-gap-above-limit') 'Gap guard blocks entry.'
Assert ($risk.blockers -contains 'missing-or-invalid-rsi') 'Missing numeric signal cannot silently become zero.'
Assert ((Convert-FinancialAmount '-1,234') -eq -1234) 'DART loss sign must be preserved.'
Assert ((Convert-FinancialAmount '(1,234)') -eq -1234) 'Accounting negative amount.'
Assert ($null -eq (Convert-FinancialAmount '-')) 'Unavailable financial value stays null.'
Assert ($null -eq (Convert-FinancialAmount 'NaN')) 'Nonfinite financial value rejected.'
$flow = [pscustomobject]@{available=$true;flowAsOf='2026-09-18';flowUnit='KRW';flowRows=60}
Assert (Test-FreshFlow $flow ([datetime]'2026-09-20')) 'Dated complete flow accepted.'
Assert (-not (Test-FreshFlow $flow ([datetime]'2026-10-01'))) 'Old source data rejected despite a new collection timestamp.'
Assert (-not (Test-FreshFlow $flow ([datetime]'2026-09-17'))) 'Future source data rejected.'
$flow.flowRows = 20
Assert (-not (Test-FreshFlow $flow ([datetime]'2026-09-20'))) 'Incomplete flow window rejected.'
# Execute the actual DART mapping function with fixtures; do not start proxy or load keys.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'kiwoom_proxy.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Proxy parser errors.' }
$function = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DartSnapshot'}, $true)
. ([scriptblock]::Create($function.Extent.Text))
function Get-DartCorpMap { @{ '005930' = 'fixture' } }
function Invoke-DartApi($Endpoint, $Parameters) {
    if ($Endpoint -eq 'list') { return @{status='000';list=@()} }
    if ($Parameters.bsns_year -ne [string](Get-Date).Year) { throw 'Current year was skipped.' }
    @{status='000';list=@(
        @{account_id='ifrs-full_Liabilities';thstrm_amount='1,000'},
        @{account_id='ifrs-full_Equity';thstrm_amount='-500'},
        @{account_id='dart_OperatingIncomeLoss';thstrm_amount='-123,456'}
    )}
}
$dart = Get-DartSnapshot '005930'
Assert ($dart.operatingProfit -eq -123456) 'Actual DART mapper must retain losses.'
Assert ($dart.nonPositiveEquity -and $null -eq $dart.debtRatio) 'Negative equity is distress, not a favorable debt ratio.'
Assert ($dart.financialYear -eq (Get-Date).Year) 'Current fiscal year must be queried.'
Write-Output "PASS $script:checks engine assertions"
