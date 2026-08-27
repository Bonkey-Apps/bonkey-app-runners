<#
.SYNOPSIS
    Keeps the local self-hosted runner alive, and notices when CI is stuck.

.DESCRIPTION
    Two independent checks, because they fail differently (BI-26):

      1. SELF-HEAL. If the runner container is absent, recreate it.
      2. STUCK-QUEUE. Warn when jobs are queued and nothing is starting.

    Why both: BI-25 was a container that had been REMOVED, not stopped.
    `restart: unless-stopped` recovers a stopped container and does nothing for
    a removed one, so CI queued silently for 19 hours with every dashboard
    green -- queued reads as "busy", not "broken".

    Check 1 alone is blind to a runner that exists but cannot claim jobs
    (label mismatch, wedged runner). Check 2 catches that and is immune to
    RUNNER_EPHEMERAL, under which "no runner registered right now" is normal.

.NOTES
    Safe to run repeatedly. Read-only except for `docker compose up -d`, which
    is idempotent. Never stops, removes or reconfigures anything.
    Uses no GCE. Owner standing rule: never use GCE without permission.
#>
[CmdletBinding()]
param(
    # Warn only if the oldest queued run exceeds this AND nothing has started
    # recently. Both conditions must hold -- see Test-StuckQueue.
    [int]      $QueuedMinutes  = 60,

    # A healthy fleet draining a backlog starts something regularly. Silence
    # for this long WITH work waiting is what "dead" looks like.
    [int]      $NoStartMinutes = 30,

    [string[]] $Repos = @(
        'Bonkey-Apps/bonkey-cards-app',
        'Bonkey-Apps/bonkey-puzzles-app',
        'Bonkey-Apps/bonkey-math-app'
    ),

    # Resolved after the param block: under `powershell -File` on 5.1,
    # $PSScriptRoot is EMPTY during parameter binding, so a default built from
    # it throws before the body runs. Found by dry-running this script.
    [string]   $ComposeDir,
    [string]   $LogPath,
    [switch]   $WhatIf
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot }
        elseif ($PSCommandPath) { Split-Path $PSCommandPath -Parent }
        else { (Get-Location).Path }

if (-not $ComposeDir) { $ComposeDir = Join-Path $here '..\docker-runner' }
if (-not $LogPath)    { $LogPath    = Join-Path (Join-Path $env:ProgramData 'bonkey') 'runner-watch.log' }

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    try {
        $dir = Split-Path $LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -Path $LogPath -Value $line -Encoding utf8
    } catch { Write-Output "  (could not write $LogPath : $($_.Exception.Message))" }
}

# --- Check 1: the container exists and is running -------------------------

function Test-RunnerContainer {
    # `docker ps -a`, NOT `docker ps`. The distinction is the whole point:
    # a STOPPED container is recovered by restart:unless-stopped, a REMOVED
    # one is not, and only -a tells them apart.
    $all = @(docker ps -a --filter 'name=docker-runner-runner' --format '{{.Names}}:{{.State}}' 2>$null)
    if (-not $all) { return 'absent' }
    if ($all -match ':running')  { return 'running' }
    return 'stopped'
}

function Repair-Runner {
    if ($WhatIf) { Write-Log 'WOULD' "docker compose up -d in $ComposeDir"; return }
    Push-Location $ComposeDir
    try {
        docker compose up -d 2>&1 | ForEach-Object { Write-Log 'INFO' "  compose: $_" }
        Start-Sleep -Seconds 5
        $state = Test-RunnerContainer
        if ($state -eq 'running') { Write-Log 'FIXED' 'runner recreated and running' }
        else { Write-Log 'ERROR' "compose ran but container state is '$state'" }
    } finally { Pop-Location }
}

# --- Check 2: is the queue actually moving? -------------------------------

function Test-StuckQueue {
    # A backlog is NOT a fault. One ephemeral runner drains strictly one job at
    # a time, so a deep queue is normal and expected. What distinguishes a dead
    # fleet is that nothing has STARTED while work waits.
    $now        = (Get-Date).ToUniversalTime()
    $oldest     = $null
    $lastStart  = $null
    $queued     = 0

    foreach ($repo in $Repos) {
        $json = gh run list --repo $repo --limit 40 `
                    --json status,createdAt,startedAt,name 2>$null
        if (-not $json) { Write-Log 'WARN' "could not read runs for $repo"; continue }
        foreach ($run in ($json | ConvertFrom-Json)) {
            if ($run.status -in @('queued','waiting','pending')) {
                $queued++
                $c = [datetime]::Parse($run.createdAt).ToUniversalTime()
                if (-not $oldest -or $c -lt $oldest) { $oldest = $c }
            }
            if ($run.startedAt) {
                $s = [datetime]::Parse($run.startedAt).ToUniversalTime()
                if (-not $lastStart -or $s -gt $lastStart) { $lastStart = $s }
            }
        }
    }

    if ($queued -eq 0) { Write-Log 'OK' 'no queued jobs'; return }

    $waitMin  = [math]::Round(($now - $oldest).TotalMinutes)
    $quietMin = if ($lastStart) { [math]::Round(($now - $lastStart).TotalMinutes) } else { 9999 }

    if ($waitMin -ge $QueuedMinutes -and $quietMin -ge $NoStartMinutes) {
        Write-Log 'ALERT' "STUCK: $queued queued, oldest ${waitMin}m, nothing started for ${quietMin}m"
        Write-Log 'ALERT' '  a draining queue starts jobs; this one is not. Investigate the fleet.'
    } else {
        Write-Log 'OK' "$queued queued, oldest ${waitMin}m, last start ${quietMin}m ago - draining"
    }
}

# --- main -----------------------------------------------------------------

$state = Test-RunnerContainer
switch ($state) {
    'running' { Write-Log 'OK'    'runner container running' }
    'stopped' { Write-Log 'WARN'  'container stopped - compose up will restart it'; Repair-Runner }
    'absent'  { Write-Log 'ALERT' 'container ABSENT (removed, not stopped) - this is the BI-25 failure'; Repair-Runner }
}

try { Test-StuckQueue } catch { Write-Log 'WARN' "queue check failed: $($_.Exception.Message)" }
