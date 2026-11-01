# Requires -Version 5.1
[CmdletBinding()]
param([switch]$BeginObservation, [switch]$ConfirmObservation, [switch]$TestHttps, [string]$ReportPath = '')
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$detectorCreatedUtc = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o')
if ($BeginObservation -and $ConfirmObservation) { throw 'Choose BeginObservation or ConfirmObservation, not both.' }
$deploymentPath = Join-Path $script:StateRoot 'deployment.json'
if (!(Test-Path -LiteralPath $deploymentPath)) { throw 'No deployment.json. Configure this package on this computer first.' }
$runtime = Read-JsonFile $deploymentPath
$configPath = [IO.Path]::GetFullPath((Join-Path $script:StateRoot 'config.json'))
$corePath = [IO.Path]::GetFullPath([string]$runtime.CorePath)
$configHash = (Get-GuestFileHash -LiteralPath $configPath -Algorithm SHA256).Hash
$coreHash = (Get-GuestFileHash -LiteralPath $corePath -Algorithm SHA256).Hash
$lifecycle = $null
$lifecyclePath = Join-Path $script:StateRoot 'lifecycle.json'
if (Test-Path -LiteralPath $lifecyclePath) { $lifecycle = Read-JsonFile $lifecyclePath }
$coreId = [int](Get-PropertyValue $lifecycle 'CorePid' 0)
$supervisorId = [int](Get-PropertyValue $lifecycle 'SupervisorPid' 0)
$core = $null; $supervisor = $null
if ($coreId -gt 0) { $core = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $coreId) -ErrorAction SilentlyContinue }
if ($supervisorId -gt 0) { $supervisor = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $supervisorId) -ErrorAction SilentlyContinue }
$supervisorScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Supervise-GuestProxy.ps1'))
# Inspect identity markers only; never persist or print command lines.
$coreCommand = [string](Get-PropertyValue $core 'CommandLine' '')
$supervisorCommand = [string](Get-PropertyValue $supervisor 'CommandLine' '')
$coreMatches = $core -and [string]$core.ExecutablePath -eq $corePath -and $coreCommand.IndexOf($configPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
$expectedSupervisorExe = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$supervisorMatches = $supervisor -and [string]$supervisor.ExecutablePath -eq $expectedSupervisorExe -and $supervisorCommand.IndexOf($supervisorScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
$coreCreated = $null; $supervisorCreated = $null
if ($core -and $core.CreationDate) { $coreCreated = $core.CreationDate.ToUniversalTime().ToString('o') }
if ($supervisor -and $supervisor.CreationDate) { $supervisorCreated = $supervisor.CreationDate.ToUniversalTime().ToString('o') }
$coreMatches = $coreMatches -and $coreCreated -eq [string](Get-PropertyValue $lifecycle 'CoreCreationUtc' '')
$supervisorMatches = $supervisorMatches -and $supervisorCreated -eq [string](Get-PropertyValue $lifecycle 'SupervisorCreationUtc' '') -and $supervisorScript -eq [string](Get-PropertyValue $lifecycle 'SupervisorScriptPath' '') -and $expectedSupervisorExe -eq [string](Get-PropertyValue $lifecycle 'SupervisorExePath' '')
$listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
$mixedMatches = @($listeners | Where-Object { [int]$_.LocalPort -eq [int]$runtime.MixedPort -and [int]$_.OwningProcess -eq $coreId -and $_.LocalAddress -in @('127.0.0.1', '::1') }).Count -gt 0
$apiMatches = @($listeners | Where-Object { [int]$_.LocalPort -eq [int]$runtime.ApiPort -and [int]$_.OwningProcess -eq $coreId -and $_.LocalAddress -in @('127.0.0.1', '::1') }).Count -gt 0
$computerMatches = $runtime.ComputerName -eq $env:COMPUTERNAME
$hashMatches = $coreHash -eq [string]$runtime.CoreSha256
$disabled = [bool](Get-PropertyValue $lifecycle 'Disabled' $true)
$recoveryEnabled = [bool](Get-PropertyValue $lifecycle 'RecoveryEnabled' $false)
$heartbeatFresh = $false
try { $heartbeatAge = ([DateTime]::UtcNow - [DateTime]::Parse([string]$lifecycle.LastHeartbeatUtc).ToUniversalTime()).TotalSeconds; $heartbeatFresh = $heartbeatAge -ge -5 -and $heartbeatAge -lt 60 } catch { }
$apiState = 'NotChecked'; $route = $null; $https = $null
if ($coreMatches -and $mixedMatches -and $apiMatches) {
    try { $route = [string](Invoke-GuestApi '/proxies/AUTO').now; $apiState = 'Reachable' } catch { $apiState = 'Unavailable' }
    if ($TestHttps -or $BeginObservation -or $ConfirmObservation) { $https = Test-HttpsProxy ('http://127.0.0.1:' + $runtime.MixedPort) }
}
$localHealth = $null -ne $https -and $https.Healthy
$identityReady = $computerMatches -and $hashMatches -and $coreMatches -and $supervisorMatches -and $mixedMatches -and $apiMatches -and $heartbeatFresh -and !$disabled -and $recoveryEnabled -and $apiState -eq 'Reachable'
$baselinePath = Join-Path $script:StateRoot 'survival-baseline.json'
$readinessPath = Join-Path $script:StateRoot 'readiness.json'
$survivalVerified = $false; $confirmationReason = 'NotRequested'; $failure = ''
if ($BeginObservation) {
    # Invalidate an earlier proof before attempting a new observation.
    Write-JsonFile ([ordered]@{ ComputerName = $env:COMPUTERNAME; SurvivalVerified = $false; LocalHealthPassed = [bool]$localHealth; State = 'Pending'; ModelGeneration = 'NotTested' }) $readinessPath
    Protect-PrivateFile $readinessPath
    if (!$identityReady -or !$localHealth) { $failure = 'Cannot begin observation: supervised listener identity, fresh heartbeat, hashes or HTTPS health failed.' }
    else {
        Write-JsonFile ([ordered]@{ ComputerName = $env:COMPUTERNAME; DetectorPid = $PID; DetectorCreationUtc = $detectorCreatedUtc; StartedUtc = [DateTime]::UtcNow.ToString('o'); ConfigSha256 = $configHash; CoreSha256 = $coreHash; MixedPort = [int]$runtime.MixedPort; ApiPort = [int]$runtime.ApiPort; SupervisorPid = $supervisorId; SupervisorCreatedUtc = $supervisorCreated; CorePid = $coreId; CoreCreatedUtc = $coreCreated }) $baselinePath
        Protect-PrivateFile $baselinePath
        $confirmationReason = 'BaselineSaved-ConfirmInAnotherPowerShellAfter10Seconds'
    }
}
if ($ConfirmObservation) {
    $confirmationReason = 'Failed'
    if (!(Test-Path -LiteralPath $baselinePath)) { $failure = 'No baseline. Run BeginObservation in a separate PowerShell command first.' }
    else {
        $baseline = Read-JsonFile $baselinePath
        $elapsed = ([DateTime]::UtcNow - [DateTime]::Parse($baseline.StartedUtc).ToUniversalTime()).TotalSeconds
        if ([int]$baseline.DetectorPid -eq $PID -and (Get-PropertyValue $baseline 'DetectorCreationUtc' '') -eq $detectorCreatedUtc) { $failure = 'Confirmation requires a different PowerShell process identity, not the same command.' }
        elseif ($elapsed -lt 10 -or $elapsed -gt 1800) { $failure = 'Observation must span 10 seconds to 30 minutes; repeat baseline if stale.' }
        elseif (!$identityReady -or !$localHealth) { $failure = 'Current listener identity, hashes, heartbeat or HTTPS health failed.' }
        elseif ($baseline.ComputerName -ne $env:COMPUTERNAME -or $baseline.ConfigSha256 -ne $configHash -or $baseline.CoreSha256 -ne $coreHash -or [int]$baseline.MixedPort -ne [int]$runtime.MixedPort -or [int]$baseline.ApiPort -ne [int]$runtime.ApiPort) { $failure = 'Machine/configuration/ports changed since baseline.' }
        elseif ([int]$baseline.SupervisorPid -ne $supervisorId -or $baseline.SupervisorCreatedUtc -ne $supervisorCreated) { $failure = 'Supervisor identity changed since baseline.' }
        elseif ([int]$baseline.CorePid -ne $coreId -or $baseline.CoreCreatedUtc -ne $coreCreated) { $failure = 'Core identity changed. Recovery needs separate evidence; repeat survival observation.' }
        else { $survivalVerified = $true; $confirmationReason = 'SameSupervisorAndCoreAcrossIndependentCommands' }
    }
    Write-JsonFile ([ordered]@{ ComputerName = $env:COMPUTERNAME; ConfigSha256 = $configHash; CoreSha256 = $coreHash; MixedPort = [int]$runtime.MixedPort; ApiPort = [int]$runtime.ApiPort; SupervisorPid = $supervisorId; VerifiedCorePid = $coreId; ConfirmedUtc = [DateTime]::UtcNow.ToString('o'); SurvivalVerified = $survivalVerified; LocalHealthPassed = [bool]$localHealth; ModelGeneration = 'NotTested'; VerificationScope = 'IndependentPowerShellCommandsOnly'; Failure = $failure }) $readinessPath
    Protect-PrivateFile $readinessPath
}
$report = [ordered]@{
    SchemaVersion = 2; GeneratedUtc = [DateTime]::UtcNow.ToString('o'); ComputerName = $env:COMPUTERNAME; DetectorPid = $PID
    ComputerMatches = $computerMatches; CoreHashMatches = $hashMatches; CoreIdentityMatches = [bool]$coreMatches; CorePid = $coreId; CoreCreatedUtc = $coreCreated
    SupervisorIdentityMatches = [bool]$supervisorMatches; SupervisorPid = $supervisorId; SupervisorCreatedUtc = $supervisorCreated; HeartbeatFresh = $heartbeatFresh
    MixedPort = [int]$runtime.MixedPort; ApiPort = [int]$runtime.ApiPort; MixedListenerMatches = $mixedMatches; ApiListenerMatches = $apiMatches
    RecoveryEnabled = $recoveryEnabled; Disabled = $disabled; Api = $apiState; CurrentRoute = $route; HttpsHealth = $https
    LocalHealthPassed = [bool]$localHealth; SurvivalVerified = $survivalVerified; Confirmation = $confirmationReason; Failure = $failure
    ModelGeneration = 'NotTested'; ApplicationEnvironmentAdoption = 'NotTested'; LongTermStability = 'NotEstablished'
    Acceptance = 'Independent command survival only, not survival across an entire Codex turn. Actual signed-in model generation and streaming require application testing.'
}
if (!$ReportPath) { $ReportPath = Join-Path $script:StateRoot ('diagnostics/deployment-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json') }
$directory = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
if (!(Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
Write-JsonFile $report $ReportPath
Protect-PrivateFile $ReportPath
Write-Output ('Deployment evidence: ' + $ReportPath)
Write-Output ('Owned core: ' + [bool]$coreMatches + '; owned supervisor: ' + [bool]$supervisorMatches + '; HTTPS: ' + [bool]$localHealth + '; survival verification: ' + $(if ($BeginObservation -or $ConfirmObservation) { [string]$survivalVerified } else { 'NotRequested' }))
Write-Output ('Observation: ' + $confirmationReason + '; route: ' + $route)
Write-Output 'Actual model generation and application environment adoption remain NotTested. No authentication files, tokens or model payloads were collected.'
if ($failure) { throw $failure }
