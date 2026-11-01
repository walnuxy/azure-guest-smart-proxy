#Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$launch = Read-JsonFile (Join-Path $script:StateRoot 'codex-launcher.json')
$deployment = Read-JsonFile (Join-Path $script:StateRoot 'deployment.json')
if (!(Test-Path -LiteralPath $launch.ExecutablePath -PathType Leaf)) { throw 'The inspected desktop executable no longer exists.' }
$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -eq $launch.ExecutablePath })
if ($running.Count) { throw 'Fully exit the existing desktop application before using this launcher. Your current chat will not be terminated.' }
& (Join-Path $PSScriptRoot 'Start-GuestProxy.ps1')
$uri = 'http://127.0.0.1:' + $deployment.MixedPort
$health = Test-HttpsProxy $uri
if (!$health.Healthy) { throw 'The smart entry failed HTTPS verification; no desktop app was launched.' }
$life = Read-JsonFile (Join-Path $script:StateRoot 'lifecycle.json')
if ($life.Disabled -or !$life.RecoveryEnabled) { throw 'Supervised recovery is not active.' }
$names = @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','WS_PROXY','WSS_PROXY','NO_PROXY','NODE_USE_ENV_PROXY')
$saved = @{}
try {
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
    foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','WS_PROXY','WSS_PROXY')) { [Environment]::SetEnvironmentVariable($name,$uri,'Process') }
    [Environment]::SetEnvironmentVariable('NO_PROXY','127.0.0.1,localhost,::1','Process')
    [Environment]::SetEnvironmentVariable('NODE_USE_ENV_PROXY','1','Process')
    $parameters = @{ FilePath=$launch.ExecutablePath; PassThru=$true }
    if ($launch.ChromiumProxySwitch) { $parameters.ArgumentList = @('--proxy-server=' + $uri) }
    $process = Start-Process @parameters
    Write-Output ('Desktop process started with process-scoped proxy; PID ' + $process.Id + '.')
    Write-Output 'Send a real message and inspect actual process connections; launching does not prove application adoption.'
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
}
