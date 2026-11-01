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
if (!$Apply) { Write-Output 'Preview only. After inspection and authorization, use -Apply. Existing Codex must then be restarted by the user.'; return }
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
    $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
    $lines = @(Get-Content -LiteralPath $envPath -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*(?:export\s+)?(?:HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|NODE_USE_ENV_PROXY)\s*=' })
}
$lines += @(('HTTP_PROXY=' + $uri), ('HTTPS_PROXY=' + $uri), ('ALL_PROXY=' + $uri), 'NO_PROXY=127.0.0.1,localhost', 'NODE_USE_ENV_PROXY=1')
[IO.File]::WriteAllLines($envPath, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
Protect-PrivateFile $envPath
Write-JsonFile ([ordered]@{ AppliedUtc = [DateTime]::UtcNow.ToString('o'); CodexHome = $CodexHome; EnvPath = $envPath; Backup = $backup; BackupSha256 = $backupHash; AppliedEnvHash = (Get-FileHash -LiteralPath $envPath -Algorithm SHA256).Hash; Entry = $uri }) (Join-Path $script:StateRoot 'codex-integration.json')
Write-Output 'Codex .env updated with backup. No running process was terminated; no system/user global environment variables or registry settings were changed.'
Write-Output 'Restart Codex, verify the effective environment, then test a real authenticated model request. Preserve the original proxies as fallback software.'
