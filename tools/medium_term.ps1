function Convert-MediumNumber($Value) {
    if($null -eq $Value -or $Value -is [bool]){return $null}
    $number=0.0
    if(-not [double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)){return $null}
    return $number
}

function Get-MediumTermAssessment([object]$Item) {
    # Fixed research weights, not calibrated probabilities. Do not redistribute missing weights.
    $components=[ordered]@{}
    foreach($spec in @(@('earnings',25,25),@('reports',16,15),@('financial',5,15),@('industryMomentum',10,10))) {
        $value=Convert-MediumNumber $Item.scoreBreakdown.($spec[0])
        $components[$spec[0]]=if($null -eq $value){$null}else{[math]::Round([math]::Max(0,[math]::Min(1,[double]$value/$spec[1]))*$spec[2],2)}
    }
    $valuation=Convert-MediumNumber $Item.valuationScore
    $fcf=Convert-MediumNumber $Item.fcf
    $foreign=Convert-MediumNumber $Item.signals.foreignFlowRatio
    $institution=Convert-MediumNumber $Item.signals.institutionFlowRatio
    $components['valuation']=if($null -eq $valuation){$null}else{[math]::Max(0,[math]::Min(10,[double]$valuation))*1.5}
    $components['trend']=if($Item.signals.risingMa60 -isnot [bool]){$null}else{if($Item.signals.risingMa60){10}else{0}}
    $components['cashFlow']=if($null -eq $fcf){$null}else{if([double]$fcf -gt 0){5}else{0}}
    $components['flow20']=if($null -eq $foreign -or $null -eq $institution){$null}else{if($foreign -gt 0 -and $institution -gt 0){5}else{0}}
    $missing=@($components.Keys | Where-Object {$null -eq $components[$_]})
    $risk=Convert-MediumNumber $Item.scoreBreakdown.riskPenalty
    $penalty=if($null -eq $risk){$missing+='riskPenalty';0}else{[math]::Max(0,$risk)}
    $score=[math]::Round([math]::Max(0,(@($components.Values|Where-Object {$null -ne $_})|Measure-Object -Sum).Sum-$penalty),2)
    [pscustomobject]@{
        formulaVersion='medium-term-v1';score=$score;components=[pscustomobject]$components;riskPenalty=$penalty
        horizonTradingDays=@(20,40,60);maxHoldingTradingDays=60;reviewEveryTradingDays=5
        entryStatus='watchlist';productionEnabled=$false;riseProbability=$null
        blockers=@('20-40-60-day-unused-data-validation-required','historical-point-in-time-fundamentals-required')
        missingFactors=$missing
        priceAsOf=$Item.tradingDate
        targetPrice=$null;stopPrice=$null
        targetPriceNote='Broker target upside has no verified 1-3 month maturity; not an exit target.'
    }
}

function Select-MediumTermCandidates([object[]]$Candidates,[int]$Limit=10) {
    $counts=@{};$selected=@()
    foreach($item in @($Candidates|Where-Object {$_.mediumTerm -and $_.liquid}|Sort-Object @{Expression={$_.mediumTerm.score};Descending=$true},code)) {
        $industry=if($item.industryName){[string]$item.industryName}elseif($item.industryCode){"$($item.market):$($item.industryCode)"}else{'UNKNOWN'}
        if(($counts[$industry] -as [int]) -ge 2){continue}
        $counts[$industry]=($counts[$industry] -as [int])+1
        $item | Add-Member -NotePropertyName mediumTermRank -NotePropertyValue ($selected.Count+1) -Force
        $selected+=$item
        if($selected.Count -ge $Limit){break}
    }
    return $selected
}

function Get-MediumTermOutcome([object[]]$StockHistory,[object[]]$IndexHistory,[string]$AfterDate,[int]$Horizon,[double]$CostBps=30) {
    $cutoff=(Get-Date).ToString('yyyyMMdd') # Exclude today's potentially incomplete daily bar.
    if(-not @($IndexHistory|Where-Object {$_.date -le $AfterDate}).Count){return [pscustomobject]@{status='history-insufficient';horizon=$Horizon}}
    $benchmark=@($IndexHistory|Where-Object {$_.date -gt $AfterDate -and $_.date -lt $cutoff}|Sort-Object { $_.date }|Select-Object -First $Horizon)
    if($benchmark.Count -lt $Horizon){return [pscustomobject]@{status='pending';horizon=$Horizon}}
    $byDate=@{};foreach($row in $StockHistory){$byDate[[string]$row.date]=$row}
    $bars=@($benchmark|ForEach-Object {$byDate[[string]$_.date]})
    if(@($bars|Where-Object {$null -eq $_ -or $_.open -le 0 -or $_.price -le 0 -or $_.low -le 0}).Count -or $bars.Count -ne $Horizon){return [pscustomobject]@{status='missing-bars';horizon=$Horizon}}
    if($benchmark[0].open -le 0 -or $benchmark[-1].price -le 0){return [pscustomobject]@{status='missing-benchmark';horizon=$Horizon}}
    $entry=[double]$bars[0].open;$exit=[double]$bars[-1].price
    $net=100*($exit/$entry-1)-$CostBps/100
    $peak=$entry;$drawdown=0.0
    foreach($bar in $bars){$peak=[math]::Max($peak,[double]$bar.price);$drawdown=[math]::Min($drawdown,100*([double]$bar.price/$peak-1))}
    [pscustomobject]@{status='observed';horizon=$Horizon;entryDate=$bars[0].date;exitDate=$bars[-1].date
        entryPrice=$entry;exitPrice=$exit;netReturnPct=[math]::Round($net,4)
        benchmarkExcessPct=[math]::Round($net-100*($benchmark[-1].price/$benchmark[0].open-1),4)
        closeMaxDrawdownPct=[math]::Round($drawdown,4);costAssumptionBps=$CostBps
        basis='latest-adjusted-daily-bars';productionValidated=$false}
}

function Update-MediumTermValidation([string]$SnapshotDirectory) {
    $seen=@{};$outcomes=@()
    foreach($file in @(Get-ChildItem -LiteralPath $SnapshotDirectory -Filter '*.json'|Sort-Object Name)){
        $snapshot=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
        # First saved signal per date/code; intraday reruns do not multiply the sample size.
        $after=([datetimeoffset]::Parse($snapshot.generatedAt)).ToOffset([timespan]::FromHours(9)).ToString('yyyyMMdd')
        foreach($item in $snapshot.items){
            $key="$after|$($item.code)";if($seen.ContainsKey($key)){continue};$seen[$key]=$true
            $values=@()
            if($after -ge (Get-Date).ToString('yyyyMMdd')){
                $values=@(20,40,60|ForEach-Object {[pscustomobject]@{status='pending';horizon=$_}})
            }else{
                try{$history=Get-PerformanceHistory $item.code $item.market
                    $values=@(20,40,60|ForEach-Object {Get-MediumTermOutcome $history.stockHistory $history.indexHistory $after $_ $snapshot.costAssumptionBps})
                }catch{$values=@(20,40,60|ForEach-Object {[pscustomobject]@{status='collection-failed';horizon=$_}})}
            }
            $outcomes+=[pscustomobject]@{signalDate=$after;code=$item.code;formulaVersion=$snapshot.formulaVersion;outcomes=$values}
        }
    }
    [pscustomobject]@{generatedAt=(Get-Date).ToString('o');productionEnabled=$false;status='forward-tracking-only';items=$outcomes}
}

