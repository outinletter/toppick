. "$PSScriptRoot\automation_common.ps1"
$taskName = 'weekly-audit'

try {
    $path = Join-Path $script:ReportDir 'web-recommendations.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Web recommendation file was not found.' }
    $result = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    $recentDate = [string]$result.recommendationDate
    if (-not $recentDate) { throw 'Recommendation trading date is missing.' }
    $recent = @($result.items)
    $top3 = @($result.top3)
    if ($top3.Count -ne 3 -or @($top3 | Group-Object code | Where-Object Count -gt 1).Count) {
        throw 'AI TOP3 recommendations are missing or duplicated.'
    }
    if (@($top3 | Where-Object {
        [double]$_.plannedEntryPrice -le 0 -or [double]$_.targetPrice -le [double]$_.plannedEntryPrice -or
        [double]$_.stopPrice -ge [double]$_.plannedEntryPrice -or
        $_.entryMethod -ne 'next-trading-day-open' -or
        [double]$_.riseProbability -lt 0 -or [double]$_.riseProbability -gt 100
    }).Count) {
        throw 'AI TOP3 price or probability is invalid.'
    }
    if ($result.top3SelectionTier -notin @('full-evidence', 'partial-evidence', 'score-fallback')) {
        throw 'AI TOP3 selection tier is missing or invalid.'
    }
    if (@($top3 | Where-Object selectionTier -ne $result.top3SelectionTier).Count) {
        throw 'AI TOP3 selection tier does not match its items.'
    }
    if (-not $result.snapshotCaptured -or -not $result.dataAsOf -or
        $result.dataSourceMode -ne 'realtime-first') {
        throw 'Recommendation data timestamp or source mode is missing.'
    }
    if ([datetime]$result.generatedAt -ge [datetime]'2026-06-13') {
        if ($result.pitLevel -ne 'derived-snapshot' -or
            [int]$result.snapshotSchemaVersion -lt 1 -or
            [string]::IsNullOrWhiteSpace($result.scoringFormulaVersion)) {
            throw 'Point-in-time snapshot metadata is missing.'
        }
        foreach ($market in @('KOSPI', 'KOSDAQ')) {
            $coverage = $result.candidateUniverse.$market
            if ($null -eq $coverage -or [int]$coverage.scanned -lt 500 -or
                [int]$coverage.uniqueSelected -lt 50) {
                throw "Candidate universe coverage is insufficient: $market"
            }
        }
        $pitDirectory = Join-Path $script:ReportDir "pit-snapshots\$($recentDate -replace '-', '')"
        if (-not (Test-Path -LiteralPath $pitDirectory) -or
            @(Get-ChildItem -LiteralPath $pitDirectory -Filter '*.json').Count -eq 0) {
            throw 'Point-in-time recommendation snapshot was not found.'
        }
    }
    if ($null -eq $result.pykrx -or [string]::IsNullOrWhiteSpace($result.pykrx.status)) {
        throw 'pykrx collection status is missing.'
    }
    if ($result.marketRegime.name -notin @('강세', '중립', '약세')) {
        throw 'Market regime is missing or invalid.'
    }
    $weights = $result.marketRegime.weights
    foreach ($value in @(
        $weights.earningsReports, $weights.flow, $weights.trend,
        $weights.industry, $weights.financialValue
    )) {
        if ([double]$value -lt 0.8 -or [double]$value -gt 1.2) {
            throw "Market regime weight is out of range: $value"
        }
    }
    $duplicates = @($recent | Group-Object market, code | Where-Object Count -gt 1)
    $invalid = @($recent | Where-Object {
        [double]$_.entryPrice -le 0 -or [double]$_.indexEntry -le 0 -or
        [double]$_.score -lt 0 -or [double]$_.score -gt 100 -or -not $_.liquid -or
        $null -eq $_.signals -or $null -eq $_.scoreBreakdown -or
        $null -eq $_.fixedScore -or
        $_.dataSourceMode -ne 'realtime-first' -or
        -not $_.dataAsOf -or
        ($_.market -eq 'KOSPI' -and [double]$_.marketCap -lt 5000) -or
        ($_.market -eq 'KOSDAQ' -and [double]$_.marketCap -lt 3000)
    })
    if (((Get-Date).Date - [datetime]$recentDate).Days -gt 7) {
        throw "Latest recommendation is stale: $recentDate"
    }
    $marketCounts = @{
        KOSPI = @($recent | Where-Object market -eq 'KOSPI').Count
        KOSDAQ = @($recent | Where-Object market -eq 'KOSDAQ').Count
    }
    if ($marketCounts.KOSPI -ne 10 -or $marketCounts.KOSDAQ -ne 10) {
        throw "Latest recommendation count is invalid: KOSPI=$($marketCounts.KOSPI), KOSDAQ=$($marketCounts.KOSDAQ)"
    }
    if ($duplicates.Count -gt 0) { throw "Duplicate recommendations found: $($duplicates.Count)" }
    $concentrationErrors = @($recent |
        Group-Object market, industryCode |
        Where-Object { $_.Name -notmatch ', $' -and $_.Count -gt 3 })
    if ($concentrationErrors.Count -gt 0) {
        throw "Industry concentration limit exceeded: $($concentrationErrors.Count)"
    }
    $runsPath = Join-Path $script:ReportDir 'web-recommendation-runs.json'
    if (-not (Test-Path -LiteralPath $runsPath)) { throw 'Recommendation run history was not found.' }
    $runs = @((Get-Content -Raw -LiteralPath $runsPath -Encoding UTF8 | ConvertFrom-Json))
    if ($runs.Count -eq 0 -or @($runs[-1].items).Count -ne 20) {
        throw 'Latest recommendation run history is incomplete.'
    }
    if (@($result.fixedItems).Count -ne 20) {
        throw 'Fixed-weight shadow recommendations are incomplete.'
    }
    if (@($recent | Where-Object {
        $null -ne $_.targetUpside -and [double]$_.targetUpside -le -10
    }).Count -gt 0) {
        throw 'Recommendation with target downside of 10% or more was selected.'
    }
    if ($invalid.Count -gt 0) { throw "Invalid price or score found: $($invalid.Count)" }
    $logicErrors = @($recent | Where-Object {
        ([double]$_.signals.twentyDayRise -ge 50 -and [double]$_.scoreBreakdown.technicalPenalty -lt 8) -or
        ([double]$_.signals.rsi -ge 80 -and [double]$_.scoreBreakdown.technicalPenalty -lt 6) -or
        ($_.signals.volumeSurge -and [double]$_.scoreBreakdown.technicalPenalty -lt 4) -or
        [double]$_.scoreBreakdown.industryMomentum -lt -5 -or
        [double]$_.scoreBreakdown.industryMomentum -gt 10 -or
        ($null -ne $_.riseProbability -and [int]$_.probabilitySamples -lt 30) -or
        ($null -ne $_.threeMonthProbability -and [int]$_.threeMonthSamples -lt 30) -or
        $null -eq $_.relativeStrengthScore -or
        $null -eq $_.signals.pykrx -or
        [double]$_.relativeStrengthScore -lt -3 -or
        [double]$_.relativeStrengthScore -gt 3 -or
        [math]::Abs([double]$_.signals.foreignFlowRatio) -gt 100 -or
        [math]::Abs([double]$_.signals.institutionFlowRatio) -gt 100
    })
    if ($logicErrors.Count -gt 0) {
        throw "Recommendation logic invariant failed: $($logicErrors.Count)"
    }
    $weightErrors = @($recent | Where-Object {
        $expected =
            ($_.scoreBreakdown.earnings + $_.scoreBreakdown.reports) * $weights.earningsReports +
            $_.scoreBreakdown.flow * $weights.flow +
            ($_.scoreBreakdown.trend + $_.relativeStrengthScore) * $weights.trend +
            $_.scoreBreakdown.industryMomentum * $weights.industry +
            ($_.scoreBreakdown.financial + $_.valuationScore) * $weights.financialValue -
            $_.scoreBreakdown.riskPenalty - $_.scoreBreakdown.technicalPenalty
        $expected = [math]::Max(0, [math]::Min(100, $expected))
        [math]::Abs([double]$_.score - $expected) -gt 0.01
    })
    if ($weightErrors.Count -gt 0) {
        throw "Market regime weighting mismatch: $($weightErrors.Count)"
    }

    $scores = @($recent | ForEach-Object { [double]$_.score })
    Write-TopPicksLog $taskName 'success' 'Weekly recommendation integrity audit passed.' @{
        recommendationDate = $recentDate
        count = $recent.Count
        minimumScore = [math]::Round(($scores | Measure-Object -Minimum).Minimum, 2)
        maximumScore = [math]::Round(($scores | Measure-Object -Maximum).Maximum, 2)
        averageScore = [math]::Round(($scores | Measure-Object -Average).Average, 2)
        simultaneousBuyCount = @($recent | Where-Object { $_.signals.simultaneousBuy }).Count
        overheatPenaltyCount = @($recent | Where-Object { [double]$_.scoreBreakdown.technicalPenalty -gt 0 }).Count
    }
    exit 0
} catch {
    Write-TopPicksLog $taskName 'failure' $_.Exception.Message
    exit 1
}
