param(
    [int]$TimeoutMinutes = 10
)

. "$PSScriptRoot\automation_common.ps1"
$taskName = 'entry-alert-monitor'

function Send-TopPicksTelegramText([string]$Text) {
    $tokenPath = Join-Path $script:ProjectRoot 'key\telegram_bot_token.txt'
    $chatIdPath = Join-Path $script:ProjectRoot 'key\telegram_chat_id.txt'
    if (-not (Test-Path -LiteralPath $tokenPath) -or -not (Test-Path -LiteralPath $chatIdPath)) {
        throw 'Telegram token or chat ID file was not found.'
    }
    $tokenText = (Get-Content -Raw -LiteralPath $tokenPath).Trim()
    $chatIdText = (Get-Content -Raw -LiteralPath $chatIdPath).Trim()
    $tokenMatch = [regex]::Match($tokenText, '\d{6,}:[A-Za-z0-9_-]{20,}')
    $chatIdMatch = [regex]::Match($chatIdText, '-?\d{5,}')
    if (-not $tokenMatch.Success -or -not $chatIdMatch.Success) {
        throw 'Telegram token or chat ID format is invalid.'
    }
    $bodyJson = @{
        chat_id = $chatIdMatch.Value
        text = $Text
        disable_web_page_preview = $true
    } | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "https://api.telegram.org/bot$($tokenMatch.Value)/sendMessage" `
        -ContentType 'application/json; charset=utf-8' `
        -Body $bodyBytes
    if (-not $response.ok) { throw 'Telegram API returned an unsuccessful response.' }
    return $response.result.message_id
}

try {
    $now = Get-Date
    if ($now.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)) {
        Write-TopPicksLog $taskName 'success' 'Skipped outside weekday market session.' @{ now = $now.ToString('o') }
        exit 0
    }
    $sessionStart = $now.Date.AddHours(9)
    $sessionEnd = $now.Date.AddHours(15).AddMinutes(30)
    if ($now -lt $sessionStart -or $now -gt $sessionEnd) {
        Write-TopPicksLog $taskName 'success' 'Skipped outside intraday alert window.' @{ now = $now.ToString('o') }
        exit 0
    }

    Start-TopPicksProxy | Out-Null
    $progress = Invoke-RestMethod 'http://127.0.0.1:8787/api/progress' -TimeoutSec 10
    if ($progress.status -eq 'running') {
        Write-TopPicksLog $taskName 'success' 'Skipped because recommendation analysis is already running.' @{
            stage = $progress.stage
            percent = $progress.percent
            message = $progress.message
        }
        exit 0
    }

    $start = Invoke-RestMethod 'http://127.0.0.1:8787/api/recommendations?refresh=1' -TimeoutSec 30
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 3
        $progress = Invoke-RestMethod 'http://127.0.0.1:8787/api/progress' -TimeoutSec 15
        if ($progress.runId -eq $start.runId -and $progress.status -eq 'failed') {
            throw "Recommendation failed: $($progress.message)"
        }
        if ((Get-Date) -gt $deadline) {
            throw "Recommendation timed out after $TimeoutMinutes minutes."
        }
    } until ($progress.runId -eq $start.runId -and $progress.status -eq 'completed')

    $result = Invoke-RestMethod 'http://127.0.0.1:8787/api/recommendations' -TimeoutSec 30
    $statePath = Join-Path $script:ReportDir 'entry-alert-state.json'
    $state = if (Test-Path -LiteralPath $statePath) {
        Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
    } else {
        [pscustomobject]@{ sentKeys = @(); stopSentKeys = @(); openPositions = @() }
    }
    $sentKeys = @($state.sentKeys | Where-Object { $_ })
    $stopSentKeys = @($state.stopSentKeys | Where-Object { $_ })
    $openPositions = @($state.openPositions | Where-Object { $_ -and $_.code })
    $sent = [Collections.Generic.List[object]]::new()
    $stopSent = [Collections.Generic.List[object]]::new()
    $pendingBuyMessages = [Collections.Generic.List[string]]::new()
    $pendingBuyPicks = [Collections.Generic.List[object]]::new()

    foreach ($position in $openPositions) {
        $stopPrice = [double]$position.stopPrice
        if ($stopPrice -le 0) { continue }
        $horizon = if ($position.PSObject.Properties['horizon'] -and $position.horizon) { $position.horizon } else { 'short' }
        $current = @(@($result.top3) + @($result.items) | Where-Object { $_.code -eq $position.code } | Select-Object -First 1)
        if (-not $current.Count) { continue }
        $currentPrice = if ($current[0].PSObject.Properties['signals'] -and $current[0].signals -and $current[0].signals.PSObject.Properties['currentPrice']) {
            [double]$current[0].signals.currentPrice
        } elseif ($current[0].PSObject.Properties['entryPrice']) {
            [double]$current[0].entryPrice
        } else { 0.0 }
        if ($currentPrice -le 0 -or $currentPrice -gt $stopPrice) { continue }
        $stopKey = "$($position.recommendationDate)|$($position.code)|$horizon|stop"
        if ($stopSentKeys -contains $stopKey) { continue }
        $horizonLabel = if ($horizon -eq 'long') { '(장기)' } else { '(단기)' }
        $message = @(
            "손절 필요 $horizonLabel $($position.name) ($($position.code))",
            "현재가 $($currentPrice.ToString('N0')) / 손절가 $($stopPrice.ToString('N0'))",
            "진입가 $(([double]$position.entryPrice).ToString('N0'))",
            "$((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
        ) -join "`n"
        $messageId = Send-TopPicksTelegramText $message
        $stopSentKeys += $stopKey
        $stopSent.Add([pscustomobject]@{ code = $position.code; name = $position.name; messageId = $messageId; key = $stopKey; currentPrice = $currentPrice; stopPrice = $stopPrice; horizon = $horizon })
    }

    $active = @($result.top3 | Where-Object {
        $_.entryStatus -eq 'pending' -and
        $_.entryMethod -eq 'next-trading-day-open-if-within-entry-band' -and
        [double]$_.shortTermScore -ge 45 -and
        @($_.entryBlockers | Where-Object { $_ }).Count -eq 0 -and
        $_.strategyAction -eq 'long-candidate'
    })

    foreach ($pick in $active) {
        $key = "$($result.recommendationDate)|$($pick.code)"
        if ($sentKeys -contains $key) { continue }
        $entryPrice = ([double]$pick.plannedEntryPrice).ToString('N0')
        $maxEntryPrice = ([double]$pick.maxEntryPrice).ToString('N0')
        $targetPrice = ([double]$pick.targetPrice).ToString('N0')
        $stopPrice = ([double]$pick.stopPrice).ToString('N0')
        $tags = @($pick.strategyTags | Select-Object -First 2) -join ', '
        $warnings = @($pick.entryWarnings | Where-Object { $_ } | Select-Object -First 2) -join ' / '
        if ([string]::IsNullOrWhiteSpace($warnings)) { $warnings = '없음' }
        $message = @(
            "BUY $($pick.name) ($($pick.code))",
            "#$($pick.rank) score $($pick.shortTermScore) · $($pick.strategyEngine)",
            "Entry $entryPrice / max $maxEntryPrice",
            "Target $targetPrice / stop $stopPrice",
            "Warn: $warnings",
            "Tags: $tags",
            "$($result.recommendationDate) $((Get-Date).ToString('HH:mm'))"
        ) -join "`n"
        $message = @(
            "매수 후보 $($pick.name) ($($pick.code))",
            "순위 $($pick.rank) / 점수 $($pick.shortTermScore)",
            "진입가 $entryPrice / 상한가 $maxEntryPrice",
            "목표가 $targetPrice / 손절가 $stopPrice",
            "$($result.recommendationDate) $((Get-Date).ToString('HH:mm'))"
        ) -join "`n"
        $pendingBuyMessages.Add($message)
        $pendingBuyPicks.Add([pscustomobject]@{ pick = $pick; key = $key })
    }

    if ($pendingBuyMessages.Count -gt 0) {
        $message = @(
            "매수 진입 후보 $($result.recommendationDate) $((Get-Date).ToString('HH:mm'))",
            "",
            ($pendingBuyMessages -join "`n`n")
        ) -join "`n"
        $messageId = Send-TopPicksTelegramText $message
        foreach ($pending in $pendingBuyPicks) {
            $pick = $pending.pick
            $key = $pending.key
            $sentKeys += $key
            $sent.Add([pscustomobject]@{ code = $pick.code; name = $pick.name; messageId = $messageId; key = $key })
            $openPositions = @($openPositions | Where-Object {
                -not (
                    "$($_.recommendationDate)|$($_.code)" -eq $key -and
                    (-not $_.PSObject.Properties['horizon'] -or $_.horizon -ne 'long')
                )
            })
            $openPositions += [pscustomobject]@{
                recommendationDate = $result.recommendationDate
                code = $pick.code
                name = $pick.name
                entryPrice = [double]$pick.plannedEntryPrice
                maxEntryPrice = [double]$pick.maxEntryPrice
                targetPrice = [double]$pick.targetPrice
                stopPrice = [double]$pick.stopPrice
                horizon = 'short'
                sentAt = (Get-Date).ToString('o')
            }
        }
    }

    # 장기(펀더멘털 기반) 진입 후보: 대시보드의 longEntryState 로직과 동일한 조건으로 판단
    $pendingLongMessages = [Collections.Generic.List[string]]::new()
    $pendingLongPicks = [Collections.Generic.List[object]]::new()
    $longActive = @($result.items | Where-Object {
        [double]$_.longTermScore -ge 45 -and
            ($null -eq $_.debtRatio -or [double]$_.debtRatio -lt 250) -and
            ($null -eq $_.targetUpside -or [double]$_.targetUpside -ge 0)
    })
    foreach ($pick in $longActive) {
        $key = "$($result.recommendationDate)|$($pick.code)|long"
        if ($sentKeys -contains $key) { continue }
        $entryPrice = [double]$pick.entryPrice
        if ($entryPrice -le 0) { continue }
        $targetRate = if ($null -ne $pick.targetUpside) { [math]::Max(5, [math]::Min(60, [double]$pick.targetUpside)) } else { 15 }
        $targetPrice = [math]::Round($entryPrice * (1 + $targetRate / 100), 0)
        $stopPrice = [math]::Round($entryPrice * 0.88, 0)
        $reason = [string](@($pick.reasons | Select-Object -First 2) -join ', ')
        $perPbr = "$(if ($pick.per -gt 0) { "$([math]::Round([double]$pick.per,1))배" } else { '-' }) / $(if ($pick.pbr -gt 0) { "$([math]::Round([double]$pick.pbr,1))배" } else { '-' })"
        $message = @(
            "장기 후보 $($pick.name) ($($pick.code))",
            "장기점수 $([math]::Round([double]$pick.longTermScore, 1)) / PER·PBR $perPbr",
            "현재가 $($entryPrice.ToString('N0'))",
            "참고 목표가 $($targetPrice.ToString('N0')) / 참고 손절가 $($stopPrice.ToString('N0'))",
            "근거: $reason",
            "$($result.recommendationDate) $((Get-Date).ToString('HH:mm'))"
        ) -join "`n"
        $pendingLongMessages.Add($message)
        $pendingLongPicks.Add([pscustomobject]@{ pick = $pick; key = $key; targetPrice = $targetPrice; stopPrice = $stopPrice; entryPrice = $entryPrice })
    }
    if ($pendingLongMessages.Count -gt 0) {
        $message = @(
            "장기 진입 후보 $($result.recommendationDate) $((Get-Date).ToString('HH:mm'))",
            "",
            ($pendingLongMessages -join "`n`n")
        ) -join "`n"
        $messageId = Send-TopPicksTelegramText $message
        foreach ($pending in $pendingLongPicks) {
            $pick = $pending.pick
            $key = $pending.key
            $sentKeys += $key
            $sent.Add([pscustomobject]@{ code = $pick.code; name = $pick.name; messageId = $messageId; key = $key; horizon = 'long' })
            $openPositions = @($openPositions | Where-Object {
                -not (
                    $_.recommendationDate -eq $result.recommendationDate -and
                    $_.code -eq $pick.code -and
                    $_.PSObject.Properties['horizon'] -and $_.horizon -eq 'long'
                )
            })
            $openPositions += [pscustomobject]@{
                recommendationDate = $result.recommendationDate
                code = $pick.code
                name = $pick.name
                entryPrice = $pending.entryPrice
                targetPrice = $pending.targetPrice
                stopPrice = $pending.stopPrice
                horizon = 'long'
                sentAt = (Get-Date).ToString('o')
            }
        }
    }

    [pscustomobject]@{
        updatedAt = (Get-Date).ToString('o')
        sentKeys = @($sentKeys | Select-Object -Last 500)
        stopSentKeys = @($stopSentKeys | Select-Object -Last 500)
        openPositions = @($openPositions | Select-Object -Last 200)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8

    Write-TopPicksLog $taskName 'success' 'Entry alert monitor completed.' @{
        recommendationDate = $result.recommendationDate
        activeCount = $active.Count
        longActiveCount = $longActive.Count
        sentCount = $sent.Count
        stopSentCount = $stopSent.Count
        sent = @($sent)
        stopSent = @($stopSent)
    }
    exit 0
} catch {
    Write-TopPicksLog $taskName 'failure' $_.Exception.Message
    exit 1
}
