# Requires -Version 5.1
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$pidPath = Join-Path $script:StateRoot 'listener.json'
if (!(Test-Path -LiteralPath $pidPath)) { Write-Output 'No tracked guest listener.'; return }
$tracked = Read-JsonFile $pidPath
$owner = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $tracked.ListenerPid) -ErrorAction SilentlyContinue
if ($owner) {
    if ($owner.ExecutablePath -ne $tracked.CorePath -or !$owner.CommandLine.Contains($tracked.ConfigPath)) { throw 'PID was reused or belongs to another process; refusing to stop it.' }
    Stop-Process -Id $tracked.ListenerPid
}
Remove-Item -LiteralPath $pidPath
Write-Output 'Only the tracked guest proxy instance was stopped. Existing proxies and system settings were not changed.'
