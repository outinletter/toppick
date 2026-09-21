function Convert-FinancialAmount([object]$Value) {
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim().Replace(',', '')
    if ($text -in @('', '-', '--', 'N/A')) { return $null }
    if ($text -match '^\((.+)\)$') { $text = '-' + $Matches[1] }
    $number = 0.0
    if (-not [double]::TryParse($text, [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
    return $number
}

function Test-FreshFlow([object]$Signal, [datetime]$AsOf = (Get-Date)) {
    if (-not $Signal.available -or -not $Signal.flowAsOf -or $Signal.flowUnit -ne 'KRW') { return $false }
    try { $date = [datetime]::ParseExact([string]$Signal.flowAsOf, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) } catch { return $false }
    # Conservative calendar-day ceiling, not a substitute for an exchange calendar.
    $age = ($AsOf.Date - $date.Date).Days
    return $age -ge 0 -and $age -le 7 -and [int]$Signal.flowRows -ge 60
}
