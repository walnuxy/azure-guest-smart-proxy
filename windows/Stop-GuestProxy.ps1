#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'scripts/Lifecycle.ps1')
Ensure-StateDirectory
[IO.File]::WriteAllText($script:DisabledPath, [DateTime]::UtcNow.ToString('o'), (New-Object Text.UTF8Encoding($false)))
Write-Lifecycle @{ Disabled = $true; RecoveryEnabled = $false; LifecycleState = 'Stopping'; LastEventUtc = [DateTime]::UtcNow.ToString('o') }
Write-LifecycleEvent 'StopRequested' 'PersistentDisable'
$state = Read-Lifecycle
$task = Get-OwnGuestTask
if ($task) { try { Stop-ScheduledTask -TaskName $script:GuestTaskName -ErrorAction Stop } catch { Write-LifecycleEvent 'TaskStopUnavailable' 'ContinueIdentityCheckedStop' } }
if ($state -and (Test-OwnSupervisor ([int]$state.SupervisorPid))) {
    Stop-Process -Id ([int]$state.SupervisorPid) -ErrorAction SilentlyContinue
}
Stop-OwnedCore
Write-Lifecycle @{ SupervisorPid = 0; CorePid = 0; RecoveryEnabled = $false; Disabled = $true; LifecycleState = 'Disabled'; LastEventUtc = [DateTime]::UtcNow.ToString('o') }
Write-Output 'This guest instance is persistently disabled and its identity-checked processes were stopped.'
Write-Output 'Supervisor and login startup will not restart it. Explicit Start-GuestProxy.ps1 enables recovery again; unrelated proxies were untouched.'
