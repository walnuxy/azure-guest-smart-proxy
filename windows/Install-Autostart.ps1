#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Remove)
. (Join-Path $PSScriptRoot 'scripts/Common.ps1')
$startupFolder = [Environment]::GetFolderPath('Startup')
if (!$startupFolder -or !(Test-Path -LiteralPath $startupFolder)) { throw 'Current-user Startup folder is unavailable.' }
$shortcutPath = Join-Path $startupFolder 'Codex Azure Guest Proxy.lnk'
$startScript = Join-Path $PSScriptRoot 'Start-GuestProxy.ps1'
$shell = New-Object -ComObject WScript.Shell
if (Test-Path -LiteralPath $shortcutPath) {
    $existing = $shell.CreateShortcut($shortcutPath)
    if (!$existing.Arguments.Contains($startScript)) { throw 'The Startup shortcut name belongs to another package location. Review it before replacing or removing it.' }
}
if ($Remove) {
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
    Write-Output 'This package current-user login shortcut was removed; other startup entries were not changed.'
    return
}
$deploymentPath = Join-Path $script:StateRoot 'deployment.json'
if (!(Test-Path -LiteralPath $deploymentPath)) { throw 'Inspect and configure on this computer before installing login startup.' }
$deployment = Read-JsonFile $deploymentPath
if ($deployment.ComputerName -ne $env:COMPUTERNAME) { throw 'Deployment belongs to another computer; inspect and configure locally.' }
$verifiedCore = Get-CorePath
if ($verifiedCore -ne $deployment.CorePath -or (Get-FileHash -LiteralPath $verifiedCore -Algorithm SHA256).Hash -ne $deployment.CoreSha256) { throw 'Core identity changed; reconfigure before installing startup.' }
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$shortcut.Arguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $startScript + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Start only the local guest smart proxy after this user signs in.'
$shortcut.WindowStyle = 7
$shortcut.Save()
Write-Output 'Current-user login startup installed. No administrator privilege, Windows service or system-wide startup entry was used.'
Write-Output 'Keep this package at its current path. Undo with Install-Autostart.ps1 -Remove.'
