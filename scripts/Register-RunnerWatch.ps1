<#
.SYNOPSIS
    Installs Watch-Runner.ps1 as a scheduled task. Run elevated.

.DESCRIPTION
    Registers a task that runs the watcher every 10 minutes. This is the
    self-healing half of BI-26: the container disappeared once and CI queued
    for 19 hours before a human happened to ask.

    NOT run automatically by anything. Installing a scheduled task is a
    persistent change to this host, so it is a deliberate, owner-run step.

.EXAMPLE
    .\Register-RunnerWatch.ps1
    .\Register-RunnerWatch.ps1 -Remove
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string] $TaskName = 'Bonkey-RunnerWatch',
    [int]    $EveryMinutes = 10,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Watch-Runner.ps1'

if ($Remove) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "removed scheduled task '$TaskName'"
    } else { Write-Output "no such task '$TaskName'" }
    return
}

if (-not (Test-Path $script)) { throw "not found: $script" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""

# Repeat indefinitely from a start in the past, so the first run is immediate.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(-1) `
    -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)

# Run whether or not the user is logged on; the runner is not interactive.
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Output "registered '$TaskName', every $EveryMinutes minutes"
Write-Output "  log:    $env:ProgramData\bonkey\runner-watch.log"
Write-Output "  remove: .\Register-RunnerWatch.ps1 -Remove"
