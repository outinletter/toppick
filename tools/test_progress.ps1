$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'kiwoom_proxy.ps1'),[ref]$null,[ref]$null)
$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-RecommendationProgress'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$progressPath=Join-Path ([IO.Path]::GetTempPath()) ('toppicks-progress-'+[guid]::NewGuid().ToString('N')+'.json')
$script:fixtureBusy=$false
function Test-RecommendationBusy {return $script:fixtureBusy}
try{
    if((Get-RecommendationProgress).status -ne 'idle'){throw 'Missing progress not idle'}
    $script:fixtureBusy=$true
    if((Get-RecommendationProgress).status -ne 'running'){throw 'Missing progress falsely ended active generation'}
    $script:fixtureBusy=$false
    [IO.File]::WriteAllText($progressPath,'{"status":"completed","percent":100}')
    if((Get-RecommendationProgress).percent -ne 100){throw 'Valid progress lost'}
    $lock=[IO.File]::Open($progressPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{if((Get-RecommendationProgress).status -ne 'unavailable'){throw 'Locked progress misreported'}}finally{$lock.Dispose()}
    [IO.File]::WriteAllText($progressPath,'broken-json')
    if((Get-RecommendationProgress).status -ne 'unavailable'){throw 'Invalid JSON accepted'}
    'PASS missing file, active mutex, valid JSON, sharing lock and corrupt progress'
}finally{if(Test-Path -LiteralPath $progressPath){Remove-Item -LiteralPath $progressPath}}
