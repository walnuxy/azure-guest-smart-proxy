#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('ScheduledTask','ExplorerShell','Manual')][string]$LauncherMethod = 'Manual')
. (Join-Path $PSScriptRoot 'scripts/Lifecycle.ps1')
Ensure-StateDirectory
$mutex = New-Object Threading.Mutex($false, ('Local\CodexGuestSupervisor-' + $script:LifecycleId))
$locked = $false
$started = [DateTime]::UtcNow
$restartCount = 0
$failureBurst = 0
$badChecks = 0
$backoff = @(2,5,15,30,60)
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { return }
    if (Test-Path -LiteralPath $script:DisabledPath) { return }
    $self = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction SilentlyContinue
    $parentId = 0
    if ($self) { $parentId = [int]$self.ParentProcessId }
    $supervisorCreation = $started.ToString('o')
    if ($self) { $supervisorCreation = ([DateTime]$self.CreationDate).ToUniversalTime().ToString('o') }
    $runtimeIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $runtimePrincipal = New-Object Security.Principal.WindowsPrincipal($runtimeIdentity)
    $isElevated = $runtimePrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Lifecycle @{ SupervisorPid = $PID; SupervisorCreationUtc = $supervisorCreation; SupervisorScriptPath = $script:SupervisorPath; SupervisorExePath = $script:PowerShellPath; CorePid = 0; LauncherMethod = $LauncherMethod; RecoveryEnabled = $true; ReadyPending = $true; LifecycleState = 'Starting'; ValidationStartedUtc = $started.ToString('o'); ParentPid = $parentId; IsElevated = $isElevated; LastHeartbeatUtc = $started.ToString('o'); LastEventUtc = $started.ToString('o') }
    Write-LifecycleEvent 'SupervisorStarted' $LauncherMethod
    while (!(Test-Path -LiteralPath $script:DisabledPath)) {
        $observation = Get-CoreObservation
        if ($observation.Healthy) {
            $badChecks = 0
            Write-Lifecycle @{ SupervisorPid = $PID; CorePid = $observation.CorePid; CoreCreationUtc = $observation.CoreCreationUtc; RecoveryEnabled = $true; LifecycleState = 'Healthy'; RestartCount = $restartCount; LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o'); LastHealthyUtc = [DateTime]::UtcNow.ToString('o') }
            if (([DateTime]::UtcNow - $started).TotalSeconds -gt 300) { $failureBurst = 0 }
            if (!(Wait-GuestEnabled 5)) { break }
            continue
        }
        if ($observation.Owned) {
            $badChecks++
            Write-Lifecycle @{ CorePid = $observation.CorePid; LifecycleState = 'LocalHealthRetry'; LastReason = $observation.Reason; LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o') }
            if ($badChecks -lt 3) { if (!(Wait-GuestEnabled 5)) { break }; continue }
            Stop-OwnedCore
        }
        $failureBurst++
        if ($failureBurst -gt ($backoff.Count + 1)) {
            Write-Lifecycle @{ CorePid = 0; LifecycleState = 'Cooldown'; LastReason = 'RepeatedLocalStartOrExitFailure'; LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o'); NextRetryUtc = [DateTime]::UtcNow.AddSeconds(300).ToString('o') }
            Write-LifecycleEvent 'RecoveryCooldown' 'FiveMinutes'
            if (!(Wait-GuestEnabled 300)) { break }
            $failureBurst = 1
        } elseif ($failureBurst -gt 1) {
            $delay = $backoff[$failureBurst - 2]
            Write-Lifecycle @{ CorePid = 0; LifecycleState = 'Backoff'; LastReason = $observation.Reason; LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o'); NextRetryUtc = [DateTime]::UtcNow.AddSeconds($delay).ToString('o') }
            if (!(Wait-GuestEnabled $delay)) { break }
        }
        $restartCount++
        Write-Lifecycle @{ CorePid = 0; LifecycleState = 'Recovering'; RestartCount = $restartCount; LastReason = $observation.Reason; LastEventUtc = [DateTime]::UtcNow.ToString('o'); LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o') }
        Write-LifecycleEvent 'CoreRecovery' $observation.Reason
        try {
            if (Test-Path -LiteralPath $script:DisabledPath) { break }
            & (Join-Path $PSScriptRoot 'scripts/Start-Core.ps1') | Out-Null
            $observation = Get-CoreObservation
            if (!$observation.Healthy) { throw 'Core did not become locally healthy.' }
            $badChecks = 0
            $started = [DateTime]::UtcNow
            Write-Lifecycle @{ CorePid = $observation.CorePid; CoreCreationUtc = $observation.CoreCreationUtc; LifecycleState = 'Healthy'; RestartCount = $restartCount; LastHealthyUtc = [DateTime]::UtcNow.ToString('o'); LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o') }
            Write-LifecycleEvent 'CoreReady' ('PID=' + $observation.CorePid)
        } catch {
            Write-LifecycleEvent 'RecoveryFailed' ('Attempt=' + $failureBurst)
        }
    }
} catch {
    Write-LifecycleEvent 'SupervisorFailed' 'LocalLifecycleError'
    Write-Lifecycle @{ LifecycleState = 'SupervisorFailed'; LastReason = 'LocalLifecycleError'; RecoveryEnabled = $false; LastEventUtc = [DateTime]::UtcNow.ToString('o') }
    throw
} finally {
    if ($locked) {
        if (Test-Path -LiteralPath $script:DisabledPath) { Stop-OwnedCore; Write-Lifecycle @{ SupervisorPid = 0; CorePid = 0; LifecycleState = 'Disabled'; RecoveryEnabled = $false; LastEventUtc = [DateTime]::UtcNow.ToString('o') }; Write-LifecycleEvent 'SupervisorStopped' 'Disabled' }
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
