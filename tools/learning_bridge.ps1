function Get-MediumLearningReport([string]$Path,[datetimeoffset]$AsOf=[datetimeoffset]::Now) {
    $empty=[pscustomobject]@{status='unavailable';productionEnabled=$false;scoreAdjustment=0;items=@();validation=$null}
    if(-not (Test-Path -LiteralPath $Path)){return $empty}
    try{
        $data=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
        $age=($AsOf-[datetimeoffset]::Parse($data.generatedAt)).TotalHours
        if($data.version -ne 'medium-price-learning-v1' -or $age -lt 0 -or $age -gt 24){return $empty}
        # No JSON flag can authorize automatic score activation or lift other evidence/risk gates.
        return [pscustomobject]@{version=$data.version;generatedAt=$data.generatedAt;status=$data.status;productionEnabled=$false;scoreAdjustment=0;modelsTrained=$data.modelsTrained;validation=$data.validation;items=@($data.items);limitations=@($data.manifest.limitations)}
    }catch{return $empty}
}

function Get-MediumLearningEvidence([object]$Item,[object]$Report) {
    $match=@($Report.items|Where-Object code -eq $Item.code|Select-Object -First 1)
    [pscustomobject]@{status=$(if($match.Count){'shadow-only'}else{'unavailable'});scoreAdjustment=0;productionEnabled=$false;
        sourceGeneratedAt=$Report.generatedAt;researchHorizons=$(if($match.Count){$match[0].horizons}else{$null});
        activationBlockers=@('unused-data-incremental-engine-comparison-required','no-automatic-activation');
        maximumFutureScoreAdjustment=5;probabilityIsValidated=$false}
}
