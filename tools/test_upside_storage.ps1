$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'kiwoom_proxy.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
foreach($name in @('Write-JsonAtomic','New-WebRecommendations')) {
    $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($function.Extent.Text.Replace('Local\TopPicks-Recommendation-Generation','Local\TopPicks-Test-Generation')))
}
$target=Join-Path ([IO.Path]::GetTempPath()) ('atomic-upside-'+[guid]::NewGuid().ToString('N')+'.json')
Write-JsonAtomic $target @{n=1}
Write-JsonAtomic $target @{n=2}
if((Get-Content -Raw $target|ConvertFrom-Json).n -ne 2){throw 'Atomic replacement failed'}
function Invoke-RecommendationGeneration { throw 'fixture-failure' }
try { New-WebRecommendations } catch { if($_ -notmatch 'fixture-failure'){throw} }
$job=Start-Job {
    $mutex=[Threading.Mutex]::new($false,'Local\TopPicks-Test-Generation')
    $owned=$mutex.WaitOne(0)
    if($owned){$mutex.ReleaseMutex()}
    $mutex.Dispose()
    $owned
}
$job | Wait-Job -Timeout 10 | Out-Null
$released=Receive-Job $job
Remove-Job $job
if($released -ne $true){throw 'Generation lock not released on failure'}
function Invoke-RecommendationGeneration { 'fixture-success' }
if((New-WebRecommendations) -ne 'fixture-success'){throw 'Generation wrapper failed'}
'PASS atomic create/replace, exception lock release and generation wrapper'
Remove-Item -LiteralPath $target
