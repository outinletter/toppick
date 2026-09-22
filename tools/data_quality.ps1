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

function Get-DartMediumEvidence([object]$Financials,[int]$Year,[string]$ReportCode) {
    $rows=@($Financials.list)
    $profit=@($rows|Where-Object {$_.account_id -eq 'dart_OperatingIncomeLoss' -and $_.sj_div -in @('IS','CIS')}|Select-Object -First 1)
    $revenue=@($rows|Where-Object {$_.account_id -eq 'ifrs-full_Revenue' -and $_.sj_div -in @('IS','CIS')}|Select-Object -First 1)
    $cash=@($rows|Where-Object {$_.account_id -eq 'ifrs-full_CashFlowsFromUsedInOperatingActivities' -and $_.sj_div -eq 'CF'}|Select-Object -First 1)
    $equity=@($rows|Where-Object {$_.account_id -eq 'ifrs-full_Equity' -and $_.sj_div -eq 'BS'}|Select-Object -First 1)
    $liability=@($rows|Where-Object {$_.account_id -eq 'ifrs-full_Liabilities' -and $_.sj_div -eq 'BS'}|Select-Object -First 1)
    $priorField=if($ReportCode -eq '11011'){'frmtrm_amount'}else{'frmtrm_q_amount'}
    $month=@{'11013'=3;'11012'=6;'11014'=9;'11011'=12}[$ReportCode]
    $receipt=[string]($rows|Select-Object -First 1).rcept_no
    $receiptDate=if($receipt -match '^\d{14}$'){[datetime]::ParseExact($receipt.Substring(0,8),'yyyyMMdd',$null).ToString('yyyy-MM-dd')}else{$null}
    $evidence=[ordered]@{source='DART-CFS';reportCode=$ReportCode;receiptNo=$receipt;publishedDate=$receiptDate
        collectedAt=([datetimeoffset]::Now).ToString('o');periodEnd=if($month){([datetime]::new($Year,$month,[datetime]::DaysInMonth($Year,$month))).ToString('yyyy-MM-dd')}else{$null}
        profit=$null;priorYearProfit=$null;revenue=$null;priorYearRevenue=$null;operatingCashFlow=$null;equity=$null;liabilities=$null
        profitComparisonField=$priorField;cashFlowBasis='report-period-cumulative';currency='KRW'}
    foreach($pair in @(@('profit',$profit,'thstrm_amount'),@('priorYearProfit',$profit,$priorField),@('revenue',$revenue,'thstrm_amount'),@('priorYearRevenue',$revenue,$priorField),@('operatingCashFlow',$cash,'thstrm_amount'),@('equity',$equity,'thstrm_amount'),@('liabilities',$liability,'thstrm_amount'))){
        $row=@($pair[1])|Select-Object -First 1
        if($row -and $row.currency -eq 'KRW'){$evidence[$pair[0]]=Convert-FinancialAmount $row.($pair[2])}
    }
    [pscustomobject]$evidence
}
