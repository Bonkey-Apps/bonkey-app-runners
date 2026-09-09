<#
.SYNOPSIS
    Decides whether the Docker VM ran continuously across a window, and if not,
    WHY it did not. Three outcomes, not two (BI-42).

.DESCRIPTION
    A job that dies on this host has an ambiguous signature: no step conclusion,
    logs 404, GitHub marks it failed ~10-17 minutes later. That looks exactly
    like a crash in the code under test, and two products have now spent a day
    each debugging application code for a failure that happened underneath them.
    This script exists so the ambiguity can be resolved in one command instead
    of by an Infra human reading uptime.

    RECORD a baseline before the window, CHECK it after:

        .\Test-VmContinuity.ps1 -Record        # before the job
        .\Test-VmContinuity.ps1                # after the job

    VERDICTS

      CONTINUOUS  boot_id unchanged, btime unmoved. The VM was up the whole
                  window. A job that died in it died of its own causes, and a
                  "no OOM in dmesg" reading is TRUSTWORTHY.

      REBOOTED    boot_id changed. The kernel is a different kernel. The ring
                  buffer does not cover the window, so "no OOM" means NOTHING
                  -- not "clean". Any job in flight was killed by the reboot.

      SUSPENDED   boot_id unchanged but btime moved forward N seconds. The
                  Windows host was asleep (Modern Standby / S3) for ~N seconds
                  and the VM was frozen, not rebooted. Wall-clock time passed
                  that the VM did not experience. A job in flight may still
                  have been killed -- GitHub times out a runner that stops
                  heartbeating -- but the kernel buffer DOES still cover the
                  window.

.NOTES
    WHY boot_id AND NOT THE TWO INSTRUMENTS THAT CAME BEFORE IT

    1. `now - uptime` jitters +/-1s. `date +%s` and /proc/uptime are sampled
       microseconds apart and uptime truncates to whole seconds, so the
       computed value moves between reads. This produced a false
       `*** VM REBOOTED ***` on BI-42 with a one-second "difference".

    2. `/proc/stat`'s btime is stable across reads -- that fix was correct as
       far as it went -- but it is NOT a boot identity. Linux computes btime as
       (wall clock now) - (monotonic uptime). Under WSL2 the monotonic clock
       FREEZES while the Windows host is in Modern Standby, and the wall clock
       is resynced from the host on resume. So btime marches forward on a
       kernel that never rebooted, by exactly the amount of host sleep.
       MEASURED on this host 2026-09-09: btime moved 5853s (97m33s) with no
       reboot -- Runner.Listener's own log file, Runner_20260909-201533-utc.log,
       shows the process it claimed had started at 21:53:19Z actually wrote its
       first line at 20:15:33Z and logged continuously across the "reboot".

    3. /proc/sys/kernel/random/boot_id is a random UUID generated once at boot
       and held in memory. It is not derived from any clock, so no amount of
       clock stepping, NTP correction or host suspend can move it. It changes
       if and only if the kernel is a new kernel.

    btime is still READ here -- not as a boot identity, but because its
    movement is the measurement of how long the host slept. The instrument
    that caused the false positive becomes the second signal.

    Safe to run repeatedly. Read-only: starts nothing, stops nothing,
    reconfigures nothing. Uses no GCE (owner standing rule: never use GCE
    without permission).
#>
[CmdletBinding()]
param(
    # Write the current boot identity to the baseline file and exit.
    [switch] $Record,

    # Where the baseline lives. Overridable so the detector can be exercised
    # against a fabricated baseline without disturbing the real one.
    [string] $BaselinePath,

    # btime movement below this is ignored. btime is stable across reads, but
    # an NTP step on the Windows host can nudge it a second or two, and a
    # detector that cries wolf gets ignored -- which costs exactly as much as
    # one that cannot fire at all.
    [int]    $SuspendToleranceSeconds = 60,

    # Exit 2 on REBOOTED or SUSPENDED, for use as a gate in a job wrapper.
    # Default is exit 0 always, so the script is safe in a pipeline that has
    # not opted in to failing on it.
    #
    # CALLER TRAP, found while mutation-testing this script: if you PIPE the
    # output into something that short-circuits the pipeline (`| Select-Object
    # -First 4`, `| Select-String -Quiet`), `exit 2` is never reached and the
    # gate silently reports success. Verified: piped -> exitcode 0 on a
    # REBOOTED verdict; unpiped via `powershell -File` -> exitcode 2.
    # Invoke it as
    #     powershell -NoProfile -File .\Test-VmContinuity.ps1 -FailOnChange
    # and read $LASTEXITCODE without a truncating pipe.
    [switch] $FailOnChange
)

$ErrorActionPreference = 'Stop'

if (-not $BaselinePath) {
    $BaselinePath = Join-Path (Join-Path $env:ProgramData 'bonkey') 'vm-boot-baseline.json'
}

function Get-BootIdentity {
    # GUARD: `wsl -d docker-desktop` on a STOPPED distro BOOTS it -- which
    # would both take a new boot_id and make this read the very thing it is
    # supposed to observe. `docker info` succeeding proves the daemon, and
    # therefore the VM, is already up, so the read below cannot start anything.
    docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Docker daemon is not responding -- the VM is down or starting. Not reading boot identity, because doing so could start it.'
    }

    # One shell, two reads. Deliberately NOT `now - uptime`.
    #
    # The field is split HERE rather than with an inline awk program: the
    # quoting of `awk "/^btime/{print \$2}"` does not survive the
    # PowerShell -> wsl.exe -> sh argument boundary intact (it arrives as a
    # syntax error), and a detector whose read silently half-fails is the
    # failure mode this whole script exists to end.
    $raw = wsl -d docker-desktop sh -c "cat /proc/sys/kernel/random/boot_id; grep ^btime /proc/stat"
    $lines = @($raw | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    if ($lines.Count -lt 2) { throw "Unexpected read from docker-desktop: '$raw'" }

    $btimeField = ($lines[1] -split '\s+')[1]
    if (-not $btimeField) { throw "Could not parse btime from '$($lines[1])'" }

    return [pscustomobject]@{
        boot_id      = $lines[0]
        btime        = [long]$btimeField
        recorded_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

$current = Get-BootIdentity

if ($Record) {
    $dir = Split-Path $BaselinePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $current | ConvertTo-Json | Set-Content -Path $BaselinePath -Encoding utf8
    Write-Output "RECORDED baseline -> $BaselinePath"
    Write-Output ("  boot_id={0} btime={1}" -f $current.boot_id, $current.btime)
    exit 0
}

if (-not (Test-Path $BaselinePath)) {
    Write-Output 'VERDICT=UNKNOWN'
    Write-Output "  No baseline at $BaselinePath. Run with -Record before the window."
    Write-Output '  UNKNOWN is not CONTINUOUS. Do not read it as "clean".'
    exit 0
}

$base = Get-Content $BaselinePath -Raw | ConvertFrom-Json
$drift = $current.btime - $base.btime

Write-Output ("baseline  boot_id={0} btime={1} at {2}" -f $base.boot_id, $base.btime, $base.recorded_utc)
Write-Output ("current   boot_id={0} btime={1} at {2}" -f $current.boot_id, $current.btime, $current.recorded_utc)
Write-Output ''

$changed = $false

if ($current.boot_id -ne $base.boot_id) {
    $changed = $true
    Write-Output 'VERDICT=REBOOTED'
    Write-Output '  The Docker VM rebooted during this window. boot_id is a different UUID,'
    Write-Output '  so this is a different kernel -- not a clock artifact.'
    Write-Output '  * Any job in flight was KILLED by this, not by its own code.'
    Write-Output '  * The kernel ring buffer does NOT cover the window. A "no OOM" reading'
    Write-Output '    from dmesg means nothing here.'
}
elseif ($drift -ge $SuspendToleranceSeconds) {
    $changed = $true
    $m = [math]::Round($drift / 60.0, 1)
    Write-Output 'VERDICT=SUSPENDED'
    Write-Output ("  Same kernel (boot_id unchanged), but btime advanced {0}s (~{1} min)." -f $drift, $m)
    Write-Output '  The Windows HOST was asleep for about that long and the VM was frozen.'
    Write-Output '  * NOT a reboot. Do not report one.'
    Write-Output '  * The ring buffer DOES still cover the window -- dmesg is trustworthy.'
    Write-Output '  * A job in flight may still have died: a frozen runner stops'
    Write-Output '    heartbeating and GitHub times it out with no step conclusion.'
}
else {
    Write-Output 'VERDICT=CONTINUOUS'
    Write-Output ("  Same kernel, btime moved {0}s (within {1}s tolerance)." -f $drift, $SuspendToleranceSeconds)
    Write-Output '  The VM ran continuously. A job that failed in this window failed on its'
    Write-Output '  own merits, and dmesg evidence for the window is trustworthy.'
}

if ($changed -and $FailOnChange) { exit 2 }
exit 0
