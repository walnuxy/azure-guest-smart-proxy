#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Remove)
. (Join-Path $PSScriptRoot 'scripts/Lifecycle.ps1')
$startupFolder = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupFolder 'Codex Azure Guest Proxy.lnk'
$startScript = Join-Path $PSScriptRoot 'Start-GuestProxy.ps1'
$shell = New-Object -ComObject WScript.Shell
if (Test-Path -LiteralPath $shortcutPath) {
    $existing = $shell.CreateShortcut($shortcutPath)
    if (!$existing.Arguments.Contains($startScript)) { throw 'Startup shortcut belongs to another package path; refusing to replace it.' }
}
if ($Remove) {
    $task = Get-OwnGuestTask
    if ($task) { Unregister-ScheduledTask -TaskName $script:GuestTaskName -Confirm:$false -ErrorAction Stop }
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
    Write-Output 'This package login trigger/shortcut removed. Use Stop-GuestProxy.ps1 to persistently disable and stop current operation.'
    return
}
$deploymentPath = Join-Path $script:StateRoot 'deployment.json'
if (!(Test-Path -LiteralPath $deploymentPath)) { throw 'Inspect and configure on this computer first.' }
$deployment = Read-JsonFile $deploymentPath
if ($deployment.ComputerName -ne $env:COMPUTERNAME) { throw 'Deployment belongs to another computer.' }
$verifiedCore = Get-CorePath
if ($verifiedCore -ne $deployment.CorePath -or (Get-GuestFileHash -LiteralPath $verifiedCore -Algorithm SHA256).Hash -ne $deployment.CoreSha256) { throw 'Core identity changed; reconfigure before installing startup.' }
try {
    Register-GuestTask -AtLogon | Out-Null
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
    Write-Lifecycle @{ AutostartMethod = 'CurrentUserScheduledTask'; TaskName = $script:GuestTaskName }
    Write-Output 'Installed current-user Interactive/Limited logon task for the supervisor. No duplicate Startup shortcut or system service; task RunLevel is Limited and does not request elevation.'
} catch {
    if ($_.Exception.Message -match 'unrelated|principal differs|policy|blocked|AppLocker|not allowed') { throw 'Task conflict or explicit policy block; no alternate scheduler API or elevation was used.' }
    if (!$startupFolder -or !(Test-Path -LiteralPath $startupFolder)) { throw 'Current-user task unavailable and Startup folder unavailable.' }
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $script:PowerShellPath
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $startScript + '" -FromAutostart'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Description = 'Start the guest proxy lifecycle broker at user login; preserve explicit Stop.'
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    Write-Lifecycle @{ AutostartMethod = 'StartupBrokerFallback' }
    Write-Output 'Current-user scheduler unavailable; installed a Startup shortcut to the lifecycle broker, not bare Mihomo. Persistent independence still requires target-machine acceptance.'
}
Write-Output 'No persistent execution-policy change or system-proxy change was made. Undo with Install-Autostart.ps1 -Remove.'
