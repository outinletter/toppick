$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:LogDir = Join-Path $script:ProjectRoot 'logs'
$script:ReportDir = Join-Path $script:ProjectRoot 'reports'
New-Item -ItemType Directory -Force -Path $script:LogDir, $script:ReportDir | Out-Null

function Write-TopPicksLog([string]$Task, [string]$Status, [string]$Message, $Data = $null) {
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        task = $Task
        status = $Status
        message = $Message
        data = $Data
    }
    $path = Join-Path $script:LogDir "$Task-$((Get-Date).ToString('yyyy-MM')).jsonl"
    Add-Content -LiteralPath $path -Value ($entry | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
}

function Send-TopPicksTelegram([object]$Recommendation) {
    $tokenPath = Join-Path $script:ProjectRoot 'key\telegram_bot_token.txt'
    $chatIdPath = Join-Path $script:ProjectRoot 'key\telegram_chat_id.txt'
    if (-not (Test-Path -LiteralPath $tokenPath) -or -not (Test-Path -LiteralPath $chatIdPath)) {
        throw 'Telegram token or chat ID file was not found.'
    }
    $tokenText = (Get-Content -Raw -LiteralPath $tokenPath).Trim()
    $chatIdText = (Get-Content -Raw -LiteralPath $chatIdPath).Trim()
    $tokenMatch = [regex]::Match($tokenText, '\d{6,}:[A-Za-z0-9_-]{20,}')
    $chatIdMatch = [regex]::Match($chatIdText, '-?\d{5,}')
    if (-not $tokenMatch.Success -or -not $chatIdMatch.Success) {
        throw 'Telegram token or chat ID format is invalid.'
    }
    $token = $tokenMatch.Value
    $chatId = $chatIdMatch.Value

    $lines = @(
        "오늘의 추천 종목 $($Recommendation.recommendationDate)"
        "시장 국면: $($Recommendation.marketRegime.name)"
        ''
    )
    foreach ($pick in @($Recommendation.top3 | Sort-Object rank)) {
        $entryPrice = ([double]$pick.plannedEntryPrice).ToString('N0')
        $targetPrice = ([double]$pick.targetPrice).ToString('N0')
        $stopPrice = ([double]$pick.stopPrice).ToString('N0')
        $score = if ($pick.PSObject.Properties['shortTermScore']) { $pick.shortTermScore } else { $pick.riseProbability }
        $status = if ($pick.entryStatus -eq 'pending') { '진입 후보' } else { '관망' }
        $reason = [string](@($pick.reasons | Select-Object -First 1))
        $lines += @(
            "$($pick.rank). [$status] $($pick.name) $($pick.code) / 점수 $score",
            "진입가 $entryPrice / 목표가 $targetPrice / 손절가 $stopPrice / $reason"
        )
    }
    $bodyJson = @{
        chat_id = $chatId
        text = ($lines -join "`n")
        disable_web_page_preview = $true
    } | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "https://api.telegram.org/bot$token/sendMessage" `
        -ContentType 'application/json; charset=utf-8' `
        -Body $bodyBytes
    if (-not $response.ok) { throw 'Telegram API returned an unsuccessful response.' }
    return $response.result.message_id
}

function Get-TopPicksIdleSeconds {
    if (-not ('TopPicks.LastInput' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace TopPicks {
    public static class LastInput {
        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }
        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
        public static uint IdleSeconds() {
            var info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(info);
            return GetLastInputInfo(ref info)
                ? ((uint)Environment.TickCount - info.dwTime) / 1000
                : 0;
        }
    }
}
'@
    }
    return [TopPicks.LastInput]::IdleSeconds()
}

function Test-TopPicksRemoteSession {
    $sessions = & quser.exe 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return [bool]($sessions | Where-Object {
        $_ -match 'rdp-tcp' -and $_ -match '\s(Active|Disc|활성|연결 끊김)\s'
    })
}

function Invoke-TopPicksSafeHibernate(
    [int]$InitialDelaySeconds = 300,
    [int]$IdleThresholdSeconds = 900,
    [int]$WarningSeconds = 60,
    [switch]$TestOnly
) {
    if ($InitialDelaySeconds -gt 0) { Start-Sleep -Seconds $InitialDelaySeconds }
    $idleSeconds = Get-TopPicksIdleSeconds
    if ($idleSeconds -lt $IdleThresholdSeconds) {
        return [pscustomobject]@{ hibernated = $false; reason = 'recent-user-input'; idleSeconds = $idleSeconds }
    }
    if (Test-TopPicksRemoteSession) {
        return [pscustomobject]@{ hibernated = $false; reason = 'remote-session'; idleSeconds = $idleSeconds }
    }
    & msg.exe * "TopPicks will hibernate this PC in $WarningSeconds seconds. Use the keyboard or mouse to cancel." 2>$null
    Start-Sleep -Seconds $WarningSeconds
    $idleAfterWarning = Get-TopPicksIdleSeconds
    if ($idleAfterWarning -lt $WarningSeconds) {
        return [pscustomobject]@{
            hibernated = $false
            reason = 'user-cancelled'
            idleSeconds = $idleAfterWarning
        }
    }
    if (Test-TopPicksRemoteSession) {
        return [pscustomobject]@{ hibernated = $false; reason = 'remote-session'; idleSeconds = $idleAfterWarning }
    }
    if ($TestOnly) {
        return [pscustomobject]@{ hibernated = $false; reason = 'test-only'; idleSeconds = $idleAfterWarning }
    }
    & shutdown.exe /h
    if ($LASTEXITCODE -ne 0) { throw 'Windows hibernate command failed.' }
    return [pscustomobject]@{ hibernated = $true; reason = 'idle'; idleSeconds = $idleAfterWarning }
}

function Get-TopPicksAdb {
    $localProperties = Join-Path $script:ProjectRoot 'local.properties'
    if (Test-Path $localProperties) {
        $line = Get-Content $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
        if ($line) {
            $sdk = ($line -replace '^sdk\.dir=', '') -replace '\\:', ':' -replace '\\\\', '\'
            $adb = Join-Path $sdk 'platform-tools\adb.exe'
            if (Test-Path $adb) { return $adb }
        }
    }
    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'ADB executable not found.'
}

function Test-TopPicksDevice([string]$Adb) {
    $devices = & $Adb devices
    return [bool]($devices | Select-String '\sdevice$')
}

function Start-TopPicksProxy {
    $listener = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $listener) {
        $proxy = Join-Path $PSScriptRoot 'kiwoom_proxy.ps1'
        Start-Process powershell.exe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$proxy`"", '-Port', '8787') `
            -WindowStyle Hidden | Out-Null
        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 500
            $listener = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue |
                Select-Object -First 1
        } until ($listener -or (Get-Date) -ge $deadline)
    }
    if (-not $listener) { throw 'Kiwoom proxy did not start.' }
    $health = Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 5
    if (-not $health.ok) { throw 'Kiwoom proxy health check failed.' }
    return $listener.OwningProcess
}

function Enable-TopPicksAdbReverse([string]$Adb) {
    & $Adb reverse tcp:8787 tcp:8787 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ADB reverse setup failed.' }
}
