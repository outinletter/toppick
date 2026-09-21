param(
    [int]$MinimumMaturedRecommendations = 30
)

. "$PSScriptRoot\automation_common.ps1"
$taskName = 'auto-tuning'

function Get-Rate([int]$Count, [int]$Total) {
    if ($Total -le 0) { return 0.0 }
    return [math]::Round($Count * 100.0 / $Total, 2)
}

function Get-Average([object[]]$Values) {
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if (-not $numbers.Count) { return 0.0 }
    return [math]::Round(($numbers | Measure-Object -Average).Average, 4)
}

try {
    $validationPath = Join-Path $script:ReportDir 'ai-top3-validation.json'
    if (-not (Test-Path -LiteralPath $validationPath)) {
        throw 'AI TOP3 validation report was not found.'
    }

    $validation = Get-Content -Raw -LiteralPath $validationPath -Encoding UTF8 | ConvertFrom-Json
    $current = $validation.currentFormulaStatistics
    $formulaVersion = if ($current -and $current.formulaVersion) { [string]$current.formulaVersion } else { 'short-term-v3-gapguard-1to3d' }
    $items = @($validation.items | Where-Object {
        $_.scoringFormulaVersion -eq $formulaVersion
    })
    $activeRows = @($items | Where-Object { -not $_.entrySkipped })
    $watchRows = @($items | Where-Object { $_.entryStatus -eq 'watchlist' })
    $activeD3Returns = @($activeRows | Where-Object { $null -ne $_.d3Return } | ForEach-Object { $_.d3Return })
    $watchD3Returns = @($watchRows | Where-Object { $null -ne $_.hypotheticalD3Return } | ForEach-Object { $_.hypotheticalD3Return })
    $allD3Returns = $activeD3Returns

    $maturedCount = $activeD3Returns.Count
    $savedCount = if ($current -and $null -ne $current.savedRecommendationCount) { [int]$current.savedRecommendationCount } else { 0 }
    $pendingCount = if ($current -and $null -ne $current.pendingRecommendationCount) { [int]$current.pendingRecommendationCount } else { 0 }
    $avgActiveD3 = Get-Average $activeD3Returns
    $avgWatchD3 = Get-Average $watchD3Returns
    $hitRateD3 = if ($allD3Returns.Count) { Get-Rate @($allD3Returns | Where-Object { [double]$_ -gt 0 }).Count $allD3Returns.Count } else { 0.0 }

    $suggestions = [Collections.Generic.List[object]]::new()
    $observations = [Collections.Generic.List[string]]::new()
    if ($savedCount -gt 0) { $observations.Add("Current formula saved $savedCount, pending $pendingCount, matured $maturedCount") }
    if ($activeD3Returns.Count -gt 0) { $observations.Add("Active D+3 average $avgActiveD3%") }
    if ($watchD3Returns.Count -gt 0) { $observations.Add("Watchlist hypothetical D+3 average $avgWatchD3%") }
    $strategyStats = @($current.strategyStatistics)
    foreach ($strategy in @($strategyStats | Where-Object { $_.matured3DayCount -gt 0 } | Sort-Object averageD3Return -Descending)) {
        $observations.Add("Strategy $($strategy.strategyEngine): D+3 avg $($strategy.averageD3Return)%, hit $($strategy.hitRate3Day)%, n=$($strategy.matured3DayCount)")
    }

    if ($maturedCount -lt $MinimumMaturedRecommendations) {
        $suggestions.Add([pscustomobject]@{
            area = 'sample-size'
            action = 'wait'
            priority = 'high'
            reason = "Matured sample $maturedCount is below minimum $MinimumMaturedRecommendations"
            proposedChange = 'No automatic setting change'
        })
    } else {
        if ($avgActiveD3 -lt 0 -and $hitRateD3 -lt 45) {
            $suggestions.Add([pscustomobject]@{
                area = 'entry-threshold'
                action = 'review-tightening'
                priority = 'high'
                reason = "D+3 average $avgActiveD3%, hit rate $hitRateD3%"
                proposedChange = 'Review keeping shortTermScore threshold at 45 or raising it to 47'
            })
        }
        if ($watchD3Returns.Count -ge 10 -and $avgWatchD3 -gt ($avgActiveD3 + 1.0)) {
            $suggestions.Add([pscustomobject]@{
                area = 'watchlist-threshold'
                action = 'review-lowering'
                priority = 'medium'
                reason = "Watchlist hypothetical D+3 average $avgWatchD3% is above active average $avgActiveD3%"
                proposedChange = 'Review entry activation rules for shortTermScore 43 to 44'
            })
        }
        foreach ($strategy in @($strategyStats | Where-Object { $_.matured3DayCount -ge 10 })) {
            if ([double]$strategy.averageD3Return -lt 0 -and [double]$strategy.hitRate3Day -lt 45) {
                $suggestions.Add([pscustomobject]@{
                    area = "strategy-$($strategy.strategyEngine)"
                    action = 'review-downweight'
                    priority = 'medium'
                    reason = "$($strategy.strategyEngine) D+3 average $($strategy.averageD3Return)%, hit rate $($strategy.hitRate3Day)%"
                    proposedChange = "Review downweighting or stricter entry rules for $($strategy.strategyEngine)"
                })
            }
            if ([double]$strategy.averageD3Return -gt 1.0 -and [double]$strategy.hitRate3Day -ge 55) {
                $suggestions.Add([pscustomobject]@{
                    area = "strategy-$($strategy.strategyEngine)"
                    action = 'review-upweight'
                    priority = 'low'
                    reason = "$($strategy.strategyEngine) D+3 average $($strategy.averageD3Return)%, hit rate $($strategy.hitRate3Day)%"
                    proposedChange = "Review preserving or modestly upweighting $($strategy.strategyEngine)"
                })
            }
        }
    }

    foreach ($failure in @($current.failureSummary)) {
        $rate = Get-Rate ([int]$failure.count) ([math]::Max(1, $maturedCount))
        if ($failure.reason -eq 'gap-up-entry-risk' -and $rate -ge 20) {
            $suggestions.Add([pscustomobject]@{
                area = 'entry-band'
                action = 'review-tightening'
                priority = 'medium'
                reason = "Gap-up entry failure rate $rate%"
                proposedChange = 'Review reducing maxEntryGapRate from 2.5% to 2.0%'
            })
        }
        if ($failure.reason -eq 'weak-sector-rotation' -and $rate -ge 20) {
            $suggestions.Add([pscustomobject]@{
                area = 'sector-filter'
                action = 'review-tightening'
                priority = 'medium'
                reason = "Weak sector failure rate $rate%"
                proposedChange = 'Review requiring sectorRotationStatus strong for active entry candidates'
            })
        }
        if ($failure.reason -in @('large-drawdown', 'stop-loss-hit') -and $rate -ge 25) {
            $suggestions.Add([pscustomobject]@{
                area = 'risk-filter'
                action = 'review-overheat-filter'
                priority = 'medium'
                reason = "$($failure.reason) rate $rate%"
                proposedChange = 'Review tightening RSI, MA20 deviation, and 20-day rise overheating filters'
            })
        }
    }

    if (-not $suggestions.Count) {
        $suggestions.Add([pscustomobject]@{
            area = 'no-change'
            action = 'keep-current-settings'
            priority = 'low'
            reason = 'There is not enough evidence to change current settings automatically'
            proposedChange = 'No automatic setting change'
        })
    }

    $result = [pscustomobject]@{
        generatedAt = (Get-Date).ToString('o')
        mode = 'suggestion-only'
        autoApply = $false
        formulaVersion = $formulaVersion
        minimumMaturedRecommendations = $MinimumMaturedRecommendations
        savedRecommendationCount = $savedCount
        pendingRecommendationCount = $pendingCount
        maturedRecommendationCount = $maturedCount
        activeEntryMaturedCount = $activeD3Returns.Count
        watchlistMaturedCount = $watchD3Returns.Count
        averageActiveD3Return = $avgActiveD3
        averageWatchlistHypotheticalD3Return = $avgWatchD3
        hitRateD3 = $hitRateD3
        strategyStatistics = @($strategyStats)
        observations = @($observations)
        suggestions = @($suggestions)
    }

    $jsonPath = Join-Path $script:ReportDir 'tuning-suggestions.json'
    $mdPath = Join-Path $script:ReportDir 'tuning-suggestions.md'
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = @(
        '# TopPicks Tuning Suggestions',
        '',
        "- Generated: $($result.generatedAt)",
        "- Mode: suggestion-only",
        "- Formula: $formulaVersion",
        "- Saved/Pending/Matured: $savedCount / $pendingCount / $maturedCount",
        "- Minimum matured recommendations: $MinimumMaturedRecommendations",
        '',
        '## Observations',
        ''
    )
    if ($observations.Count) {
        foreach ($item in $observations) { $lines += "- $item" }
    } else {
        $lines += '- No matured current-formula observations yet.'
    }
    $lines += @('', '## Suggestions', '')
    foreach ($item in $suggestions) {
        $lines += "- [$($item.priority)] $($item.area): $($item.proposedChange) ($($item.reason))"
    }
    $lines += @('', '## Safety', '', '- This report does not change scoring settings automatically.', '- Review suggestions before editing live recommendation logic.')
    $lines | Set-Content -LiteralPath $mdPath -Encoding UTF8

    Write-TopPicksLog $taskName 'success' 'Tuning suggestion report was generated.' @{
        json = $jsonPath
        markdown = $mdPath
        formulaVersion = $formulaVersion
        maturedRecommendationCount = $maturedCount
        pendingRecommendationCount = $pendingCount
        suggestionCount = $suggestions.Count
    }
    exit 0
} catch {
    Write-TopPicksLog $taskName 'failure' $_.Exception.Message
    exit 1
}
