param(
    [string]$RunLabel = 'DailyRecommendation',
    [switch]$SendTelegram
)

. "$PSScriptRoot\automation_common.ps1"
$taskName = 'daily-recommendation'

try {
    Start-TopPicksProxy | Out-Null
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $start = Invoke-RestMethod 'http://127.0.0.1:8787/api/recommendations?refresh=1' -TimeoutSec 30
    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Seconds 2
        $progress = Invoke-RestMethod 'http://127.0.0.1:8787/api/progress' -TimeoutSec 30
        if ($progress.runId -eq $start.runId -and $progress.status -eq 'failed') {
            throw "Recommendation failed: $($progress.message)"
        }
        if ((Get-Date) -gt $deadline) {
            throw 'Recommendation timed out after 15 minutes.'
        }
    } until ($progress.runId -eq $start.runId -and $progress.status -eq 'completed')
    $result = Invoke-RestMethod 'http://127.0.0.1:8787/api/recommendations' -TimeoutSec 30
    $items = @($result.items)
    $kospi = @($items | Where-Object market -eq 'KOSPI').Count
    $kosdaq = @($items | Where-Object market -eq 'KOSDAQ').Count
    if ($kospi -ne 10 -or $kosdaq -ne 10) {
        throw "Recommendation count is invalid: KOSPI=$kospi, KOSDAQ=$kosdaq"
    }
    if (@($result.top3).Count -ne 3) {
        throw "AI TOP3 count is invalid: $(@($result.top3).Count)"
    }
    if ($result.recommendationDate -ne $today) {
        Write-TopPicksLog $taskName 'success' 'No new trading-day recommendation was saved.' @{
            date = $today
            runLabel = $RunLabel
            latestTradingDate = $result.recommendationDate
        }
        exit 0
    }
    $telegramStatePath = Join-Path $script:ReportDir 'telegram-top3-state.json'
    $telegramState = if (Test-Path -LiteralPath $telegramStatePath) {
        Get-Content -Raw -LiteralPath $telegramStatePath -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    $telegramMessageId = $null
    if ($SendTelegram -and (
        $null -eq $telegramState -or
        $telegramState.recommendationDate -ne $result.recommendationDate -or
        $telegramState.runLabel -ne $RunLabel
    )) {
        $telegramMessageId = Send-TopPicksTelegram $result
        @{
            recommendationDate = $result.recommendationDate
            runLabel = $RunLabel
            sentAt = (Get-Date).ToString('o')
            messageId = $telegramMessageId
        } | ConvertTo-Json | Set-Content -LiteralPath $telegramStatePath -Encoding UTF8
    }
    Write-TopPicksLog $taskName 'success' 'Daily recommendation was generated and saved.' @{
        date = $today
        runLabel = $RunLabel
        savedCount = $items.Count
        kospi = $kospi
        kosdaq = $kosdaq
        top3 = @($result.top3 | ForEach-Object code)
        telegramEnabled = [bool]$SendTelegram
        telegramMessageId = $telegramMessageId
    }
    if ((Get-Date).Hour -ge 16) {
        $powerResult = Invoke-TopPicksSafeHibernate
        if (-not $powerResult.hibernated) {
            Write-TopPicksLog $taskName 'success' 'Automatic hibernation was skipped.' $powerResult
        }
    } else {
        Write-TopPicksLog $taskName 'success' 'Automatic hibernation was skipped for morning analysis.' @{
            hour = (Get-Date).Hour
        }
    }
    exit 0
} catch {
    Write-TopPicksLog $taskName 'failure' $_.Exception.Message
    exit 1
}
