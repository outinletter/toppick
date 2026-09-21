function Convert-RiskNumber([object]$Value) {
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $parsed=0.0
    if (-not [double]::TryParse([string]$Value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed) -or
        [double]::IsNaN($parsed) -or [double]::IsInfinity($parsed)) { return $null }
    return $parsed
}

function Get-EntryRisk {
    param([object]$Candidate, [object]$TargetRate, [object]$StopRate,
        [object]$MinimumRewardRisk = 1.0)
    $blockers = @()
    $signals = $Candidate.signals
    foreach ($field in @('averageTradingValue', 'rsi', 'ma20Deviation', 'intradayReturn', 'openingGapRate')) {
        $value = Convert-RiskNumber $signals.$field
        if ($null -eq $value) { $blockers += "missing-or-invalid-$field" }
    }
    if (-not $signals.pykrx.available) { $blockers += 'unverified-investor-flow' }
    $rsi=Convert-RiskNumber $signals.rsi
    $turnover=Convert-RiskNumber $signals.averageTradingValue
    if (($null -ne $rsi -and ($rsi -lt 0 -or $rsi -gt 100)) -or ($null -ne $turnover -and $turnover -le 0)) {
        $blockers+='signal-out-of-domain'
    }
    if ((Convert-RiskNumber $signals.openingGapRate) -gt 2.5) { $blockers += 'opening-gap-above-limit' }
    if ($Candidate.sectorRotationStatus -notin @('strong', 'neutral')) { $blockers += 'unverified-or-weak-sector' }
    $slippage = if ($Candidate.market -eq 'KOSPI') { 0.10 } elseif ($Candidate.market -eq 'KOSDAQ') { 0.20 } else { $null }
    $ratio = $null
    $stressRatio = $null
    $TargetRate=Convert-RiskNumber $TargetRate; $StopRate=Convert-RiskNumber $StopRate
    $MinimumRewardRisk=Convert-RiskNumber $MinimumRewardRisk
    if ($null -eq $slippage -or $null -eq $TargetRate -or $null -eq $StopRate -or $null -eq $MinimumRewardRisk -or
        $MinimumRewardRisk -lt 1 -or $TargetRate -le 0 -or $StopRate -le 0 -or $StopRate -ge 100) {
        $blockers += 'invalid-risk-input'
    } else {
        # Target and stop are rebased on the slippage-adjusted entry by validation.
        $reward = ((1 + $TargetRate / 100) * (1 - $slippage / 100) - 1) * 100 - 0.35
        $risk = (1 - (1 - $StopRate / 100) * (1 - $slippage / 100)) * 100 + 0.35
        $ratio = $reward / $risk
        if ($ratio -lt $MinimumRewardRisk) { $blockers += 'insufficient-net-reward-risk' }
        $stressedReward=((1+$TargetRate/100)*(1-2*$slippage/100)-1)*100-0.70
        $stressedRisk=(1-(1-$StopRate/100)*(1-2*$slippage/100))*100+0.70
        $stressRatio=$stressedReward/$stressedRisk
        if ($stressRatio -lt $MinimumRewardRisk) { $blockers += 'insufficient-stressed-reward-risk' }
    }
    [pscustomobject]@{ blockers = $blockers; netRewardRisk = $ratio; stressedRewardRisk=$stressRatio; costStressMultiplier=2;
        minimumRewardRisk = $MinimumRewardRisk; policyVersion = 'entry-risk-v2-cost-stress' }
}
