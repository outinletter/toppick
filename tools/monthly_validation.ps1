. "$PSScriptRoot\automation_common.ps1"
. "$PSScriptRoot\validation_core.ps1"
$taskName = 'monthly-validation'
$roundTripCostRate = 0.35
$slippageRates = @{ KOSPI = 0.10; KOSDAQ = 0.20 }

function Get-ReturnRate([double]$Entry, [double]$Exit) {
    if ($Entry -le 0) { return 0.0 }
    return ($Exit - $Entry) / $Entry * 100.0
}

function Get-MaxDrawdown([double]$Entry, [object[]]$Rows) {
    if ($Entry -le 0) { return 0.0 }
    $peak = $Entry
    $maxDrawdown = 0.0
    foreach ($row in $Rows) {
        $high = if ($null -ne $row.high -and [double]$row.high -gt 0) { [double]$row.high } else { [double]$row.price }
        $low = if ($null -ne $row.low -and [double]$row.low -gt 0) { [double]$row.low } else { [double]$row.price }
        if ($high -gt $peak) { $peak = $high }
        if ($peak -gt 0) {
            $drawdown = ($low - $peak) / $peak * 100.0
            if ($drawdown -lt $maxDrawdown) { $maxDrawdown = $drawdown }
        }
    }
    return $maxDrawdown
}

function Get-AverageField([object[]]$Items, [string]$Field) {
    $values = @($Items | Where-Object { $null -ne $_.$Field } | ForEach-Object { [double]$_.$Field })
    if (-not $values.Count) { return 0 }
    return [math]::Round(($values | Measure-Object -Average).Average, 4)
}

try {
    Start-TopPicksProxy | Out-Null
    $historyPath = Join-Path $script:ReportDir 'web-recommendation-history.json'
    if (-not (Test-Path -LiteralPath $historyPath)) { throw 'Web recommendation history was not found.' }
    $saved = [object[]](Get-Content -Raw -LiteralPath $historyPath -Encoding UTF8 | ConvertFrom-Json)
    $top3HistoryPath = Join-Path $script:ReportDir 'ai-top3-history.json'
    $top3ValidationPath = Join-Path $script:ReportDir 'ai-top3-validation.json'
    $rows = [Collections.Generic.List[object]]::new()
    $failed = 0
    $failures = [Collections.Generic.List[object]]::new()

    foreach ($pick in $saved) {
        try {
            $history = Invoke-RestMethod "http://127.0.0.1:8787/history/$($pick.code)/$($pick.market)" -TimeoutSec 60
            $stock = @(Get-ValidationBars $history.stockHistory $pick.date $pick.recordedAt)
            if (((Get-Date).Date - [datetime]$pick.date).Days -ge 5 -and $stock.Count -eq 0) { throw 'No post-recommendation price history was returned.' }
            $indexByDate = @{}
            foreach ($item in @($history.indexHistory)) { $indexByDate[$item.date] = [double]$item.price }
            foreach ($horizon in @(1, 2, 3)) {
                if ($stock.Count -lt $horizon) { continue }
                $entryDay = $stock[0]
                $evaluation = $stock[$horizon - 1]
                if (-not $indexByDate.ContainsKey($entryDay.date) -or -not $indexByDate.ContainsKey($evaluation.date)) { continue }
                $slippageRate = [double]$slippageRates[$pick.market]
                $executionEntry = [double]$entryDay.open * (1 + $slippageRate / 100)
                if ($executionEntry -le 0) { continue }
                $targetUpsideRate = if ($pick.PSObject.Properties['targetUpside'] -and $null -ne $pick.targetUpside) { [math]::Max(2.5, [math]::Min(8, [double]$pick.targetUpside / 3)) } else { 4.0 }
                $targetPrice = [math]::Round($executionEntry * (1 + $targetUpsideRate / 100), 0)
                $executionExit = [double]$evaluation.price * (1 - $slippageRate / 100)
                $returnRate = Get-ReturnRate $executionEntry $executionExit
                $indexReturn = Get-BenchmarkReturn $history.indexHistory $entryDay.date $evaluation.date
                $netReturn = $returnRate - $roundTripCostRate
                $maxDrawdown = Get-MaxDrawdown $executionEntry @($stock | Select-Object -First $horizon)
                $rows.Add([pscustomobject]@{
                    recommendationDate = $pick.date
                    evaluationDate = $evaluation.date
                    horizon = $horizon
                    market = $pick.market
                    industryCode = $pick.industryCode
                    code = $pick.code
                    name = $pick.name
                    score = [math]::Round([double]$pick.score, 2)
                    fixedScore = if ($pick.PSObject.Properties['fixedScore']) { [math]::Round([double]$pick.fixedScore, 2) } else { $null }
                    shortTermScore = if ($pick.PSObject.Properties['shortTermScore']) { $pick.shortTermScore } else { $pick.oneMonthScore }
                    oneMonthScore = if ($pick.PSObject.Properties['oneMonthScore']) { $pick.oneMonthScore } else { $null }
                    sectorRotationScore = if ($pick.PSObject.Properties['sectorRotationScore']) { $pick.sectorRotationScore } else { $null }
                    sectorRotationStatus = if ($pick.PSObject.Properties['sectorRotationStatus']) { $pick.sectorRotationStatus } else { $null }
                    sectorPersistenceScore = if ($pick.PSObject.Properties['sectorPersistenceScore']) { $pick.sectorPersistenceScore } else { $null }
                    institutionQualityScore = if ($pick.PSObject.Properties['institutionQualityScore']) { $pick.institutionQualityScore } else { $null }
                    themeScore = if ($pick.PSObject.Properties['themeScore']) { $pick.themeScore } else { $null }
                    themeTags = if ($pick.PSObject.Properties['themeTags']) { $pick.themeTags -join ',' } else { $null }
                    qualityScore = if ($pick.PSObject.Properties['qualityScore']) { $pick.qualityScore } else { $null }
                    macdSignalScore = if ($pick.PSObject.Properties['macdSignalScore']) { $pick.macdSignalScore } else { $null }
                    disclosureCatalystScore = if ($pick.PSObject.Properties['disclosureCatalystScore']) { $pick.disclosureCatalystScore } else { $null }
                    marketRegime = $pick.marketRegime
                    model = if ($pick.model) { $pick.model } else { 'dynamic' }
                    entryDate = $entryDay.date
                    quotedOpen = [double]$entryDay.open
                    slippageRate = $slippageRate
                    entryPrice = [math]::Round($executionEntry, 4)
                    targetPrice = $targetPrice
                    targetReached = if ($null -ne $targetPrice) { @($stock | Select-Object -First $horizon | Where-Object { [double]$_.high -ge [double]$targetPrice }).Count -gt 0 } else { $null }
                    evaluationPrice = [double]$evaluation.price
                    executionExitPrice = [math]::Round($executionExit, 4)
                    returnRate = [math]::Round($returnRate, 4)
                    transactionCost = $roundTripCostRate
                    netReturn = [math]::Round($netReturn, 4)
                    excessReturn = if ($null -ne $indexReturn) { [math]::Round($netReturn - $indexReturn, 4) } else { $null }
                    maxDrawdown = [math]::Round($maxDrawdown, 4)
                    hit = $netReturn -gt 0
                    excessHit = if ($null -ne $indexReturn) { ($netReturn - $indexReturn) -gt 0 } else { $null }
                })
            }
        } catch {
            $failed++
            $failures.Add([pscustomobject]@{ date = $pick.date; market = $pick.market; code = $pick.code; message = $_.Exception.Message })
        }
    }

    $rows = @($rows | Sort-Object recommendationDate, code, horizon, marketRegime, model -Unique)
    foreach ($row in $rows) {
        $peers = @($rows | Where-Object { $_.recommendationDate -eq $row.recommendationDate -and $_.horizon -eq $row.horizon -and $_.model -eq $row.model -and $_.industryCode -eq $row.industryCode -and $_.code -ne $row.code })
        $peerReturn = if ($peers.Count) { ($peers.netReturn | Measure-Object -Average).Average } else { $null }
        $row | Add-Member -NotePropertyName industryPeerReturn -NotePropertyValue $peerReturn
        $row | Add-Member -NotePropertyName industryExcessReturn -NotePropertyValue $(if ($null -ne $peerReturn) { [math]::Round([double]$row.netReturn - [double]$peerReturn, 4) } else { $null })
    }

    $stamp = (Get-Date).ToString('yyyy-MM')
    $csvPath = Join-Path $script:ReportDir "validation-$stamp.csv"
    $jsonPath = Join-Path $script:ReportDir "validation-$stamp-summary.json"
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    $masterPath = Join-Path $script:ReportDir 'validation-master.csv'
    $masterRows = foreach ($file in Get-ChildItem $script:ReportDir -Filter 'validation-????-??.csv') { Import-Csv -LiteralPath $file.FullName }
    @($masterRows | Sort-Object recommendationDate, code, horizon, marketRegime, model -Unique) | Export-Csv -LiteralPath $masterPath -NoTypeInformation -Encoding UTF8

    $summary = foreach ($horizon in @(1, 2, 3)) {
        $group = @($rows | Where-Object { $_.horizon -eq $horizon -and $_.model -eq 'dynamic' })
        [pscustomobject]@{
            horizon = $horizon
            count = $group.Count
            averageReturn = if ($group.Count) { [math]::Round(($group.netReturn | Measure-Object -Average).Average, 4) } else { 0 }
            averageExcessReturn = if ($group.Count) { [math]::Round(($group.excessReturn | Measure-Object -Average).Average, 4) } else { 0 }
            averageIndustryExcessReturn = Get-AverageField @($group | Where-Object { $null -ne $_.industryExcessReturn }) 'industryExcessReturn'
            averageMaxDrawdown = if ($group.Count) { [math]::Round(($group.maxDrawdown | Measure-Object -Average).Average, 4) } else { 0 }
            hitRate = if ($group.Count) { [math]::Round(@($group | Where-Object hit).Count * 100.0 / $group.Count, 2) } else { 0 }
            excessHitRate = if ($group.Count) { [math]::Round(@($group | Where-Object excessHit).Count * 100.0 / $group.Count, 2) } else { 0 }
        }
    }
    $modelSummary = foreach ($model in @('dynamic', 'fixed')) {
        foreach ($horizon in @(1, 2, 3)) {
            $group = @($rows | Where-Object { $_.model -eq $model -and $_.horizon -eq $horizon })
            [pscustomobject]@{
                model = $model
                horizon = $horizon
                count = $group.Count
                averageReturn = if ($group.Count) { [math]::Round(($group.netReturn | Measure-Object -Average).Average, 4) } else { 0 }
                averageExcessReturn = if ($group.Count) { [math]::Round(($group.excessReturn | Measure-Object -Average).Average, 4) } else { 0 }
                averageMaxDrawdown = if ($group.Count) { [math]::Round(($group.maxDrawdown | Measure-Object -Average).Average, 4) } else { 0 }
                hitRate = if ($group.Count) { [math]::Round(@($group | Where-Object hit).Count * 100.0 / $group.Count, 2) } else { 0 }
            }
        }
    }
    $alerts = @()
    foreach ($period in @($summary | Where-Object { $_.horizon -in @(1, 3) -and $_.count -ge 30 })) {
        if ($period.hitRate -lt 50) { $alerts += "$($period.horizon)-day hit rate below 50%" }
        if ($period.averageExcessReturn -lt 0) { $alerts += "$($period.horizon)-day average excess return below 0%" }
    }
    if ($failed -gt 0) { $alerts += "$failed recommendation history queries failed" }

    $top3Rows = [Collections.Generic.List[object]]::new()
    $top3Saved = @()
    if (Test-Path -LiteralPath $top3HistoryPath) {
        $top3Saved = [object[]](Get-Content -Raw -LiteralPath $top3HistoryPath -Encoding UTF8 | ConvertFrom-Json)
        foreach ($pick in $top3Saved) {
            try {
                $history = Invoke-RestMethod "http://127.0.0.1:8787/history/$($pick.code)/$($pick.market)" -TimeoutSec 60
                $stock = @(Get-ValidationBars $history.stockHistory $pick.recommendationDate $pick.recordedAt)
                if (-not $stock.Count -or [double]$stock[0].open -le 0) { continue }
                $quotedOpen = [double]$stock[0].open
                $slippageRate = [double]$slippageRates[$pick.market]
                $entryMethod = if ($pick.PSObject.Properties['entryMethod']) { [string]$pick.entryMethod } else { 'next-trading-day-open' }
                $entryStatus = if ($pick.PSObject.Properties['entryStatus']) { [string]$pick.entryStatus } else { 'pending' }
                $maxEntryPrice = if ($pick.PSObject.Properties['maxEntryPrice'] -and $null -ne $pick.maxEntryPrice) { [double]$pick.maxEntryPrice } else { 0.0 }
                $entrySkipped = $false
                $skipReason = $null
                if ($entryStatus -eq 'watchlist' -or $entryMethod -eq 'watchlist-low-confidence') {
                    $entrySkipped = $true
                    $skipReason = if ($entryMethod -eq 'watchlist-blocked-entry') { 'blocked-entry-watchlist' } else { 'low-confidence-watchlist' }
                } elseif ($maxEntryPrice -gt 0 -and $quotedOpen -gt $maxEntryPrice) {
                    $entrySkipped = $true
                    $skipReason = 'gap-up-above-entry-band'
                }
                $hypotheticalEntry = $quotedOpen * (1 + $slippageRate / 100)
                $entry = if ($entrySkipped) { $null } else { $hypotheticalEntry }
                $targetPrice = if ($entrySkipped) { [double]$pick.targetPrice } elseif ($null -ne $pick.targetUpsideRate) { [math]::Round($entry * (1 + [double]$pick.targetUpsideRate / 100), 0) } else { [double]$pick.targetPrice }
                $stopPrice = if ($entrySkipped) { [double]$pick.stopPrice } elseif ($null -ne $pick.stopRate) { [math]::Round($entry * (1 - [double]$pick.stopRate / 100), 0) } else { [double]$pick.stopPrice }
                $indexByDate = @{}
                foreach ($item in @($history.indexHistory)) { $indexByDate[$item.date] = [double]$item.price }
                $horizonValues = @{}
                foreach ($horizon in @(1, 2, 3)) {
                    if ($stock.Count -ge $horizon) { $horizonValues["d$horizon"] = [double]$stock[$horizon - 1].price }
                }
                $observed = @($stock | Select-Object -First 3)
                $high = if ($observed.Count) { ($observed | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum } else { $null }
                $low = if ($observed.Count) { ($observed | ForEach-Object { [double]$_.low } | Measure-Object -Minimum).Minimum } else { $null }
                $current = if ($observed.Count) { [double]$observed[-1].price } else { $null }
                $entryIndex = if ($indexByDate.ContainsKey($stock[0].date)) { $indexByDate[$stock[0].date] } else { $null }
                $latestIndex = if ($observed.Count -and $indexByDate.ContainsKey($observed[-1].date)) { $indexByDate[$observed[-1].date] } else { $null }
                $outcomes = @{}
                $excess = @{}
                foreach ($horizon in @(1, 2, 3)) {
                    if (-not $entrySkipped -and $stock.Count -ge $horizon) {
                        $outcomes["d$horizon"] = Get-TradeOutcome $entry $targetPrice $stopPrice $stock $horizon $slippageRate $roundTripCostRate
                        $benchmark = Get-BenchmarkReturn $history.indexHistory $stock[0].date $stock[$horizon - 1].date
                        $excess["d$horizon"] = if ($null -ne $benchmark) { [math]::Round($outcomes["d$horizon"].netReturn - $benchmark, 4) } else { $null }
                    }
                }
                $lastOutcome = $outcomes["d$($observed.Count)"]
                $currentReturn = if ($lastOutcome) { $lastOutcome.netReturn } else { $null }
                $indexReturn = Get-BenchmarkReturn $history.indexHistory $stock[0].date $observed[-1].date
                $stopReached = [bool]$lastOutcome.stopReached
                $targetReached = [bool]$lastOutcome.targetReached
                $exitEvent = $lastOutcome.exitEvent
                $d1Return = $outcomes.d1.netReturn
                $d2Return = $outcomes.d2.netReturn
                $d3Return = $outcomes.d3.netReturn
                $hypotheticalD1Return = if ($entrySkipped -and $horizonValues.d1) { [math]::Round((Get-ReturnRate $hypotheticalEntry ($horizonValues.d1 * (1 - $slippageRate / 100))) - $roundTripCostRate, 4) } else { $null }
                $hypotheticalD2Return = if ($entrySkipped -and $horizonValues.d2) { [math]::Round((Get-ReturnRate $hypotheticalEntry ($horizonValues.d2 * (1 - $slippageRate / 100))) - $roundTripCostRate, 4) } else { $null }
                $hypotheticalD3Return = if ($entrySkipped -and $horizonValues.d3) { [math]::Round((Get-ReturnRate $hypotheticalEntry ($horizonValues.d3 * (1 - $slippageRate / 100))) - $roundTripCostRate, 4) } else { $null }
                $plannedEntry = if ($pick.PSObject.Properties['plannedEntryPrice'] -and $null -ne $pick.plannedEntryPrice) { [double]$pick.plannedEntryPrice } else { 0.0 }
                $entryGapRate = if ($plannedEntry -gt 0) { [math]::Round(($quotedOpen - $plannedEntry) / $plannedEntry * 100, 4) } else { $null }
                $maxDecline = if (-not $entrySkipped -and $null -ne $low) { [math]::Round((Get-ReturnRate $entry $low), 4) } else { $null }
                $maxRise = if (-not $entrySkipped -and $null -ne $high) { [math]::Round((Get-ReturnRate $entry $high), 4) } else { $null }
                $failureReasons = @()
                if ($entrySkipped) { $failureReasons += $skipReason }
                elseif ($null -ne $d3Return -and $d3Return -lt 0) {
                    if ($null -ne $entryGapRate -and $entryGapRate -gt 2.5) { $failureReasons += 'gap-up-entry-risk' }
                    if ($stopReached) { $failureReasons += 'stop-loss-hit' }
                    if ($null -ne $indexReturn -and $indexReturn -lt 0) { $failureReasons += 'weak-market' }
                    if ($null -ne $pick.sectorRotationStatus -and $pick.sectorRotationStatus -notin @('strong', 'neutral')) { $failureReasons += 'weak-sector-rotation' }
                    if ($null -ne $pick.rsi -and [double]$pick.rsi -ge 75) { $failureReasons += 'overheated-rsi' }
                    if ($null -ne $pick.ma20Deviation -and [double]$pick.ma20Deviation -ge 12) { $failureReasons += 'overextended-ma20' }
                    if ($null -ne $maxDecline -and $maxDecline -le -5) { $failureReasons += 'large-drawdown' }
                    if ($failureReasons.Count -eq 0) { $failureReasons += 'unclassified-loss' }
                }
                $top3Rows.Add([pscustomobject]@{
                    recommendationDate = $pick.recommendationDate
                    recommendationTime = $pick.recommendationTime
                    rank = $pick.rank
                    market = $pick.market
                    code = $pick.code
                    name = $pick.name
                    quotedOpen = $quotedOpen
                    slippageRate = $slippageRate
                    entryPrice = $entry
                    hypotheticalEntryPrice = if ($entrySkipped) { [math]::Round($hypotheticalEntry, 4) } else { $null }
                    entryDate = $stock[0].date
                    entryMethod = $entryMethod
                    entryStatus = $entryStatus
                    maxEntryPrice = if ($maxEntryPrice -gt 0) { $maxEntryPrice } else { $null }
                    entryGapRate = $entryGapRate
                    entrySkipped = $entrySkipped
                    skipReason = $skipReason
                    targetPrice = $targetPrice
                    stopPrice = $stopPrice
                    riseProbability = [double]$pick.riseProbability
                    probabilityType = if ($pick.PSObject.Properties['probabilityType']) { $pick.probabilityType } else { $null }
                    scoringFormulaVersion = if ($pick.PSObject.Properties['scoringFormulaVersion']) { $pick.scoringFormulaVersion } else { $null }
                    strategyEngine = if ($pick.PSObject.Properties['strategyEngine']) { $pick.strategyEngine } else { $null }
                    strategyAction = if ($pick.PSObject.Properties['strategyAction']) { $pick.strategyAction } else { $null }
                    strategyTags = if ($pick.PSObject.Properties['strategyTags']) { $pick.strategyTags -join ',' } else { $null }
                    shortTermScore = if ($pick.PSObject.Properties['shortTermScore']) { $pick.shortTermScore } else { $pick.oneMonthScore }
                    targetUpsideRate = if ($pick.PSObject.Properties['targetUpsideRate']) { $pick.targetUpsideRate } else { $null }
                    selectionTier = if ($pick.PSObject.Properties['selectionTier']) { $pick.selectionTier } else { $null }
                    averageTradingValue = if ($pick.PSObject.Properties['averageTradingValue']) { $pick.averageTradingValue } else { $null }
                    ma20Deviation = if ($pick.PSObject.Properties['ma20Deviation']) { $pick.ma20Deviation } else { $null }
                    rsi = if ($pick.PSObject.Properties['rsi']) { $pick.rsi } else { $null }
                    twentyDayRise = if ($pick.PSObject.Properties['twentyDayRise']) { $pick.twentyDayRise } else { $null }
                    sectorRotationScore = if ($pick.PSObject.Properties['sectorRotationScore']) { $pick.sectorRotationScore } else { $null }
                    sectorRotationStatus = if ($pick.PSObject.Properties['sectorRotationStatus']) { $pick.sectorRotationStatus } else { $null }
                    themeScore = if ($pick.PSObject.Properties['themeScore']) { $pick.themeScore } else { $null }
                    macdSignalScore = if ($pick.PSObject.Properties['macdSignalScore']) { $pick.macdSignalScore } else { $null }
                    d1Close = $horizonValues.d1
                    d2Close = $horizonValues.d2
                    d3Close = $horizonValues.d3
                    highestPrice = $high
                    lowestPrice = $low
                    stopReached = $stopReached
                    targetReached = $targetReached
                    exitEvent = $exitEvent
                    exitDate = $lastOutcome.exitDate
                    executionExitPrice = $lastOutcome.executionExitPrice
                    validationVersion = 'ohlc-exit-v2'
                    d1ExcessReturn = $excess.d1
                    d2ExcessReturn = $excess.d2
                    d3ExcessReturn = $excess.d3
                    failureReasons = $failureReasons
                    primaryFailureReason = if ($failureReasons.Count) { $failureReasons[0] } else { $null }
                    maximumRise = $maxRise
                    maximumDecline = $maxDecline
                    currentPrice = $current
                    currentReturn = if ($null -ne $currentReturn) { [math]::Round($currentReturn, 4) } else { $null }
                    marketExcessReturn = if ($null -ne $currentReturn -and $null -ne $indexReturn) { [math]::Round($currentReturn - $indexReturn, 4) } else { $null }
                    d1Return = $d1Return
                    d2Return = $d2Return
                    d3Return = $d3Return
                    hypotheticalD1Return = $hypotheticalD1Return
                    hypotheticalD2Return = $hypotheticalD2Return
                    hypotheticalD3Return = $hypotheticalD3Return
                })
            } catch {
                $alerts += "TOP3 validation failed: $($pick.recommendationDate) $($pick.code)"
            }
        }
    }
    $top3Array = @($top3Rows)
    $top1Matured = @($top3Array | Where-Object { $_.rank -eq 1 -and $null -ne $_.d3Return })
    $matured1 = @($top3Array | Where-Object { $null -ne $_.d1Return })
    $matured3 = @($top3Array | Where-Object { $null -ne $_.d3Return })
    $gains3 = @($matured3 | Where-Object { $_.d3Return -gt 0 } | ForEach-Object { [double]$_.d3Return })
    $losses3 = @($matured3 | Where-Object { $_.d3Return -lt 0 } | ForEach-Object { [math]::Abs([double]$_.d3Return) })
    $failureReasonRows = @($top3Array | ForEach-Object {
        foreach ($reason in @($_.failureReasons | Where-Object { $_ })) {
            [pscustomobject]@{ reason = $reason }
        }
    })
    $failureSummary = @($failureReasonRows | Group-Object reason | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ reason = $_.Name; count = $_.Count }
    })
    $activeEntryRows = @($top3Array | Where-Object { -not $_.entrySkipped })
    $activeEntryD1 = @($activeEntryRows | Where-Object { $null -ne $_.d1Return })
    $activeEntryD3 = @($activeEntryRows | Where-Object { $null -ne $_.d3Return })
    $watchlistRows = @($top3Array | Where-Object { $_.entryStatus -eq 'watchlist' })
    $watchlistD1 = @($watchlistRows | Where-Object { $null -ne $_.hypotheticalD1Return })
    $watchlistD3 = @($watchlistRows | Where-Object { $null -ne $_.hypotheticalD3Return })
    $top3Statistics = [pscustomobject]@{
        totalRecommendations = $top3Array.Count
        top1HitRate = if ($top1Matured.Count) { [math]::Round(@($top1Matured | Where-Object { $_.d3Return -gt 0 }).Count * 100 / $top1Matured.Count, 2) } else { 0 }
        averageCurrentReturn = Get-AverageField $top3Array 'currentReturn'
        average1DayReturn = Get-AverageField $top3Array 'd1Return'
        average2DayReturn = Get-AverageField $top3Array 'd2Return'
        average3DayReturn = Get-AverageField $top3Array 'd3Return'
        hitRate1Day = if ($matured1.Count) { [math]::Round(@($matured1 | Where-Object { $_.d1Return -gt 0 }).Count * 100.0 / $matured1.Count, 2) } else { 0 }
        hitRate3Day = if ($matured3.Count) { [math]::Round(@($matured3 | Where-Object { $_.d3Return -gt 0 }).Count * 100.0 / $matured3.Count, 2) } else { 0 }
        average1DayExcessReturn = Get-AverageField $matured1 'd1ExcessReturn'
        average3DayExcessReturn = Get-AverageField $matured3 'd3ExcessReturn'
        profitFactor3Day = if ($losses3.Count -and ($losses3 | Measure-Object -Sum).Sum -gt 0) { [math]::Round(($gains3 | Measure-Object -Sum).Sum / ($losses3 | Measure-Object -Sum).Sum, 4) } else { 0 }
        failureSummary = $failureSummary
        activeEntryStatistics = [pscustomobject]@{
            count = $activeEntryRows.Count
            matured1DayCount = $activeEntryD1.Count
            matured3DayCount = $activeEntryD3.Count
            average1DayReturn = Get-AverageField $activeEntryD1 'd1Return'
            average3DayReturn = Get-AverageField $activeEntryD3 'd3Return'
            hitRate1Day = if ($activeEntryD1.Count) { [math]::Round(@($activeEntryD1 | Where-Object { $_.d1Return -gt 0 }).Count * 100.0 / $activeEntryD1.Count, 2) } else { 0 }
            hitRate3Day = if ($activeEntryD3.Count) { [math]::Round(@($activeEntryD3 | Where-Object { $_.d3Return -gt 0 }).Count * 100.0 / $activeEntryD3.Count, 2) } else { 0 }
        }
        watchlistStatistics = [pscustomobject]@{
            count = $watchlistRows.Count
            matured1DayCount = $watchlistD1.Count
            matured3DayCount = $watchlistD3.Count
            hypotheticalAverage1DayReturn = Get-AverageField $watchlistD1 'hypotheticalD1Return'
            hypotheticalAverage3DayReturn = Get-AverageField $watchlistD3 'hypotheticalD3Return'
            hypotheticalHitRate1Day = if ($watchlistD1.Count) { [math]::Round(@($watchlistD1 | Where-Object { $_.hypotheticalD1Return -gt 0 }).Count * 100.0 / $watchlistD1.Count, 2) } else { 0 }
            hypotheticalHitRate3Day = if ($watchlistD3.Count) { [math]::Round(@($watchlistD3 | Where-Object { $_.hypotheticalD3Return -gt 0 }).Count * 100.0 / $watchlistD3.Count, 2) } else { 0 }
        }
        skippedEntryCount = @($top3Array | Where-Object entrySkipped).Count
        stopRate = if ($top3Array.Count) { [math]::Round(@($top3Array | Where-Object stopReached).Count * 100 / $top3Array.Count, 2) } else { 0 }
        targetRate = if ($top3Array.Count) { [math]::Round(@($top3Array | Where-Object targetReached).Count * 100 / $top3Array.Count, 2) } else { 0 }
        kospiExcessReturn = Get-AverageField @($top3Array | Where-Object market -eq 'KOSPI') 'marketExcessReturn'
        kosdaqExcessReturn = Get-AverageField @($top3Array | Where-Object market -eq 'KOSDAQ') 'marketExcessReturn'
    }
    $currentFormulaVersion = 'short-term-v3-gapguard-1to3d'
    $currentFormulaRows = @($top3Array | Where-Object {
        $_.scoringFormulaVersion -eq $currentFormulaVersion
    })
    $currentFormulaSaved = @($top3Saved | Where-Object {
        $_.scoringFormulaVersion -eq $currentFormulaVersion
    })
    $currentFormulaD1 = @($currentFormulaRows | Where-Object { $null -ne $_.d1Return })
    $currentFormulaD3 = @($currentFormulaRows | Where-Object { $null -ne $_.d3Return })
    $currentFormulaReturns3 = @($currentFormulaD3 | ForEach-Object {
        if (-not $_.entrySkipped) { $_.d3Return }
    } | Where-Object { $null -ne $_ })
    $currentFormulaGains3 = @($currentFormulaReturns3 | Where-Object { [double]$_ -gt 0 } | ForEach-Object { [double]$_ })
    $currentFormulaLosses3 = @($currentFormulaReturns3 | Where-Object { [double]$_ -lt 0 } | ForEach-Object { [math]::Abs([double]$_) })
    $currentFormulaFailureSummary = @($currentFormulaRows | ForEach-Object {
        foreach ($reason in @($_.failureReasons | Where-Object { $_ })) {
            [pscustomobject]@{ reason = $reason }
        }
    } | Group-Object reason | Sort-Object Count -Descending | ForEach-Object {
        [pscustomobject]@{ reason = $_.Name; count = $_.Count }
    })
    $strategyStatistics = @($currentFormulaRows | Group-Object strategyEngine | Sort-Object Name | ForEach-Object {
        $strategyName = if ($_.Name) { $_.Name } else { 'unclassified' }
        $groupRows = @($_.Group)
        $groupD1 = @($groupRows | Where-Object { $null -ne $_.d1Return })
        $groupD3 = @($groupRows | Where-Object { $null -ne $_.d3Return })
        $groupReturns3 = @($groupD3 | ForEach-Object {
            if (-not $_.entrySkipped) { $_.d3Return }
        } | Where-Object { $null -ne $_ })
        [pscustomobject]@{
            strategyEngine = $strategyName
            count = $groupRows.Count
            activeEntryCount = @($groupRows | Where-Object { -not $_.entrySkipped }).Count
            watchlistCount = @($groupRows | Where-Object { $_.entryStatus -eq 'watchlist' }).Count
            matured1DayCount = $groupD1.Count
            matured3DayCount = $groupD3.Count
            averageD3Return = if ($groupReturns3.Count) { [math]::Round(($groupReturns3 | Measure-Object -Average).Average, 4) } else { 0 }
            hitRate3Day = if ($groupReturns3.Count) { [math]::Round(@($groupReturns3 | Where-Object { [double]$_ -gt 0 }).Count * 100.0 / $groupReturns3.Count, 2) } else { 0 }
            averageActiveD3Return = Get-AverageField @($groupRows | Where-Object { -not $_.entrySkipped }) 'd3Return'
            averageWatchlistHypotheticalD3Return = Get-AverageField @($groupRows | Where-Object { $_.entrySkipped }) 'hypotheticalD3Return'
        }
    })
    $currentFormulaStatistics = [pscustomobject]@{
        formulaVersion = $currentFormulaVersion
        savedRecommendationCount = $currentFormulaSaved.Count
        pendingRecommendationCount = [math]::Max(0, $currentFormulaSaved.Count - $currentFormulaRows.Count)
        totalRecommendations = $currentFormulaRows.Count
        activeEntryCount = @($currentFormulaRows | Where-Object { -not $_.entrySkipped }).Count
        watchlistCount = @($currentFormulaRows | Where-Object { $_.entryStatus -eq 'watchlist' }).Count
        average1DayReturn = Get-AverageField @($currentFormulaRows | Where-Object { -not $_.entrySkipped }) 'd1Return'
        average3DayReturn = Get-AverageField @($currentFormulaRows | Where-Object { -not $_.entrySkipped }) 'd3Return'
        hypotheticalAverage1DayReturn = Get-AverageField @($currentFormulaRows | Where-Object { $_.entrySkipped }) 'hypotheticalD1Return'
        hypotheticalAverage3DayReturn = Get-AverageField @($currentFormulaRows | Where-Object { $_.entrySkipped }) 'hypotheticalD3Return'
        hitRate3Day = if ($currentFormulaReturns3.Count) { [math]::Round(@($currentFormulaReturns3 | Where-Object { [double]$_ -gt 0 }).Count * 100.0 / $currentFormulaReturns3.Count, 2) } else { 0 }
        profitFactor3Day = if ($currentFormulaLosses3.Count -and ($currentFormulaLosses3 | Measure-Object -Sum).Sum -gt 0) { [math]::Round(($currentFormulaGains3 | Measure-Object -Sum).Sum / ($currentFormulaLosses3 | Measure-Object -Sum).Sum, 4) } else { 0 }
        failureSummary = $currentFormulaFailureSummary
        strategyStatistics = $strategyStatistics
    }
    @{
        generatedAt = (Get-Date).ToString('o')
        validationVersion = 'ohlc-exit-v2'
        methodology = 'Next-session open with slippage; stop/target exit with conservative same-bar ordering and gap stops; cash held after exit through D+1/D+2/D+3; benchmark open-to-close; watchlists excluded from active statistics.'
        slippageRates = $slippageRates
        backtestMode = 'snapshot-only'
        statistics = $top3Statistics
        currentFormulaStatistics = $currentFormulaStatistics
        items = $top3Array
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $top3ValidationPath -Encoding UTF8
    $pythonPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.venv\Scripts\python.exe'
    $storePath = Join-Path $PSScriptRoot 'store_top3.py'
    $databasePath = Join-Path $script:ReportDir 'top3.db'
    if (Test-Path -LiteralPath $pythonPath) {
        & $pythonPath $storePath performance $top3ValidationPath $databasePath
        if ($LASTEXITCODE -ne 0) { throw 'AI TOP3 performance database save failed.' }
    }
    @{
        generatedAt = (Get-Date).ToString('o')
        roundTripCostRate = $roundTripCostRate
        failedRecommendations = $failed
        failures = @($failures)
        periods = @($summary)
        models = @($modelSummary)
        alerts = $alerts
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-TopPicksLog $taskName 'success' 'Monthly validation report was generated.' @{
        rows = $rows.Count
        failedRecommendations = $failed
        failureDetails = @($failures)
        alerts = $alerts
        csv = $csvPath
        summary = $jsonPath
        top3Validation = $top3ValidationPath
    }
    if ($alerts.Count -gt 0) { exit 2 }
    exit 0
} catch {
    Write-TopPicksLog $taskName 'failure' $_.Exception.Message
    exit 1
}
