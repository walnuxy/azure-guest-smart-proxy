#Requires -Version 5.1
[CmdletBinding()]
param([int]$TimeoutSeconds = 45)
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
Ensure-StateDirectory
$deployment = Read-JsonFile (Join-Path $script:StateRoot 'deployment.json')
$configPath = Join-Path $script:StateRoot 'config.json'
$lifecyclePath = Join-Path $script:StateRoot 'lifecycle.json'
if (!(Test-Path -LiteralPath $lifecyclePath)) { throw 'Start the supervised proxy before testing recovery.' }
$life = Read-JsonFile $lifecyclePath
if ((Get-PropertyValue $life 'Disabled' $true) -or !(Get-PropertyValue $life 'RecoveryEnabled' $false)) { throw 'Recovery is disabled; no process was stopped.' }
$supervisorPid = [int](Get-PropertyValue $life 'SupervisorPid' 0)
$supervisorPath = Join-Path $PSScriptRoot 'Supervise-GuestProxy.ps1'
$supervisor = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $supervisorPid) -ErrorAction SilentlyContinue
if (!$supervisor -or !$supervisor.CommandLine -or !$supervisor.CommandLine.Contains($supervisorPath)) { throw 'Supervisor identity could not be verified; no process was stopped.' }
$corePid = [int](Get-PropertyValue $life 'CorePid' 0)
$core = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $corePid) -ErrorAction SilentlyContinue
$listeners = @(Get-Listeners | Where-Object { $_.LocalPort -eq $deployment.MixedPort -and $_.OwningProcess -eq $corePid -and $_.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::') })
if (!$core -or !$core.CommandLine -or $core.ExecutablePath -ne $deployment.CorePath -or !$core.CommandLine.Contains($configPath) -or !$listeners.Count) { throw 'Core identity/port differs; no process was stopped.' }
if ((Get-GuestFileHash -LiteralPath $deployment.CorePath -Algorithm SHA256).Hash -ne $deployment.CoreSha256) { throw 'Core hash changed; no process was stopped.' }
$null = Invoke-GuestApi '/version'
$oldCoreCreatedUtc = ([DateTime]$core.CreationDate).ToUniversalTime().ToString('o')
$start = [DateTime]::UtcNow
$record = [ordered]@{ ComputerName=$env:COMPUTERNAME; ConfigSha256=(Get-GuestFileHash -LiteralPath $configPath -Algorithm SHA256).Hash; CoreSha256=$deployment.CoreSha256; SupervisorPid=$supervisorPid; OldCorePid=$corePid; OldCoreCreationUtc=$oldCoreCreatedUtc; NewCorePid=0; NewCoreCreationUtc=''; StartedUtc=$start.ToString('o'); CompletedUtc=$null; Passed=$false; RecoverySeconds=$null }
Write-JsonFile $record (Join-Path $script:StateRoot 'recovery-test.json')
Write-Output 'Testing unexpected exit of this package core only; a brief interruption is expected.'
Stop-Process -Id $corePid -ErrorAction Stop
$recovered = $false
while (([DateTime]::UtcNow - $start).TotalSeconds -lt $TimeoutSeconds) {
    Start-Sleep -Milliseconds 500
    try {
        $current = Read-JsonFile $lifecyclePath
        if ([int]$current.SupervisorPid -ne $supervisorPid -or $current.Disabled) { throw 'Supervisor changed or deployment was stopped.' }
        $newPid = [int](Get-PropertyValue $current 'CorePid' 0)
        if (!$newPid) { continue }
        $newProcess = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $newPid) -ErrorAction SilentlyContinue
        if (!$newProcess -or $newProcess.ExecutablePath -ne $deployment.CorePath -or !$newProcess.CommandLine.Contains($configPath)) { continue }
        $newCreatedUtc = ([DateTime]$newProcess.CreationDate).ToUniversalTime().ToString('o')
        if ($newPid -eq $corePid -and $newCreatedUtc -eq $oldCoreCreatedUtc) { continue }
        if ([DateTime]::Parse($newCreatedUtc).ToUniversalTime() -lt $start) { continue }
        $newListeners = @(Get-Listeners | Where-Object { $_.LocalPort -eq $deployment.MixedPort -and $_.OwningProcess -eq $newPid })
        if (!$newListeners.Count) { continue }
        $null = Invoke-GuestApi '/version' -TimeoutSec 2
        $record.NewCorePid = $newPid
        $record.NewCoreCreationUtc = $newCreatedUtc
        $record.Passed = $true
        $record.RecoverySeconds = [Math]::Round(([DateTime]::UtcNow - $start).TotalSeconds,2)
        $recovered = $true
        break
    } catch { }
}
$record.CompletedUtc = [DateTime]::UtcNow.ToString('o')
Write-JsonFile $record (Join-Path $script:StateRoot 'recovery-test.json')
if (!$recovered) { throw 'Automatic recovery was not observed in time. Leave Codex on its previous working proxy and inspect lifecycle diagnostics.' }
Write-Output ('Automatic recovery verified in ' + $record.RecoverySeconds + ' seconds; new core PID ' + $record.NewCorePid + '.')
Write-Output 'Re-run BeginObservation and ConfirmObservation before integration. This does not prove desktop model generation.'
