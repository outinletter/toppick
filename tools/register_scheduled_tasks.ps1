$ErrorActionPreference = 'Stop'
$taskPath = '\TopPicks\'
$wscript = "$env:SystemRoot\System32\wscript.exe"
$hiddenRunner = Join-Path $PSScriptRoot 'run_hidden.vbs'

function Register-TopPicksTask(
    [string]$Name,
    [string]$ScriptName,
    [Microsoft.Management.Infrastructure.CimInstance[]]$Trigger,
    [string[]]$ExtraArguments = @()
) {
    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $argumentText = @("//B", "//Nologo", "`"$hiddenRunner`"", "`"$scriptPath`"") + @($ExtraArguments | ForEach-Object { "`"$_`"" })
    $action = New-ScheduledTaskAction `
        -Execute $wscript `
        -Argument ($argumentText -join ' ')
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -WakeToRun `
        -Hidden `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask `
        -TaskName $Name `
        -TaskPath $taskPath `
        -Action $action `
        -Trigger $Trigger `
        -Settings $settings `
        -Description "TopPicks automated task: $Name" `
        -Force | Out-Null
}

$weekdays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
$legacyDaily = Get-ScheduledTask -TaskPath $taskPath -TaskName 'DailyRecommendation' -ErrorAction SilentlyContinue
if ($legacyDaily) {
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName 'DailyRecommendation' -Confirm:$false
}
Register-TopPicksTask 'DailyHealth' 'health_check.ps1' (
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weekdays -At '08:30'
)
Register-TopPicksTask 'MarketPrep' 'daily_recommendation.ps1' (
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weekdays -At '08:50'
) @('-RunLabel', 'MarketPrep')
Register-TopPicksTask 'MorningRefresh' 'daily_recommendation.ps1' (
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weekdays -At '09:30'
) @('-RunLabel', 'MorningRefresh')
Register-TopPicksTask 'FinalRefresh' 'daily_recommendation.ps1' (
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weekdays -At '14:50'
) @('-RunLabel', 'FinalRefresh', '-SendTelegram')
Register-TopPicksTask 'CloseSnapshot' 'daily_recommendation.ps1' (
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weekdays -At '15:40'
) @('-RunLabel', 'CloseSnapshot')
Register-TopPicksTask 'DailyValidationTuning' 'daily_validation_tuning.ps1' (
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weekdays -At '16:20'
)
Register-TopPicksTask 'WeeklyAudit' 'weekly_audit.ps1' (
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek Monday -At '08:45'
)
$monthlyScript = Join-Path $PSScriptRoot 'monthly_validation.ps1'
$monthlyCommand = "$wscript //B //Nologo `"$hiddenRunner`" `"$monthlyScript`""
& schtasks.exe /Create `
    /TN '\TopPicks\MonthlyValidation' `
    /TR $monthlyCommand `
    /SC MONTHLY `
    /D 1 `
    /ST '09:00' `
    /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to register MonthlyValidation task.' }
$entryAlertScript = Join-Path $PSScriptRoot 'entry_alert_monitor.ps1'
$entryAlertCommand = "$wscript //B //Nologo `"$hiddenRunner`" `"$entryAlertScript`""
& schtasks.exe /Create `
    /TN '\TopPicks\EntryAlertMonitor' `
    /TR $entryAlertCommand `
    /SC WEEKLY `
    /D MON,TUE,WED,THU,FRI `
    /ST '09:05' `
    /RI 5 `
    /DU '06:25' `
    /K `
    /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to register EntryAlertMonitor task.' }
$monthlyTask = Get-ScheduledTask -TaskName 'MonthlyValidation' -TaskPath $taskPath
$monthlySettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -WakeToRun `
    -Hidden `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew
Set-ScheduledTask `
    -TaskName $monthlyTask.TaskName `
    -TaskPath $monthlyTask.TaskPath `
    -Settings $monthlySettings | Out-Null

Get-ScheduledTask -TaskPath $taskPath |
    Select-Object TaskName, State |
    Sort-Object TaskName
