function Get-ModelManifest([string]$ToolRoot) {
    $files=[ordered]@{}
    foreach ($name in @('kiwoom_proxy.ps1','entry_risk.ps1','data_quality.ps1','upside_bridge.ps1','model_governance.ps1','independent_upside.py','collect_pykrx.py','validation_core.ps1')) {
        $files[$name]=(Get-FileHash -LiteralPath (Join-Path $ToolRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes(($files|ConvertTo-Json -Compress))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $fingerprint=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    [pscustomobject]@{fingerprint=$fingerprint;files=$files}
}

function Select-RiskDiversifiedTop([object[]]$Candidates,[int]$Limit=3,[int]$IndustryLimit=2) {
    if ($Limit -lt 1 -or $IndustryLimit -lt 1) { throw 'Invalid concentration limit' }
    $counts=@{}; $selected=@()
    foreach ($candidate in @($Candidates|Sort-Object @{Expression='selectionScore';Descending=$true},@{Expression='code';Descending=$false})) {
        $industry=if($candidate.industryName){[string]$candidate.industryName}else{'UNKNOWN'}
        if (($counts[$industry] -as [int]) -ge $IndustryLimit) { continue }
        $selected+=$candidate;$counts[$industry]=($counts[$industry] -as [int])+1
        if($selected.Count -ge $Limit){break}
    }
    return $selected
}

function Test-RecommendationBusy {
    $mutex=[Threading.Mutex]::new($false,'Local\TopPicks-Recommendation-Generation')
    $owned=$false
    try {
        try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
        return (-not $owned)
    } finally { if($owned){$mutex.ReleaseMutex()};$mutex.Dispose() }
}

function Get-RecommendationGovernance([object[]]$Candidates,[object[]]$Selected,[int]$Attempted,
    [object[]]$Failures,[object]$StartManifest,[object]$EndManifest) {
    $available=@($Selected|Where-Object {$_.upsideEvidence.status -eq 'available'}).Count
    $coverage=if($Selected.Count){[math]::Round(100*$available/$Selected.Count,2)}else{0}
    $modules=[ordered]@{}
    foreach($name in @('regime','sector','priceVolume','flow','revisions','catalysts','shortPressure','execution','risk')){
        $modules[$name]=@($Selected|Where-Object {$_.upsideEvidence.status -eq 'available' -and $_.upsideEvidence.components.$name.status -eq 'available'}).Count
    }
    $reasons=@('unused-data-validation-required','point-in-time-universe-and-corporate-actions-required','execution-cost-calibration-required')
    if($available -lt $Selected.Count){$reasons+='incomplete-independent-evidence-coverage'}
    if($Failures.Count){$reasons+='collection-failures'}
    $stable=$StartManifest.fingerprint -eq $EndManifest.fingerprint
    if(-not $stable){$reasons+='source-code-changed-during-run'}
    [pscustomobject]@{
        status='research-only';productionEnabled=$false;blockers=$reasons;
        attemptedCount=$Attempted;analyzedCount=$Candidates.Count;
        excludedOrUnavailableCount=[math]::Max(0,$Attempted-$Candidates.Count-$Failures.Count);
        collectionFailureCount=$Failures.Count;collectionFailures=@($Failures);
        selectedCount=$Selected.Count;evidenceAvailableCount=$available;evidenceCoveragePct=$coverage;
        moduleAvailableCounts=$modules;modelFingerprint=$StartManifest.fingerprint;
        sourceManifest=$StartManifest.files;sourceStableDuringRun=$stable;
        validationStatus='not-validated-for-current-model-fingerprint'
    }
}
