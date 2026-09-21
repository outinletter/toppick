. "$PSScriptRoot\automation_common.ps1"
$taskName = 'daily-validation-tuning'

try {
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $validationScript = Join-Path $PSScriptRoot 'monthly_validation.ps1'
    $tuningScript = Join-Path $PSScriptRoot 'auto_tuning.ps1'

    & $powershell -NoProfile -ExecutionPolicy Bypass -File $validationScript
    $validationExitCode = $LASTEXITCODE
    if ($validationExitCode -eq 1) {
        throw 'Validation failed before tuning could run.'
    }

    & $powershell -NoProfile -ExecutionPolicy Bypass -File $tuningScript
    $tuningExitCode = $LASTEXITCODE
    if ($tuningExitCode -ne 0) {
        throw 'Auto tuning suggestion generation failed.'
    }

    $suggestionPath = Join-Path $script:ReportDir 'tuning-suggestions.json'
    $suggestions = if (Test-Path -LiteralPath $suggestionPath) {
        Get-Content -Raw -LiteralPath $suggestionPath -Encoding UTF8 | ConvertFrom-Json
    } else { $null }

    Write-TopPicksLog $taskName 'success' 'Daily validation and tuning suggestion run completed.' @{
        validationExitCode = $validationExitCode
        tuningExitCode = $tuningExitCode
        maturedRecommendationCount = if ($suggestions) { $suggestions.maturedRecommendationCount } else { $null }
        pendingRecommendationCount = if ($suggestions) { $suggestions.pendingRecommendationCount } else { $null }
        suggestionCount = if ($suggestions) { @($suggestions.suggestions).Count } else { $null }
    }
    exit 0
} catch {
    Write-TopPicksLog $taskName 'failure' $_.Exception.Message
    exit 1
}
