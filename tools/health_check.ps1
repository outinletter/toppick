. "$PSScriptRoot\automation_common.ps1"
$taskName = 'health-check'

try {
    $proxyPid = Start-TopPicksProxy
    $stock = Invoke-RestMethod 'http://127.0.0.1:8787/stock/005930' -TimeoutSec 120
    $required = @('per', 'pbr', 'dailyPrices', 'dailyTradingValues', 'dailyVolumes', 'foreignerBuys', 'institutionBuys')
    $missing = @($required | Where-Object { $stock.PSObject.Properties.Name -notcontains $_ })
    if ($missing.Count -gt 0) { throw "Missing fields: $($missing -join ', ')" }
    if (@($stock.dailyPrices).Count -lt 80) { throw 'Daily price history is shorter than 80 rows.' }
    if (@($stock.foreignerBuys).Count -lt 20 -or @($stock.institutionBuys).Count -lt 20) {
        throw 'Investor flow history is shorter than 20 rows.'
    }
    if (-not $stock.dartAvailable) { throw 'DART data is unavailable.' }
    $macro = Invoke-RestMethod 'http://127.0.0.1:8787/macro' -TimeoutSec 120
    if ([double]$macro.exchange.usdKrw -le 0) { throw 'ECOS exchange-rate data is unavailable.' }
    if ([int]$macro.dram.sampleCount -lt 1) { throw 'DRAMeXchange free spot-price data is unavailable.' }

    $data = @{
        proxyPid = $proxyPid
        priceRows = @($stock.dailyPrices).Count
        flowRows = @($stock.foreignerBuys).Count
        dartAvailable = $stock.dartAvailable
        usdKrw = $macro.exchange.usdKrw
        dramChangeRate = $macro.dram.changeRate
        customsExportAvailable = $macro.exports.available
        customsStatus = $macro.exports.status
        krxAvailable = $macro.krx.available
        krxStatus = $macro.krx.status
    }
    Write-TopPicksLog $taskName 'success' 'All required data sources are healthy.' $data
    exit 0
} catch {
    Write-TopPicksLog $taskName 'failure' $_.Exception.Message
    exit 1
}
