function Convert-MediumNumber($Value) {
    if($null -eq $Value -or $Value -is [bool]){return $null}
    $number=0.0
    if(-not [double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)){return $null}
    return $number
}

function Test-MediumDate($Value,[datetimeoffset]$AsOf,[int]$MaxDays) {
    try {
        if([string]::IsNullOrWhiteSpace([string]$Value)){return $false}
        $date=[datetimeoffset]::Parse([string]$Value)
        if([string]$Value -match 'T|\d{2}:\d{2}' -and $date -gt $AsOf){return $false}
        $today=$AsOf.ToOffset([timespan]::FromHours(9)).Date
        $age=($today-$date.Date).TotalDays
        return $age -ge 0 -and $age -le $MaxDays
    } catch {return $false}
}

function Get-MediumTermAssessment([object]$Item,[datetimeoffset]$AsOf=[datetimeoffset]::Now) {
    $weights=[ordered]@{earnings=25;reports=15;financial=15;industryMomentum=10;valuation=15;trend=10;cashFlow=5;flow20=5}
    $components=[ordered]@{};foreach($key in $weights.Keys){$components[$key]=$null}
    $blockers=@()
    $validationRequirements=@('20-40-60-day-unused-data-validation-required')
    $limitations=@('estimate-revision-api-not-connected')
    $priceFresh=Test-MediumDate $Item.tradingDate $AsOf 7
    if(-not $priceFresh){$blockers+='price-date-missing-stale-or-future'}
    $f=$Item.mediumFinancialEvidence
    $financialFresh=$false
    if($f -and $f.source -eq 'DART-CFS' -and $f.currency -eq 'KRW'){
        $maxDays=if($f.reportCode -eq '11011'){450}else{210}
        $financialFresh=(Test-MediumDate $f.periodEnd $AsOf $maxDays) -and (Test-MediumDate $f.publishedDate $AsOf $maxDays)
        try{
            $published=[datetimeoffset]::Parse($f.publishedDate)
            $collected=[datetimeoffset]::Parse($f.collectedAt)
            $financialFresh=$financialFresh -and $collected -le $AsOf -and $collected -ge $published -and ([datetimeoffset]::Parse($f.periodEnd)).Date -le $published.Date
        }catch{$financialFresh=$false}
    }
    $profit=Convert-MediumNumber $f.profit;$prior=Convert-MediumNumber $f.priorYearProfit
    $revenue=Convert-MediumNumber $f.revenue;$priorRevenue=Convert-MediumNumber $f.priorYearRevenue
    $equity=Convert-MediumNumber $f.equity;$liabilities=Convert-MediumNumber $f.liabilities
    $cash=Convert-MediumNumber $f.operatingCashFlow
    $profitYoY=$null;$revenueYoY=$null
    if($financialFresh){
        if($null -ne $profit -and $null -ne $prior -and $prior -gt 0){$profitYoY=100*($profit/$prior-1)}
        if($null -ne $revenue -and $null -ne $priorRevenue -and $priorRevenue -gt 0){$revenueYoY=100*($revenue/$priorRevenue-1)}
        if($null -ne $profitYoY -and $null -ne $revenueYoY){
            $components.earnings=[math]::Max(0,[math]::Min(1,$profitYoY/50))*20+[math]::Max(0,[math]::Min(1,$revenueYoY/30))*5
        }
        if($null -ne $profit -and $null -ne $equity -and $null -ne $liabilities -and $liabilities -ge 0){
            $components.financial=0
            if($equity -gt 0 -and $profit -gt 0){$debt=100*$liabilities/$equity;$components.financial=if($debt -le 80){15}elseif($debt -le 150){10}elseif($debt -le 250){4}else{0}}
        }
        if($null -ne $cash){$components.cashFlow=if($cash -gt 0){5}else{0}}
    }else{$blockers+='financial-source-missing-stale-or-future'}
    if($null -ne $equity -and $equity -le 0){$blockers+='non-positive-equity'}
    $target=Convert-MediumNumber $Item.targetUpside
    if($priceFresh -and (Test-MediumDate $Item.reportEvidence.latestPublishedAt $AsOf 90) -and $null -ne $target -and $Item.reportEvidence.targetBrokerCount -ge 2){
        $components.reports=[math]::Max(0,[math]::Min(1,$target/50))*15
    }
    if($priceFresh -and $Item.sectorRotationStatus -in @('strong','neutral','weak')){
        $industry=Convert-MediumNumber $Item.scoreBreakdown.industryMomentum
        if($null -ne $industry){$components.industryMomentum=[math]::Max(0,[math]::Min(10,$industry))}
    }
    $valuation=Convert-MediumNumber $Item.valuationScore
    $per=Convert-MediumNumber $Item.per;$pbr=Convert-MediumNumber $Item.pbr
    if($priceFresh -and $financialFresh -and $null -ne $valuation -and $per -gt 0 -and $pbr -gt 0){$components.valuation=[math]::Max(0,[math]::Min(10,$valuation))*1.5}
    if($priceFresh -and $Item.signals.risingMa60 -is [bool]){$components.trend=if($Item.signals.risingMa60){10}else{0}}
    $flow=$Item.signals.pykrx
    if($flow.available -eq $true -and $flow.flowUnit -eq 'KRW' -and $flow.flowRows -ge 60 -and (Test-MediumDate $flow.flowAsOf $AsOf 7)){
        $f20=Convert-MediumNumber $flow.foreign20;$i20=Convert-MediumNumber $flow.institution20
        $f60=Convert-MediumNumber $flow.foreign60;$i60=Convert-MediumNumber $flow.institution60
        if($null -ne $f20 -and $null -ne $i20 -and $null -ne $f60 -and $null -ne $i60){
            $components.flow20=0
            if($f20 -gt 0 -and $f60 -gt 0){$components.flow20+=2.5}
            if($i20 -gt 0 -and $i60 -gt 0){$components.flow20+=2.5}
        }
    }
    $missing=@($weights.Keys|Where-Object {$null -eq $components[$_]})
    $coverage=0;foreach($key in $weights.Keys){if($null -ne $components[$key]){$coverage+=$weights[$key]}}
    $risk=Convert-MediumNumber $Item.scoreBreakdown.riskPenalty
    if($null -eq $risk){$missing+='riskPenalty';$blockers+='risk-input-missing'}
    $penalty=if($null -eq $risk){0}else{[math]::Max(0,$risk)}
    $score=[math]::Round([math]::Max(0,(@($components.Values|Where-Object {$null -ne $_})|Measure-Object -Sum).Sum-$penalty),2)
    if($coverage -lt 60){$blockers+='insufficient-data-coverage'}
    $eligible=($priceFresh -and $financialFresh -and $coverage -ge 60 -and $null -ne $risk -and $null -ne $equity -and $equity -gt 0)
    # Eligibility describes usable evidence. It does not certify investment performance.
    $conditional=$eligible -and $score -ge 45 -and $Item.liquid -eq $true -and $Item.signals.risingMa60 -eq $true -and $profit -gt 0
    # Negative operating cash flow is observable risk, not missing evidence.
    if($null -ne $cash -and $cash -le 0){$conditional=$false;$limitations+='non-positive-operating-cash-flow'}
    $dispersion=Convert-MediumNumber $Item.reportEvidence.targetDispersionPct
    if($null -ne $dispersion -and $dispersion -ge 50){$limitations+='wide-broker-target-dispersion'}
    $flowIntensity=$null
    $cap=Convert-MediumNumber $Item.marketCap
    if($null -ne $components.flow20 -and $cap -gt 0){$flowIntensity=[math]::Round(100*($f20+$i20)/($cap*100000000),4)}
    if($eligible -and -not $conditional){$limitations+='candidate-score-profit-trend-or-liquidity-not-met'}
    [pscustomobject]@{
        formulaVersion='medium-term-v3-audited';score=$score;components=[pscustomobject]$components;riskPenalty=$penalty
        dataCoveragePct=$coverage;dataCoverageIsProbability=$false
        candidateEligible=$eligible
        horizonTradingDays=@(20,40,60);maxHoldingTradingDays=60;reviewEveryTradingDays=5
        entryStatus=$(if($conditional){'conditional-candidate'}elseif($eligible){'watchlist'}else{'data-insufficient'});productionEnabled=$false;riseProbability=$null
        validationRequirements=$validationRequirements;limitations=$limitations
        evidenceAudit=[pscustomobject]@{priceFresh=$priceFresh;financialFresh=$financialFresh;financialSource='DART-CFS';financialPublishedAt=$f.publishedDate;financialCollectedAt=$f.collectedAt;flowAsOf=$flow.flowAsOf;flowUnit=$flow.flowUnit;netFlow20MarketCapPct=$flowIntensity;marketCapUnit='100-million-KRW';reportMethod=$Item.reportEvidence.method;limitationsAreProbability=$false}
        blockers=$blockers;missingFactors=$missing;priceAsOf=$Item.tradingDate
        evidenceAsOf=$AsOf.ToString('o');financialEvidence=$f;profitYoYPct=$profitYoY;revenueYoYPct=$revenueYoY
        targetPrice=$null;stopPrice=$null
        targetPriceNote='Broker targets are valuation context; no verified 1-3 month exit target.'
    }
}

function Get-MediumQualitySummary([object[]]$Candidates) {
    $missing=[ordered]@{}
    foreach($item in $Candidates){foreach($key in $item.mediumTerm.missingFactors){$missing[$key]=1+($missing[$key] -as [int])}}
    [pscustomobject]@{analyzedCount=$Candidates.Count;eligibleCount=@($Candidates|Where-Object {$_.mediumTerm.candidateEligible}).Count
        missingFactorCounts=[pscustomobject]$missing;estimateRevisionApi='not-connected';coverageIsProbability=$false
        candidateAudit=@($Candidates|ForEach-Object {[pscustomobject]@{code=$_.code;score=$_.mediumTerm.score;eligible=$_.mediumTerm.candidateEligible;dataCoveragePct=$_.mediumTerm.dataCoveragePct;missingFactors=$_.mediumTerm.missingFactors;blockers=$_.mediumTerm.blockers}})}
}

function Select-MediumTermCandidates([object[]]$Candidates,[int]$Limit=10) {
    $counts=@{};$selected=@()
    foreach($item in @($Candidates|Where-Object {$_.mediumTerm -and $_.mediumTerm.candidateEligible -and $_.liquid}|Sort-Object @{Expression={$_.mediumTerm.score};Descending=$true},code)) {
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
    if($Horizon -notin @(20,40,60) -or [double]::IsNaN($CostBps) -or [double]::IsInfinity($CostBps) -or $CostBps -lt 0){throw 'Invalid horizon or costs'}
    $cutoff=(Get-Date).ToString('yyyyMMdd') # Exclude today's potentially incomplete daily bar.
    if(-not @($IndexHistory|Where-Object {$_.date -le $AfterDate}).Count){return [pscustomobject]@{status='history-insufficient';horizon=$Horizon}}
    $benchmark=@($IndexHistory|Where-Object {$_.date -gt $AfterDate -and $_.date -lt $cutoff}|Sort-Object { $_.date }|Select-Object -First $Horizon)
    if($benchmark.Count -lt $Horizon){return [pscustomobject]@{status='pending';horizon=$Horizon}}
    $byDate=@{};foreach($row in $StockHistory){$byDate[[string]$row.date]=$row}
    if(@($StockHistory|Group-Object { $_.date }|Where-Object Count -gt 1).Count -or @($IndexHistory|Group-Object { $_.date }|Where-Object Count -gt 1).Count){return [pscustomobject]@{status='duplicate-bars';horizon=$Horizon}}
    $bars=@($benchmark|ForEach-Object {$byDate[[string]$_.date]})
    foreach($bar in $bars){foreach($field in @('open','price','low')){$number=Convert-MediumNumber $bar.$field;if($null -eq $number -or $number -le 0){return [pscustomobject]@{status='missing-bars';horizon=$Horizon}}}}
    foreach($bar in $benchmark){foreach($field in @('open','price')){$number=Convert-MediumNumber $bar.$field;if($null -eq $number -or $number -le 0){return [pscustomobject]@{status='missing-benchmark';horizon=$Horizon}}}}
    if(@($bars|Where-Object {$null -eq $_ -or $_.open -le 0 -or $_.price -le 0 -or $_.low -le 0}).Count -or $bars.Count -ne $Horizon){return [pscustomobject]@{status='missing-bars';horizon=$Horizon}}
    if($benchmark[0].open -le 0 -or $benchmark[-1].price -le 0){return [pscustomobject]@{status='missing-benchmark';horizon=$Horizon}}
    $entry=[double]$bars[0].open;$exit=[double]$bars[-1].price
    $net=100*($exit/$entry-1)-$CostBps/100
    $stressNet=100*($exit/$entry-1)-2*$CostBps/100
    $mae=100*(([double](@($bars.low)|Measure-Object -Minimum).Minimum)/$entry-1)
    $peak=$entry;$drawdown=0.0
    foreach($bar in $bars){$peak=[math]::Max($peak,[double]$bar.price);$drawdown=[math]::Min($drawdown,100*([double]$bar.price/$peak-1))}
    [pscustomobject]@{status='observed';horizon=$Horizon;entryDate=$bars[0].date;exitDate=$bars[-1].date
        entryPrice=$entry;exitPrice=$exit;netReturnPct=[math]::Round($net,4)
        stressedNetReturnPct=[math]::Round($stressNet,4);adverseExcursionPct=[math]::Round([math]::Min(0,$mae),4)
        benchmarkExcessPct=[math]::Round($net-100*($benchmark[-1].price/$benchmark[0].open-1),4)
        closeMaxDrawdownPct=[math]::Round($drawdown,4);costAssumptionBps=$CostBps
        basis='latest-adjusted-daily-bars';productionValidated=$false}
}

function Update-MediumTermValidation([string]$SnapshotDirectory,[string]$ModelFingerprint='') {
    $seen=@{};$outcomes=@()
    foreach($file in @(Get-ChildItem -LiteralPath $SnapshotDirectory -Filter '*.json'|Sort-Object Name)){
        $snapshot=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
        # First saved signal per date/code; intraday reruns do not multiply the sample size.
        $after=([datetimeoffset]::Parse($snapshot.generatedAt)).ToOffset([timespan]::FromHours(9)).ToString('yyyyMMdd')
        foreach($item in $snapshot.items){
            $key="$($snapshot.modelFingerprint)|$($snapshot.formulaVersion)|$after|$($item.market)|$($item.code)";if($seen.ContainsKey($key)){continue};$seen[$key]=$true
            $values=@()
            if($after -ge (Get-Date).ToString('yyyyMMdd')){
                $values=@(20,40,60|ForEach-Object {[pscustomobject]@{status='pending';horizon=$_}})
            }else{
                try{$history=Get-PerformanceHistory $item.code $item.market
                    $values=@(20,40,60|ForEach-Object {Get-MediumTermOutcome $history.stockHistory $history.indexHistory $after $_ $snapshot.costAssumptionBps})
                }catch{$values=@(20,40,60|ForEach-Object {[pscustomobject]@{status='collection-failed';horizon=$_}})}
            }
            $outcomes+=[pscustomobject]@{signalDate=$after;code=$item.code;market=$item.market;formulaVersion=$snapshot.formulaVersion;modelFingerprint=$(if($snapshot.sourceStableDuringRun -eq $true){$snapshot.modelFingerprint}else{$null});outcomes=$values}
        }
    }
    [pscustomobject]@{generatedAt=(Get-Date).ToString('o');productionEnabled=$false;status='forward-tracking-only';items=$outcomes;summary=(Get-MediumValidationSummary $outcomes $ModelFingerprint)}
}

function Get-MediumValidationSummary([object[]]$Rows,[string]$ModelFingerprint) {
    $matching=@($Rows|Where-Object {$ModelFingerprint -and $_.modelFingerprint -eq $ModelFingerprint})
    $summaries=@(foreach($horizon in @(20,40,60)){
        $observed=@(foreach($row in $matching){foreach($outcome in $row.outcomes){if($outcome.status -eq 'observed' -and $outcome.horizon -eq $horizon){[pscustomobject]@{signalDate=$row.signalDate;value=$outcome}}}})
        $periods=@();$previousExit='';$incomplete=0
        # Equal-weight each signal-date cohort; skip any cohort overlapping the preceding selected period.
        foreach($group in @($observed|Group-Object signalDate|Sort-Object Name)){
            $expected=@($matching|Where-Object signalDate -eq $group.Name).Count
            if($group.Count -ne $expected){$incomplete++;continue}
            $values=@($group.Group.value)
            $entry=($values.entryDate|Sort-Object|Select-Object -First 1)
            $exit=($values.exitDate|Sort-Object|Select-Object -Last 1)
            if(-not $entry -or -not $exit -or ($previousExit -and $entry -le $previousExit)){continue}
            $previousExit=$exit
            $periods+=[pscustomobject]@{signalDate=$group.Name;entryDate=$entry;exitDate=$exit;stocks=$values.Count;netReturnPct=($values|Measure-Object netReturnPct -Average).Average;excessPct=($values|Measure-Object benchmarkExcessPct -Average).Average;stressPct=($values|Measure-Object stressedNetReturnPct -Average).Average}
        }
        [pscustomobject]@{horizon=$horizon;observedStockCount=$observed.Count;incompleteCohortCount=$incomplete;nonOverlappingPeriodCount=$periods.Count;meanNetReturnPct=$(if($periods.Count){[math]::Round(($periods|Measure-Object netReturnPct -Average).Average,4)}else{$null});meanBenchmarkExcessPct=$(if($periods.Count){[math]::Round(($periods|Measure-Object excessPct -Average).Average,4)}else{$null});meanStressedReturnPct=$(if($periods.Count){[math]::Round(($periods|Measure-Object stressPct -Average).Average,4)}else{$null});periods=$periods}
    })
    [pscustomobject]@{modelFingerprint=$ModelFingerprint;excludedModelRows=$Rows.Count-$matching.Count;horizons=$summaries;productionEnabled=$false;method='same-fingerprint-equal-weight-signal-date-nonoverlapping-periods';limitations=@('nonoverlap-does-not-prove-independence','selection-universe-survivorship-not-resolved','corporate-actions-and-execution-not-validated','no-automatic-release')}
}

