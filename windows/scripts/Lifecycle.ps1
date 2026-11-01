. (Join-Path $PSScriptRoot 'Common.ps1')
try { Import-Module ScheduledTasks -Scope Local -ErrorAction Stop; $script:SchedulerAvailable = $true } catch { $script:SchedulerAvailable = $false }
$script:DisabledPath = Join-Path $script:StateRoot 'disabled.flag'
$script:LifecyclePath = Join-Path $script:StateRoot 'lifecycle.json'
$identityHasher = [Security.Cryptography.SHA256]::Create()
try { $script:LifecycleId = [BitConverter]::ToString($identityHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:PackageRoot.ToLowerInvariant()))).Replace('-','').Substring(0,16) } finally { $identityHasher.Dispose() }
$script:GuestTaskName = 'CodexAzureGuest-' + $script:LifecycleId
$script:SupervisorPath = Join-Path $script:PackageRoot 'Supervise-GuestProxy.ps1'
$script:PowerShellPath = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
function Read-Lifecycle {
    if (Test-Path -LiteralPath $script:LifecyclePath) { try { return Read-JsonFile $script:LifecyclePath } catch { } }
    return $null
}
function Write-Lifecycle($Values) {
    Ensure-StateDirectory
    $state = [ordered]@{ SchemaVersion = 1; ComputerName = $env:COMPUTERNAME; PackageRoot = $script:PackageRoot; SupervisorPid = 0; CorePid = 0; TaskName = $script:GuestTaskName; LauncherMethod = ''; RecoveryEnabled = $false; Disabled = $false; ReadyPending = $true; LifecycleState = 'NotStarted'; RestartCount = 0; LastHeartbeatUtc = ''; LastHealthyUtc = ''; LastEventUtc = '' }
    $old = Read-Lifecycle
    if ($old) { foreach ($property in $old.PSObject.Properties) { $state[$property.Name] = $property.Value } }
    foreach ($key in $Values.Keys) { $state[$key] = $Values[$key] }
    $state.Disabled = Test-Path -LiteralPath $script:DisabledPath
    if ($state.Disabled) { $state.RecoveryEnabled = $false }
    $temporary = $script:LifecyclePath + '.' + $PID + '.tmp'
    Write-JsonFile $state $temporary
    if (Test-Path -LiteralPath $script:LifecyclePath) {
        # Windows PowerShell 5.1 can bind $null to String.Empty for this
        # overload. A per-writer real backup path retains atomic replacement.
        $backup = $script:LifecyclePath + '.' + $PID + '.replace-backup'
        [IO.File]::Replace($temporary, $script:LifecyclePath, $backup)
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup }
    }
    else { [IO.File]::Move($temporary, $script:LifecyclePath) }
}
function Write-LifecycleEvent([string]$Event, [string]$Detail = '') {
    Ensure-StateDirectory
    $path = Join-Path $script:StateRoot 'supervisor.log'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 262144) {
        if (Test-Path -LiteralPath ($path + '.2')) { Remove-Item -LiteralPath ($path + '.2') }
        if (Test-Path -LiteralPath ($path + '.1')) { Move-Item -LiteralPath ($path + '.1') -Destination ($path + '.2') }
        Move-Item -LiteralPath $path -Destination ($path + '.1')
    }
    # Detail is a caller-selected event code, never raw proxy/config/error data.
    [IO.File]::AppendAllText($path, ([DateTime]::UtcNow.ToString('o') + ' ' + $Event + ' ' + $Detail + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}
function Test-OwnSupervisor([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $ProcessId) -ErrorAction SilentlyContinue
    return [bool]($process -and $process.ExecutablePath -eq $script:PowerShellPath -and $process.CommandLine -and $process.CommandLine.Contains($script:SupervisorPath))
}
function Get-CoreObservation {
    $deployment = Read-JsonFile (Join-Path $script:StateRoot 'deployment.json')
    $pidPath = Join-Path $script:StateRoot 'listener.json'
    if (!(Test-Path -LiteralPath $pidPath)) { return [pscustomobject]@{ Healthy = $false; Owned = $false; CorePid = 0; Reason = 'NoTrackedCore' } }
    $tracked = Read-JsonFile $pidPath
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $tracked.ListenerPid) -ErrorAction SilentlyContinue
    $configPath = Join-Path $script:StateRoot 'config.json'
    $owned = [bool]($process -and $process.ExecutablePath -eq $deployment.CorePath -and $process.CommandLine -and $process.CommandLine.Contains($configPath))
    if (!$owned) { return [pscustomobject]@{ Healthy = $false; Owned = $false; CorePid = 0; Reason = 'TrackedCoreExitedOrChanged' } }
    $listeners = Get-Listeners
    $mixed = @($listeners | Where-Object { $_.LocalPort -eq $deployment.MixedPort -and $_.OwningProcess -eq $tracked.ListenerPid })
    $api = @($listeners | Where-Object { $_.LocalPort -eq $deployment.ApiPort -and $_.OwningProcess -eq $tracked.ListenerPid })
    if (!$mixed.Count -or !$api.Count) { return [pscustomobject]@{ Healthy = $false; Owned = $true; CorePid = [int]$tracked.ListenerPid; Reason = 'LocalListenerMissing' } }
    try { $version = Invoke-GuestApi '/version' -TimeoutSec 3; $healthy = [bool]$version.version } catch { $healthy = $false }
    [pscustomobject]@{ Healthy = $healthy; Owned = $true; CorePid = [int]$tracked.ListenerPid; CoreCreationUtc = ([DateTime]$process.CreationDate).ToUniversalTime().ToString('o'); Reason = $(if ($healthy) { 'LocalApiHealthy' } else { 'LocalApiUnresponsive' }) }
}
function Stop-OwnedCore {
    $pidPath = Join-Path $script:StateRoot 'listener.json'
    if (!(Test-Path -LiteralPath $pidPath)) { return }
    $tracked = Read-JsonFile $pidPath
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $tracked.ListenerPid) -ErrorAction SilentlyContinue
    if ($process) {
        if ($process.ExecutablePath -ne $tracked.CorePath -or !$process.CommandLine -or !$process.CommandLine.Contains($tracked.ConfigPath)) { throw 'Tracked core identity differs; refusing to stop an unrelated process.' }
        Stop-Process -Id $tracked.ListenerPid -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pidPath -ErrorAction SilentlyContinue
}
function Get-OwnGuestTask {
    if (!$script:SchedulerAvailable) { return $null }
    $task = Get-ScheduledTask -TaskName $script:GuestTaskName -ErrorAction SilentlyContinue
    if (!$task) { return $null }
    $action = @($task.Actions) | Select-Object -First 1
    if (!$action -or $action.Execute -ne $script:PowerShellPath -or !$action.Arguments.Contains($script:SupervisorPath)) { throw 'Task name is occupied by an unrelated action; refusing to replace it.' }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principalSid = ''
    try {
        if ([string]$task.Principal.UserId -match '^S-\d-') { $principalSid = (New-Object Security.Principal.SecurityIdentifier([string]$task.Principal.UserId)).Value }
        else { $principalSid = (New-Object Security.Principal.NTAccount([string]$task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value }
    } catch { throw 'Task principal could not be resolved to the current user SID; refusing to reuse it.' }
    if ($principalSid -ne $user.User.Value -or [string]$task.Principal.RunLevel -notin @('Limited','0')) { throw 'Task principal differs from this limited user; refusing to reuse it.' }
    return $task
}
function Register-GuestTask([switch]$AtLogon) {
    if (!$script:SchedulerAvailable) { throw 'Task scheduler cmdlets unavailable.' }
    $existing = Get-OwnGuestTask
    if ($existing -and !$AtLogon) { return $existing }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $script:SupervisorPath + '" -LauncherMethod ScheduledTask'
    $action = New-ScheduledTaskAction -Execute $script:PowerShellPath -Argument $arguments -WorkingDirectory $script:PackageRoot
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
    $parameters = @{ TaskName = $script:GuestTaskName; Action = $action; Principal = $principal; Settings = $settings; Description = 'Current-user guest proxy supervisor; no administrator rights or TUN.'; Force = $true; ErrorAction = 'Stop' }
    if ($AtLogon) { $parameters.Trigger = New-ScheduledTaskTrigger -AtLogOn -User $user }
    Register-ScheduledTask @parameters
}
function Wait-GuestEnabled([int]$Seconds) {
    for ($second = 0; $second -lt $Seconds; $second++) {
        if (Test-Path -LiteralPath $script:DisabledPath) { return $false }
        if ($second -gt 0 -and $second % 5 -eq 0) { Write-Lifecycle @{ LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o') } }
        Start-Sleep -Seconds 1
    }
    return !(Test-Path -LiteralPath $script:DisabledPath)
}
function Invoke-ExplorerSupervisor {
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $explorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
    if (!$explorer.Count) { throw 'No current-user interactive Explorer shell exists. No bare child-process fallback was used.' }
    $arguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $script:SupervisorPath + '" -LauncherMethod ExplorerShell'
    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute($script:PowerShellPath, $arguments, $script:PackageRoot, 'open', 0)
}
