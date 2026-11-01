#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ExecutablePath,[switch]$ChromiumProxySwitch,[string]$Destination='')
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
Ensure-StateDirectory
$deployment = Read-JsonFile (Join-Path $script:StateRoot 'deployment.json')
if (!(Test-Path -LiteralPath $ExecutablePath -PathType Leaf) -or [IO.Path]::GetExtension($ExecutablePath) -ne '.exe') { throw 'Supply the actual inspected Win32 desktop executable, not an app-server command.' }
$path = (Resolve-Path -LiteralPath $ExecutablePath).Path
if (!$Destination) { $Destination=[Environment]::GetFolderPath('Desktop') }
if (!(Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination | Out-Null }
$shell=New-Object -ComObject WScript.Shell
$targetScript=Join-Path $PSScriptRoot 'Launch-CodexWithProxy.ps1'
$linkPath=Join-Path $Destination 'Codex-SmartProxy.lnk'
$link=$shell.CreateShortcut($linkPath)
if ((Test-Path -LiteralPath $linkPath) -and !$link.Arguments.Contains($targetScript)) { throw 'Shortcut name belongs to another deployment.' }
Write-JsonFile ([ordered]@{ ExecutablePath=$path; ChromiumProxySwitch=[bool]$ChromiumProxySwitch; ConfiguredUtc=[DateTime]::UtcNow.ToString('o'); MixedPort=$deployment.MixedPort }) (Join-Path $script:StateRoot 'codex-launcher.json')
$link.TargetPath=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$link.Arguments='-NoProfile -ExecutionPolicy RemoteSigned -File "'+$targetScript+'"'
$link.WorkingDirectory=$PSScriptRoot
$link.Save()
Write-Output 'Launcher prepared. Fully exit the app and double-click the shortcut; do not restart the active desktop from its own agent command.'
Write-Output 'Use ChromiumProxySwitch only for an inspected Chromium/Electron client. No system proxy or global environment was changed.'
