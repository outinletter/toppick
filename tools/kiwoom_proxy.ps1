param(
    [int]$Port = 8787,
    [switch]$GenerateOnly,
    [string]$RunId = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\entry_risk.ps1"
. "$PSScriptRoot\data_quality.ps1"
. "$PSScriptRoot\upside_bridge.ps1"
. "$PSScriptRoot\model_governance.ps1"
. "$PSScriptRoot\medium_term.ps1"
$projectRoot = Split-Path -Parent $PSScriptRoot
$appKeyPath = Join-Path $projectRoot 'key\44125103_appkey.txt'
$secretKeyPath = Join-Path $projectRoot 'key\44125103_secretkey.txt'
$dartKeyPath = Join-Path $projectRoot 'key\opendart API key.txt'
$appKey = (Get-Content -Raw -LiteralPath $appKeyPath).Trim()
$secretKey = (Get-Content -Raw -LiteralPath $secretKeyPath).Trim()
$dartKey = (Get-Content -Raw -LiteralPath $dartKeyPath).Trim()
$script:token = $null
$script:tokenExpires = [datetime]::MinValue
$script:dartCorpMap = $null
$script:stockCache = @{}
$script:historyCache = @{}
$script:macroCache = $null
$script:macroCacheDate = ''
$recommendationPath = Join-Path $projectRoot 'reports\web-recommendations.json'
$recommendationHistoryPath = Join-Path $projectRoot 'reports\web-recommendation-history.json'
$recommendationRunsPath = Join-Path $projectRoot 'reports\web-recommendation-runs.json'
$progressPath = Join-Path $projectRoot 'reports\recommendation-progress.json'
$pitSnapshotRoot = Join-Path $projectRoot 'reports\pit-snapshots'
$top3HistoryPath = Join-Path $projectRoot 'reports\ai-top3-history.json'
$top3ValidationPath = Join-Path $projectRoot 'reports\ai-top3-validation.json'
$top3DatabasePath = Join-Path $projectRoot 'reports\top3.db'
$top3StorePath = Join-Path $projectRoot 'tools\store_top3.py'
$macroHistoryPath = Join-Path $projectRoot 'reports\macro-indicators-history.json'
$sectorRotationPath = Join-Path $projectRoot 'reports\sector-rotation-history.json'
$pykrxPath = Join-Path $projectRoot 'tools\collect_pykrx.py'
$pykrxPythonPath = Join-Path $projectRoot '.venv\Scripts\python.exe'
$pykrxSnapshotPath = Join-Path $projectRoot 'reports\pykrx-latest.json'
$customsKeyPath = @(
    (Join-Path $projectRoot 'key\10일 단위 품목별 수출입Decoding.txt'),
    (Join-Path $projectRoot 'key\10일 단위 품목별 수출입Encoding.txt'),
    (Join-Path $projectRoot 'key\data.go.kr API key.txt')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$krxKeyPath = @(
    (Join-Path $projectRoot 'key\KRX인증키.txt'),
    (Join-Path $projectRoot 'key\krx API key.txt')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$script:customsApiStatus = 'key not found'
$script:krxApiStatus = 'key not found'

function Get-KiwoomToken {
    if ($script:token -and (Get-Date) -lt $script:tokenExpires.AddMinutes(-5)) {
        return $script:token
    }
    $body = @{
        grant_type = 'client_credentials'
        appkey = $appKey
        secretkey = $secretKey
    } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Method Post `
        -Uri 'https://api.kiwoom.com/oauth2/token' `
        -ContentType 'application/json;charset=UTF-8' `
        -Body $body
    if ($response.return_code -ne 0) {
        throw "Kiwoom authentication failed: $($response.return_msg)"
    }
    $script:token = $response.token
    $script:tokenExpires = [datetime]::ParseExact(
        $response.expires_dt,
        'yyyyMMddHHmmss',
        [Globalization.CultureInfo]::InvariantCulture
    )
    return $script:token
}

function Invoke-KiwoomApi([string]$ApiId, [string]$Path, [hashtable]$Body) {
    $headers = @{
        authorization = "Bearer $(Get-KiwoomToken)"
        'api-id' = $ApiId
        'cont-yn' = 'N'
        'next-key' = ''
    }
    $response = Invoke-RestMethod -Method Post `
        -Uri "https://api.kiwoom.com$Path" `
        -Headers $headers `
        -ContentType 'application/json;charset=UTF-8' `
        -Body ($Body | ConvertTo-Json -Compress)
    if ($response.return_code -ne 0) {
        throw "Kiwoom API $ApiId failed: $($response.return_msg)"
    }
    return $response
}

function Get-DartCorpMap {
    if ($script:dartCorpMap) {
        return $script:dartCorpMap
    }
    $zipPath = Join-Path $env:TEMP 'toppicks_corpCode.zip'
    $extractPath = Join-Path $env:TEMP 'toppicks_corpCode'
    Invoke-WebRequest `
        -Uri "https://opendart.fss.or.kr/api/corpCode.xml?crtfc_key=$dartKey" `
        -OutFile $zipPath
    if (Test-Path $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath
    [xml]$xml = [IO.File]::ReadAllText(
        (Join-Path $extractPath 'CORPCODE.xml'),
        [Text.Encoding]::UTF8
    )
    $map = @{}
    foreach ($item in $xml.result.list) {
        $stockCode = ([string]$item.stock_code).Trim()
        if ($stockCode) {
            $map[$stockCode] = [string]$item.corp_code
        }
    }
    $script:dartCorpMap = $map
    return $script:dartCorpMap
}

function Invoke-DartApi([string]$Endpoint, [hashtable]$Parameters) {
    $query = @{ crtfc_key = $dartKey }
    foreach ($key in $Parameters.Keys) {
        $query[$key] = $Parameters[$key]
    }
    $pairs = $query.GetEnumerator() | ForEach-Object {
        "$([uri]::EscapeDataString([string]$_.Key))=$([uri]::EscapeDataString([string]$_.Value))"
    }
    $response = Invoke-RestMethod "https://opendart.fss.or.kr/api/$Endpoint.json?$($pairs -join '&')"
    if ($response.status -notin @('000', '013')) {
        throw "DART API failed: $($response.message)"
    }
    return $response
}

function Get-DartSnapshot([string]$Code) {
    $corpCode = (Get-DartCorpMap)[$Code]
    if (-not $corpCode) {
        return @{ available = $false; riskPenalty = 0; reasons = @(); catalystScore = 0; catalysts = @() }
    }
    $endDate = Get-Date
    $startDate = $endDate.AddMonths(-6)
    $disclosures = Invoke-DartApi 'list' @{
        corp_code = $corpCode
        bgn_de = $startDate.ToString('yyyyMMdd')
        end_de = $endDate.ToString('yyyyMMdd')
        last_reprt_at = 'Y'
        page_count = '100'
    }
    $riskPatterns = @(
        @{ Regex = '\uC720\uC0C1\uC99D\uC790\uACB0\uC815'; Label = 'rights offering'; Penalty = 8 }
        @{ Regex = '\uC804\uD658\uC0AC\uCC44\uAD8C\uBC1C\uD589\uACB0\uC815'; Label = 'convertible bond'; Penalty = 6 }
        @{ Regex = '\uC2E0\uC8FC\uC778\uC218\uAD8C\uBD80\uC0AC\uCC44\uAD8C\uBC1C\uD589\uACB0\uC815'; Label = 'warrant bond'; Penalty = 6 }
        @{ Regex = '\uAD50\uD658\uC0AC\uCC44\uAD8C\uBC1C\uD589\uACB0\uC815'; Label = 'exchangeable bond'; Penalty = 4 }
        @{ Regex = '\uD68C\uC0DD\uC808\uCC28'; Label = 'rehabilitation'; Penalty = 15 }
        @{ Regex = '(\uD55C\uC815|\uBD80\uC801\uC815|\uC758\uACAC\uAC70\uC808).{0,20}\uAC10\uC0AC\uC758\uACAC|\uAC10\uC0AC\uC758\uACAC.{0,20}(\uD55C\uC815|\uBD80\uC801\uC815|\uC758\uACAC\uAC70\uC808)'; Label = 'adverse audit opinion'; Penalty = 12 }
        @{ Regex = '\uBD88\uC131\uC2E4\uACF5\uC2DC'; Label = 'disclosure violation'; Penalty = 8 }
        @{ Regex = '\uAD00\uB9AC\uC885\uBAA9'; Label = 'administrative issue'; Penalty = 12 }
        @{ Regex = '\uD6A1\uB839'; Label = 'embezzlement'; Penalty = 15 }
        @{ Regex = '\uBC30\uC784'; Label = 'breach of trust'; Penalty = 15 }
        @{ Regex = '\uC804\uD658\uCCAD\uAD6C\uAD8C\uD589\uC0AC'; Label = 'convertible bond conversion'; Penalty = 6 }
        @{ Regex = '\uC2E0\uC8FC\uC778\uC218\uAD8C\uD589\uC0AC'; Label = 'warrant exercise'; Penalty = 6 }
        @{ Regex = '\uBCF4\uD638\uC608\uC218.{0,20}\uD574\uC81C|\uC758\uBB34\uBCF4\uC720.{0,20}\uD574\uC81C'; Label = 'lock-up expiry'; Penalty = 5 }
        @{ Regex = '\uCD5C\uB300\uC8FC\uC8FC.{0,20}(\uBCC0\uACBD|\uC8FC\uC2DD\uB9E4\uB9E4)'; Label = 'controlling shareholder change'; Penalty = 6 }
    )
    $riskPenalty = 0
    $reasons = @()
    $catalystScore = 0
    $catalysts = @()
    $catalystPatterns = @(
        @{ Regex = '공급계약|단일판매|수주|order'; Label = 'supply/order catalyst'; Score = 4 }
        @{ Regex = '자기주식|자사주'; Label = 'buyback catalyst'; Score = 3 }
        @{ Regex = '배당'; Label = 'dividend catalyst'; Score = 2 }
        @{ Regex = '합병|인수|타법인주식'; Label = 'M&A/investment catalyst'; Score = 2 }
        @{ Regex = '정부|국책|정책|선정'; Label = 'policy catalyst'; Score = 2 }
    )
    $seenRiskTypes = @{}
    $seenCatalystTypes = @{}
    $catalystDisclosures = @()
    foreach ($item in @($disclosures.list)) {
        foreach ($pattern in $riskPatterns) {
            if ($item.report_nm -match $pattern.Regex -and -not $seenRiskTypes[$pattern.Label]) {
                $riskPenalty += $pattern.Penalty
                $reasons += $pattern.Label
                $seenRiskTypes[$pattern.Label] = $true
                break
            }
        }
        foreach ($pattern in $catalystPatterns) {
            if ($item.report_nm -match $pattern.Regex -and -not $seenCatalystTypes[$pattern.Label]) {
                $catalystScore += $pattern.Score
                $catalysts += $pattern.Label
                $seenCatalystTypes[$pattern.Label] = $true
                if ($catalystDisclosures.Count -lt 4) {
                    $catalystDisclosures += "$($item.rcept_dt): $($item.report_nm)"
                }
            }
        }
    }

    $financials = $null
    foreach ($year in @($endDate.Year, ($endDate.Year - 1), ($endDate.Year - 2))) {
        foreach ($reportCode in @('11011', '11014', '11012', '11013')) {
            $candidate = Invoke-DartApi 'fnlttSinglAcntAll' @{
                corp_code = $corpCode
                bsns_year = [string]$year
                reprt_code = $reportCode
                fs_div = 'CFS'
            }
            if ($candidate.status -eq '000') {
                $financials = $candidate
                break
            }
        }
        if ($financials) { break }
    }

    $debtRatio = $null
    $equityValue = $null
    $operatingProfit = $null
    if ($financials) {
        $liabilities = @($financials.list | Where-Object {
            $_.account_id -eq 'ifrs-full_Liabilities'
        } | Select-Object -First 1)
        $equity = @($financials.list | Where-Object {
            $_.account_id -eq 'ifrs-full_Equity'
        } | Select-Object -First 1)
        $profit = @($financials.list | Where-Object {
            $_.account_id -eq 'dart_OperatingIncomeLoss'
        } | Select-Object -First 1)
        $liabilityValue = Convert-FinancialAmount $liabilities.thstrm_amount
        $equityValue = Convert-FinancialAmount $equity.thstrm_amount
        if ($null -ne $liabilityValue -and $null -ne $equityValue -and $equityValue -gt 0) {
            $debtRatio = $liabilityValue / $equityValue * 100
        }
        if ($profit) {
            $operatingProfit = Convert-FinancialAmount $profit.thstrm_amount
        }
    }
    return @{
        available = $disclosures.status -in @('000', '013')
        financialAvailable = $null -ne $financials
        financialYear = if ($financials) { $year } else { $null }
        financialReportCode = if ($financials) { $reportCode } else { $null }
        equity = $equityValue
        nonPositiveEquity = $null -ne $equityValue -and $equityValue -le 0
        debtRatio = $debtRatio
        operatingProfit = $operatingProfit
        riskPenalty = [math]::Min($riskPenalty, 25)
        reasons = @($reasons | Select-Object -Unique -First 3)
        catalystScore = [math]::Min($catalystScore, 10)
        catalysts = @($catalysts | Select-Object -Unique -First 3)
        catalystDisclosures = @($catalystDisclosures)
    }
}

function Get-StockSnapshot([string]$Code) {
    $baseDate = (Get-Date).ToString('yyyyMMdd')
    $cacheKey = "$baseDate-$Code"
    if ($script:stockCache.ContainsKey($cacheKey)) {
        return $script:stockCache[$cacheKey]
    }
    $basic = Invoke-KiwoomApi 'ka10001' '/api/dostk/stkinfo' @{ stk_cd = $Code }
    $chart = Invoke-KiwoomApi 'ka10081' '/api/dostk/chart' @{
        stk_cd = $Code
        base_dt = $baseDate
        upd_stkpc_tp = '1'
    }
    $investors = Invoke-KiwoomApi 'ka10059' '/api/dostk/stkinfo' @{
        dt = $baseDate
        stk_cd = $Code
        amt_qty_tp = '2'
        trde_tp = '0'
        unit_tp = '1'
    }
    $dart = try {
        Get-DartSnapshot $Code
    } catch {
        @{ available = $false; debtRatio = $null; operatingProfit = $null; riskPenalty = 0; reasons = @() }
    }

    $days = @($chart.stk_dt_pole_chart_qry | Select-Object -First 260)
    $tradingDate = if ($days.Count -and $days[0].dt -match '^\d{8}$') {
        [datetime]::ParseExact([string]$days[0].dt, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
    } else {
        (Get-Date).ToString('yyyy-MM-dd')
    }
    $flowsByDate = @{}
    foreach ($row in @($investors.stk_invsr_orgn | Select-Object -First 20)) {
        $flowsByDate[$row.dt] = $row
    }
    $dailyPrices = @()
    $dailyTradingValues = @()
    $dailyVolumes = @()
    $foreignerBuys = @()
    $institutionBuys = @()
    foreach ($day in $days) {
        $dailyPrices += [math]::Abs([double]$day.cur_prc)
        # Kiwoom trde_prica is expressed in million won.
        $dailyTradingValues += ([math]::Abs([double]$day.trde_prica) / 100)
        $dailyVolumes += [math]::Abs([double]$day.trde_qty)
        $flow = $flowsByDate[$day.dt]
        $foreignerBuys += if ($flow) { [double]$flow.frgnr_invsr } else { 0 }
        $institutionBuys += if ($flow) { [double]$flow.orgn } else { 0 }
    }
    $currentPrice = [math]::Abs([double]$basic.cur_prc)
    $currentVolume = [math]::Abs([double]$basic.trde_qty)
    if ($currentPrice -gt 0 -and $dailyPrices.Count -gt 0) {
        $dailyPrices[0] = $currentPrice
        $dailyVolumes[0] = $currentVolume
        # Preserve provider transaction value; last price x volume is not traded notional.
    }
    $snapshot = @{
        code = $Code
        currentPrice = $currentPrice
        changeRate = [double]$basic.flu_rt
        currentVolume = $currentVolume
        openPrice = [math]::Abs([double]$basic.open_pric)
        previousClose = [math]::Abs([double]$basic.base_pric)
        realtimeAsOf = (Get-Date).ToString('o')
        tradingDate = $tradingDate
        per = [double]$basic.per
        pbr = [double]$basic.pbr
        dailyPrices = $dailyPrices
        dailyTradingValues = $dailyTradingValues
        dailyVolumes = $dailyVolumes
        foreignerBuys = $foreignerBuys
        institutionBuys = $institutionBuys
        dartAvailable = $dart.available
        dartDebtRatio = $dart.debtRatio
        dartOperatingProfit = $dart.operatingProfit
        dartNonPositiveEquity = $dart.nonPositiveEquity
        dartFinancialYear = $dart.financialYear
        dartFinancialReportCode = $dart.financialReportCode
        dartRiskPenalty = $dart.riskPenalty
        dartReasons = $dart.reasons
        dartCatalystScore = $dart.catalystScore
        dartCatalysts = $dart.catalysts
        dartCatalystDisclosures = @($dart.catalystDisclosures)
    }
    $script:stockCache[$cacheKey] = $snapshot
    return $snapshot
}

function Get-PerformanceHistory([string]$Code, [string]$Market) {
    $baseDate = (Get-Date).ToString('yyyyMMdd')
    $cacheKey = "$baseDate-$Code-$Market"
    if ($script:historyCache.ContainsKey($cacheKey) -and
        ((Get-Date) - [datetime]$script:historyCache[$cacheKey].collectedAt).TotalMinutes -lt 5) {
        return $script:historyCache[$cacheKey]
    }
    $stock = Invoke-KiwoomApi 'ka10081' '/api/dostk/chart' @{
        stk_cd = $Code
        base_dt = $baseDate
        upd_stkpc_tp = '1'
    }
    $industryCode = if ($Market -eq 'KOSDAQ') { '101' } else { '001' }
    $index = Invoke-KiwoomApi 'ka20006' '/api/dostk/chart' @{
        inds_cd = $industryCode
        base_dt = $baseDate
    }
    $history = @{
        collectedAt = (Get-Date).ToString('o')
        stockHistory = @($stock.stk_dt_pole_chart_qry | ForEach-Object {
            @{
                date = $_.dt
                price = [math]::Abs([double]$_.cur_prc)
                open = [math]::Abs([double]$_.open_pric)
                high = [math]::Abs([double]$_.high_pric)
                low = [math]::Abs([double]$_.low_pric)
                volume = if ($null -ne $_.trde_qty -and [string]$_.trde_qty -ne '') { [math]::Abs([double]$_.trde_qty) } else { $null }
                tradingValueKrw = if ($null -ne $_.trde_prica -and [string]$_.trde_prica -ne '') { [math]::Abs([double]$_.trde_prica) * 1000000 } else { $null }
            }
        })
        indexHistory = @($index.inds_dt_pole_qry | ForEach-Object {
            @{ date = $_.dt; price = [math]::Abs([double]$_.cur_prc) / 100; open = [math]::Abs([double]$_.open_pric) / 100 }
        })
    }
    $script:historyCache[$cacheKey] = $history
    return $history
}

function Convert-ToNumber([object]$Value) {
    $number = 0.0
    if ([double]::TryParse(
        ([string]$Value -replace ',', ''),
        [Globalization.NumberStyles]::Any,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }
    return 0.0
}

function Write-JsonAtomic([string]$Path, [object]$Value, [int]$Depth = 8) {
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($Value | ConvertTo-Json -Depth $Depth),
        [Text.UTF8Encoding]::new($false)
    )
    if ([IO.File]::Exists($Path)) {
        [IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
    } else {
        try { [IO.File]::Move($temporaryPath, $Path) }
        catch [IO.IOException] {
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporaryPath, $Path, [NullString]::Value) } else { throw }
        }
    }
}

function Get-NarrativeScores {
    # Loads narrative_score data produced by tools/run_daily_narrative.py.
    # File format: { "005930": { "narrativeScore": 0-100, "confidence": 0-1, "category": "...", "summary": "..." }, ... }
    $path = Join-Path $PSScriptRoot '..\reports\narrative-scores.json'
    if (-not (Test-Path $path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $map = @{}
        foreach ($prop in $raw.PSObject.Properties) {
            $map[$prop.Name] = $prop.Value
        }
        return $map
    } catch {
        return @{}
    }
}

function Set-RecommendationProgress(
    [string]$Status,
    [string]$Stage,
    [string]$StageName,
    [int]$Percent,
    [string]$Message,
    [int]$Completed = 0,
    [int]$Total = 0
) {
    Write-JsonAtomic $progressPath ([ordered]@{
        runId = $script:activeRunId
        status = $Status
        stage = $Stage
        stageName = $StageName
        percent = [math]::Max(0, [math]::Min(100, $Percent))
        completed = $Completed
        total = $Total
        updatedAt = (Get-Date).ToString('o')
        message = $Message
    }) 4
}

function Get-CachedPykrxSnapshots([string]$Status, [string[]]$Codes = @(), [double]$MinimumCoverage = 0.0) {
    if (-not (Test-Path -LiteralPath $pykrxSnapshotPath)) { return $null }
    try {
        $cache = Get-Content -Raw -LiteralPath $pykrxSnapshotPath -Encoding UTF8 | ConvertFrom-Json
        if (-not $cache -or -not $cache.items) { return $null }
        if (-not $cache.generatedAt) { return $null }
        if ([datetimeoffset]$cache.generatedAt -gt [datetimeoffset]::Now) { return $null }
        if ($cache.PSObject.Properties['generatedAt'] -and $cache.generatedAt) {
            $cacheDate = ([datetime]$cache.generatedAt).Date
            if ($cacheDate -ne (Get-Date).Date) { return $null }
        }
        $coverageCount = 0
        $requestedCount = @($Codes | Where-Object { $_ }).Count
        if ($requestedCount -gt 0) {
            foreach ($code in @($Codes | Where-Object { $_ })) {
                if ($cache.items.PSObject.Properties["K$code"] -and (Test-FreshFlow $cache.items.PSObject.Properties["K$code"].Value)) { $coverageCount++ }
            }
            $coverageRate = $coverageCount / $requestedCount
            if ($coverageRate -lt $MinimumCoverage) { return $null }
        } else {
            $coverageRate = 0
        }
        $cacheAgeMinutes = [math]::Round(([datetimeoffset]::Now - [datetimeoffset]$cache.generatedAt).TotalMinutes, 1)
        if ($cacheAgeMinutes -gt 60) { return $null }
        $cache.available = @($cache.items.PSObject.Properties | Where-Object { Test-FreshFlow $_.Value }).Count -gt 0
        if (-not $cache.available) { return $null }
        $cache.status = "cached $Status; coverage $coverageCount/$requestedCount; age ${cacheAgeMinutes}m"
        return $cache
    } catch {
        return $null
    }
}

function Get-PykrxSnapshots([string[]]$Codes) {
    $warmCache = Get-CachedPykrxSnapshots 'warm-start' $Codes 1.0
    if ($warmCache) { return $warmCache }
    if (-not (Test-Path -LiteralPath $pykrxPythonPath) -or
        -not (Test-Path -LiteralPath $pykrxPath)) {
        $cached = Get-CachedPykrxSnapshots 'after pykrx environment missing' $Codes 0.0
        if ($cached) { return $cached }
        return [pscustomobject]@{
            available = $false
            status = 'pykrx environment missing'
            items = [pscustomobject]@{}
        }
    }
    $stdoutPath = Join-Path $env:TEMP ('toppicks_pykrx_' + [guid]::NewGuid().ToString('N') + '.out')
    $stderrPath = Join-Path $env:TEMP ('toppicks_pykrx_' + [guid]::NewGuid().ToString('N') + '.err')
    try {
        $process = Start-Process -FilePath $pykrxPythonPath `
            -ArgumentList @($pykrxPath, '--codes', ($Codes -join ',')) `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru
        # Retain the native handle so Windows PowerShell can read the exit code.
        $collectorHandle = $process.Handle
        $collectorTimeoutSeconds = [math]::Min(900, [math]::Max(90, 30 + @($Codes).Count * 5))
        if (-not $process.WaitForExit($collectorTimeoutSeconds * 1000)) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
            throw "pykrx collector timed out after $collectorTimeoutSeconds seconds"
        }
        $process.WaitForExit()
        $json = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath -Encoding UTF8 } else { '' }
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { throw 'pykrx collector failed' }
        $result = $json | ConvertFrom-Json
        Write-JsonAtomic $pykrxSnapshotPath $result 6
        return $result
    } catch {
        $cached = Get-CachedPykrxSnapshots "after $($_.Exception.Message)" $Codes 0.0
        if ($cached) { return $cached }
        return [pscustomobject]@{
            available = $false
            status = $_.Exception.Message
            items = [pscustomobject]@{}
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath,$stderrPath -ErrorAction SilentlyContinue
    }
}
function Get-NaverJson([string]$Path) {
    $response = Invoke-RestMethod -Uri "https://m.stock.naver.com$Path" -Headers @{
        'User-Agent' = 'TopPicks Web'
    }
    foreach ($item in @($response)) { Write-Output $item }
}

function Get-CustomsExportGrowth([string]$HsCode) {
    if (-not $customsKeyPath -or -not (Test-Path -LiteralPath $customsKeyPath)) { return $null }
    $serviceKey = (Get-Content -Raw -LiteralPath $customsKeyPath).Trim()
    if (-not $serviceKey) { return $null }
    $latestMonth = (Get-Date).AddMonths(-1)
    $start = $latestMonth.AddYears(-1).ToString('yyyyMM')
    $end = $latestMonth.ToString('yyyyMM')
    $uri = 'https://apis.data.go.kr/1220000/Itemtrade/getItemtradeList' +
        "?serviceKey=$([uri]::EscapeDataString($serviceKey))&strtYymm=$start&endYymm=$end&hsSgn=$HsCode"
    try {
        [xml]$response = (Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 30).Content
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
        $script:customsApiStatus = "HTTP $status"
        return $null
    }
    $script:customsApiStatus = [string]$response.response.header.resultMsg
    $rows = @($response.response.body.items.item)
    if ($rows.Count -lt 2) { return $null }
    $datedRows = @($rows | ForEach-Object {
        $digits = ([string]$_.year -replace '\D', '')
        if ($digits.Length -ge 6) {
            [pscustomobject]@{ date = [datetime]::ParseExact($digits.Substring(0, 6), 'yyyyMM', $null); row = $_ }
        }
    })
    if ($datedRows.Count -lt 2) { return $null }
    $latestDated = $datedRows | Sort-Object date -Descending | Select-Object -First 1
    $latest = $latestDated.row
    $previous = ($datedRows | Where-Object {
        $_.date -eq $latestDated.date.AddYears(-1)
    } | Select-Object -First 1).row
    if (-not $previous) { $previous = $rows | Sort-Object year -Descending | Select-Object -Skip 1 -First 1 }
    $latestValue = Convert-ToNumber $latest.expDlr
    $previousValue = Convert-ToNumber $previous.expDlr
    if ($previousValue -le 0) { return $null }
    return [math]::Round(($latestValue - $previousValue) / $previousValue * 100, 2)
}

function Get-KrxMarketIndicators {
    if (-not $krxKeyPath -or -not (Test-Path -LiteralPath $krxKeyPath)) {
        return [pscustomobject]@{ available = $false; status = 'key not found'; breadthScore = 0 }
    }
    $key = (Get-Content -Raw -LiteralPath $krxKeyPath).Trim()
    $headers = @{ AUTH_KEY = $key }
    foreach ($offset in 1..7) {
        $date = (Get-Date).AddDays(-$offset).ToString('yyyyMMdd')
        try {
            $kospi = Invoke-RestMethod `
                "https://data-dbg.krx.co.kr/svc/apis/sto/stk_bydd_trd?basDd=$date" `
                -Headers $headers -TimeoutSec 30
            $kosdaq = Invoke-RestMethod `
                "https://data-dbg.krx.co.kr/svc/apis/sto/ksq_bydd_trd?basDd=$date" `
                -Headers $headers -TimeoutSec 30
            $rows = @($kospi.OutBlock_1) + @($kosdaq.OutBlock_1)
            if ($rows.Count -eq 0) { continue }
            $advancers = @($rows | Where-Object { (Convert-ToNumber $_.CMPPREVDD_PRC) -gt 0 }).Count
            $decliners = @($rows | Where-Object { (Convert-ToNumber $_.CMPPREVDD_PRC) -lt 0 }).Count
            $breadth = if (($advancers + $decliners) -gt 0) {
                ($advancers - $decliners) / ($advancers + $decliners) * 100
            } else { 0 }
            $script:krxApiStatus = 'OK'
            return [pscustomobject]@{
                available = $true
                status = 'OK'
                date = $date
                rows = $rows.Count
                advanceDeclineRate = [math]::Round($breadth, 2)
                breadthScore = [math]::Max(-2, [math]::Min(2, $breadth / 25))
            }
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
            $script:krxApiStatus = "HTTP $status"
            break
        }
    }
    return [pscustomobject]@{
        available = $false
        status = $script:krxApiStatus
        breadthScore = 0
    }
}

function Get-MacroIndicators {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:macroCache -and $script:macroCacheDate -eq $today) {
        return $script:macroCache
    }
    $endDate = (Get-Date).ToString('yyyyMMdd')
    $startDate = (Get-Date).AddDays(-20).ToString('yyyyMMdd')
    $exchange = Invoke-RestMethod (
        "https://ecos.bok.or.kr/api/StatisticSearch/sample/json/kr/1/10/731Y001/D/$startDate/$endDate/0000001"
    ) -TimeoutSec 30
    $exchangeRows = @($exchange.StatisticSearch.row | Sort-Object TIME)
    $exchangeLatest = Convert-ToNumber $exchangeRows[-1].DATA_VALUE
    $exchangeOldest = Convert-ToNumber $exchangeRows[0].DATA_VALUE
    $exchangeChange = if ($exchangeOldest -gt 0) {
        [math]::Round(($exchangeLatest - $exchangeOldest) / $exchangeOldest * 100, 2)
    } else { $null }

    $html = (Invoke-WebRequest -UseBasicParsing 'https://www.dramexchange.com/' -TimeoutSec 30).Content
    $dramChanges = @()
    foreach ($pattern in @(
        'DDR5 16Gb \(2Gx8\) 4800/5600',
        'DDR4 16Gb \(2Gx8\) 3200',
        'DDR4 8Gb \(1Gx8\) 3200'
    )) {
        $match = [regex]::Match(
            $html,
            $pattern + '.{0,1600}?([+-]?\d+(?:\.\d+)?)\s*%',
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
        if ($match.Success) { $dramChanges += Convert-ToNumber $match.Groups[1].Value }
    }
    $dramChange = if ($dramChanges.Count) {
        [math]::Round(($dramChanges | Measure-Object -Average).Average, 2)
    } else { $null }
    $exports = @{
        semiconductor = Get-CustomsExportGrowth '8542'
        automobile = Get-CustomsExportGrowth '87'
        electronicParts = Get-CustomsExportGrowth '85'
    }
    $krx = Get-KrxMarketIndicators
    $customsAvailable = $null -ne $exports.semiconductor -or
        $null -ne $exports.automobile -or $null -ne $exports.electronicParts
    $snapshot = [pscustomobject]@{
        date = $today
        exchange = [pscustomobject]@{
            source = 'Bank of Korea ECOS'
            usdKrw = $exchangeLatest
            changeRate = $exchangeChange
        }
        dram = [pscustomobject]@{
            source = 'DRAMeXchange free spot prices'
            changeRate = $dramChange
            sampleCount = $dramChanges.Count
        }
        exports = [pscustomobject]@{
            source = 'Korea Customs Service item trade API'
            keyDetected = [bool]$customsKeyPath
            available = $customsAvailable
            status = $script:customsApiStatus
            semiconductor = $exports.semiconductor
            automobile = $exports.automobile
            electronicParts = $exports.electronicParts
        }
        krx = $krx
    }
    $history = if (Test-Path -LiteralPath $macroHistoryPath) {
        @((Get-Content -Raw -LiteralPath $macroHistoryPath -Encoding UTF8 | ConvertFrom-Json))
    } else { @() }
    $history = @($history | Where-Object { $_.date -ne $today }) + $snapshot
    [IO.File]::WriteAllText(
        $macroHistoryPath,
        ($history | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )
    $script:macroCache = $snapshot
    $script:macroCacheDate = $today
    return $snapshot
}

function Get-IndustryMomentum([string]$IndustryCode, [object]$Macro) {
    $score = [double]$Macro.krx.breadthScore
    $details = @(
        $(if ($Macro.krx.available) {
            "KRX 시장 등락 확산도 $($Macro.krx.advanceDeclineRate)%로 $([math]::Round($Macro.krx.breadthScore, 1))점"
        } else {
            "KRX API $($Macro.krx.status)로 시장 강도는 점수에 미반영"
        })
    )
    $exportGrowth = $null
    if ($IndustryCode -in @('270', '278', '282') -and $null -ne $Macro.exchange.changeRate) {
        $exchangeScore = [math]::Max(-3, [math]::Min(3, [double]$Macro.exchange.changeRate * 1.5))
        $score += $exchangeScore
        $details += "원/달러 $($Macro.exchange.usdKrw)원, 최근 변화 $($Macro.exchange.changeRate)%로 수출 민감도 점수 $([math]::Round($exchangeScore, 1))점"
    }
    if ($IndustryCode -eq '278') {
        $exportGrowth = $Macro.exports.semiconductor
        if ($null -ne $Macro.dram.changeRate) {
            $dramScore = [math]::Max(-4, [math]::Min(4, [double]$Macro.dram.changeRate * 2))
            $score += $dramScore
            $details += "DRAM 대표 현물가격 평균 등락 $($Macro.dram.changeRate)%로 $([math]::Round($dramScore, 1))점"
        }
    } elseif ($IndustryCode -eq '270') {
        $exportGrowth = $Macro.exports.automobile
    } elseif ($IndustryCode -eq '282') {
        $exportGrowth = $Macro.exports.electronicParts
    }
    if ($null -ne $exportGrowth) {
        $exportScore = [math]::Max(-4, [math]::Min(4, [double]$exportGrowth / 5))
        $score += $exportScore
        $details += "관세청 품목별 수출 증가율 $exportGrowth%로 $([math]::Round($exportScore, 1))점"
    } elseif ($IndustryCode -in @('270', '278', '282')) {
        $details += "관세청 API $($Macro.exports.status)로 품목별 수출 증가율은 점수에 미반영"
    }
    if ($details.Count -eq 0) {
        $details += '현재 연결된 선행지표와 직접 매핑되지 않은 업종으로 중립 처리'
    }
    return [pscustomobject]@{
        score = [math]::Max(-5, [math]::Min(10, $score))
        details = $details
    }
}

function Get-FinanceMetric([object[]]$Rows, [string]$Title, [string]$Key) {
    if (-not $Key) { return $null }
    $row = $Rows | Where-Object { $_.title -eq $Title } | Select-Object -First 1
    if (-not $row) { return $null }
    $value = $row.columns.$Key.value
    if (-not $value -or $value -eq '-') { return $null }
    return Convert-ToNumber $value
}

function Get-GrowthRate([Nullable[double]]$OldValue, [Nullable[double]]$NewValue) {
    if ($null -eq $OldValue -or $null -eq $NewValue -or [math]::Abs($OldValue) -lt 0.0001) {
        return $null
    }
    return ($NewValue - $OldValue) / [math]::Abs($OldValue) * 100
}

function Get-WeightedMedian([object[]]$Values) {
    $sorted = @($Values | Sort-Object value)
    $half = ($sorted | Measure-Object weight -Sum).Sum / 2
    $total = 0.0
    foreach ($item in $sorted) {
        $total += $item.weight
        if ($total -ge $half) { return [double]$item.value }
    }
    return [double]$sorted[-1].value
}

function Get-Rsi([double[]]$Prices, [int]$Period = 14) {
    if ($Prices.Count -le $Period) { return $null }
    $gains = 0.0
    $losses = 0.0
    for ($index = 0; $index -lt $Period; $index++) {
        $change = $Prices[$index] - $Prices[$index + 1]
        if ($change -gt 0) { $gains += $change } else { $losses += [math]::Abs($change) }
    }
    if ($losses -eq 0) { return 100.0 }
    $relativeStrength = ($gains / $Period) / ($losses / $Period)
    return 100 - (100 / (1 + $relativeStrength))
}

function Get-ThemeScore([string]$Name, [string]$IndustryName) {
    $text = "$Name $IndustryName"
    $rules = @(
        @{ tag = 'AI/semiconductor'; pattern = 'AI|인공지능|반도체|HBM|전기전자|장비|소부장'; score = 5 },
        @{ tag = 'power-infra'; pattern = '전력|변압기|전선|송전|배전|전기장비'; score = 5 },
        @{ tag = 'defense/space'; pattern = '방산|항공우주|우주|미사일|레이다'; score = 4 },
        @{ tag = 'nuclear'; pattern = '원전|원자력|SMR|핵연료'; score = 4 },
        @{ tag = 'bio'; pattern = '바이오|제약|신약|임상|ADC'; score = 3 },
        @{ tag = 'beauty/export-consumer'; pattern = '화장품|뷰티|미용|K뷰티'; score = 3 }
    )
    $score = 0
    $tags = @()
    foreach ($rule in $rules) {
        if ($text -match $rule.pattern) {
            $score += [int]$rule.score
            $tags += [string]$rule.tag
        }
    }
    [pscustomobject]@{ score = [math]::Min(10, $score); tags = @($tags | Select-Object -Unique) }
}

function Get-MacdSignalScore([double[]]$Prices) {
    if (-not $Prices -or $Prices.Count -lt 35) { return 0 }
    $chronological = @($Prices)
    [array]::Reverse($chronological)
    $ema12 = @(); $ema26 = @(); $macd = @(); $signal = @()
    $e12 = [double]$chronological[0]; $e26 = [double]$chronological[0]
    foreach ($price in $chronological) {
        $e12 = ([double]$price * (2.0 / 13)) + ($e12 * (1 - (2.0 / 13)))
        $e26 = ([double]$price * (2.0 / 27)) + ($e26 * (1 - (2.0 / 27)))
        $ema12 += $e12; $ema26 += $e26; $macd += ($e12 - $e26)
    }
    $sig = [double]$macd[0]
    foreach ($value in $macd) {
        $sig = ([double]$value * (2.0 / 10)) + ($sig * (1 - (2.0 / 10)))
        $signal += $sig
    }
    $last = [double]$macd[-1] - [double]$signal[-1]
    $prev = [double]$macd[-2] - [double]$signal[-2]
    if ($last -gt 0 -and $last -gt $prev) { return 4 }
    if ($last -gt 0) { return 2 }
    if ($last -lt 0 -and $last -lt $prev) { return -3 }
    return -1
}
function Get-TargetPrice([string]$Text) {
    $match = [regex]::Match($Text, '목표주가.{0,20}?([\d,.]+)\s*만원')
    if ($match.Success) { return (Convert-ToNumber $match.Groups[1].Value) * 10000 }
    $match = [regex]::Match($Text, '목표주가.{0,20}?([\d,]+)\s*원')
    if ($match.Success) { return Convert-ToNumber $match.Groups[1].Value }
    return $null
}


function Test-EligibleCommonStock([object]$Stock) {
    $name = [string]$Stock.name
    $code = [string]$Stock.code
    if ($code -match '[^0-9]') { return $false }
    if ($name -match '(KODEX|TIGER|ACE|SOL|KOSEF|KBSTAR|ARIRANG|HANARO|RISE|TIMEFOLIO|PLUS|TREX|ETN|ETF|레버리지|인버스|선물|TR|합성|스팩|SPAC|우선주|\b우\b|우C|우B)') { return $false }
    return $true
}

function Get-MarketCandidates([string]$Market) {
    $minimumMarketCap = if ($Market -eq 'KOSPI') { 5000 } else { 3000 }
    $rising = foreach ($page in 1..3) {
        (Get-NaverJson "/api/stocks/up/${Market}?page=$page&pageSize=50").stocks
    }
    $representative = foreach ($page in 1..20) {
        (Get-NaverJson "/api/stocks/marketValue/${Market}?page=$page&pageSize=50").stocks
    }
    $convert = {
        param($stock)
        [pscustomobject]@{
            market = $Market
            code = $stock.itemCode
            name = $stock.stockName
            price = Convert-ToNumber $stock.closePrice
            changeRate = Convert-ToNumber $stock.fluctuationsRatio
            tradingValue = Convert-ToNumber $stock.accumulatedTradingValue
            marketCap = Convert-ToNumber $stock.marketValue
        }
    }
    $risingCandidates = @($rising | ForEach-Object { & $convert $_ } |
        Where-Object { $_.marketCap -ge $minimumMarketCap -and (Test-EligibleCommonStock $_) } |
        Sort-Object @{ Expression = {
            $_.changeRate * 3 +
                $(if ($_.tradingValue -gt 0) { [math]::Log($_.tradingValue) } else { 0 })
        }; Descending = $true } | Select-Object -First 60)
    $activeCandidates = @($representative | ForEach-Object { & $convert $_ } |
        Where-Object { $_.marketCap -ge $minimumMarketCap -and (Test-EligibleCommonStock $_) } |
        Sort-Object tradingValue -Descending | Select-Object -First 60)
    $stableCandidates = @($representative | ForEach-Object { & $convert $_ } |
        Where-Object {
            $_.marketCap -ge $minimumMarketCap -and (Test-EligibleCommonStock $_) -and [math]::Abs($_.changeRate) -le 5
        } | Sort-Object marketCap -Descending | Select-Object -First 40)
    $quietCandidates = @($representative | ForEach-Object { & $convert $_ } |
        Where-Object {
            $_.marketCap -ge $minimumMarketCap -and (Test-EligibleCommonStock $_) -and $_.tradingValue -gt 0 -and
                [math]::Abs($_.changeRate) -le 3
        } | Sort-Object tradingValue -Descending | Select-Object -First 40)
    $seen = @{}
    $selected = @($risingCandidates + $activeCandidates + $stableCandidates + $quietCandidates | Where-Object {
        if ($seen[$_.code]) { $false } else { $seen[$_.code] = $true; $true }
    })
    $eligibleRepresentative = @($representative | ForEach-Object { & $convert $_ } |
        Where-Object { $_.marketCap -ge $minimumMarketCap -and (Test-EligibleCommonStock $_) })
    $script:candidateUniverse[$Market] = [pscustomobject]@{
        market = $Market
        scanned = @($representative).Count
        marketCapEligible = $eligibleRepresentative.Count
        risingSelected = $risingCandidates.Count
        activeSelected = $activeCandidates.Count
        stableSelected = $stableCandidates.Count
        quietSelected = $quietCandidates.Count
        uniqueSelected = $selected.Count
        marketCapMinimum = $minimumMarketCap
    }
    return $selected
}

function Get-AnalyzedStock([object]$Stock) {
    $snapshot = Get-StockSnapshot $Stock.code
    if (-not $snapshot.dartAvailable -or $snapshot.dartNonPositiveEquity) { return $null }
    $currentPrice = if ([double]$snapshot.currentPrice -gt 0) {
        [double]$snapshot.currentPrice
    } else {
        [double]$Stock.price
    }
    $currentChangeRate = if ($null -ne $snapshot.changeRate) {
        [double]$snapshot.changeRate
    } else {
        [double]$Stock.changeRate
    }
    $basic = Get-NaverJson "/api/stock/$($Stock.code)/basic"
    $integration = Get-NaverJson "/api/stock/$($Stock.code)/integration"
    $macro = Get-MacroIndicators
    $industryMomentum = Get-IndustryMomentum $integration.industryCode $macro
    $statusText = @($integration.iconInfos | ForEach-Object { "$($_.name) $($_.description) $($_.value)" }) -join ' '
    if ($basic.stockEndType -ne 'stock' -or $basic.tradeStopType.name -ne 'TRADING' -or
        $basic.newlyListed -or $statusText -match '관리종목|투자주의|투자경고|투자위험') {
        return $null
    }
    [object[]]$reports = @(Get-NaverJson "/api/research/stock/$($Stock.code)" |
        Where-Object { [datetime]($_.writeDate) -ge (Get-Date).Date.AddMonths(-3) -and [datetime]($_.writeDate) -le (Get-Date) } |
        Select-Object -First 50)
    $financeMode = 'quarter'
    try {
        $finance = Get-NaverJson "/api/stock/$($Stock.code)/finance/quarter"
    } catch {
        $financeMode = 'annual-fallback'
        $finance = Get-NaverJson "/api/stock/$($Stock.code)/finance/annual"
    }
    $latestReports = @($reports | Where-Object { $_.brokerName } |
        Group-Object brokerName | ForEach-Object {
            $_.Group | Sort-Object writeDate -Descending | Select-Object -First 1
        })
    $targets = @()
    $upgrades = 0
    $downgrades = 0
    $upgradeBrokers = @{}
    $earningsUpgradeBrokers = @{}
    $recentUpgradeBrokers = @{}
    $recentEarningsUpgradeBrokers = @{}
    $recentDowngradeBrokers = @{}
    foreach ($report in $latestReports) {
        $text = "$($report.title) $($report.previewContent)"
        $target = Get-TargetPrice $text
        if ($target -and $currentPrice -gt 0) {
            $upside = ($target - $currentPrice) / $currentPrice * 100
            if ($upside -ge -30 -and $upside -le 150) {
                $reportDateText = @($report.writeDate)[0]
                $reportDate = [datetime]$reportDateText
                $age = [math]::Max(0, ((Get-Date) - $reportDate).Days)
                $targets += [pscustomobject]@{ value = $target; weight = 1 / (1 + $age / 30) }
            }
        }
        if ($text -match '상향' -and $text -match '목표주가') {
            $upgrades++
            $upgradeBrokers[$report.brokerName] = $true
        }
        if ($text -match '상향' -and $text -match '영업이익|EPS|매출|실적|이익.*전망') {
            $earningsUpgradeBrokers[$report.brokerName] = $true
        }
        if ($text -match '하향' -and $text -match '목표주가') { $downgrades++ }
    }
    # 인사말/광고성 문구 등 의미 없는 리포트 제목은 걸러내고, 실제 투자 판단과 관련된 키워드가 있는 것만 채택
    $meaningfulReportPattern = '목표주가|상향|하향|실적|매출|영업이익|투자의견|매수|비중확대|Overweight|BUY|수주|컨센서스|이익|성장|Preview|Review|호실적|어닝'
    $reportHighlights = @($latestReports | Sort-Object writeDate -Descending | Where-Object {
        "$($_.title) $($_.previewContent)" -match $meaningfulReportPattern
    } | Select-Object -First 3 | ForEach-Object {
        $dateText = @($_.writeDate)[0]
        $snippetSource = if ($_.previewContent -and $_.previewContent.Trim().Length -ge 10) { $_.previewContent } else { $_.title }
        $snippet = $snippetSource.Trim()
        if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0, 80) + '…' }
        "$dateText $($_.brokerName): $snippet"
    })
    foreach ($report in @($reports | Where-Object { [datetime]($_.writeDate) -ge (Get-Date).Date.AddDays(-30) })) {
        $text = "$($report.title) $($report.previewContent)"
        if ($text -match '상향' -and $text -match '목표주가') { $recentUpgradeBrokers[$report.brokerName] = $true }
        if ($text -match '상향' -and $text -match '영업이익|EPS|매출|실적|이익.*전망') { $recentEarningsUpgradeBrokers[$report.brokerName] = $true }
        if ($text -match '하향' -and $text -match '목표주가|영업이익|EPS|실적') { $recentDowngradeBrokers[$report.brokerName] = $true }
    }
    $consensusTrendScore = [math]::Max(-6, [math]::Min(
        8,
        $recentUpgradeBrokers.Count * 1.5 +
            $recentEarningsUpgradeBrokers.Count * 2 -
            $recentDowngradeBrokers.Count * 2.5
    ))
    $targetUpside = if ($targets.Count -ge 3) {
        ((Get-WeightedMedian $targets) - $currentPrice) / $currentPrice * 100
    } elseif ($latestReports.Count -ge 3) {
        $consensusTarget = Convert-ToNumber ($integration.consensusInfo.priceTargetMean)
        if ($consensusTarget -gt 0 -and $currentPrice -gt 0) {
            ($consensusTarget - $currentPrice) / $currentPrice * 100
        } else { $null }
    } else { $null }
    $targetBiasPenalty = 0.0
    if ($null -ne $targetUpside -and [double]$targetUpside -gt 40 -and $upgradeBrokers.Count -eq 0) {
        $targetBiasPenalty += 3
    }
    if ($downgrades -gt 0) {
        $targetBiasPenalty += [math]::Min(5, $downgrades * 2)
    }

    [object[]]$periods = @($finance.financeInfo.trTitleList)
    [object[]]$rows = @($finance.financeInfo.rowList)
    $actualKeys = @($periods | Where-Object { $_.isConsensus -eq 'N' } | ForEach-Object key)
    $consensusKey = ($periods | Where-Object { $_.isConsensus -eq 'Y' } | Select-Object -First 1).key
    $latestKey = $actualKeys | Select-Object -Last 1
    $previousKey = $actualKeys | Select-Object -Last 2 | Select-Object -First 1
    $priorKey = $actualKeys | Select-Object -Last 3 | Select-Object -First 1
    $actualProfit = Get-FinanceMetric $rows '영업이익' $latestKey
    $previousProfit = Get-FinanceMetric $rows '영업이익' $previousKey
    $priorProfit = Get-FinanceMetric $rows '영업이익' $priorKey
    $expectedProfit = Get-FinanceMetric $rows '영업이익' $consensusKey
    $actualEps = Get-FinanceMetric $rows 'EPS' $latestKey
    $expectedEps = Get-FinanceMetric $rows 'EPS' $consensusKey
    $profitGrowth = Get-GrowthRate $actualProfit $expectedProfit
    $epsGrowth = Get-GrowthRate $actualEps $expectedEps
    $quarterProfitGrowth = Get-GrowthRate $previousProfit $actualProfit
    $previousQuarterProfitGrowth = Get-GrowthRate $priorProfit $previousProfit
    $quarterGrowthScore = if ($financeMode -eq 'quarter' -and $null -ne $quarterProfitGrowth -and $null -ne $previousQuarterProfitGrowth) {
        if ($quarterProfitGrowth -gt 0 -and $previousQuarterProfitGrowth -gt 0) {
            [math]::Min(7, ([math]::Min(80, $quarterProfitGrowth) + [math]::Min(80, $previousQuarterProfitGrowth)) / 20)
        } elseif ($quarterProfitGrowth -gt 20) { 3 } elseif ($quarterProfitGrowth -lt -20 -and $previousQuarterProfitGrowth -lt 0) { -4 } else { 0 }
    } else { 0 }
    $roe = Get-FinanceMetric $rows 'ROE' $latestKey
    if ($null -eq $roe -and $consensusKey) { $roe = Get-FinanceMetric $rows 'ROE' $consensusKey }
    $operatingMargin = Get-FinanceMetric $rows '영업이익률' $latestKey
    if ($null -eq $operatingMargin -and $consensusKey) { $operatingMargin = Get-FinanceMetric $rows '영업이익률' $consensusKey }
    $fcf = Get-FinanceMetric $rows 'FCF' $latestKey
    if ($null -eq $fcf) { $fcf = Get-FinanceMetric $rows '잉여현금흐름' $latestKey }
    $per = if ($snapshot.per -gt 0) { $snapshot.per } else {
        Get-FinanceMetric $rows 'PER' $consensusKey
    }
    $pbr = if ($snapshot.pbr -gt 0) { $snapshot.pbr } else {
        Get-FinanceMetric $rows 'PBR' $consensusKey
    }
    $debtRatio = if ($null -ne $snapshot.dartDebtRatio) { $snapshot.dartDebtRatio } else {
        Get-FinanceMetric $rows '부채비율' $latestKey
    }
    $priceCount = @($snapshot.dailyPrices).Count
    $trendDays = [math]::Min(20, $priceCount)
    if ($priceCount -lt 80 -or $trendDays -lt 20 -or
        @($snapshot.dailyTradingValues).Count -lt $trendDays -or
        @($snapshot.dailyVolumes).Count -lt 20 -or
        @($snapshot.foreignerBuys).Count -lt $trendDays -or
        @($snapshot.institutionBuys).Count -lt $trendDays) {
        return $null
    }
    $foreignBuy = (@($snapshot.foreignerBuys)[0..($trendDays - 1)] | Measure-Object -Sum).Sum
    $institutionBuy = (@($snapshot.institutionBuys)[0..($trendDays - 1)] | Measure-Object -Sum).Sum
    $tradingValues = @($snapshot.dailyTradingValues)[0..($trendDays - 1)]
    $averageTradingValue = ($tradingValues | Measure-Object -Average).Average
    $liquidDays = @($tradingValues | Select-Object -First 5 | Where-Object { $_ -ge 30 }).Count
    $totalVolume = (@($snapshot.dailyVolumes)[0..($trendDays - 1)] | Measure-Object -Sum).Sum
    $liquid = $averageTradingValue -ge 50 -and $liquidDays -ge 3 -and $actualKeys.Count -ge 2
    $foreignRatio = if ($totalVolume -gt 0) { $foreignBuy / $totalVolume * 100 } else { 0 }
    $institutionRatio = if ($totalVolume -gt 0) { $institutionBuy / $totalVolume * 100 } else { 0 }
    $flowRatio = $foreignRatio + $institutionRatio
    $simultaneousBuy = $foreignBuy -gt 0 -and $institutionBuy -gt 0
    $priceTrend = if ($trendDays -ge 2 -and $snapshot.dailyPrices[$trendDays - 1] -gt 0) {
        ($snapshot.dailyPrices[0] - $snapshot.dailyPrices[$trendDays - 1]) /
            $snapshot.dailyPrices[$trendDays - 1] * 100
    } else { $currentChangeRate }
    $prices = [double[]]@($snapshot.dailyPrices)
    $volumes = [double[]]@($snapshot.dailyVolumes)
    $ma20 = (@($prices | Select-Object -First 20) | Measure-Object -Average).Average
    $ma60 = (@($prices | Select-Object -First 60) | Measure-Object -Average).Average
    $previousMa60 = (@($prices[20..79]) | Measure-Object -Average).Average
    $aboveMa20 = $prices[0] -gt $ma20
    $ma20Deviation = if ($ma20 -gt 0) { ($prices[0] - $ma20) / $ma20 * 100 } else { 0 }
    $risingMa60 = $ma60 -gt $previousMa60
    $rsi = Get-Rsi $prices 14
    $highRange = [math]::Min(250, $prices.Count)
    $high52Week = (@($prices | Select-Object -First $highRange) | Measure-Object -Maximum).Maximum
    $nearHigh = $high52Week -gt 0 -and $prices[0] / $high52Week -ge 0.9
    $boxBreakout = $prices[0] -gt (@($prices[1..20]) | Measure-Object -Maximum).Maximum
    $twentyDayRise = if ($prices[19] -gt 0) { ($prices[0] - $prices[19]) / $prices[19] * 100 } else { 0 }
    $recentVolatilityRates = for ($volatilityIndex = 0; $volatilityIndex -lt 10; $volatilityIndex++) {
        if ($prices[$volatilityIndex + 1] -gt 0) {
            [math]::Abs(($prices[$volatilityIndex] - $prices[$volatilityIndex + 1]) / $prices[$volatilityIndex + 1] * 100)
        }
    }
    $shortTermVolatility = if (@($recentVolatilityRates).Count) {
        [math]::Round((@($recentVolatilityRates) | Measure-Object -Average).Average, 2)
    } else { 2.0 }
    $averageVolume = (@($volumes[1..19]) | Measure-Object -Average).Average
    $volumeSurge = $averageVolume -gt 0 -and $volumes[0] / $averageVolume -ge 5
    $currentTradingValue = if ($tradingValues.Count) { [double]$tradingValues[0] } else { 0 }
    $previousTradingValueAverage = if ($tradingValues.Count -gt 1) {
        (@($tradingValues | Select-Object -Skip 1) | Measure-Object -Average).Average
    } else { 0 }
    $transactionValueIncrease = if ($previousTradingValueAverage -gt 0) {
        ($currentTradingValue - $previousTradingValueAverage) / $previousTradingValueAverage * 100
    } else { 0 }
    $macdSignalScore = Get-MacdSignalScore $prices
    $theme = Get-ThemeScore $Stock.name $integration.industryName
    $qualityScore = 0.0
    if ($roe -ne $null) { $qualityScore += [math]::Min(4, [math]::Max(-2, [double]$roe / 5)) }
    if ($operatingMargin -ne $null) { $qualityScore += [math]::Min(3, [math]::Max(-1, [double]$operatingMargin / 5)) }
    if ($debtRatio -ne $null -and [double]$debtRatio -gt 180) { $qualityScore -= 2 }
    if ($fcf -ne $null -and [double]$fcf -gt 0) { $qualityScore += 1 }
    if ($snapshot.dartOperatingProfit -ne $null -and [double]$snapshot.dartOperatingProfit -gt 0) { $qualityScore += 1 }
    $qualityScore = [math]::Round([math]::Max(-3, [math]::Min(8, $qualityScore)), 2)
    $openingGapRate = if ($snapshot.previousClose -gt 0 -and $snapshot.openPrice -gt 0) { ($snapshot.openPrice - $snapshot.previousClose) / $snapshot.previousClose * 100 } else { 0 }
    $intradayPullbackRate = if ($snapshot.openPrice -gt 0) { ($currentPrice - $snapshot.openPrice) / $snapshot.openPrice * 100 } else { 0 }
    $gapRiskPenalty = 0.0
    if ($openingGapRate -ge 8) { $gapRiskPenalty += 8 }
    elseif ($openingGapRate -ge 5) { $gapRiskPenalty += 4 }
    if ($openingGapRate -ge 4 -and $intradayPullbackRate -lt 0) { $gapRiskPenalty += 3 }
    if ($currentChangeRate -ge 15) { $gapRiskPenalty += 6 }
    elseif ($currentChangeRate -ge 10) { $gapRiskPenalty += 3 }
    $technicalPenalty = 0.0
    if ($twentyDayRise -ge 50) { $technicalPenalty += 8 }
    if ($ma20Deviation -ge 20) { $technicalPenalty += 6 }
    elseif ($ma20Deviation -ge 12) { $technicalPenalty += 3 }
    if ($null -ne $rsi -and $rsi -ge 80) { $technicalPenalty += 6 }
    if ($volumeSurge -and $currentChangeRate -ge 8) { $technicalPenalty += 5 } elseif ($volumeSurge) { $technicalPenalty += 2 }

    $earningsScore = [math]::Max(0, [math]::Min(25,
        5 + $(if ($null -ne $profitGrowth) { [math]::Max(-30, [math]::Min(60, $profitGrowth)) / 12 } else { 0 }) +
        $(if ($null -ne $epsGrowth) { [math]::Max(-30, [math]::Min(60, $epsGrowth)) / 12 } else { 0 }) +
        $quarterGrowthScore + $earningsUpgradeBrokers.Count * 3
    ))
    $reportScore = [math]::Max(0, [math]::Min(16,
        $(if ($null -ne $targetUpside) {
            [math]::Max(-4, [math]::Min(8, $targetUpside / 8))
        } else { 0 }) +
        $upgrades * 2 - $downgrades * 3.5 + [math]::Min(5, $latestReports.Count) - $targetBiasPenalty
    ))
    $flowScore = [math]::Max(0, [math]::Min(20,
        8 + $foreignRatio * 1.5 + $institutionRatio * 1.5 +
        $(if ($simultaneousBuy) { 4 } else { 0 })
    ))
    $trendScore = [math]::Max(0, [math]::Min(15,
        3 + $(if ($aboveMa20) { 3 } else { 0 }) +
        $(if ($risingMa60) { 3 } else { 0 }) +
        $(if ($nearHigh) { 2 } else { 0 }) +
        $(if ($boxBreakout) { 2 } else { 0 }) +
        [math]::Max(-3, [math]::Min(2, $priceTrend / 10))
    ))
    $verifiedProfit = if ($null -ne $snapshot.dartOperatingProfit) { $snapshot.dartOperatingProfit } else { $actualProfit }
    $financialScore = if ($null -ne $verifiedProfit -and $verifiedProfit -le 0) { 0 }
        elseif ($null -eq $debtRatio) { 2.5 } elseif ($debtRatio -le 80) { 5 }
        elseif ($debtRatio -le 150) { 3.5 } elseif ($debtRatio -le 250) { 1.5 } else { 0 }
    $riskPenalty = [double]$snapshot.dartRiskPenalty + $gapRiskPenalty
    $actualGrowth = Get-GrowthRate $previousProfit $actualProfit
    if ($null -ne $actualGrowth -and [math]::Abs($actualGrowth) -gt 150) { $riskPenalty += 4 }
    if (($null -ne $actualProfit -and $actualProfit -le 0) -and
        ($null -ne $previousProfit -and $previousProfit -le 0)) { return $null }
    if ($null -ne $debtRatio -and $debtRatio -gt 250) { return $null }
    if (@($snapshot.dartReasons).Count -gt 0) { return $null }
    $baseScore = [math]::Max(0, [math]::Min(95,
        $earningsScore + $reportScore + $flowScore + $trendScore + $financialScore +
            $industryMomentum.score -
            $riskPenalty - $technicalPenalty
    ))
    $reasons = @()
    if ($null -ne $targetUpside -and $targetUpside -gt 10) { $reasons += "상승여력 $([math]::Round($targetUpside, 1))%" }
    if ($upgradeBrokers.Count -ge 2) { $reasons += "복수 증권사 상향 $($upgradeBrokers.Count)곳" }
    if ($earningsUpgradeBrokers.Count -ge 2) {
        $reasons += "복수 증권사 실적 상향 $($earningsUpgradeBrokers.Count)곳"
    } elseif (($profitGrowth -gt 15) -or ($epsGrowth -gt 15)) {
        $reasons += '컨센서스 실적 성장'
    }
    if ($simultaneousBuy) { $reasons += '외국인·기관 동시 순매수' }
    if ($aboveMa20 -and $risingMa60) { $reasons += '20일선 상회·60일선 상승' }
    if ($liquid) { $reasons += '유동성 기준 통과' }
    if ($theme.score -ge 4) { $reasons += ('강한 테마: ' + (@($theme.tags) -join ', ')) }
    if ($snapshot.dartCatalystScore -ge 3) { $reasons += ('긍정 공시: ' + (@($snapshot.dartCatalysts) -join ', ')) }
    if ($qualityScore -ge 5) { $reasons += '재무 퀄리티 우수' }
    $details = @(
        $(if ($null -ne $targetUpside) {
            if ($targets.Count -ge 3) {
                "상승여력 $([math]::Round($targetUpside, 1))%: 목표가 $($targets.Count)건을 발행일에 따라 가중한 중앙값과 현재가를 비교했습니다."
            } else {
                "상승여력 $([math]::Round($targetUpside, 1))%: 개별 목표가가 3건 미만이어서 네이버 증권 컨센서스 평균 목표가와 현재가를 비교했습니다."
            }
        } else {
            "상승여력: 유효한 목표가가 3건 미만이어서 목표가 점수에는 반영하지 않았습니다."
        }),
        "리포트 $([math]::Round($reportScore, 1))/20점: 최근 3개월 증권사 $($latestReports.Count)곳의 최신 의견을 사용했고 상향 ${upgrades}건($($upgradeBrokers.Count)개 증권사), 하향 ${downgrades}건을 반영했습니다.",
        "컨센서스 추세 $([math]::Round($consensusTrendScore, 1))점: 최근 30일 목표가 상향 $($recentUpgradeBrokers.Count)곳, 실적 전망 상향 $($recentEarningsUpgradeBrokers.Count)곳, 하향 $($recentDowngradeBrokers.Count)곳을 반영했습니다.",
        "실적 $([math]::Round($earningsScore, 1))/25점: $financeMode 데이터를 사용했고 최근 분기 영업이익 성장률 $(
            if ($null -ne $quarterProfitGrowth) { "$([math]::Round($quarterProfitGrowth, 1))%" } else { '자료 부족' }
        ), 직전 분기 성장률 $(if ($null -ne $previousQuarterProfitGrowth) { "$([math]::Round($previousQuarterProfitGrowth, 1))%" } else { '자료 부족' })을 반영했습니다. 컨센서스 성장률은 $(
            if ($null -ne $profitGrowth) { "$([math]::Round($profitGrowth, 1))%" } else { '자료 부족' }
        ), EPS 성장률 $(if ($null -ne $epsGrowth) { "$([math]::Round($epsGrowth, 1))%" } else { '자료 부족' })이며 최근 3개월 실적 추정 상향 증권사는 $($earningsUpgradeBrokers.Count)곳입니다.",
        "수급 $([math]::Round($flowScore, 1))/20점: 최근 20일 외국인 $([math]::Round($foreignRatio, 2))%, 기관 $([math]::Round($institutionRatio, 2))%이며 동시 순매수 여부는 $(if ($simultaneousBuy) { '예' } else { '아니오' })입니다.",
        "차트 $([math]::Round($trendScore, 1))/15점: 20일선 상회 $(if ($aboveMa20) { '예' } else { '아니오' }), 20일선 이격도 $([math]::Round($ma20Deviation, 1))%, 60일선 상승 $(if ($risingMa60) { '예' } else { '아니오' }), RSI $([math]::Round($rsi, 1)), 20일 상승률 $([math]::Round($twentyDayRise, 1))%, 과열 감점 ${technicalPenalty}점입니다.",
        "재무 $financialScore/5점: 부채비율 $(if ($null -ne $debtRatio) { "$([math]::Round($debtRatio, 1))%" } else { '자료 부족' }), DART 위험 감점 $([math]::Round($riskPenalty, 1))점입니다.",
        "업종 선행지표 $([math]::Round($industryMomentum.score, 1))/10점: $($industryMomentum.details -join '; ').",
        "유동성: 최근 20일 일평균 거래대금 $([math]::Round($averageTradingValue, 1))억원, 최근 5일 중 30억원 이상 거래 ${liquidDays}일로 기준을 통과했습니다."
    )
    $narrativeEntry = if ($script:narrativeScores) { $script:narrativeScores[$Stock.code] } else { $null }
    $narrativeScore = if ($narrativeEntry) {
        # Confidence-weighted: low-confidence narrative classifications contribute less (spec section 7).
        [math]::Max(0, [math]::Min(10, [double]$narrativeEntry.narrativeScore / 10 * [double]$narrativeEntry.confidence))
    } else { 0 }
    # 뉴스·리포트·수급·실적·재무·기술적 신호를 종목별로 종합해 여러 문장의 상세 서술로 구성 (원문 리포트 제목 나열 대신 사용)
    # 1) 목표주가·리포트 방향성
    $valuationParts = @()
    if ($null -ne $targetUpside) {
        $basis = if ($targets.Count -ge 3) { "발행일 가중 목표가 중앙값" } else { "네이버 컨센서스 평균 목표가" }
        $valuationParts += "$basis 기준 현재가 대비 상승여력은 약 $([math]::Round($targetUpside, 1))%로 산출됩니다"
    } else {
        $valuationParts += "유효한 목표주가 데이터가 3건 미만이라 상승여력은 정량 점수 위주로 판단합니다"
    }
    if ($upgrades -gt $downgrades -and $upgrades -gt 0) {
        $valuationParts += "최근 3개월 사이 목표주가를 상향한 증권사가 ${upgrades}건(하향 ${downgrades}건)으로 더 많아 증권가 시각이 우호적입니다"
    } elseif ($downgrades -gt $upgrades -and $downgrades -gt 0) {
        $valuationParts += "다만 최근 3개월 목표주가 하향 리포트가 ${downgrades}건으로 상향(${upgrades}건)보다 많아 신중한 접근이 필요합니다"
    } elseif ($latestReports.Count -gt 0) {
        $valuationParts += "최근 3개월 발행된 증권사 리포트는 $($latestReports.Count)건이며 뚜렷한 상향·하향 쏠림은 없습니다"
    }
    # 2) 실적 전망
    $earningsParts = @()
    if ($null -ne $profitGrowth -or $null -ne $epsGrowth) {
        $profitText = if ($null -ne $profitGrowth) { "영업이익 컨센서스 성장률 $([math]::Round($profitGrowth, 1))%" } else { "영업이익 컨센서스 자료 부족" }
        $epsText = if ($null -ne $epsGrowth) { "EPS 성장률 $([math]::Round($epsGrowth, 1))%" } else { "EPS 자료 부족" }
        $earningsParts += "실적 전망은 $profitText, $epsText 로 컨센서스가 형성되어 있습니다"
    }
    if ($financeMode -eq 'quarter' -and $null -ne $quarterProfitGrowth) {
        $earningsParts += "직전 분기 대비 최근 분기 영업이익 증감률은 $([math]::Round($quarterProfitGrowth, 1))%입니다"
    }
    # 3) 수급
    $flowParts = @()
    if ($simultaneousBuy) {
        $flowParts += "최근 20일간 외국인(누적 비중 $([math]::Round($foreignRatio, 1))%)과 기관(비중 $([math]::Round($institutionRatio, 1))%)이 동시에 순매수하며 수급이 개선되고 있습니다"
    } elseif ($foreignRatio -gt 0 -or $institutionRatio -gt 0) {
        $flowParts += "최근 20일 외국인 비중 $([math]::Round($foreignRatio, 1))%, 기관 비중 $([math]::Round($institutionRatio, 1))%로 일부 순매수가 확인됩니다"
    } else {
        $flowParts += "최근 20일 외국인·기관 수급은 뚜렷한 순매수 신호가 없습니다"
    }
    # 4) 재무 건전성
    $financeParts = @()
    if ($null -ne $debtRatio) {
        $debtComment = if ($debtRatio -le 80) { "안정적인 수준" } elseif ($debtRatio -le 150) { "관리 가능한 수준" } else { "다소 높은 수준" }
        $financeParts += "부채비율은 $([math]::Round($debtRatio, 1))%로 $debtComment 입니다"
    }
    if ($null -ne $roe) { $financeParts += "ROE는 $([math]::Round([double]$roe, 1))%입니다" }
    # 5) 공시·테마·기술적 흐름
    $eventParts = @()
    if (@($snapshot.dartCatalysts).Count -gt 0) {
        $eventParts += "최근 6개월 DART 공시에서 " + (@($snapshot.dartCatalysts) -join ', ') + " 관련 재료가 확인됩니다"
    }
    if ($theme.score -ge 4) {
        $eventParts += "테마 흐름상 " + (@($theme.tags) -join ', ') + " 관련 부각으로 순환매 수혜가 기대됩니다"
    }
    if ($aboveMa20 -and $risingMa60) {
        $eventParts += "주가가 20일선을 상회하며 60일선도 상승 전환해 중기 추세가 개선되고 있습니다"
    } elseif (-not $aboveMa20) {
        $eventParts += "다만 현재 주가가 20일선을 하회하고 있어 단기 추세 회복 여부를 확인할 필요가 있습니다"
    }
    if (@($snapshot.dartReasons).Count -gt 0) {
        $eventParts += "주의: DART 공시에서 " + (@($snapshot.dartReasons) -join ', ') + " 관련 리스크 요인이 함께 확인되어 유의가 필요합니다"
    }
    $narrativeSummary = (@($valuationParts + $earningsParts + $flowParts + $financeParts + $eventParts) -join '. ') + '.'
    return [pscustomobject]@{
        date = $snapshot.tradingDate
        market = $Stock.market
        code = $Stock.code
        name = $Stock.name
        entryPrice = $currentPrice
        openPrice = $snapshot.openPrice
        previousClose = $snapshot.previousClose
        marketCap = $Stock.marketCap
        score = $baseScore
        baseScore = $baseScore
        targetUpside = $targetUpside
        targetBiasPenalty = $targetBiasPenalty
        themeScore = $theme.score
        themeTags = @($theme.tags)
        qualityScore = $qualityScore
        roe = $roe
        operatingMargin = $operatingMargin
        fcf = $fcf
        macdSignalScore = $macdSignalScore
        disclosureCatalystScore = $snapshot.dartCatalystScore
        disclosureCatalysts = @($snapshot.dartCatalysts)
        disclosureCatalystDisclosures = @($snapshot.dartCatalystDisclosures)
        reportHighlights = $reportHighlights
        narrativeSummary = $narrativeSummary
        consensusTrendScore = $consensusTrendScore
        reportCount = $latestReports.Count
        per = $per
        pbr = $pbr
        debtRatio = $debtRatio
        industryCode = $integration.industryCode
        liquid = $liquid
        dataAsOf = $snapshot.realtimeAsOf
        tradingDate = $snapshot.tradingDate
        dataSourceMode = 'realtime-first'
        reasons = @($reasons | Select-Object -First 3)
        details = $details
        scoreBreakdown = [pscustomobject]@{
            earnings = $earningsScore
            reports = $reportScore
            flow = $flowScore
            trend = $trendScore
            financial = $financialScore
            industryMomentum = $industryMomentum.score
            narrative = $narrativeScore
            riskPenalty = $riskPenalty
            technicalPenalty = $technicalPenalty
            gapRiskPenalty = $gapRiskPenalty
        }
        signals = [pscustomobject]@{
            sourceQuality = [pscustomobject]@{
                collectedAt = $snapshot.realtimeAsOf
                priceDate = $snapshot.tradingDate
                dartFinancialYear = $snapshot.dartFinancialYear
                dartFinancialReportCode = $snapshot.dartFinancialReportCode
                tradingValueUnit = 'KRW-100-million'
                investorQuantityUnit = 'shares'
                consensusMethod = 'report-keyword-proxy'
            }
            simultaneousBuy = $simultaneousBuy
            intradayReturn = $currentChangeRate
            foreignFlowRatio = $foreignRatio
            institutionFlowRatio = $institutionRatio
            averageTradingValue = $averageTradingValue
            currentTradingValue = $currentTradingValue
            transactionValueIncrease = $transactionValueIncrease
            openingGapRate = $openingGapRate
            intradayPullbackRate = $intradayPullbackRate
            priceTrend = $priceTrend
            financeMode = $financeMode
            quarterProfitGrowth = $quarterProfitGrowth
            previousQuarterProfitGrowth = $previousQuarterProfitGrowth
            quarterGrowthScore = $quarterGrowthScore
            aboveMa20 = $aboveMa20
            ma20Deviation = $ma20Deviation
            shortTermVolatility = $shortTermVolatility
            risingMa60 = $risingMa60
            nearHigh = $nearHigh
            boxBreakout = $boxBreakout
            rsi = $rsi
            macdSignalScore = $macdSignalScore
            themeScore = $theme.score
            qualityScore = $qualityScore
            disclosureCatalystScore = $snapshot.dartCatalystScore
            twentyDayRise = $twentyDayRise
            volumeSurge = $volumeSurge
            upgradeBrokerCount = $upgradeBrokers.Count
            earningsUpgradeBrokerCount = $earningsUpgradeBrokers.Count
            recentUpgradeBrokerCount = $recentUpgradeBrokers.Count
            recentEarningsUpgradeBrokerCount = $recentEarningsUpgradeBrokers.Count
            recentDowngradeBrokerCount = $recentDowngradeBrokers.Count
            consensusTrendScore = $consensusTrendScore
        }
    }
}

function Get-Median([double[]]$Values) {
    $sorted = @($Values | Where-Object { $_ -gt 0 } | Sort-Object)
    if (-not $sorted.Count) { return $null }
    $middle = [math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$middle] }
    return ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

function Get-RelativeValueScore([Nullable[double]]$Value, [Nullable[double]]$Median) {
    if ($null -eq $Value -or $null -eq $Median -or $Value -le 0 -or $Median -le 0) { return 0 }
    return [math]::Max(0, [math]::Min(5, ($Median - $Value) / $Median * 10))
}

function Get-CalibratedProbability(
    [double]$Score,
    [int]$Horizon,
    [string]$Regime,
    [datetime]$CutoffDate
) {
    if ($null -eq $script:calibrationRows) {
        $script:calibrationRows = @(foreach ($file in Get-ChildItem (Join-Path $projectRoot 'reports\validation-*.csv') -ErrorAction SilentlyContinue) {
            Import-Csv -LiteralPath $file.FullName
        })
    }
    $rows = @($script:calibrationRows | Where-Object {
        [int]$_.horizon -eq $Horizon -and $_.marketRegime -eq $Regime -and
            [datetime]$_.recommendationDate -lt $CutoffDate.Date -and
            ($_.model -eq 'dynamic' -or [string]::IsNullOrWhiteSpace($_.model)) -and
            [math]::Abs([double]$_.score - $Score) -le 5
    })
    $samples = @($rows | Sort-Object recommendationDate, code, horizon, marketRegime -Unique)
    if ($samples.Count -lt 30) {
        return [pscustomobject]@{ probability = $null; samples = $samples.Count }
    }
    $hits = @($samples | Where-Object {
        $outcome = if ($_.PSObject.Properties.Name -contains 'netReturn' -and $_.netReturn -ne '') {
            [double]$_.netReturn
        } else {
            [double]$_.returnRate
        }
        $outcome -gt 0
    }).Count
    return [pscustomobject]@{
        probability = [math]::Round($hits * 100.0 / $samples.Count, 1)
        samples = $samples.Count
    }
}

function Select-DiversifiedTop([object[]]$Candidates, [string]$ScoreProperty) {
    $selected = [Collections.Generic.List[object]]::new()
    $industryCounts = @{}
    foreach ($candidate in @($Candidates | Sort-Object $ScoreProperty -Descending)) {
        $industry = if ($candidate.industryCode) { [string]$candidate.industryCode } else { 'UNKNOWN' }
        if (($industryCounts[$industry] -as [int]) -ge 3) { continue }
        $selected.Add($candidate)
        $industryCounts[$industry] = ($industryCounts[$industry] -as [int]) + 1
        if ($selected.Count -eq 10) { break }
    }
    return @($selected)
}

function Get-ShortTermScore([object]$Candidate) {
    $probabilityScore = if ($null -ne $Candidate.riseProbability) {
        [double]$Candidate.riseProbability
    } else {
        [double]$Candidate.score
    }
    $flowScore = [math]::Max(-6, [math]::Min(24,
        ([double]$Candidate.scoreBreakdown.flow / 20 * 8) +
            $(if ($Candidate.signals.pykrx.available) {
                [math]::Max(-5, [math]::Min(7, [double]$Candidate.signals.pykrx.flowAdjustment))
            } else { -3 }) +
            $(if ($Candidate.PSObject.Properties['institutionQualityScore']) { [math]::Max(-3, [math]::Min(5, [double]$Candidate.institutionQualityScore)) } else { 0 }) +
            $(if ([double]$Candidate.signals.averageTradingValue -ge 700) { 4 } elseif ([double]$Candidate.signals.averageTradingValue -ge 150) { 2 } else { -2 })
    ))
    $liquidityBurstScore = [math]::Max(-4, [math]::Min(10,
        $(if ([double]$Candidate.signals.currentTradingValue -ge 500) { 3 } elseif ([double]$Candidate.signals.currentTradingValue -ge 100) { 1 } else { -2 }) +
            $(if ([double]$Candidate.signals.transactionValueIncrease -ge 200) { 5 } elseif ([double]$Candidate.signals.transactionValueIncrease -ge 80) { 3 } elseif ([double]$Candidate.signals.transactionValueIncrease -ge 30) { 1 } else { 0 }) +
            $(if ($Candidate.signals.volumeSurge) { 2 } else { 0 })
    ))
    $momentumScore = [math]::Max(-10, [math]::Min(24,
        ([double]$Candidate.scoreBreakdown.trend / 15 * 8) +
            [double]$Candidate.relativeStrengthScore +
            $(if ($Candidate.signals.aboveMa20) { 2 } else { -2 }) +
            $(if ($Candidate.signals.boxBreakout) { 3 } else { 0 }) +
            $(if ($Candidate.signals.volumeSurge) { 4 } else { 0 }) +
            $(if ([double]$Candidate.signals.transactionValueIncrease -ge 100) { 4 } elseif ([double]$Candidate.signals.transactionValueIncrease -ge 30) { 2 } else { 0 }) -
            $(if ([double]$Candidate.signals.rsi -ge 82) { 8 } elseif ([double]$Candidate.signals.rsi -ge 75) { 4 } else { 0 }) -
            $(if ([double]$Candidate.signals.ma20Deviation -ge 15) { 5 } elseif ([double]$Candidate.signals.ma20Deviation -ge 10) { 2 } else { 0 })
    ))
    $sectorScore = if ($Candidate.PSObject.Properties['sectorRotationScore']) {
        if ($Candidate.sectorRotationStatus -eq 'strong') {
            [math]::Max(0, [math]::Min(12, [double]$Candidate.sectorRotationScore * 0.45 + [double]$Candidate.signals.sectorPersistenceScore))
        } elseif ($Candidate.sectorRotationStatus -eq 'neutral') {
            [math]::Max(0, [math]::Min(6, [double]$Candidate.sectorRotationScore * 0.25 + [double]$Candidate.signals.sectorPersistenceScore * 0.5))
        } elseif ($Candidate.sectorRotationStatus -eq 'weak') { -4 } else { -5 }
    } else { -5 }
    $themeScore = if ($Candidate.PSObject.Properties['themeScore']) { [math]::Max(0, [math]::Min(5, [double]$Candidate.themeScore)) } else { 0 }
    $catalystScore = if ($Candidate.PSObject.Properties['disclosureCatalystScore']) { [math]::Max(0, [math]::Min(5, [double]$Candidate.disclosureCatalystScore)) } else { 0 }
    $macdScore = if ($Candidate.PSObject.Properties['macdSignalScore']) { [math]::Max(-3, [math]::Min(4, [double]$Candidate.macdSignalScore)) } else { 0 }
    $qualityGuard = if ($Candidate.PSObject.Properties['qualityScore']) { [math]::Max(-2, [math]::Min(3, [double]$Candidate.qualityScore * 0.4)) } else { 0 }
    $riskPenalty = [double]$Candidate.scoreBreakdown.riskPenalty + [double]$Candidate.scoreBreakdown.technicalPenalty + $(if ($Candidate.scoreBreakdown.PSObject.Properties['gapRiskPenalty']) { [double]$Candidate.scoreBreakdown.gapRiskPenalty } else { 0 })
    if ($Candidate.PSObject.Properties['targetBiasPenalty']) { $riskPenalty += [double]$Candidate.targetBiasPenalty * 0.25 }
    return [math]::Round([math]::Max(0, [math]::Min(
        100,
        $probabilityScore * 0.18 + $flowScore + $momentumScore + $sectorScore +
            $liquidityBurstScore + $themeScore + ($catalystScore * 0.8) + ($macdScore * 1.2) + $qualityGuard - ($riskPenalty * 0.8)
    )), 2)
}

function Get-StrategyClassification([object]$Candidate, [object]$MarketRegime) {
    $tags = [Collections.Generic.List[string]]::new()
    $scores = [ordered]@{
        trendMomentum = 0
        pullback = 0
        sectorRotation = 0
        flowFollowing = 0
        liquidityBurst = 0
        earningsRevision = 0
        eventCatalyst = 0
        meanReversion = 0
        defensiveCash = 0
        inverseHedge = 0
    }

    if ([double]$Candidate.relativeStrengthScore -gt 0) { $scores.trendMomentum += 2; $tags.Add('relative-strength') }
    if ($Candidate.signals.aboveMa20) { $scores.trendMomentum += 2; $tags.Add('above-ma20') }
    if ($Candidate.signals.boxBreakout) { $scores.trendMomentum += 3; $tags.Add('box-breakout') }
    if ([double]$Candidate.signals.twentyDayRise -gt 5) { $scores.trendMomentum += 1; $tags.Add('20d-uptrend') }

    if ($Candidate.signals.aboveMa20 -and [double]$Candidate.signals.ma20Deviation -ge -2 -and [double]$Candidate.signals.ma20Deviation -le 6) {
        $scores.pullback += 3
        $tags.Add('ma20-controlled-pullback')
    }
    if ([double]$Candidate.signals.rsi -ge 45 -and [double]$Candidate.signals.rsi -le 65) { $scores.pullback += 1; $tags.Add('rsi-balanced') }

    if ($Candidate.sectorRotationStatus -eq 'strong') { $scores.sectorRotation += 5; $tags.Add('strong-sector') }
    elseif ($Candidate.sectorRotationStatus -eq 'neutral') { $scores.sectorRotation += 2; $tags.Add('neutral-sector') }
    if ($Candidate.PSObject.Properties['sectorPersistenceScore'] -and [double]$Candidate.sectorPersistenceScore -gt 0) {
        $scores.sectorRotation += 2
        $tags.Add('sector-persistence')
    }

    if ($Candidate.signals.pykrx.available -and [double]$Candidate.signals.pykrx.flowAdjustment -gt 0) { $scores.flowFollowing += 3; $tags.Add('positive-flow') }
    if ($Candidate.PSObject.Properties['institutionQualityScore'] -and [double]$Candidate.institutionQualityScore -gt 0) { $scores.flowFollowing += 2; $tags.Add('institution-quality') }

    if ([double]$Candidate.signals.currentTradingValue -ge 100) { $scores.liquidityBurst += 1; $tags.Add('active-trading-value') }
    if ([double]$Candidate.signals.transactionValueIncrease -ge 80) { $scores.liquidityBurst += 3; $tags.Add('transaction-value-surge') }
    if ($Candidate.signals.volumeSurge) { $scores.liquidityBurst += 2; $tags.Add('volume-surge') }

    if ($Candidate.PSObject.Properties['consensusTrendScore'] -and [double]$Candidate.consensusTrendScore -gt 0) { $scores.earningsRevision += 2; $tags.Add('consensus-up') }
    if ([double]$Candidate.signals.quarterProfitGrowth -gt 0) { $scores.earningsRevision += 1; $tags.Add('quarter-profit-growth') }

    if ($Candidate.PSObject.Properties['disclosureCatalystScore'] -and [double]$Candidate.disclosureCatalystScore -gt 0) { $scores.eventCatalyst += 3; $tags.Add('disclosure-catalyst') }
    if ($Candidate.PSObject.Properties['themeScore'] -and [double]$Candidate.themeScore -gt 0) { $scores.eventCatalyst += 1; $tags.Add('theme') }

    if ([double]$Candidate.signals.rsi -lt 35) { $scores.meanReversion += 3; $tags.Add('rsi-oversold') }
    if ([double]$Candidate.signals.ma20Deviation -lt -8) { $scores.meanReversion += 2; $tags.Add('ma20-oversold') }

    if ($MarketRegime.name -ne '강세') { $scores.defensiveCash += 3; $tags.Add('non-bull-market') }
    if ($Candidate.sectorRotationStatus -eq 'weak') { $scores.defensiveCash += 2; $tags.Add('weak-sector') }
    if ([double]$Candidate.signals.rsi -ge 75 -or [double]$Candidate.signals.ma20Deviation -ge 10) { $scores.defensiveCash += 2; $tags.Add('overheat-risk') }
    if ($MarketRegime.name -eq '약세' -or $MarketRegime.name -eq '급락') { $scores.inverseHedge += 5; $tags.Add('index-weakness-hedge') }

    $ranked = @($scores.GetEnumerator() | Sort-Object Value -Descending)
    $primary = $ranked[0].Key
    $secondary = @($ranked | Where-Object { $_.Value -gt 0 -and $_.Key -ne $primary } | Select-Object -First 3 | ForEach-Object { $_.Key })
    $action = if ($primary -eq 'inverseHedge') { 'consider-index-inverse-or-cash' }
        elseif ($primary -eq 'defensiveCash') { 'watchlist-or-cash' }
        else { 'long-candidate' }

    return [pscustomobject]@{
        primary = $primary
        secondary = $secondary
        action = $action
        scores = [pscustomobject]$scores
        tags = @($tags | Select-Object -Unique)
    }
}
function Get-SectorRotation([object[]]$Items, [hashtable]$IndexChanges, [datetime]$ExecutionTime) {
    $previous = if (Test-Path -LiteralPath $sectorRotationPath) {
        @((Get-Content -Raw -LiteralPath $sectorRotationPath -Encoding UTF8 | ConvertFrom-Json))
    } else { @() }
    $latestPrevious = @($previous | Sort-Object generatedAt -Descending | Select-Object -First 1).sectors
    $previousByKey = @{}
    foreach ($sector in @($latestPrevious)) {
        $previousByKey["$($sector.market)|$($sector.industryCode)"] = $sector
    }
    $sectors = @($Items | Where-Object { $_.industryCode } |
        Group-Object market, industryCode | ForEach-Object {
            $rows = @($_.Group)
            if ($rows.Count -ge 2) {
                $market = [string]$rows[0].market
                $industryCode = [string]$rows[0].industryCode
                $industryName = [string]$rows[0].industryName
                $avgReturn = (@($rows | ForEach-Object { [double]$_.signals.intradayReturn }) | Measure-Object -Average).Average
                $risingRatio = @($rows | Where-Object { [double]$_.signals.intradayReturn -gt 0 }).Count * 100.0 / $rows.Count
                $indexReturn = if ($IndexChanges.ContainsKey($market)) { [double]$IndexChanges[$market] } else { 0 }
                $relativeStrength = $avgReturn - $indexReturn
                $transactionValueIncrease = (@($rows | ForEach-Object { [double]$_.signals.transactionValueIncrease }) | Measure-Object -Average).Average
                $momentum5 = $avgReturn
                $momentum20 = (@($rows | ForEach-Object { [double]$_.signals.priceTrend }) | Measure-Object -Average).Average
                $score = [math]::Round(
                    $avgReturn * 2.0 +
                    $relativeStrength * 2.0 +
                    ($risingRatio - 50) / 4.0 +
                    [math]::Max(-5, [math]::Min(8, $transactionValueIncrease / 12.0)) +
                    [math]::Max(-4, [math]::Min(4, $momentum5)) +
                    [math]::Max(-4, [math]::Min(4, $momentum20 / 5.0)),
                    2
                )
                $status = if ($score -ge 8) { 'strong' } elseif ($score -ge 2) { 'neutral' } else { 'weak' }
            $previousStatus = if ($previousByKey.ContainsKey("$market|$industryCode")) {
                [string]$previousByKey["$market|$industryCode"].status
            } else { 'unknown' }
            $sectorHistory = @($previous | Select-Object -Last 5 | ForEach-Object {
                $snapshotSector = @($_.sectors | Where-Object {
                    $_.market -eq $market -and $_.industryCode -eq $industryCode
                } | Select-Object -First 1)
                if ($snapshotSector.Count) { $snapshotSector[0] }
            })
            $persistentStrongCount = @($sectorHistory | Where-Object { $_.status -eq 'strong' }).Count
            $averageScore5 = if ($sectorHistory.Count) {
                [math]::Round((@($sectorHistory | ForEach-Object { [double]$_.score }) | Measure-Object -Average).Average, 2)
            } else { $score }
            $improvingCount = @($sectorHistory | Where-Object { [double]$_.score -lt $score }).Count
            $persistenceScore = [math]::Max(-4, [math]::Min(
                8,
                $persistentStrongCount * 1.5 +
                    $(if ($improvingCount -ge 3) { 2 } else { 0 }) +
                    $(if ($averageScore5 -ge 8) { 2 } elseif ($averageScore5 -lt 0) { -2 } else { 0 })
            ))
            $score = [math]::Round($score + $persistenceScore, 2)
            $status = if ($score -ge 8) { 'strong' } elseif ($score -ge 2) { 'neutral' } else { 'weak' }
            [pscustomobject]@{
                    market = $market
                    industryCode = $industryCode
                    industryName = $industryName
                    stockCount = $rows.Count
                    averageReturn = [math]::Round($avgReturn, 2)
                    risingRatio = [math]::Round($risingRatio, 2)
                    indexReturn = [math]::Round($indexReturn, 2)
                    relativeStrength = [math]::Round($relativeStrength, 2)
                    transactionValueIncrease = [math]::Round($transactionValueIncrease, 2)
                    momentum5 = [math]::Round($momentum5, 2)
                    momentum20 = [math]::Round($momentum20, 2)
                score = $score
                status = $status
                previousStatus = $previousStatus
                persistentStrongCount = $persistentStrongCount
                averageScore5 = $averageScore5
                improvingCount = $improvingCount
                persistenceScore = [math]::Round($persistenceScore, 2)
                rotationUp = $status -eq 'strong' -and $previousStatus -in @('weak', 'neutral')
            }
            }
        } | Sort-Object score -Descending)
    $snapshot = [pscustomobject]@{
        generatedAt = $ExecutionTime.ToString('o')
        sectors = @($sectors)
    }
    $history = @($previous | Select-Object -Last 60) + $snapshot
    Write-JsonAtomic $sectorRotationPath $history 8
    return [pscustomobject]@{
        generatedAt = $snapshot.generatedAt
        sectors = @($sectors)
        leaders = @()
    }
}

function Get-MarketRegime {
    $macro = Get-MacroIndicators
    $regimeScore = 0.0
    $reasons = @()
    foreach ($market in @('KOSPI', 'KOSDAQ')) {
        $industryCode = if ($market -eq 'KOSDAQ') { '101' } else { '001' }
        $chart = Invoke-KiwoomApi 'ka20006' '/api/dostk/chart' @{
            inds_cd = $industryCode
            base_dt = (Get-Date).ToString('yyyyMMdd')
        }
        $prices = [double[]]@($chart.inds_dt_pole_qry | Select-Object -First 80 | ForEach-Object {
            [math]::Abs([double]$_.cur_prc) / 100
        })
        if ($prices.Count -lt 80) { throw "$market index history is shorter than 80 rows." }
        $ma20 = (@($prices[0..19]) | Measure-Object -Average).Average
        $ma60 = (@($prices[0..59]) | Measure-Object -Average).Average
        $previousMa60 = (@($prices[20..79]) | Measure-Object -Average).Average
        $aboveMa20 = $prices[0] -gt $ma20
        $risingMa60 = $ma60 -gt $previousMa60
        $regimeScore += if ($aboveMa20) { 1 } else { -1 }
        $regimeScore += if ($risingMa60) { 1 } else { -1 }
        $reasons += "$market 20일선 $(if ($aboveMa20) { '상회' } else { '하회' }), 60일선 $(if ($risingMa60) { '상승' } else { '하락' })"
    }
    if ($macro.krx.available) {
        if ([double]$macro.krx.advanceDeclineRate -ge 15) { $regimeScore += 1 }
        elseif ([double]$macro.krx.advanceDeclineRate -le -15) { $regimeScore -= 1 }
        $reasons += "KRX 등락 확산도 $($macro.krx.advanceDeclineRate)%"
    } else {
        $reasons += "KRX 등락 확산도 미반영($($macro.krx.status))"
    }
    if ([double]$macro.exchange.changeRate -ge 2) { $regimeScore -= 1 }
    elseif ([double]$macro.exchange.changeRate -le -2) { $regimeScore += 0.5 }
    $reasons += "원/달러 최근 변화 $($macro.exchange.changeRate)%"

    $name = if ($regimeScore -ge 2) { '강세' } elseif ($regimeScore -le -2) { '약세' } else { '중립' }
    $weights = switch ($name) {
        '강세' {
            @{ earningsReports = 0.95; flow = 1.15; trend = 1.15; industry = 1.10; financialValue = 0.85; narrative = 1.10 }
        }
        '약세' {
            @{ earningsReports = 1.10; flow = 0.90; trend = 0.80; industry = 0.90; financialValue = 1.20; narrative = 0.85 }
        }
        default {
            @{ earningsReports = 1.00; flow = 1.00; trend = 1.00; industry = 1.00; financialValue = 1.00; narrative = 1.00 }
        }
    }
    return [pscustomobject]@{
        name = $name
        score = $regimeScore
        reasons = $reasons
        weights = $weights
    }
}

function New-WebRecommendations {
    $mutex = [Threading.Mutex]::new($false, 'Local\TopPicks-Recommendation-Generation')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Recommendation generation already running; retry after completion.' }
        Invoke-RecommendationGeneration
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-RecommendationGeneration {
    $executionTime = Get-Date
    $modelManifest=Get-ModelManifest $PSScriptRoot
    $collectionFailures=[Collections.Generic.List[object]]::new()
    $upsideEvidenceMap = Get-UpsideEvidenceMap (Join-Path $projectRoot 'reports\independent-upside\latest.json') ([datetimeoffset]$executionTime)
    if (-not $script:activeRunId) {
        $script:activeRunId = $executionTime.ToString('yyyyMMdd-HHmmss')
    }
    Set-RecommendationProgress 'running' 'prepare' '실행 준비 및 API 점검' 2 '추천 분석을 준비하고 있습니다.'
    $script:stockCache = @{}
    $script:calibrationRows = $null
    $script:narrativeScores = Get-NarrativeScores
    Set-RecommendationProgress 'running' 'market_regime' '시장 국면 분석' 5 '시장 지수와 거시지표를 분석하고 있습니다.'
    $marketRegime = Get-MarketRegime
    $script:fixedShadowItems = @()
    $script:candidateUniverse = @{}
    $indexEntries = @{}
    $indexChanges = @{}
    foreach ($market in @('KOSPI', 'KOSDAQ')) {
        $indexRows = @(Get-NaverJson "/api/index/$market/price")
        $indexEntries[$market] = Convert-ToNumber ($indexRows[0].closePrice)
        $indexChanges[$market] = Convert-ToNumber ($indexRows[0].fluctuationsRatio)
    }
    $marketIndexes = [pscustomobject]@{
        KOSPI = [pscustomobject]@{
            value = $indexEntries['KOSPI']
            changeRate = $indexChanges['KOSPI']
            source = 'Naver index realtime-first'
            collectedAt = $executionTime.ToString('o')
        }
        KOSDAQ = [pscustomobject]@{
            value = $indexEntries['KOSDAQ']
            changeRate = $indexChanges['KOSDAQ']
            source = 'Naver index realtime-first'
            collectedAt = $executionTime.ToString('o')
        }
    }
    Set-RecommendationProgress 'running' 'candidates' '후보 종목 구성' 10 '코스피·코스닥 후보 종목을 구성하고 있습니다.'
    $candidateRows = @(
        foreach ($market in @('KOSPI', 'KOSDAQ')) {
            @(Get-MarketCandidates $market)
        }
    )
    $candidateTotal = $candidateRows.Count
    $candidateCompleted = 0
    $all = foreach ($candidate in $candidateRows) {
        $candidateCompleted++
        $analysisPercent = if ($candidateTotal) {
            15 + [math]::Floor($candidateCompleted * 50 / $candidateTotal)
        } else { 65 }
        Set-RecommendationProgress 'running' 'stock_analysis' '시세·재무·리포트 분석' $analysisPercent (
            "$candidateCompleted/$candidateTotal 종목 분석 중: $($candidate.name)"
        ) $candidateCompleted $candidateTotal
        try { Get-AnalyzedStock $candidate } catch {
            $httpStatus=0
            try { $httpStatus=[int]$_.Exception.Response.StatusCode } catch {}
            $collectionFailures.Add([pscustomobject]@{code=$candidate.code;market=$candidate.market;errorType=$_.Exception.GetType().Name;httpStatus=$httpStatus})
            Write-Host "Recommendation analysis failed for $($candidate.code): $($_.Exception.Message) $($_.ScriptStackTrace)"
        }
    }
    Set-RecommendationProgress 'running' 'pykrx' '수급·공매도 분석' 68 '투자자별 수급과 공매도 데이터를 분석하고 있습니다.'
    $pykrx = Get-PykrxSnapshots @($all | Where-Object { $_ -and $_.code } | ForEach-Object code)
    foreach ($item in @($all | Where-Object { $_ -and $_.code })) {
        $property = if ($pykrx.items) {
            $pykrx.items.PSObject.Properties["K$($item.code)"]
        } else { $null }
        $signal = if ($property) { $property.Value } else { $null }
        if ($null -ne $signal -and $signal.industryName) {
            $item | Add-Member -NotePropertyName industryName -NotePropertyValue $signal.industryName
        }
        if ($null -ne $signal -and (Test-FreshFlow $signal)) {
            $flowAmount20 = [double]$signal.foreign20 + [double]$signal.institution20
            $tradingValueBase = [double]$item.signals.averageTradingValue * 100000000 * 20
            $marketCapBase = [double]$item.marketCap * 100000000
            $turnoverIntensity = if ($tradingValueBase -gt 0) {
                $flowAmount20 / $tradingValueBase * 100
            } else { 0 }
            $marketCapIntensity = if ($marketCapBase -gt 0) {
                $flowAmount20 / $marketCapBase * 100
            } else { 0 }
            $normalizedFlowAdjustment = [math]::Max(-2, [math]::Min(
                2, $turnoverIntensity / 2 + $marketCapIntensity
            ))
            $institutionQualityScore = [math]::Max(-5, [math]::Min(
                8,
                $(if ([double]$signal.pension20 -gt 0) { 3 } elseif ([double]$signal.pension20 -lt 0) { -3 } else { 0 }) +
                    $(if ([double]$signal.trust20 -gt 0) { 2 } elseif ([double]$signal.trust20 -lt 0) { -2 } else { 0 }) +
                    $(if ([double]$signal.institution20 -gt 0 -and [double]$signal.institution60 -gt 0) { 2 } elseif ([double]$signal.institution20 -lt 0 -and [double]$signal.institution60 -lt 0) { -2 } else { 0 }) +
                    $(if ([double]$signal.institutionStreak -ge 3) { 1 } elseif ([double]$signal.institutionSellStreak -ge 3) { -1 } else { 0 })
            ))
            $item.scoreBreakdown.flow = [math]::Max(0, [math]::Min(
                20, [double]$item.scoreBreakdown.flow +
                    [double]$signal.flowAdjustment + $normalizedFlowAdjustment
            ))
            $item.scoreBreakdown.riskPenalty =
                [double]$item.scoreBreakdown.riskPenalty + [double]$signal.shortPenalty
            $item.signals | Add-Member -NotePropertyName pykrx -NotePropertyValue $signal
            $item.signals.pykrx | Add-Member -NotePropertyName turnoverIntensity -NotePropertyValue $turnoverIntensity
            $item.signals.pykrx | Add-Member -NotePropertyName marketCapIntensity -NotePropertyValue $marketCapIntensity
            $item.signals.pykrx | Add-Member -NotePropertyName normalizedFlowAdjustment -NotePropertyValue $normalizedFlowAdjustment
            $item.signals.pykrx | Add-Member -NotePropertyName institutionQualityScore -NotePropertyValue $institutionQualityScore
            $item | Add-Member -Force -NotePropertyName institutionQualityScore -NotePropertyValue $institutionQualityScore
            $item.details += "pykrx 수급: 외국인·기관 5·20·60일 지속성과 거래대금·시가총액 대비 순매수 강도로 $([math]::Round([double]$signal.flowAdjustment + $normalizedFlowAdjustment, 1))점을 조정하고, 연기금·투신 매집 품질로 $([math]::Round($institutionQualityScore, 1))점을 반영하며, 공매도 거래·잔고 변화로 $([math]::Round([double]$signal.shortPenalty, 1))점을 감점했습니다."
            if ([double]$signal.flowAdjustment -ge 2) {
                $item.reasons = @($item.reasons + '중장기 수급 지속' | Select-Object -First 3)
            }
        } else {
            $item.signals | Add-Member -NotePropertyName pykrx -NotePropertyValue ([pscustomobject]@{
                available = $false
                status = $pykrx.status
            })
            $item.details += "pykrx 수급·공매도 데이터는 $($pykrx.status) 상태로 점수에 반영하지 않았습니다."
        }
        if (-not $item.PSObject.Properties['industryName']) {
            $item | Add-Member -NotePropertyName industryName -NotePropertyValue "업종코드 $($item.industryCode)"
        }
        $profitText = if ([double]$item.scoreBreakdown.earnings -ge 15) {
            '실적 전망이 양호하고'
        } elseif ([double]$item.scoreBreakdown.earnings -ge 8) {
            '실적 전망이 보통이며'
        } else {
            '실적 불확실성이 있으나'
        }
        $item | Add-Member -NotePropertyName companySummary -NotePropertyValue (
            "$($item.market) $($item.industryName) 기업으로, $profitText 수급·가격 추세를 종합 평가한 종목입니다."
        )
    }
    $sectorRotation = Get-SectorRotation @($all | Where-Object { $_ }) $indexChanges $executionTime
    $sectorByKey = @{}
    foreach ($sector in @($sectorRotation.sectors)) {
        $sectorByKey["$($sector.market)|$($sector.industryCode)"] = $sector
    }
    foreach ($item in @($all | Where-Object { $_ })) {
        $key = "$($item.market)|$($item.industryCode)"
        $sector = if ($sectorByKey.ContainsKey($key)) { $sectorByKey[$key] } else { $null }
        $sectorScore = if ($sector) { [double]$sector.score } else { 0 }
        $item | Add-Member -Force -NotePropertyName sectorRotationScore -NotePropertyValue $sectorScore
        $item | Add-Member -Force -NotePropertyName sectorRotationStatus -NotePropertyValue $(if ($sector) { $sector.status } else { 'unknown' })
        $item.signals | Add-Member -Force -NotePropertyName sectorRotationScore -NotePropertyValue $sectorScore
        $item.signals | Add-Member -Force -NotePropertyName sectorRotationStatus -NotePropertyValue $(if ($sector) { $sector.status } else { 'unknown' })
        $item.signals | Add-Member -Force -NotePropertyName sectorPersistenceScore -NotePropertyValue $(if ($sector) { [double]$sector.persistenceScore } else { 0 })
        $item | Add-Member -Force -NotePropertyName sectorPersistenceScore -NotePropertyValue $(if ($sector) { [double]$sector.persistenceScore } else { 0 })
        if ($sector -and $sector.rotationUp) {
            $item.reasons = @($item.reasons + '순환매 강세 전환 섹터' | Select-Object -First 3)
        }
        if ($sector) {
            $item.details += "섹터 순환매: $($sector.industryName) 섹터 점수 $($sector.score)점, 상태 $($sector.status), 지수 대비 상대강도 $($sector.relativeStrength)%입니다."
        }
    }
    Set-RecommendationProgress 'running' 'scoring' '점수 및 확률 계산' 82 '시장 국면 가중치와 상대가치 점수를 계산하고 있습니다.'
    $mediumUniverse = [System.Collections.Generic.List[object]]::new()
    $items = foreach ($market in @('KOSPI', 'KOSDAQ')) {
        $pool = @($all | Where-Object {
            $_.market -eq $market -and $_.liquid -and
                ($null -eq $_.targetUpside -or [double]$_.targetUpside -gt -10)
        })
        $scored = @($pool | ForEach-Object {
            $current = $_
            $industryPool = @($all | Where-Object {
                $current.industryCode -and $_.industryCode -eq $current.industryCode -and
                    $_.code -ne $current.code
            })
            $comparisonPool = if ($industryPool.Count -ge 3) { $industryPool } else { $pool }
            $medianPer = Get-Median @($comparisonPool | ForEach-Object { $_.per })
            $medianPbr = Get-Median @($comparisonPool | ForEach-Object { $_.pbr })
            $marketTrendMedian = Get-Median @($pool | ForEach-Object { [double]$_.signals.priceTrend + 100 })
            $industryTrendMedian = Get-Median @($comparisonPool | ForEach-Object {
                [double]$_.signals.priceTrend + 100
            })
            $relativeStrengthScore = if ($null -ne $marketTrendMedian -and $null -ne $industryTrendMedian) {
                $stockVsIndustry = ([double]$_.signals.priceTrend + 100 - $industryTrendMedian) / 5
                $industryVsMarket = ($industryTrendMedian - $marketTrendMedian) / 5
                [math]::Max(-3, [math]::Min(3, $stockVsIndustry * 0.5 + $industryVsMarket))
            } else { 0 }
            $valuationScore = ((Get-RelativeValueScore $_.per $medianPer) +
                (Get-RelativeValueScore $_.pbr $medianPbr)) / 2
            $fixedScore = [math]::Max(0, [math]::Min(100,
                $_.scoreBreakdown.earnings + $_.scoreBreakdown.reports +
                $_.scoreBreakdown.flow + $_.scoreBreakdown.trend +
                $relativeStrengthScore +
                $_.scoreBreakdown.industryMomentum + $_.scoreBreakdown.financial +
                $valuationScore + $_.scoreBreakdown.narrative - $_.scoreBreakdown.riskPenalty -
                $_.scoreBreakdown.technicalPenalty
            ))
            $weights = $marketRegime.weights
            $dynamicScore =
                ($_.scoreBreakdown.earnings + $_.scoreBreakdown.reports) * $weights.earningsReports +
                $_.scoreBreakdown.flow * $weights.flow +
                ($_.scoreBreakdown.trend + $relativeStrengthScore) * $weights.trend +
                $_.scoreBreakdown.industryMomentum * $weights.industry +
                ($_.scoreBreakdown.financial + $valuationScore) * $weights.financialValue +
                $_.scoreBreakdown.narrative * $weights.narrative -
                $_.scoreBreakdown.riskPenalty - $_.scoreBreakdown.technicalPenalty
            $_.score = [math]::Max(0, [math]::Min(100, $dynamicScore))
            $_ | Add-Member -NotePropertyName fixedScore -NotePropertyValue $fixedScore
            $_ | Add-Member -NotePropertyName valuationScore -NotePropertyValue $valuationScore
            $_ | Add-Member -NotePropertyName relativeStrengthScore -NotePropertyValue $relativeStrengthScore
            $threeDay = Get-CalibratedProbability $_.score 3 $marketRegime.name $executionTime
            $_ | Add-Member -NotePropertyName riseProbability -NotePropertyValue $threeDay.probability
            $_ | Add-Member -NotePropertyName probabilitySamples -NotePropertyValue $threeDay.samples
            $_ | Add-Member -NotePropertyName indexEntry -NotePropertyValue $indexEntries[$market]
            $shortTermScore = Get-ShortTermScore $_
            $_ | Add-Member -NotePropertyName shortTermScore -NotePropertyValue $shortTermScore
            $null = Add-IntegratedUpsideEvidence $_ $upsideEvidenceMap ([datetimeoffset]$executionTime)
            $_ | Add-Member -NotePropertyName legacyRiseProbability -NotePropertyValue $_.riseProbability
            $_.riseProbability = $null
            $medium = Get-MediumTermAssessment $_
            $_ | Add-Member -NotePropertyName mediumTerm -NotePropertyValue $medium
            $_ | Add-Member -NotePropertyName oneMonthScore -NotePropertyValue $medium.score
            $_ | Add-Member -NotePropertyName mediumTermScore -NotePropertyValue $medium.score
            $_ | Add-Member -NotePropertyName longTermScore -NotePropertyValue $medium.score
            $mediumUniverse.Add($_)
            if ($valuationScore -ge 6) {
                $label = if ($industryPool.Count -ge 3) { '동종 업종 대비 저평가' } else { '시장 후보군 대비 저평가' }
                $_.reasons = @($_.reasons + $label | Select-Object -First 3)
            }
            # 종합 서술문에 동종/시장 후보군 대비 밸류에이션 문장을 이어 붙임 (여기서만 medianPer/medianPbr 비교가 가능)
            $comparisonLabel = if ($industryPool.Count -ge 3) { '동종 업종' } else { '시장 후보군' }
            $valuationComment = if ($valuationScore -ge 6) {
                "$comparisonLabel 대비 PER·PBR이 낮게 형성되어 있어 밸류에이션 매력이 있습니다"
            } elseif ($valuationScore -le 2.5) {
                "$comparisonLabel 대비 PER·PBR이 높은 편이라 밸류에이션 부담이 있습니다"
            } else {
                "$comparisonLabel 대비 밸류에이션은 중립적인 수준입니다"
            }
            $perPbrText = "PER $(if ($_.per -gt 0) { "$([math]::Round($_.per,1))배" } else { '자료 부족' }), PBR $(if ($_.pbr -gt 0) { "$([math]::Round($_.pbr,1))배" } else { '자료 부족' })"
            $_.narrativeSummary = "$($_.narrativeSummary) $perPbrText 기준으로 $valuationComment."
            $_
        })
        $script:fixedShadowItems += @(Select-DiversifiedTop $scored 'fixedScore')
        Select-DiversifiedTop $scored 'selectionScore'
    }
    $strongSectorKeys = @($sectorRotation.sectors | Where-Object { $_.status -eq 'strong' -or $_.rotationUp } |
        ForEach-Object { "$($_.market)|$($_.industryCode)" } | Select-Object -Unique)
    $sectorRotation.leaders = @($strongSectorKeys | ForEach-Object {
        $key = $_
        $sector = $sectorByKey[$key]
        $leaders = @($items | Where-Object { "$($_.market)|$($_.industryCode)" -eq $key } |
            Sort-Object shortTermScore -Descending | Select-Object -First 5)
        if ($leaders.Count) {
            [pscustomobject]@{
                market = $sector.market
                industryCode = $sector.industryCode
                industryName = $sector.industryName
                sectorScore = $sector.score
                status = $sector.status
                rotationUp = $sector.rotationUp
                stocks = @($leaders | ForEach-Object {
                    [pscustomobject]@{
                        code = $_.code
                        name = $_.name
                        shortTermScore = $_.shortTermScore
            oneMonthScore = $_.oneMonthScore
                        intradayReturn = $_.signals.intradayReturn
                        transactionValueIncrease = $_.signals.transactionValueIncrease
                        relativeStrengthScore = $_.relativeStrengthScore
                    }
                })
            }
        }
    })
    if (@($items | Where-Object market -eq 'KOSPI').Count -lt 10 -or
        @($items | Where-Object market -eq 'KOSDAQ').Count -lt 10) {
        throw '필수 데이터와 유동성 기준을 통과한 종목을 시장별 10개 확보하지 못했습니다.'
    }
    Set-RecommendationProgress 'running' 'selection' 'TOP10·TOP3 선정' 94 '시장별 추천 종목과 AI TOP3를 선정하고 있습니다.'
    $recommendationDate = [string](@($items | Select-Object -First 1).tradingDate)
    if (-not $recommendationDate) { throw 'Latest trading date is missing.' }
    $top3Pool = @($items | Where-Object {
        $_.signals.pykrx.available -and [double]$_.signals.averageTradingValue -ge 100 -and
            ([double]$_.signals.currentTradingValue -ge 100 -or [double]$_.signals.transactionValueIncrease -ge 80 -or $_.signals.volumeSurge -or $_.signals.boxBreakout) -and
            [double]$_.signals.rsi -ge 38 -and [double]$_.signals.rsi -lt 80 -and
            [double]$_.signals.twentyDayRise -lt 22 -and [double]$_.signals.ma20Deviation -lt 13 -and [double]$_.signals.openingGapRate -lt 6 -and [double]$_.signals.intradayReturn -lt 12 -and
            $_.sectorRotationStatus -in @('strong', 'neutral')
    })
    $top3SelectionTier = 'short-term-full-evidence'
    if ($top3Pool.Count -lt 3) {
        $top3Pool = @($items | Where-Object {
            $_.signals.pykrx.available -and [double]$_.signals.averageTradingValue -ge 50 -and
                ([double]$_.signals.transactionValueIncrease -ge 30 -or $_.signals.volumeSurge -or $_.signals.boxBreakout -or [double]$_.relativeStrengthScore -gt 0) -and
                [double]$_.signals.rsi -lt 80 -and [double]$_.signals.ma20Deviation -lt 15 -and [double]$_.signals.openingGapRate -lt 8 -and
                [double]$_.signals.twentyDayRise -lt 28 -and [double]$_.signals.intradayReturn -lt 15
        })
        $top3SelectionTier = 'short-term-partial-evidence'
    }
    if ($top3Pool.Count -lt 3) {
        $top3Pool = @($items)
        $top3SelectionTier = 'score-fallback'
    }
    if ($marketRegime.name -eq '약세') {
        $defensivePool = @($top3Pool | Where-Object {
            [double]$_.signals.averageTradingValue -ge 100 -and
                [double]$_.signals.rsi -ge 38 -and [double]$_.signals.rsi -lt 72 -and
                [double]$_.signals.ma20Deviation -lt 10 -and
                [double]$_.signals.openingGapRate -lt 4 -and
                [double]$_.signals.intradayReturn -lt 8 -and
                $_.sectorRotationStatus -eq 'strong'
        })
        if ($defensivePool.Count -ge 3) {
            $top3Pool = $defensivePool
            $top3SelectionTier = "$top3SelectionTier-defensive-market-guard"
        }
    } elseif ($marketRegime.name -eq '중립') {
        $neutralGuardPool = @($top3Pool | Where-Object {
            [double]$_.signals.rsi -lt 75 -and
                [double]$_.signals.ma20Deviation -lt 12 -and
                [double]$_.signals.intradayReturn -lt 10
        })
        if ($neutralGuardPool.Count -ge 3) {
            $top3Pool = $neutralGuardPool
            $top3SelectionTier = "$top3SelectionTier-neutral-overheat-guard"
        }
    }
    $rotationPool = @($top3Pool | Where-Object { $_.sectorRotationStatus -in @('strong', 'neutral') })
    if ($rotationPool.Count -ge 3) {
        $top3Pool = $rotationPool
        $top3SelectionTier = "$top3SelectionTier-sector-rotation"
    }
    $scorePriorityPool = @($items | Where-Object {
        [double]$_.shortTermScore -ge 45 -and
            [double]$_.signals.averageTradingValue -ge 100 -and
            [double]$_.signals.rsi -lt 80 -and
            [double]$_.signals.ma20Deviation -lt 18 -and
            [double]$_.signals.openingGapRate -lt 8 -and
            [double]$_.signals.intradayReturn -lt 12 -and
            $_.sectorRotationStatus -in @('strong', 'neutral')
    })
    if ($scorePriorityPool.Count -gt 0) {
        $top3Pool = @(@($scorePriorityPool) + @($top3Pool) | Sort-Object code -Unique)
        $top3SelectionTier = "$top3SelectionTier-score-priority"
    }
    $top3 = @(Select-RiskDiversifiedTop $top3Pool | ForEach-Object -Begin { $rank = 0 } -Process {
        $rank++
        $probability = $null
        $plannedEntryPrice = [double]$_.entryPrice
        $targetUpsideRate = if ($null -ne $_.targetUpside -and [double]$_.targetUpside -gt 3) {
            [math]::Max(2.5, [math]::Min(8, [double]$_.targetUpside / 3))
        } else { 4.0 }
        $targetPrice = [math]::Round([double]$_.entryPrice * (1 + $targetUpsideRate / 100), 0)
        $targetPrice = [math]::Max($targetPrice, [math]::Round($plannedEntryPrice * 1.02, 0))
        $maxEntryGapRate = 2.5
        $maxEntryPrice = [math]::Round($plannedEntryPrice * (1 + $maxEntryGapRate / 100), 0)
        $shortTermVolatility = if ($_.signals.PSObject.Properties['shortTermVolatility']) { [double]$_.signals.shortTermVolatility } else { 2.0 }
        $stopRate = [math]::Round([math]::Max(2.8, [math]::Min(5.5, $shortTermVolatility * 1.35)), 2)
        if ([double]$_.signals.ma20Deviation -ge 10 -or [double]$_.signals.intradayReturn -ge 8) {
            $stopRate = [math]::Min($stopRate, 4.2)
        }
        $stopPrice = [math]::Round($plannedEntryPrice * (1 - $stopRate / 100), 0)
        $entryBlockers = @()
        $entryBlockers += @($_.upsideEvidence.blockers)
        $entryWarnings = @()
        if ([double]$_.shortTermScore -lt 45) { $entryBlockers += "단기 점수 부족($([math]::Round([double]$_.shortTermScore, 1))<45)" }
        if (-not $_.signals.pykrx.available) { $entryWarnings += 'pykrx 수급 미확인' }
        elseif ($pykrx.status -like 'cached*') { $entryWarnings += 'pykrx 캐시 사용' }
        if ($null -eq $_.signals.pykrx.shortRatio5) { $entryWarnings += '공매도 거래비중 미확인' }
        if ($null -eq $_.signals.pykrx.shortBalanceRatio) { $entryWarnings += '공매도 순보유잔고 미확인' }
        if (-not $_.signals.pykrx.securitiesLendingAvailable) { $entryWarnings += '대차잔고 미수집' }
        if ($marketRegime.name -eq '약세') { $entryWarnings += "시장 국면 $($marketRegime.name)" }
        elseif ($marketRegime.name -ne '강세') { $entryWarnings += "시장 국면 $($marketRegime.name)" }
        if ($_.sectorRotationStatus -eq 'weak') { $entryBlockers += "섹터 $($_.sectorRotationStatus)" }
        elseif ($_.sectorRotationStatus -ne 'strong') { $entryWarnings += "섹터 $($_.sectorRotationStatus)" }
        if ([double]$_.signals.rsi -ge 80) { $entryBlockers += "RSI 극단 과열($([math]::Round([double]$_.signals.rsi, 1)))" }
        elseif ([double]$_.signals.rsi -ge 75) { $entryWarnings += "RSI 과열 주의($([math]::Round([double]$_.signals.rsi, 1)))" }
        if ([double]$_.signals.ma20Deviation -ge 18) { $entryBlockers += "20일선 이격 극단($([math]::Round([double]$_.signals.ma20Deviation, 1))%)" }
        elseif ([double]$_.signals.ma20Deviation -ge 10) { $entryWarnings += "20일선 이격 주의($([math]::Round([double]$_.signals.ma20Deviation, 1))%)" }
        if ([double]$_.signals.intradayReturn -ge 12) { $entryBlockers += "장중 급등 과다($([math]::Round([double]$_.signals.intradayReturn, 1))%)" }
        elseif ([double]$_.signals.intradayReturn -ge 8) { $entryWarnings += "장중 급등 주의($([math]::Round([double]$_.signals.intradayReturn, 1))%)" }
        if ([double]$_.signals.averageTradingValue -lt 100) { $entryBlockers += "거래대금 부족($([math]::Round([double]$_.signals.averageTradingValue, 1))억)" }
        $entryRisk = Get-EntryRisk $_ $targetUpsideRate $stopRate
        $entryBlockers += @($entryRisk.blockers)
        $activeEntry = [double]$_.shortTermScore -ge 45 -and $entryBlockers.Count -eq 0
        $activationRequirements = @()
        if ([double]$_.shortTermScore -lt 45) { $activationRequirements += "단기 점수 +$([math]::Round(45 - [double]$_.shortTermScore, 1))점 이상 개선" }
        if ($_.sectorRotationStatus -eq 'weak') { $activationRequirements += '섹터 순환매 neutral 이상 회복' }
        if ([double]$_.signals.ma20Deviation -ge 18) { $activationRequirements += '20일선 이격 18% 미만 완화' }
        if ([double]$_.signals.rsi -ge 80) { $activationRequirements += 'RSI 80 미만 완화' }
        if ([double]$_.signals.intradayReturn -ge 12) { $activationRequirements += '장중 상승률 12% 미만 완화' }
        $scoreDiagnostics = [pscustomobject]@{
            shortTermScore = $_.shortTermScore
            threshold = 45
            marketRegime = $marketRegime.name
            pykrxStatus = $pykrx.status
            sectorRotationStatus = $_.sectorRotationStatus
            rsi = $_.signals.rsi
            ma20Deviation = $_.signals.ma20Deviation
            intradayReturn = $_.signals.intradayReturn
            averageTradingValue = $_.signals.averageTradingValue
        }
        $strategy = Get-StrategyClassification $_ $marketRegime
        [pscustomobject]@{
            recommendationDate = $recommendationDate
            recommendationTime = $executionTime.ToString('HH:mm:ss')
            recordedAt = $executionTime.ToString('o')
            runId = $script:activeRunId
            entryPolicyVersion = $entryRisk.policyVersion
            netRewardRisk = $entryRisk.netRewardRisk
            stressedRewardRisk = $entryRisk.stressedRewardRisk
            costStressMultiplier = $entryRisk.costStressMultiplier
            minimumRewardRisk = $entryRisk.minimumRewardRisk
            rank = $rank
            market = $_.market
            marketCap = $_.marketCap
            industryName = $_.industryName
            companySummary = $_.companySummary
            code = $_.code
            name = $_.name
            openPrice = $_.openPrice
            previousClose = $_.previousClose
            recommendationPrice = $_.entryPrice
            plannedEntryPrice = $plannedEntryPrice
            maxEntryPrice = $maxEntryPrice
            maxEntryGapRate = $maxEntryGapRate
            virtualEntryPrice = $null
            entryMethod = if ($activeEntry) { 'next-trading-day-open-if-within-entry-band' } elseif ([double]$_.shortTermScore -ge 45) { 'watchlist-blocked-entry' } else { 'watchlist-low-confidence' }
            entryRule = if ($activeEntry) { "다음 거래일 시가가 추천가 대비 +$maxEntryGapRate% 이내일 때만 진입" } elseif ([double]$_.shortTermScore -ge 45) { '진입 차단 사유 해소 전 관망 후보' } else { '단기 점수 45점 미만으로 관망 후보' }
            entryStatus = if ($activeEntry) { 'pending' } else { 'watchlist' }
            entryBlockers = $entryBlockers
            upsideEvidence = $_.upsideEvidence
            selectionScore = $_.selectionScore
            entryWarnings = $entryWarnings
            activationRequirements = $activationRequirements
            scoreDiagnostics = $scoreDiagnostics
            strategyEngine = $strategy.primary
            strategyAction = $strategy.action
            strategyTags = $strategy.tags
            strategyScores = $strategy.scores
            secondaryStrategies = $strategy.secondary
            targetPrice = $targetPrice
            targetUpsideRate = $targetUpsideRate
            stopPrice = $stopPrice
            stopRate = $stopRate
            stopMethod = 'recent-10d-volatility'
            shortTermVolatility = $shortTermVolatility
            riseProbability = $probability
            probabilityType = 'unvalidated-integrated-policy'
            scoringFormulaVersion = 'short-term-v5-governed-evidence'
            score = $_.score
            shortTermScore = $_.shortTermScore
            oneMonthScore = $_.oneMonthScore
            mediumTermScore = $_.mediumTermScore
            shortTermProbability = $_.riseProbability
            shortTermSamples = $_.probabilitySamples
            averageTradingValue = $_.signals.averageTradingValue
            volumeSurge = $_.signals.volumeSurge
            financeMode = $_.signals.financeMode
            quarterProfitGrowth = $_.signals.quarterProfitGrowth
            ma20Deviation = $_.signals.ma20Deviation
            rsi = $_.signals.rsi
            twentyDayRise = $_.signals.twentyDayRise
            sectorRotationScore = $_.sectorRotationScore
            sectorRotationStatus = $_.sectorRotationStatus
            sectorPersistenceScore = $_.sectorPersistenceScore
            consensusTrendScore = $_.consensusTrendScore
            institutionQualityScore = if ($_.PSObject.Properties['institutionQualityScore']) { $_.institutionQualityScore } else { $null }
            selectionTier = $top3SelectionTier
            indexEntry = $_.indexEntry
            reasons = @($_.reasons)
            dataAsOf = $_.dataAsOf
            sourceQuality = $_.signals.sourceQuality
            flowSource = $_.signals.pykrx
        }
    })
    $activeTop3 = @($top3 | Where-Object { $_.entryStatus -ne 'watchlist' })
    $watchTop3 = @($top3 | Where-Object { $_.entryStatus -eq 'watchlist' })
    $blockerSummary = @($top3 | ForEach-Object {
        foreach ($blocker in @($_.entryBlockers | Where-Object { $_ })) {
            [pscustomobject]@{ reason = $blocker }
        }
    } | Group-Object reason | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
        [pscustomobject]@{ reason = $_.Name; count = $_.Count }
    })
    $entrySummary = [pscustomobject]@{
        activeCount = $activeTop3.Count
        watchlistCount = $watchTop3.Count
        decision = if ($activeTop3.Count -gt 0) { 'active-entry-candidates' } else { 'no-active-entry' }
        message = if ($activeTop3.Count -gt 0) { "진입 대기 $($activeTop3.Count)개, 관망 $($watchTop3.Count)개" } else { '현재 기준 실제 매수 진입 후보 없음' }
        blockerSummary = $blockerSummary
    }
    $scorePassItems = @($items | Where-Object { [double]$_.shortTermScore -ge 45 })
    $strongSectorItems = @($items | Where-Object { $_.sectorRotationStatus -eq 'strong' })
    $nonOverheatedItems = @($items | Where-Object {
        [double]$_.signals.rsi -lt 75 -and
            [double]$_.signals.ma20Deviation -lt 10 -and
            [double]$_.signals.intradayReturn -lt 8
    })
    $entryReadyItems = @($items | Where-Object {
        [double]$_.shortTermScore -ge 45 -and
            $_.sectorRotationStatus -ne 'weak' -and
            [double]$_.signals.rsi -lt 80 -and
            [double]$_.signals.ma20Deviation -lt 18 -and
            [double]$_.signals.intradayReturn -lt 12 -and
            [double]$_.signals.averageTradingValue -ge 100 -and
            (Get-EntryRisk $_ $(if ($null -ne $_.targetUpside -and [double]$_.targetUpside -gt 3) { [math]::Max(2.5, [math]::Min(8, [double]$_.targetUpside / 3)) } else { 4.0 }) $(
                $vol = if ($_.signals.PSObject.Properties['shortTermVolatility']) { [double]$_.signals.shortTermVolatility } else { 2.0 }
                $stop = [math]::Round([math]::Max(2.8, [math]::Min(5.5, $vol * 1.35)), 2)
                if ([double]$_.signals.ma20Deviation -ge 10 -or [double]$_.signals.intradayReturn -ge 8) { $stop = [math]::Min($stop, 4.2) }
                $stop
            )).blockers.Count -eq 0
    })
    $rankedByShortTermScore = @($items | Sort-Object shortTermScore -Descending)
    $bestShortTermScore = if ($rankedByShortTermScore.Count) { [double]$rankedByShortTermScore[0].shortTermScore } else { 0.0 }
    $averageShortTermScore = if (@($items).Count) {
        [math]::Round((@($items | ForEach-Object { [double]$_.shortTermScore }) | Measure-Object -Average).Average, 2)
    } else { 0.0 }
    $nearMissItems = @($rankedByShortTermScore | Select-Object -First 5 | ForEach-Object {
        $hints = @()
        if ([double]$_.shortTermScore -lt 45) { $hints += "점수 +$([math]::Round(45 - [double]$_.shortTermScore, 1))" }
        if ($_.sectorRotationStatus -ne 'strong') { $hints += '섹터 strong 전환' }
        if ([double]$_.signals.ma20Deviation -ge 10) { $hints += '이격 완화' }
        if ([double]$_.signals.rsi -ge 75) { $hints += 'RSI 완화' }
        if ($pykrx.status -like 'cached*') { $hints += '수급 최신화' }
        [pscustomobject]@{
            code = $_.code
            name = $_.name
            shortTermScore = $_.shortTermScore
            scoreGap = [math]::Round([math]::Max(0, 45 - [double]$_.shortTermScore), 2)
            sectorRotationStatus = $_.sectorRotationStatus
            activationHints = $hints
        }
    })
    $entryGateSummary = [pscustomobject]@{
        totalCandidates = @($items).Count
        scorePassCount = $scorePassItems.Count
        strongSectorCount = $strongSectorItems.Count
        nonOverheatedCount = $nonOverheatedItems.Count
        entryReadyCount = $entryReadyItems.Count
        bestShortTermScore = $bestShortTermScore
        averageShortTermScore = $averageShortTermScore
        scoreThreshold = 45
        bestScoreGap = [math]::Round([math]::Max(0, 45 - $bestShortTermScore), 2)
        nearMisses = $nearMissItems
    }
    [object[]]$top3History = if (Test-Path -LiteralPath $top3HistoryPath) {
        [object[]](Get-Content -Raw -LiteralPath $top3HistoryPath -Encoding UTF8 | ConvertFrom-Json)
    } else { @() }
    $top3Date = $recommendationDate
    $executionDate = $executionTime.ToString('yyyy-MM-dd')
    if ($executionDate -ne $top3Date) {
        $cleanedTop3History = @($top3History | Where-Object recommendationDate -ne $executionDate)
        if ($cleanedTop3History.Count -ne $top3History.Count) {
            $top3History = $cleanedTop3History
            Write-JsonAtomic $top3HistoryPath $top3History 8
        }
    }
    $savedToday = @($top3History | Where-Object recommendationDate -eq $top3Date)
    $result = @{
        generatedAt = $executionTime.ToString('yyyy-MM-dd HH:mm:ss')
        recommendationDate = $recommendationDate
        dataAsOf = $executionTime.ToString('o')
        dataSourceMode = 'realtime-first'
        snapshotCaptured = $true
        historicalReplaySafe = $false
        pitLevel = 'derived-snapshot'
        snapshotSchemaVersion = 1
        scoringFormulaVersion = 'short-term-v5-governed-evidence'
        governance = Get-RecommendationGovernance @($all|Where-Object {$_ -and $_.code}) @($items) $candidateTotal @($collectionFailures.ToArray()) $modelManifest (Get-ModelManifest $PSScriptRoot)
        generatedAtISO = ([datetimeoffset]$executionTime).ToString('o')
        candidateUniverse = $script:candidateUniverse
        pykrx = [pscustomobject]@{
            available = [bool]$pykrx.available
            status = $pykrx.status
        }
        marketRegime = $marketRegime
        marketIndexes = $marketIndexes
        sectorRotation = $sectorRotation
        primaryHorizon = '1-3-months'
        mediumTerm = [pscustomobject]@{
            formulaVersion='medium-term-v1';productionEnabled=$false;validationStatus='not-evaluated'
            horizonTradingDays=@(20,40,60)
            items=@(Select-MediumTermCandidates @($mediumUniverse.ToArray()))
        }
        items = @($items)
        fixedItems = @($script:fixedShadowItems)
        top3 = $top3
        top3SelectionTier = $top3SelectionTier
        entrySummary = $entrySummary
        entryGateSummary = $entryGateSummary
    }
    $directory = Split-Path -Parent $recommendationPath
    if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    Set-RecommendationProgress 'running' 'saving' '결과 저장' 97 '추천 스냅숏과 검증 데이터를 저장하고 있습니다.'
    $mediumSnapshotDir=Join-Path $projectRoot 'reports\medium-term-snapshots'
    New-Item -ItemType Directory -Path $mediumSnapshotDir -Force | Out-Null
    $mediumSnapshotPath=Join-Path $mediumSnapshotDir "$($script:activeRunId).json"
    if(Test-Path -LiteralPath $mediumSnapshotPath){throw 'Medium-term snapshot already exists'}
    Write-JsonAtomic $mediumSnapshotPath ([ordered]@{
        generatedAt=([datetimeoffset]$executionTime).ToString('o');recommendationDate=$recommendationDate
        formulaVersion='medium-term-v1';productionEnabled=$false
        items=@($result.mediumTerm.items);costAssumptionBps=30;entryConvention='next-session-open'
    }) 12
    $result.mediumTerm | Add-Member -NotePropertyName validation -NotePropertyValue (Update-MediumTermValidation $mediumSnapshotDir)
    Write-JsonAtomic $recommendationPath $result 12
    $pitDateDirectory = Join-Path $pitSnapshotRoot ($recommendationDate -replace '-', '')
    if (-not (Test-Path -LiteralPath $pitDateDirectory)) {
        New-Item -ItemType Directory -Path $pitDateDirectory -Force | Out-Null
    }
    Write-JsonAtomic (Join-Path $pitDateDirectory "$($script:activeRunId).json") $result 8
    [object[]]$runs = if (Test-Path -LiteralPath $recommendationRunsPath) {
        [object[]](Get-Content -Raw -LiteralPath $recommendationRunsPath -Encoding UTF8 | ConvertFrom-Json)
    } else { @() }
    $runs = @((@($runs) + @($result)) | Select-Object -Last 365)
    Write-JsonAtomic $recommendationRunsPath $runs 8
    $top3History = @($top3History | Where-Object recommendationDate -ne $top3Date) + @($top3)
    Write-JsonAtomic $top3HistoryPath $top3History 8
    if (Test-Path -LiteralPath $pykrxPythonPath) {
        & $pykrxPythonPath $top3StorePath recommendations $top3HistoryPath $top3DatabasePath
        if ($LASTEXITCODE -ne 0) { throw 'AI TOP3 database save failed.' }
    }
    [object[]]$history = if (Test-Path -LiteralPath $recommendationHistoryPath) {
        [object[]](Get-Content -Raw -LiteralPath $recommendationHistoryPath -Encoding UTF8 | ConvertFrom-Json)
    } else { @() }
    $date = $recommendationDate
    $history = @($history | Where-Object {
        $_.date -ne $date -and ($executionDate -eq $date -or $_.date -ne $executionDate)
    }) +
        @($items | ForEach-Object {
            [pscustomobject]@{
                date = $date
                recordedAt = $executionTime.ToString('o')
                runId = $script:activeRunId
                market = $_.market
                code = $_.code
                name = $_.name
                entryPrice = $_.entryPrice
                targetUpside = $_.targetUpside
                score = $_.score
                fixedScore = $_.fixedScore
                shortTermScore = $_.shortTermScore
            oneMonthScore = $_.oneMonthScore
                mediumTermScore = $_.mediumTermScore
                sectorRotationScore = $_.sectorRotationScore
                sectorRotationStatus = $_.sectorRotationStatus
                sectorPersistenceScore = $_.sectorPersistenceScore
                consensusTrendScore = $_.consensusTrendScore
                institutionQualityScore = if ($_.PSObject.Properties['institutionQualityScore']) { $_.institutionQualityScore } else { $null }
                themeScore = if ($_.PSObject.Properties['themeScore']) { $_.themeScore } else { $null }
                themeTags = if ($_.PSObject.Properties['themeTags']) { $_.themeTags } else { @() }
                qualityScore = if ($_.PSObject.Properties['qualityScore']) { $_.qualityScore } else { $null }
                roe = if ($_.PSObject.Properties['roe']) { $_.roe } else { $null }
                operatingMargin = if ($_.PSObject.Properties['operatingMargin']) { $_.operatingMargin } else { $null }
                fcf = if ($_.PSObject.Properties['fcf']) { $_.fcf } else { $null }
                macdSignalScore = if ($_.PSObject.Properties['macdSignalScore']) { $_.macdSignalScore } else { $null }
                disclosureCatalystScore = if ($_.PSObject.Properties['disclosureCatalystScore']) { $_.disclosureCatalystScore } else { $null }
                disclosureCatalysts = if ($_.PSObject.Properties['disclosureCatalysts']) { $_.disclosureCatalysts } else { @() }
                marketRegime = $marketRegime.name
                model = 'dynamic'
                indexEntry = $_.indexEntry
                industryCode = $_.industryCode
                dataAsOf = $_.dataAsOf
            }
        }) +
        @($script:fixedShadowItems | ForEach-Object {
            [pscustomobject]@{
                date = $date
                recordedAt = $executionTime.ToString('o')
                runId = $script:activeRunId
                market = $_.market
                code = $_.code
                name = $_.name
                entryPrice = $_.entryPrice
                targetUpside = $_.targetUpside
                score = $_.fixedScore
                fixedScore = $_.fixedScore
                shortTermScore = $_.shortTermScore
            oneMonthScore = $_.oneMonthScore
                mediumTermScore = $_.mediumTermScore
                sectorRotationScore = $_.sectorRotationScore
                sectorRotationStatus = $_.sectorRotationStatus
                sectorPersistenceScore = $_.sectorPersistenceScore
                consensusTrendScore = $_.consensusTrendScore
                institutionQualityScore = if ($_.PSObject.Properties['institutionQualityScore']) { $_.institutionQualityScore } else { $null }
                themeScore = if ($_.PSObject.Properties['themeScore']) { $_.themeScore } else { $null }
                themeTags = if ($_.PSObject.Properties['themeTags']) { $_.themeTags } else { @() }
                qualityScore = if ($_.PSObject.Properties['qualityScore']) { $_.qualityScore } else { $null }
                roe = if ($_.PSObject.Properties['roe']) { $_.roe } else { $null }
                operatingMargin = if ($_.PSObject.Properties['operatingMargin']) { $_.operatingMargin } else { $null }
                fcf = if ($_.PSObject.Properties['fcf']) { $_.fcf } else { $null }
                macdSignalScore = if ($_.PSObject.Properties['macdSignalScore']) { $_.macdSignalScore } else { $null }
                disclosureCatalystScore = if ($_.PSObject.Properties['disclosureCatalystScore']) { $_.disclosureCatalystScore } else { $null }
                disclosureCatalysts = if ($_.PSObject.Properties['disclosureCatalysts']) { $_.disclosureCatalysts } else { @() }
                marketRegime = $marketRegime.name
                model = 'fixed'
                indexEntry = $_.indexEntry
                industryCode = $_.industryCode
                dataAsOf = $_.dataAsOf
            }
        })
    Write-JsonAtomic $recommendationHistoryPath $history 6
    $target10Script = Join-Path $PSScriptRoot 'target10.py'
    $target10Output = Join-Path $projectRoot 'reports\target10\latest.json'
    if ((Test-Path -LiteralPath $pykrxPythonPath) -and (Test-Path -LiteralPath $target10Script)) {
        & $pykrxPythonPath $target10Script predict | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if (-not (Test-Path (Split-Path $target10Output))) { New-Item -ItemType Directory -Path (Split-Path $target10Output) -Force | Out-Null }
            Write-JsonAtomic $target10Output @{ status='forecast-failed'; productionEnabled=$false; items=@() } 4
        }
    }
    Set-RecommendationProgress 'completed' 'completed' '추천 분석 완료' 100 '추천 분석과 결과 저장이 완료되었습니다.' $candidateTotal $candidateTotal
    return $result
}


function Get-LatestRecommendations([bool]$Refresh = $false) {
    if ($Refresh -or -not (Test-Path -LiteralPath $recommendationPath)) { return New-WebRecommendations }
    return Get-Content -Raw -LiteralPath $recommendationPath -Encoding UTF8 | ConvertFrom-Json
}

function Get-RecommendationProgress {
    if (Test-Path -LiteralPath $progressPath) { return Get-Content -Raw -LiteralPath $progressPath -Encoding UTF8 | ConvertFrom-Json }
    return [pscustomobject]@{ runId=$null; status='idle'; stage='idle'; stageName='대기'; percent=0; completed=0; total=0; updatedAt=$null; message='실행 중인 추천 분석이 없습니다.' }
}

function Get-Top3Validation {
    if (Test-Path -LiteralPath $top3ValidationPath) { return Get-Content -Raw -LiteralPath $top3ValidationPath -Encoding UTF8 | ConvertFrom-Json }
    return [pscustomobject]@{ statistics=[pscustomobject]@{}; items=@() }
}

function Get-Target10Forecast {
    $path = Join-Path $projectRoot 'reports\target10\latest.json'
    if (Test-Path -LiteralPath $path) {
        $forecast = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
        $currentHash = (Get-FileHash -LiteralPath $recommendationPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $forecastAge = if ($forecast.generatedAt) { ([datetimeoffset]::Now - [datetimeoffset]$forecast.generatedAt).TotalHours } else { 25 }
        if ($forecast.sourceSnapshotHash -eq $currentHash -and $forecastAge -ge 0 -and $forecastAge -le 24) { return $forecast }
        return @{ status='stale-source'; productionEnabled=$false; items=@() }
    }
    return @{ status='not-evaluated'; productionEnabled=$false; items=@() }
}

function Get-IndependentUpsideReport {
    $path = Join-Path $projectRoot 'reports\independent-upside\latest.json'
    if (Test-Path -LiteralPath $path) {
        $report = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
        $age = if ($report.generatedAt) { ([datetimeoffset]::Now - [datetimeoffset]$report.generatedAt).TotalHours } else { 25 }
        if ($age -ge 0 -and $age -le 24) { return $report }
        return @{ status='stale-source'; productionEnabled=$false; items=@() }
    }
    return @{ status='not-collected'; productionEnabled=$false; items=@() }
}

function Get-Top3History([string]$Date = '') {
    $history = if (Test-Path -LiteralPath $top3HistoryPath) { [object[]](Get-Content -Raw -LiteralPath $top3HistoryPath -Encoding UTF8 | ConvertFrom-Json) } else { @() }
    $availableDates = @($history | ForEach-Object recommendationDate | Where-Object { $_ } | Sort-Object -Descending -Unique)
    if (-not $Date) { $Date = [string](@($availableDates | Select-Object -First 1)) }
    return [pscustomobject]@{ date=$Date; availableDates=$availableDates; recommendations=@($history | Where-Object recommendationDate -eq $Date | Sort-Object rank); performance=@((Get-Top3Validation).items | Where-Object recommendationDate -eq $Date) }
}

function Get-DashboardHtml {
    return @'
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TopPicks 투자 대시보드</title>
<style>
:root{--bg:#f3f5f9;--panel:#fff;--line:#dce3ed;--text:#18263b;--muted:#596b82;--green:#087b59;--red:#bb3535;--soft:#f6f8fb;--navy:#172d4b;--accent:#225ad2}
*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:90px}body{margin:0;background:var(--bg);color:var(--text);font-family:"Segoe UI","Malgun Gothic",sans-serif;font-size:15px;line-height:1.6}button,a{ -webkit-tap-highlight-color:transparent}button{font:inherit;cursor:pointer;border:1px solid #c6d2e3;background:white;color:var(--text);border-radius:10px;padding:11px 18px;font-weight:700}button:hover{background:#eef3ff;border-color:#225ad2}button:focus-visible,a:focus-visible,summary:focus-visible,.clickrow:focus-visible{outline:3px solid #528bff;outline-offset:3px}.shell{max-width:1560px;margin:auto;padding:30px 36px 64px}.topbar{display:flex;align-items:center;justify-content:space-between;gap:24px;margin-bottom:24px}.brandline{display:flex;align-items:center;gap:12px}.mark{display:inline-flex;align-items:center;justify-content:center;background:var(--navy);color:white;border-radius:10px;font-size:13px;font-weight:800;width:42px;height:42px}.brand h1{font-size:30px;letter-spacing:-1px;margin:0;line-height:1.3}.brand .sub{font-size:13px;color:var(--muted);margin-top:8px}.live{font-size:12px;color:#835315;background:#fff3d8;border:1px solid #eed4a6;padding:3px 9px;border-radius:6px;font-weight:700}.live-dot{display:none}.topbar>button{background:var(--accent);color:white;border-color:var(--accent);white-space:nowrap}.section-nav{position:sticky;top:0;z-index:5;display:flex;gap:8px;background:rgba(243,245,249,.97);border-bottom:1px solid var(--line);padding:12px 0;margin:18px 0 24px}.section-nav a{text-decoration:none;color:var(--muted);font-weight:700;font-size:14px;padding:9px 16px;border-radius:8px}.section-nav a:hover,.section-nav a:first-child{background:#e5edfd;color:#194bb5}.notice{padding:14px 18px;border:1px solid #d5dfef;border-left:4px solid var(--accent);background:#edf3ff;border-radius:8px;margin-bottom:20px;color:#354d70;font-size:14px}.statusbar-row{margin:0}.statusbar{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}.metric{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px 20px;min-height:112px}.metric .k{color:var(--muted);font-size:13px;font-weight:600}.metric .v{font-size:27px;font-weight:750;line-height:1.3;margin:5px 0;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}.metric .s{color:var(--muted);font-size:12px;overflow-wrap:anywhere}.flow-layout{display:flex;flex-direction:column;gap:28px}.panel{min-width:0;background:white;border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:0 3px 10px #22375405}.panel h2{margin:0;padding:24px 26px 4px;font-size:22px;letter-spacing:-.5px;font-weight:750}.panel-body{padding:18px 26px}.section-description{margin:0;padding:4px 26px 22px;color:var(--muted);font-size:14px}.section-kicker{font-size:12px;font-weight:750;color:var(--accent);letter-spacing:1px;display:block;margin-bottom:3px}.scroll{overflow-x:auto}table{width:100%;border-collapse:collapse;table-layout:auto;min-width:1080px}th,td{padding:18px 16px;border-bottom:1px solid #e7ecf3;text-align:left;vertical-align:middle;white-space:nowrap}th{font-size:13px;font-weight:700;background:#f5f7fb;color:#4d6078;padding-top:14px;padding-bottom:14px;border-top:1px solid var(--line);border-bottom:1px solid var(--line)}td:first-child,th:first-child{padding-left:26px}td:last-child,th:last-child{padding-right:26px}tbody tr:last-child td{border-bottom:0}td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}.tbl-short td:nth-child(4){white-space:normal;min-width:230px;max-width:340px;line-height:1.65}.name{font-size:17px;font-weight:750;line-height:1.5;white-space:normal;min-width:145px}.code{font-size:12px;color:var(--muted);margin-top:4px;white-space:normal}.score{display:inline-block;min-width:64px;padding:5px 10px;font-size:21px;font-weight:750;line-height:1.4;background:#edf3ff;color:#204d9b;border-radius:8px;font-variant-numeric:tabular-nums}.badge{display:inline-flex;align-items:center;justify-content:center;white-space:nowrap;border-radius:6px;padding:5px 10px;font-size:13px;font-weight:700;border:1px solid transparent}.b-buy{background:#e6f5ee;color:#086844;border-color:#b4ddc9}.b-watch,.b-neutral{background:#f0f3f8;color:#4b5f77;border-color:#d9e1ec}.b-block{background:#fff0ed;color:#a73a2b;border-color:#f1c5ba}.pos{color:var(--red)}.neg{color:var(--green)}.clickrow{cursor:pointer}.clickrow:hover{background:#f2f6ff}.clickrow:focus{background:#eef4ff}.mono{font-variant-numeric:tabular-nums}.split{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0}.tag{border:1px solid var(--line);background:#f5f8fc;border-radius:6px;padding:4px 9px;font-size:13px}.line{color:var(--muted);margin-top:10px;line-height:1.7}.grid2{display:flex;flex-direction:column;gap:12px}.box{border:1px solid var(--line);border-radius:8px;padding:16px}.box .title{color:var(--muted);font-size:13px}.box .value{font-size:22px;font-weight:700}.loading{padding:30px;color:var(--muted)}.research-panel{margin-top:28px}.research-panel>summary{cursor:pointer;list-style:none;font-size:18px;font-weight:700;padding:22px 26px;display:flex;align-items:center;justify-content:space-between;gap:16px}.research-panel>summary::-webkit-details-marker{display:none}.research-panel>summary:after{content:'펼치기 +';font-size:13px;color:var(--accent);white-space:nowrap}.research-panel[open]>summary:after{content:'접기 −'}.research-panel h2{font-size:18px}.research-panel .statusbar{padding:20px 26px}.research-panel .metric{background:var(--soft)}.modal-overlay{display:none;position:fixed;inset:0;background:#14243a99;z-index:100;align-items:center;justify-content:center;padding:24px}.modal-overlay.open{display:flex}.modal-box{background:white;border-radius:16px;width:100%;max-width:840px;max-height:88vh;display:flex;flex-direction:column;box-shadow:0 24px 80px #12213550}.modal-header{display:flex;align-items:center;justify-content:space-between;gap:20px;padding:22px 26px;border-bottom:1px solid var(--line)}.modal-title{font-size:19px;font-weight:750}.modal-body{padding:26px;overflow-y:auto;font-size:15px}.modal-body table{min-width:0}.modal-body td{white-space:normal}.modal-close{white-space:nowrap}
@media(min-width:1700px){.shell{padding-left:20px;padding-right:20px}th,td{padding-top:21px;padding-bottom:21px}}
@media(max-width:1100px){.shell{padding:24px 20px 48px}.metric{padding:15px}.metric .v{font-size:23px}.panel h2{font-size:21px}.scroll{scrollbar-width:thin}}
@media(max-width:760px){html{scroll-padding-top:75px}.shell{padding:20px 12px 40px}.topbar{align-items:flex-start;gap:12px}.brandline{gap:8px;flex-wrap:wrap}.brand h1{font-size:24px}.mark{width:32px;height:32px;font-size:11px}.live{font-size:11px}.brand .sub{font-size:12px}.topbar>button{padding:9px 12px;font-size:12px}.statusbar{grid-template-columns:1fr;gap:8px}.metric{min-height:0;display:flex;align-items:center;flex-wrap:wrap;gap:8px 14px;padding:12px 16px}.metric .k{min-width:95px}.metric .v{font-size:23px;margin:0}.metric .s{margin-left:auto}.section-nav{gap:0;justify-content:space-between;padding:8px 0;margin:16px 0}.section-nav a{font-size:13px;padding:8px 10px}.notice{font-size:13px;padding:12px 14px}.flow-layout{gap:22px}.panel h2{padding:20px 18px 4px;font-size:21px}.section-description{padding:4px 18px 18px;font-size:13px}.scroll{overflow:visible;padding:0 14px 14px}table,tbody{display:block;min-width:0;width:100%}thead{display:none}tbody tr{display:block;border:1px solid var(--line);border-radius:10px;padding:8px 14px;margin:0 0 12px;background:white}tbody tr:last-child{margin-bottom:0}td,td.num{display:flex;align-items:center;justify-content:space-between;gap:14px;width:auto;min-width:0;max-width:none;padding:9px 0!important;font-size:14px;white-space:normal;text-align:right;border-bottom:1px solid #edf0f5}td:before{content:attr(data-label);color:var(--muted);font-size:12px;white-space:nowrap;text-align:left;flex:0 0 80px}td:first-child{display:block;text-align:left;padding:8px 0 14px!important}td:first-child:before{display:none}td:last-child{border-bottom:0}.tbl-short td:nth-child(4){display:block;min-width:0;max-width:none;text-align:left;line-height:1.7}.tbl-short td:nth-child(4):before{display:block;margin-bottom:5px}.name{font-size:19px;min-width:0}.code{font-size:12px}.score{font-size:20px}.research-panel>summary{padding:20px 18px;font-size:16px}.research-panel .statusbar{padding:14px}.research-panel table{font-size:13px}.modal-overlay{padding:12px}.modal-box{max-height:94vh}.modal-header{padding:16px}.modal-title{font-size:16px}.modal-body{padding:18px}.modal-close{padding:8px 12px}}
.detail-verdict{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px 18px;background:#f2f6ff;border:1px solid #d8e3fa;border-radius:10px;margin-bottom:18px}.detail-verdict strong{font-size:17px}.detail-verdict span{color:var(--muted);font-size:13px;text-align:right}.detail-grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}.detail-card{border:1px solid var(--line);border-radius:10px;padding:16px 18px}.detail-title{font-size:13px;font-weight:750;color:var(--muted);margin-bottom:9px}.detail-list{margin:0;padding-left:18px}.detail-list li{margin:6px 0;line-height:1.55}.detail-card.risk{background:#fff9f7}.detail-card.positive{background:#f7fbf9}.detail-reports{grid-column:1/-1}.detail-report{padding:10px 0;border-top:1px solid #e8edf4;line-height:1.55}.detail-report:first-of-type{border-top:0}.detail-empty{color:var(--muted)}
@media(max-width:760px){.detail-verdict{align-items:flex-start;flex-direction:column}.detail-verdict span{text-align:left}.detail-grid{grid-template-columns:1fr}.detail-reports{grid-column:auto}}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}
</style>
</head>
<body>
<div class="shell">
  <div class="topbar">
    <div class="brand">
      <div class="brandline"><span class="mark">TOP</span><h1>TopPicks</h1><span class="live">연구·관찰용</span></div>
      <div id="meta" class="sub">추천 분석 로딩 중</div>
    </div>
    <button onclick="refresh()">분석 갱신</button>
  </div>
  <div class="statusbar-row">
    <div id="metrics" class="statusbar"></div>

  </div>
  <nav class="section-nav" aria-label="대시보드 목차"><a href="#longSection">1~3개월 후보</a><a href="#shortSection">단기 참고</a><a href="#researchSection">검증 데이터</a></nav>
  <div class="notice">점수는 상승 확률이 아닙니다. 관망·차단 사유를 먼저 확인하고, 종목을 선택해 상세 근거를 살펴보세요.</div>
  <div class="flow-layout">
    <section class="panel" id="shortSection">
      <h2><span class="section-kicker">SHORT TERM · 1~3거래일</span>단기 관찰 후보</h2>
      <p class="section-description">수급·가격 흐름·손익비를 함께 평가합니다. 종목을 선택하면 판단 근거를 확인할 수 있습니다.</p>
      <div class="scroll"><table class="tbl-short"><thead><tr><th>종목 / 시장</th><th class="num">선정점수</th><th>진입</th><th>핵심 사유</th><th>섹터</th><th class="num">RSI</th><th class="num">이격</th><th class="num">거래대금</th></tr></thead><tbody id="shortItems"><tr><td colspan="8" class="loading">로딩 중</td></tr></tbody></table></div>
    </section>
    <section class="panel" id="longSection">
      <h2><span class="section-kicker">1~3개월 · 20/40/60거래일</span>중기 상승 관찰 후보</h2>
      <p class="section-description">실적·재무·기업가치·60일 추세를 평가합니다. 주 1회 재검토, 최대 60거래일 관찰 기준이며 상승을 보장하는 보유 기간은 아닙니다. 별도 성과 검증 전에는 연구·관망으로 표시합니다.</p>
      <div id="mediumValidation" class="section-description">중기 엔진 재계산 대기</div>
      <div class="scroll"><table class="tbl-long"><thead><tr><th>종목 / 시장</th><th class="num">중기점수</th><th>진입</th><th>PER/PBR</th><th>리포트</th><th>섹터</th><th class="num">부채비율</th><th class="num">상승여력</th><th class="num">거래대금</th></tr></thead><tbody id="longItems"><tr><td colspan="9" class="loading">로딩 중</td></tr></tbody></table></div>
    </section>
  </div>
  <details class="panel research-panel" id="researchSection"><summary>연구 모델 · 검증 데이터</summary>

    <h2>비용 차감 +10% 목표 · 1~3거래일 연구 모델</h2>
    <div id="target10Status" class="panel-body" style="padding:8px 14px;color:var(--muted);font-size:12px">검증 결과 확인 중</div>
    <div class="scroll"><table><thead><tr><th>종목</th><th>1일 목표 / 손절</th><th>2일 목표 / 손절</th><th>3일 목표 / 손절</th><th>3일 기대 순수익</th><th>상태</th></tr></thead><tbody id="target10Items"></tbody></table></div>


    <div id="validation" class="statusbar"></div>
  </details>
</div>
<div id="modalOverlay" class="modal-overlay" onclick="if(event.target===this)closeModal()">
  <div class="modal-box" role="dialog" aria-modal="true" aria-labelledby="modalTitle">
    <div class="modal-header">
      <div id="modalTitle" class="modal-title"></div>
      <button class="modal-close" onclick="closeModal()">닫기</button>
    </div>
    <div id="modalBody" class="modal-body"></div>
  </div>
</div>
<script>
const fmt=n=>n===null||n===undefined||n===""?"-":Number(n).toLocaleString("ko-KR");
const won=n=>n?fmt(n)+"원":"-";
const pct=n=>n===null||n===undefined?"-":Number(n).toFixed(2)+"%";
const idx=n=>n===null||n===undefined?"-":Number(n).toLocaleString("ko-KR",{minimumFractionDigits:2,maximumFractionDigits:2});
const signed=n=>n===null||n===undefined?"-":`${Number(n)>0?"+":""}${Number(n).toFixed(2)}%`;
const score=x=>Number(x.selectionScore??x.shortTermScore??x.oneMonthScore??x.score??0);
const statusBadge=x=>{
  if(x.entryStatus!=="watchlist") return `<span class="badge b-buy">진입</span>`;
  if(x.entryMethod==="watchlist-blocked-entry") return `<span class="badge b-block">차단</span>`;
  return `<span class="badge b-watch">관망</span>`;
};
const sectorLabel=v=>({strong:"강세",neutral:"중립",weak:"약세",unknown:"미확인"}[v]||"미확인");
const stockCell=x=>`<div class="name">${x.name||"-"}</div><div class="code">${x.code||""} ${x.market||""}</div>`;
const blockerText=x=>{
  const blockers=(x.entryBlockers||[]).filter(Boolean);
  if(blockers.length) return blockers.slice(0,3).join(" · ");
  const warnings=(x.entryWarnings||[]).filter(Boolean);
  if(warnings.length) return "주의 " + warnings.slice(0,3).join(" · ");
  return (x.activationRequirements||[]).slice(0,2).join(" · ") || x.entryRule || "-";
};
function topRow(x){
  return `<tr><td data-label="순위" class="num">${x.rank||""}</td><td data-label="종목">${stockCell(x)}</td><td data-label="점수" class="num score">${score(x).toFixed(1)}</td><td data-label="상태">${statusBadge(x)}</td><td data-label="전략"><div>${x.strategyEngine||"-"}</div><div class="code">${x.strategyAction||""}</div></td><td data-label="추천가" class="num">${won(x.plannedEntryPrice||x.recommendationPrice)}</td><td data-label="목표" class="num pos">${won(x.targetPrice)}</td><td data-label="손절" class="num neg">${won(x.stopPrice)}</td><td data-label="차단/조건" title="${blockerText(x)}">${blockerText(x)}</td></tr>`;
}
const candidateEntryState=x=>{
  const s=x.signals||{};
  const reasons=[...(x.upsideEvidence?.blockers||[])];
  const value=Number(s.averageTradingValue??x.averageTradingValue??0);
  const rsi=Number(s.rsi??x.rsi??0);
  const dev=Number(s.ma20Deviation??x.ma20Deviation??0);
  const intraday=Number(s.intradayReturn??x.intradayReturn??0);
  const sector=x.sectorRotationStatus||s.sectorRotationStatus||"unknown";
  if(score(x)<45) reasons.push(`점수 ${score(x).toFixed(1)}<45`);
  if(value<100) reasons.push(`거래대금 ${value.toFixed(1)}억<100억`);
  if(sector==="weak") reasons.push("섹터 weak");
  if(rsi>=80) reasons.push(`RSI ${rsi.toFixed(1)}>=80`);
  if(dev>=18) reasons.push(`이격 ${dev.toFixed(1)}%>=18%`);
  if(intraday>=12) reasons.push(`장중 ${intraday.toFixed(1)}%>=12%`);
  if(reasons.length) return {label:score(x)>=45?"차단":"관망", cls:score(x)>=45?"b-block":"b-watch", text:reasons.join(" · ")};
  const warnings=[];
  if(sector!=="strong") warnings.push(`섹터 ${sector}`);
  if(rsi>=75) warnings.push(`RSI ${rsi.toFixed(1)}`);
  if(dev>=10) warnings.push(`이격 ${dev.toFixed(1)}%`);
  if(intraday>=8) warnings.push(`장중 ${intraday.toFixed(1)}%`);
  return {label:"가능", cls:"b-buy", text:warnings.length?`주의 ${warnings.join(" · ")}`:"진입 가능 · 근접 사유 없음"};
};
const candidateEntryBadge=x=>{const e=candidateEntryState(x);return `<span class="badge ${e.cls}" title="${e.text}">${e.label}</span>`};
const longEntryState=x=>({label:"연구·관망",cls:"b-watch",text:x.mediumTerm?"20·40·60거래일 성과 검증 전 · 주 1회 재검토":"중기 엔진 재계산 필요"});
const longEntryBadge=x=>{const e=longEntryState(x);return `<span class="badge ${e.cls}" title="${e.text}">${e.label}</span>`};
const candidateEntryRank=x=>{
  const label=candidateEntryState(x).label;
  if(label==="가능") return 0;
  if(label==="차단") return 1;
  return 2;
};
function escapeHtml(t){return String(t==null?"":t).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
function reasonHtml(x,horizon){
  const s=x.signals||{}; const positive=[]; const risk=[];
  const add=(list,condition,text)=>{if(condition)list.push(text)};
  if(horizon==='long'){
    add(positive,Number(s.recentUpgradeBrokerCount||0)>0,`최근 3개월 목표가 상향 ${Number(s.recentUpgradeBrokerCount)}개 증권사`);
    add(positive,s.simultaneousBuy===true,'외국인·기관 동시 순매수');
    add(positive,x.sectorRotationStatus==='strong','업종 흐름 강세');
    add(positive,Number(x.roe||0)>=10,`ROE ${Number(x.roe).toFixed(1)}%`);
    add(positive,s.aboveMa20===true&&s.risingMa60===true,'20일선 상회·60일선 상승');
    add(risk,x.targetUpside!=null&&Number(x.targetUpside)<0,`목표가 기준 상승여력 ${signed(x.targetUpside)}`);
    add(risk,Number(x.debtRatio||0)>=150,`부채비율 ${Number(x.debtRatio).toFixed(1)}%`);
    add(risk,Number(x.per||0)>=40,`PER ${Number(x.per).toFixed(1)}배`);
    add(risk,Number(s.quarterProfitGrowth||0)<0,`최근 분기 영업이익 ${signed(s.quarterProfitGrowth)}`);
  }else{
    add(positive,s.simultaneousBuy===true,'외국인·기관 동시 순매수');
    add(positive,s.volumeSurge===true,'거래량 증가 확인');
    add(positive,s.boxBreakout===true,'가격 박스권 돌파');
    add(positive,x.sectorRotationStatus==='strong','업종 흐름 강세');
    add(positive,s.aboveMa20===true,'20일선 상회');
    add(risk,Number(s.rsi||0)>=75,`RSI 과열 ${Number(s.rsi).toFixed(1)}`);
    add(risk,Number(s.ma20Deviation||0)>=10,`20일선 이격 ${pct(s.ma20Deviation)}`);
    add(risk,Number(s.intradayReturn||0)>=8,`당일 상승 ${signed(s.intradayReturn)}`);
  }
  const state=horizon==='long'?longEntryState(x):candidateEntryState(x);
  const reports=(x.reportHighlights||[]).slice(0,2).map(d=>{const text=String(d);return `<div class="detail-report">${escapeHtml(text.length>150?text.slice(0,150)+'…':text)}</div>`}).join('');
  const list=items=>items.length?`<ul class="detail-list">${items.slice(0,5).map(v=>`<li>${escapeHtml(v)}</li>`).join('')}</ul>`:'<div class="detail-empty">확인된 항목 없음</div>';
  return `<div class="detail-verdict"><strong>${state.label}</strong><span>${escapeHtml(state.text.split(' · ').slice(0,2).join(' · '))}</span></div><div class="detail-grid"><section class="detail-card positive"><div class="detail-title">긍정 근거</div>${list(positive)}</section><section class="detail-card risk"><div class="detail-title">주의할 점</div>${list(risk)}</section><section class="detail-card detail-reports"><div class="detail-title">최신 리포트 ${x.reportCount?`· ${x.reportCount}건 중 2건`:''}</div>${reports||'<div class="detail-empty">표시할 리포트 없음</div>'}</section></div>`;
}
const modalStore=new Map();
function openModal(rid){
  const entry=modalStore.get(rid);
  if(!entry) return;
  const x=entry.x;
  const scoreLabel=entry.horizon==='long'?`1~3개월 ${Number(x.longTermScore||0).toFixed(1)}점`:`단기 ${score(x).toFixed(1)}점`;
  modalTitle.textContent=`${x.name||"-"} (${x.code||""}) · ${x.market||"-"} · ${scoreLabel}`;
  modalBody.innerHTML=reasonHtml(x,entry.horizon);
  modalOverlay.classList.add('open');
}
function closeModal(){ modalOverlay.classList.remove('open'); }
document.addEventListener('keydown',e=>{ if(e.key==='Escape') closeModal(); });
function itemRow(x,idPrefix){
  const s=x.signals||{};
  const rid=`${idPrefix}-${x.code||x.name}`;
  modalStore.set(rid,{x,horizon:'short'});
  const coreReason=(x.reasons||[])[0]||"-";
  return `<tr class="clickrow" tabindex="0" aria-label="${escapeHtml(x.name||x.code)} 상세 근거" onclick="openModal('${rid}')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();openModal('${rid}')}"><td data-label="종목">${stockCell(x)}</td><td data-label="점수" class="num"><span class="score">${score(x).toFixed(1)}</span></td><td data-label="진입">${candidateEntryBadge(x)}</td><td data-label="핵심 사유">${coreReason}</td><td data-label="섹터">${sectorLabel(x.sectorRotationStatus||s.sectorRotationStatus)}</td><td data-label="RSI" class="num">${Number(s.rsi||x.rsi||0).toFixed(1)}</td><td data-label="이격" class="num">${pct(s.ma20Deviation??x.ma20Deviation)}</td><td data-label="거래대금" class="num">${fmt(s.averageTradingValue??x.averageTradingValue)}억</td></tr>`;
}
function longItemRow(x,idPrefix){
  const rid=`${idPrefix}-${x.code||x.name}`;
  modalStore.set(rid,{x,horizon:'long'});
  const perPbr=`${x.per?Number(x.per).toFixed(1):"-"} / ${x.pbr?Number(x.pbr).toFixed(1):"-"}`;
  return `<tr class="clickrow" tabindex="0" aria-label="${escapeHtml(x.name||x.code)} 상세 근거" onclick="openModal('${rid}')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();openModal('${rid}')}"><td data-label="종목">${stockCell(x)}</td><td data-label="중기점수" class="num"><span class="score">${Number(x.longTermScore||0).toFixed(1)}</span></td><td data-label="진입">${longEntryBadge(x)}</td><td data-label="PER/PBR">${perPbr}</td><td data-label="리포트" class="num">${x.reportCount??"-"}</td><td data-label="섹터">${sectorLabel(x.sectorRotationStatus)}</td><td data-label="부채비율" class="num">${x.debtRatio!=null?pct(x.debtRatio):"-"}</td><td data-label="상승여력" class="num">${x.targetUpside!=null?signed(x.targetUpside):"-"}</td><td data-label="거래대금" class="num">${fmt(x.signals?.averageTradingValue)}억</td></tr>`;
}
function metric(k,v,s){return `<div class="metric"><div class="k">${k}</div><div class="v mono">${v}</div><div class="s">${s||""}</div></div>`}
let metaBase="";let lastLoadClientTime=0;let isRunning=false;
function tickMeta(){
  if(isRunning||!lastLoadClientTime||!metaBase) return;
  const secs=Math.floor((Date.now()-lastLoadClientTime)/1000);
  const rel=secs<60?`${secs}초 전 확인`:`${Math.floor(secs/60)}분 전 확인`;
  meta.textContent=`${metaBase} · ${rel}`;
}
async function load(){
  let d;
  try {
    const r=await fetch("/api/recommendations"); d=await r.json();
    if(!r.ok)throw new Error(d.message||"추천 데이터를 불러오지 못했습니다");
  } catch(e) {
    metaBase=e.message;lastLoadClientTime=Date.now();meta.textContent=metaBase;
    metrics.innerHTML=metric("데이터 상태","사용 불가",escapeHtml(e.message));
    shortItems.innerHTML="<tr><td colspan='8'>추천 데이터를 사용할 수 없습니다.</td></tr>";
    longItems.innerHTML="<tr><td colspan='9'>추천 데이터를 사용할 수 없습니다.</td></tr>";
    return;
  }
  const top=d.top3||[]; const active=top.filter(x=>x.entryStatus!=="watchlist").length;
  const eg=d.entryGateSummary||{};
  metaBase=`최근 분석 ${d.generatedAt||"미확인"} · 자료 기준 ${d.recommendationDate||"미확인"}`;
  lastLoadClientTime=Date.now();
  meta.textContent=`${metaBase} · 0초 전 확인`;
  const mi=d.marketIndexes||{};
  metrics.innerHTML=[
    metric("KOSPI",idx(mi.KOSPI?.value),signed(mi.KOSPI?.changeRate)),
    metric("KOSDAQ",idx(mi.KOSDAQ?.value),signed(mi.KOSDAQ?.changeRate)),
    metric("1~3개월 후보",d.mediumTerm?.items?.length??"미계산","성과 검증 전 · 연구·관망"),
    metric("독립 근거 확보",d.governance?`${d.governance.evidenceCoveragePct}%`:"미측정",`수집 실패 ${d.governance?.collectionFailureCount??"미측정"} · 연구용`),
  ].join("");
  const allItems=d.items||[];
  // 코스피·코스닥 구분 없이 상승 예상 점수가 가장 높은 종목을 그대로 상위 노출
  const shortPicks=allItems.slice().sort((a,b)=>score(b)-score(a)).slice(0,10);
  const longPicks=d.mediumTerm?.items||[];
  const mtOutcomes=(d.mediumTerm?.validation?.items||[]).flatMap(x=>x.outcomes||[]);
  document.getElementById('mediumValidation').textContent=d.mediumTerm?`20/40/60거래일 관측 완료: ${[20,40,60].map(h=>mtOutcomes.filter(x=>x.horizon===h&&x.status==='observed').length).join(' / ')}건 · 비용 가정 왕복 0.30% · 상승 확률 미검증`:'중기 엔진 재계산 필요';
  shortItems.innerHTML=shortPicks.map(x=>itemRow(x,"s")).join("")||"<tr><td colspan='8' class='loading'>데이터 없음</td></tr>";
  longItems.innerHTML=longPicks.map(x=>longItemRow(x,"l")).join("")||"<tr><td colspan='9' class='loading'>데이터 없음</td></tr>";
}
async function refresh(){if(globalThis.TOPPICKS_CLOUD){await Promise.all([load(),val(),loadTarget10()]);return;}meta.textContent="새 계산 요청됨";await fetch("/api/recommendations?refresh=1")}
async function val(){
  try{
    const r=await fetch("/api/top3-validation"); if(!r.ok)throw new Error('validation unavailable'); const d=await r.json(); const c=d.currentFormulaStatistics||{};
    const strategyBoxes=(c.strategyStatistics||[]).slice(0,4).map(x=>
      metric(x.strategyEngine||"전략", `${Number(x.averageD3Return||0).toFixed(2)}%`, `D+3 · n=${x.matured3DayCount||0}`)
    ).join("");
    validation.innerHTML=[
      metric("저장/대기/성숙", `${c.savedRecommendationCount||0}/${c.pendingRecommendationCount||0}/${c.totalRecommendations||0}`, "추천 이력"),
      metric("D+3 성과", `${Number(c.hypotheticalAverage3DayReturn||c.average3DayReturn||0).toFixed(2)}%`, "전체 평균"),
      strategyBoxes
    ].join("");
  }catch(e){validation.innerHTML=metric("검증 상태","데이터 없음","")}
}
async function loadTarget10(){
  try{
    const response=await fetch('/api/target10'); if(!response.ok)throw new Error('forecast unavailable');
    const d=await response.json(); const v=d.validation||{};
    const messages={'not-evaluated':'검증 전','stale-source':'추천이 갱신되어 확률 재계산 대기','forecast-failed':'확률 계산 실패'};
    target10Status.textContent=messages[d.status]||`연구용 · 검증 ${v.passed?'통과':'미통과'} · 검증 표본 ${v.testCount||0}건 · 확률은 목표가 선도달 / 손절가 선도달 순서`;
    const probability=x=>x==null?'—':`${(100*x).toFixed(1)}%`;
    const pair=(x,h)=>{const p=x.forecast?.horizons?.[h];return p?`${probability(p.targetBeforeStopProbability)} / ${probability(p.stopBeforeTargetProbability)}`:'표본 부족'};
    target10Items.innerHTML=(d.items||[]).slice(0,10).map(x=>`<tr><td data-label="종목">${escapeHtml(x.name||x.code)}</td><td data-label="1일 목표 / 손절">${pair(x,'1')}</td><td data-label="2일 목표 / 손절">${pair(x,'2')}</td><td data-label="3일 목표 / 손절">${pair(x,'3')}</td><td data-label="기대 순수익">${x.forecast?Number(x.forecast.horizons['3'].expectedNetReturnPct).toFixed(2)+'%':'—'}</td><td data-label="상태">연구·관망</td></tr>`).join('')||'<tr><td colspan="6">사용 가능한 확률 없음</td></tr>';
  }catch(e){target10Status.textContent='연구 모델 결과를 불러오지 못했습니다';target10Items.innerHTML=''}
}
document.querySelector(".flow-layout").prepend(document.getElementById("longSection"));
load();val();loadTarget10();
if(globalThis.TOPPICKS_CLOUD)document.querySelector('button[onclick="refresh()"]').textContent='최신 자료 확인';
const AUTO_REFRESH_MS=5*60*1000;
const LIVE_POLL_MS=30*1000;
let lastAutoRefresh=Date.now();
setInterval(tickMeta,1000);
setInterval(load,LIVE_POLL_MS);
setInterval(loadTarget10,LIVE_POLL_MS);
setInterval(async()=>{
  try{
    const r=await fetch("/api/progress");const p=await r.json();
    isRunning=p.status==="running";
    if(isRunning)meta.textContent=`${p.stageName||p.stage} ${p.percent}% ${p.message}`;
    if(p.status==="completed")load();
    if(!globalThis.TOPPICKS_CLOUD && !isRunning && Date.now()-lastAutoRefresh>=AUTO_REFRESH_MS){lastAutoRefresh=Date.now();refresh();}
  }catch(e){}
},5000);
</script>
</body>
</html>
'@
}

if ($GenerateOnly) {
    $script:activeRunId = if ($RunId) { $RunId } else { (Get-Date).ToString('yyyyMMdd-HHmmss') }
    try { New-WebRecommendations | Out-Null; exit 0 } catch {
        if ($_.Exception.Message -like 'Recommendation generation already running*') { Write-Output 'Recommendation generation already running'; exit 0 }
        Set-RecommendationProgress 'failed' 'failed' '추천 분석 실패' 100 ($_.Exception.Message + ' | ' + $_.ScriptStackTrace); Write-Error $_; exit 1
    }
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $Port)
$listener.Start()
Write-Host "Kiwoom proxy listening on port $Port"
try {
    while ($true) {
        $client = $listener.AcceptTcpClient(); $client.ReceiveTimeout = 3000; $client.SendTimeout = 10000
        try {
            $stream = $client.GetStream(); $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine(); while ($true) { $line = $reader.ReadLine(); if ([string]::IsNullOrEmpty($line)) { break } }
            $path = if ($requestLine -match '^GET\s+([^\s]+)') { $Matches[1] } else { '' }
            if ($path -eq '/') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-DashboardHtml)); $type='text/html; charset=utf-8'; $status='200 OK' }
            elseif ($path -eq '/api/recommendations?refresh=1' -and (Test-RecommendationBusy)) { $bytes=[Text.Encoding]::UTF8.GetBytes('{"accepted":false,"status":"already-running"}'); $type='application/json; charset=utf-8'; $status='409 Conflict' }
            elseif ($path -eq '/api/recommendations?refresh=1') { $runId=(Get-Date).ToString('yyyyMMdd-HHmmss-fff'); $script:activeRunId=$runId; Set-RecommendationProgress 'running' 'queued' '실행 대기' 1 '백그라운드 추천 분석을 시작하고 있습니다.'; Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-GenerateOnly','-RunId',$runId) | Out-Null; $bytes=[Text.Encoding]::UTF8.GetBytes((@{accepted=$true;runId=$runId}|ConvertTo-Json -Compress)); $type='application/json; charset=utf-8'; $status='202 Accepted' }
            elseif ($path -eq '/api/recommendations') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-LatestRecommendations $false | ConvertTo-Json -Depth 8 -Compress)); $type='application/json; charset=utf-8'; $status='200 OK' }
            elseif ($path -eq '/api/progress') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-RecommendationProgress | ConvertTo-Json -Depth 5 -Compress)); $type='application/json; charset=utf-8'; $status='200 OK' }
            elseif ($path -eq '/api/top3-validation') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-Top3Validation | ConvertTo-Json -Depth 8 -Compress)); $type='application/json; charset=utf-8'; $status='200 OK' }
            elseif ($path -match '^/api/top3-history(?:\?date=(\d{4}-\d{2}-\d{2}))?$') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-Top3History $Matches[1] | ConvertTo-Json -Depth 8 -Compress)); $type='application/json; charset=utf-8'; $status='200 OK' }
            elseif ($path -match '^/history/(\d{6})/(KOSPI|KOSDAQ)$') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-PerformanceHistory $Matches[1] $Matches[2] | ConvertTo-Json -Depth 5 -Compress)); $type='application/json; charset=utf-8'; $status='200 OK' }
            elseif ($path -eq '/api/target10') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-Target10Forecast | ConvertTo-Json -Depth 10 -Compress)); $type='application/json; charset=utf-8'; $status='200 OK' }
            elseif ($path -eq '/api/independent-upside') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-IndependentUpsideReport | ConvertTo-Json -Depth 20 -Compress)); $type='application/json; charset=utf-8'; $status='200 OK' }
            elseif ($path -eq '/health') { $bytes=[Text.Encoding]::UTF8.GetBytes('{"ok":true}'); $type='application/json'; $status='200 OK' }
            else { $bytes=[Text.Encoding]::UTF8.GetBytes('{"error":"Not found"}'); $type='application/json'; $status='404 Not Found' }
            $header="HTTP/1.1 $status`r`nContent-Type: $type`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"; try { $hb=[Text.Encoding]::ASCII.GetBytes($header); $stream.Write($hb,0,$hb.Length); $stream.Write($bytes,0,$bytes.Length) } catch [IO.IOException] { Write-Host 'Client disconnected before response was written.' }
        } catch { Write-Host "Proxy request failed: $($_.Exception.Message)" }
        finally { if($reader){$reader.Dispose()}; if($stream){$stream.Dispose()}; if($client){$client.Dispose()} }
    }
} finally { $listener.Stop() }
