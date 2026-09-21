# Pure functions: no API calls, credentials, or report writes.
function Get-ValidationBars {
    param([object[]]$Rows, [string]$RecommendationDate, [string]$RecordedAt,
        [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $zone = [timespan]::FromHours(9)
    $localNow = $Now.ToOffset($zone)
    $cutoff = [datetime]::ParseExact(($RecommendationDate -replace '-', ''), 'yyyyMMdd', [cultureinfo]::InvariantCulture)
    if ($RecordedAt) {
        $recordedDate = ([datetimeoffset]::Parse($RecordedAt)).ToOffset($zone).Date
        if ($recordedDate -gt $cutoff) { $cutoff = $recordedDate }
    }
    $seen = @{}
    foreach ($row in @($Rows | Sort-Object date)) {
        $date = [datetime]::ParseExact([string]$row.date, 'yyyyMMdd', [cultureinfo]::InvariantCulture)
        if ($date -le $cutoff -or $date -gt $localNow.Date) { continue }
        # Wait beyond the regular closing auction; partial daily bars are not D+n outcomes.
        if ($date -eq $localNow.Date -and $localNow.Hour -lt 16) { continue }
        if ($seen.ContainsKey([string]$row.date)) { throw 'Duplicate daily price bar.' }
        $seen[[string]$row.date] = $true
        $row
    }
}

function Get-TradeOutcome {
    param([double]$Entry, [double]$Target, [double]$Stop, [object[]]$Rows,
        [int]$Horizon, [double]$SlippageRate, [double]$CostRate)
    if ($Entry -le 0 -or $Stop -le 0 -or $Stop -ge $Entry -or $Target -le $Entry) {
        throw 'Invalid entry/target/stop geometry.'
    }
    if ($Horizon -lt 1 -or $Rows.Count -lt $Horizon) { return $null }
    $event = 'horizon-close'
    $exitPrice = 0.0
    $exitDate = $null
    foreach ($bar in @($Rows | Select-Object -First $Horizon)) {
        foreach ($field in @('open', 'high', 'low', 'price')) {
            $value = [double]$bar.$field
            if ($value -le 0 -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw "Invalid OHLC: $field" }
        }
        if ($bar.low -gt $bar.high -or $bar.open -lt $bar.low -or $bar.open -gt $bar.high -or $bar.price -lt $bar.low -or $bar.price -gt $bar.high) { throw 'Inconsistent OHLC.' }
        $exitDate = $bar.date
        $exitPrice = [double]$bar.price
        # Opening auction occurs before the unknown intraday high/low sequence.
        if ([double]$bar.open -le $Stop) { $event = 'stop-gap'; $exitPrice = [double]$bar.open; break }
        if ([double]$bar.open -ge $Target) { $event = 'target-gap'; $exitPrice = $Target; break }
        $hitStop = [double]$bar.low -le $Stop
        $hitTarget = [double]$bar.high -ge $Target
        if ($hitStop) {
            $event = if ($hitTarget) { 'stop-first-ambiguous' } else { 'stop' }
            $exitPrice = $Stop
            break
        }
        if ($hitTarget) { $event = 'target'; $exitPrice = $Target; break }
    }
    $executionExit = $exitPrice * (1 - $SlippageRate / 100)
    [pscustomobject]@{
        exitEvent = $event
        exitDate = $exitDate
        exitPrice = $exitPrice
        executionExitPrice = $executionExit
        netReturn = [math]::Round(($executionExit / $Entry - 1) * 100 - $CostRate, 4)
        stopReached = $event -like 'stop*'
        targetReached = $event -like 'target*'
    }
}

function Get-BenchmarkReturn {
    param([object[]]$Rows, [string]$EntryDate, [string]$EvaluationDate)
    $first = @($Rows | Where-Object date -eq $EntryDate | Select-Object -First 1)
    $last = @($Rows | Where-Object date -eq $EvaluationDate | Select-Object -First 1)
    if (-not $first.Count -or -not $last.Count -or [double]$first[0].open -le 0 -or [double]$last[0].price -le 0) { return $null }
    return ([double]$last[0].price / [double]$first[0].open - 1) * 100
}
