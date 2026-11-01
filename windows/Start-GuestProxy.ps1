#Requires -Version 5.1
[CmdletBinding()]
param([switch]$FromAutostart, [ValidateSet('Auto','ScheduledTask','ExplorerShell')][string]$LauncherMethod = 'Auto')
. (Join-Path $PSScriptRoot 'scripts/Lifecycle.ps1')
Ensure-StateDirectory
$deploymentPath = Join-Path $script:StateRoot 'deployment.json'
if (!(Test-Path -LiteralPath $deploymentPath)) { throw 'Inspect and configure on this computer first.' }
$deployment = Read-JsonFile $deploymentPath
if ($deployment.ComputerName -ne $env:COMPUTERNAME) { throw 'Deployment belongs to another computer.' }
$verifiedCore = Get-CorePath
if ($verifiedCore -ne $deployment.CorePath -or (Get-GuestFileHash -LiteralPath $verifiedCore -Algorithm SHA256).Hash -ne $deployment.CoreSha256) { throw 'Core identity changed; inspect and reconfigure before starting.' }
if ($FromAutostart -and (Test-Path -LiteralPath $script:DisabledPath)) {
    Write-Lifecycle @{ LifecycleState = 'Disabled'; RecoveryEnabled = $false }
    Write-Output 'Guest proxy remains persistently disabled. Explicitly run Start-GuestProxy.ps1 to enable it.'
    return
}
if (!$FromAutostart) { Remove-Item -LiteralPath $script:DisabledPath -ErrorAction SilentlyContinue }
$mutex = New-Object Threading.Mutex($false, ('Local\CodexGuestBroker-' + $script:LifecycleId))
$locked = $false
try {
    try { $locked = $mutex.WaitOne(15000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another lifecycle start is in progress.' }
    $state = Read-Lifecycle
    if ($state -and (Test-OwnSupervisor ([int]$state.SupervisorPid))) {
        $observation = Get-CoreObservation
        Write-Output ('Existing supervisor PID ' + $state.SupervisorPid + '; core PID ' + $observation.CorePid)
        Write-Output 'Persistence still requires independent readiness/recovery acceptance; no duplicate supervisor was launched.'
        return
    }
    Write-Lifecycle @{ SupervisorPid = 0; CorePid = 0; RecoveryEnabled = $true; ReadyPending = $true; LifecycleState = 'Launching'; LastEventUtc = [DateTime]::UtcNow.ToString('o') }
    $launcher = ''
    try {
        if ($LauncherMethod -eq 'ExplorerShell') { throw 'Explorer launcher explicitly selected for ordinary-user shell validation.' }
        Register-GuestTask | Out-Null
        Write-Lifecycle @{ LauncherMethod = 'ScheduledTask'; ReadyPending = $true }
        Start-ScheduledTask -TaskName $script:GuestTaskName -ErrorAction Stop
        $launcher = 'ScheduledTask'
        Write-LifecycleEvent 'LaunchRequested' 'ScheduledTask'
    } catch {
        $message = $_.Exception.Message
        if ($LauncherMethod -eq 'ScheduledTask') { throw }
        if ($message -match 'unrelated|principal differs|policy|blocked|AppLocker|not allowed') {
            Write-Lifecycle @{ LifecycleState = 'Blocked'; RecoveryEnabled = $false; LastReason = 'TaskConflictOrPolicy' }
            throw 'Task identity conflicts or an explicit policy blocks this action. No alternative scheduler API or elevation was attempted.'
        }
        if ($LauncherMethod -eq 'ExplorerShell') { Write-LifecycleEvent 'ExplicitLauncher' 'ExplorerShellPending' }
        else { Write-LifecycleEvent 'SchedulerUnavailable' 'ExplorerUserFallback'; Write-Lifecycle @{ SchedulerFailureType = $_.Exception.GetType().Name; SchedulerFailureHResult = $_.Exception.HResult } }
        Write-Lifecycle @{ LauncherMethod = 'ExplorerShell'; ReadyPending = $true }
        Invoke-ExplorerSupervisor
        $launcher = 'ExplorerShell'
        Write-LifecycleEvent 'LaunchRequested' 'ExplorerShellPending'
    }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $state = Read-Lifecycle
        if ($state -and (Test-OwnSupervisor ([int]$state.SupervisorPid))) {
            $observation = Get-CoreObservation
            if ($observation.Healthy) {
                Write-Output ('Guest proxy local listener ready at http://127.0.0.1:' + $deployment.MixedPort + '; supervisor PID ' + $state.SupervisorPid + '; core PID ' + $observation.CorePid)
                Write-Output ('Launcher: ' + $state.LauncherMethod + '. ReadyPending: cross-command/turn survival and recovery checks are required before Codex integration.')
                return
            }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Lifecycle @{ LifecycleState = 'LaunchPending'; ReadyPending = $true; LastReason = 'BrokerLaunchNotYetVerified' }
    throw 'Supervisor startup has not been verified. Inspect lifecycle.json and local logs; do not integrate Codex into this endpoint yet.'
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
