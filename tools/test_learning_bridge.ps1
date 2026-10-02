$ErrorActionPreference='Stop'
. "$PSScriptRoot\learning_bridge.ps1"
$dir=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir|Out-Null
$path=Join-Path $dir 'latest.json'
try{
    if((Get-MediumLearningReport $path).status -ne 'unavailable'){throw 'Missing learning report accepted'}
    $data=@{version='medium-price-learning-v1';generatedAt=([datetimeoffset]::Now).ToString('o');status='trained-shadow-only';productionEnabled=$true;scoreAdjustment=100;modelsTrained=3;validation=@{};items=@(@{code='000660';horizons=@{'20'=@{scoreAdjustment=100}}})}
    $data|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
    $report=Get-MediumLearningReport $path
    $evidence=Get-MediumLearningEvidence @{code='000660'} $report
    if($report.productionEnabled -or $report.scoreAdjustment -ne 0 -or $evidence.scoreAdjustment -ne 0 -or $evidence.probabilityIsValidated){throw 'JSON flags bypassed release gate'}
    if($evidence.status -ne 'shadow-only'){throw 'Trained model not connected'}
    $data.generatedAt=([datetimeoffset]::Now.AddHours(-25)).ToString('o')
    $data|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
    if((Get-MediumLearningReport $path).status -ne 'unavailable'){throw 'Stale learning accepted'}
    $data.generatedAt=([datetimeoffset]::Now.AddHours(1)).ToString('o')
    $data|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path -Encoding UTF8
    if((Get-MediumLearningReport $path).status -ne 'unavailable'){throw 'Future learning accepted'}
    'PASS: missing/stale/future reports and immutable zero-weight release gates'
}finally{Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $dir}
