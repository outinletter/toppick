function Get-UpsideEvidenceMap([string]$Path, [datetimeoffset]$DecisionAt) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    try {
        $bytes=[IO.File]::ReadAllBytes($Path)
        $report = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $age = ($DecisionAt - [datetimeoffset]$report.generatedAt).TotalHours
        if ($age -lt 0 -or $age -gt 24 -or $report.version -ne 'independent-upside-v1') { return $map }
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','') } finally { $sha.Dispose() }
        foreach ($item in @($report.items)) {
            $key = "$($item.market)|$($item.code)"
            if ($map.ContainsKey($key)) { return @{} }
            $map[$key] = [pscustomobject]@{ item=$item; hash=$hash; generatedAt=$report.generatedAt }
        }
    } catch { return @{} }
    return $map
}

function Get-IntegratedUpsideEvidence([object]$Candidate, [hashtable]$Map, [datetimeoffset]$DecisionAt) {
    $result = [ordered]@{ version='upside-integration-v1'; status='missing-or-stale'; adjustment=0.0;
        blockers=@('독립 상승 근거 미수집 또는 유효기간 경과'); components=$null; supports=@();
        sourceHash=$null; sourceGeneratedAt=$null; sourceAvailableAt=$null; priceAsOf=$null; sessionBasis=$null; validationStatus='new-policy-not-validated' }
    $key = "$($Candidate.market)|$($Candidate.code)"
    if (-not $Map.ContainsKey($key)) { return [pscustomobject]$result }
    $source = $Map[$key]; $item = $source.item
    try {
        if (-not $item.sourceAvailableAt) { return [pscustomobject]$result }
        $sourceAge=($DecisionAt-[datetimeoffset]$item.sourceAvailableAt).TotalHours
        if ($sourceAge -lt 0 -or $sourceAge -gt 24) { return [pscustomobject]$result }
        $age = ($DecisionAt - [datetimeoffset]$item.decisionAt).TotalHours
        $priceDate = ([datetime]::ParseExact([string]$item.priceAsOf,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd')
        $candidateDate = ([datetime]$Candidate.tradingDate).ToString('yyyy-MM-dd')
        $sessionBasis='same-session'
        if ($priceDate -ne $candidateDate) {
            $kst=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($DecisionAt,'Korea Standard Time')
            $previous=([datetime]$candidateDate).AddDays(-1)
            while ($previous.DayOfWeek -in @([DayOfWeek]::Saturday,[DayOfWeek]::Sunday)) { $previous=$previous.AddDays(-1) }
            # Only the immediately preceding weekday is allowed during the current session.
            # Holidays need an exchange calendar; they fail closed rather than widen this window.
            if ($candidateDate -ne $kst.ToString('yyyy-MM-dd') -or $kst.Hour -ge 16 -or $priceDate -ne $previous.ToString('yyyy-MM-dd')) { return [pscustomobject]$result }
            $sessionBasis='prior-completed-session-intraday'
        }
        if ($item.status -ne 'analyzed' -or $age -lt 0 -or $age -gt 24) { return [pscustomobject]$result }
        if (-not $item.components.risk -or -not $item.components.priceVolume) { return [pscustomobject]$result }
    } catch { return [pscustomobject]$result }
    $result.status='available'; $result.sourceHash=$source.hash; $result.sourceGeneratedAt=$source.generatedAt
    $result.priceAsOf=$item.priceAsOf; $result.sessionBasis=$sessionBasis
    $result.sourceAvailableAt=$item.sourceAvailableAt
    $result.components=$item.components
    $result.supports=@($item.independentSupports | Select-Object -Unique)
    # Bounded research ranking adjustment; never interpreted as probability.
    $adjustment = [math]::Min(6, 2 * $result.supports.Count)
    if ($item.components.regime.regime -eq 'defensive') { $adjustment -= 3 }
    if ($item.components.risk.riskAcceptable -ne $true) { $adjustment -= 4 }
    if (@($item.components.catalysts.risks | Where-Object { $null -ne $_ }).Count -gt 0) { $adjustment -= 6 }
    $result.adjustment=[math]::Max(-6,[math]::Min(6,$adjustment))
    $result.blockers=@($item.entryBlockers | ForEach-Object { "독립 근거: $_" })
    # A previous price snapshot cannot certify execution-time quotes.
    $result.blockers+=@('진입 시점 호가 재확인 필요','통합 추천 정책 미사용 데이터 검증 필요')
    return [pscustomobject]$result
}

function Add-IntegratedUpsideEvidence([object]$Candidate, [hashtable]$Map, [datetimeoffset]$DecisionAt) {
    $evidence=Get-IntegratedUpsideEvidence $Candidate $Map $DecisionAt
    $Candidate | Add-Member -Force -NotePropertyName upsideEvidence -NotePropertyValue $evidence
    $Candidate | Add-Member -Force -NotePropertyName selectionScore -NotePropertyValue ([math]::Round([math]::Max(0,[math]::Min(100,[double]$Candidate.shortTermScore+$evidence.adjustment)),2))
    if ($Candidate.PSObject.Properties['reasons']) {
        $Candidate.reasons=@($Candidate.reasons)+@("독립 근거 $($evidence.status), 선정 점수 조정 $($evidence.adjustment)점")
    }
    return $Candidate
}
