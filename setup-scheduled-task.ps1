# Register the Windows Scheduled Task for the daily finance report.
# One task, two triggers: daily 07:00 and at logon (catch-up).
$ErrorActionPreference = "Stop"

$dir    = $PSScriptRoot
$runner = Join-Path $dir "run-daily-report.ps1"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""

$tDaily = New-ScheduledTaskTrigger -Daily -At (Get-Date -Hour 7 -Minute 0 -Second 0)

# Retry every 2h for 14h after 07:00. The runner is idempotent (it exits
# immediately if today's report already exists), so the extra firings are
# near-free and only do work when an earlier attempt failed.
$tDaily.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date -Hour 7 -Minute 0 -Second 0) `
    -RepetitionInterval (New-TimeSpan -Hours 2) `
    -RepetitionDuration (New-TimeSpan -Hours 14)).Repetition

$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName "FinanceDailyReport" `
    -Action $action `
    -Trigger $tDaily, $tLogon `
    -Settings $settings `
    -Principal $principal `
    -Description "Daily finance news report: 07:00 daily + at logon catch-up" `
    -Force | Out-Null

Write-Output "registered: FinanceDailyReport"
