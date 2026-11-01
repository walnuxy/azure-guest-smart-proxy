# Requires -Version 5.1
[CmdletBinding()]
param([switch]$Apply, [string]$CodexHome = '')
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
if (!$CodexHome) { $CodexHome = $env:CODEX_HOME }
if (!$CodexHome) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }
$deployment = Read-JsonFile (Join-Path $script:StateRoot 'deployment.json')
$uri = 'http://127.0.0.1:' + $deployment.MixedPort
Write-Output ('Proposed Codex home: ' + $CodexHome)
Write-Output ('Proposed HTTP_PROXY / HTTPS_PROXY / ALL_PROXY: ' + $uri)
Write-Output 'This applies only a local .env file, not every desktop or MCP process. The deploying Codex must first inspect the installed client version, launch environment and existing project/MCP overrides.'
if (!$Apply) { Write-Output 'Preview only. After supervised startup, recovery and survival acceptance, use -Apply. Restart the desktop app and verify a real model request afterward.'; return }
$readinessPath = Join-Path $script:StateRoot 'readiness.json'
$recoveryPath = Join-Path $script:StateRoot 'recovery-test.json'
$lifecyclePath = Join-Path $script:StateRoot 'lifecycle.json'
foreach ($required in @($readinessPath,$recoveryPath,$lifecyclePath)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) { throw 'Proxy readiness is incomplete. Run supervised Start, Test-Recovery, then BeginObservation and a later independent ConfirmObservation. Existing Codex settings were not changed.' }
}
$ready = Read-JsonFile $readinessPath
$recovery = Read-JsonFile $recoveryPath
$life = Read-JsonFile $lifecyclePath
$configHash = (Get-GuestFileHash -LiteralPath (Join-Path $script:StateRoot 'config.json') -Algorithm SHA256).Hash
$coreHash = (Get-GuestFileHash -LiteralPath $deployment.CorePath -Algorithm SHA256).Hash
if (!(Get-PropertyValue $ready 'SurvivalVerified' $false) -or !(Get-PropertyValue $ready 'LocalHealthPassed' $false) -or !(Get-PropertyValue $recovery 'Passed' $false)) { throw 'Recovery and independent-command survival have not both passed. Existing Codex settings were not changed.' }
foreach ($evidence in @($ready,$recovery)) {
    if ($evidence.ComputerName -ne $env:COMPUTERNAME -or $evidence.ConfigSha256 -ne $configHash -or $evidence.CoreSha256 -ne $coreHash -or [int]$evidence.SupervisorPid -ne [int]$life.SupervisorPid) { throw 'Readiness evidence belongs to an older/different configuration or supervisor. Repeat acceptance before integration.' }
}
if ($life.Disabled -or !$life.RecoveryEnabled -or [int]$ready.VerifiedCorePid -ne [int]$life.CorePid -or [int]$ready.MixedPort -ne [int]$deployment.MixedPort -or [int]$ready.ApiPort -ne [int]$deployment.ApiPort) { throw 'The accepted local instance changed or stopped. Repeat acceptance before integration.' }
if (([DateTime]::UtcNow - [DateTime]::Parse($ready.ConfirmedUtc).ToUniversalTime()).TotalMinutes -gt 30 -or [DateTime]::Parse($ready.ConfirmedUtc) -lt [DateTime]::Parse($recovery.CompletedUtc)) { throw 'Acceptance is stale or predates recovery. Repeat BeginObservation and ConfirmObservation.' }
$supervisorProcess = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$life.SupervisorPid) -ErrorAction SilentlyContinue
$supervisorScript = Join-Path $PSScriptRoot 'Supervise-GuestProxy.ps1'
if (!$supervisorProcess -or !$supervisorProcess.CommandLine -or !$supervisorProcess.CommandLine.Contains($supervisorScript) -or ([DateTime]::UtcNow - [DateTime]::Parse($life.LastHeartbeatUtc).ToUniversalTime()).TotalSeconds -gt 60) { throw 'The accepted supervisor is no longer healthy. Existing Codex settings were not changed.' }
$ownedListeners = @(Get-Listeners | Where-Object { $_.OwningProcess -eq [int]$life.CorePid -and $_.LocalPort -in @([int]$deployment.MixedPort,[int]$deployment.ApiPort) })
if (@($ownedListeners.LocalPort | Select-Object -Unique).Count -ne 2) { throw 'The accepted core no longer owns both local ports. Existing Codex settings were not changed.' }
$null = Invoke-GuestApi '/version' -TimeoutSec 3
$health = Test-HttpsProxy $uri
if (!$health.Healthy) { throw 'Refusing integration: guest local entry failed the actual OpenAI HTTPS check.' }
if (!(Test-Path -LiteralPath $CodexHome)) { New-Item -ItemType Directory -Path $CodexHome | Out-Null }
$envPath = Join-Path $CodexHome '.env'
$backup = ''
$backupHash = ''
$lines = @()
if (Test-Path -LiteralPath $envPath) {
    $backup = $envPath + '.before-guest-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $envPath -Destination $backup
    Protect-PrivateFile $backup
    $backupHash = (Get-GuestFileHash -LiteralPath $backup -Algorithm SHA256).Hash
    $lines = @(Get-Content -LiteralPath $envPath -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*(?:export\s+)?(?:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|WS_PROXY|WSS_PROXY|NODE_USE_ENV_PROXY)\s*=' })
}
$lines += @(('HTTP_PROXY=' + $uri), ('HTTPS_PROXY=' + $uri), ('ALL_PROXY=' + $uri), ('WS_PROXY=' + $uri), ('WSS_PROXY=' + $uri), 'NO_PROXY=127.0.0.1,localhost,::1', 'NODE_USE_ENV_PROXY=1')
[IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
Protect-PrivateFile $envPath
Write-JsonFile ([ordered]@{ VerificationState = 'PendingDesktopRestartAndRealModelRequest'; ProcessEnvironmentGuaranteed = $false; SupervisedRecoveryVerified = $true; AppliedUtc = [DateTime]::UtcNow.ToString('o'); CodexHome = $CodexHome; EnvPath = $envPath; Backup = $backup; BackupSha256 = $backupHash; AppliedEnvHash = (Get-GuestFileHash -LiteralPath $envPath -Algorithm SHA256).Hash; Entry = $uri }) (Join-Path $script:StateRoot 'codex-integration.json')
Write-Output 'Codex .env updated with backup. No running process was terminated; no system/user global environment variables or registry settings were changed.'
Write-Output 'Desktop environment adoption and real model generation are NOT yet verified. Fully exit the app, launch it with the inspected process-scoped proxy launcher if needed, capture actual process paths/connections, and send a real message. Do not declare deployment complete from this script or HTTP200.'
